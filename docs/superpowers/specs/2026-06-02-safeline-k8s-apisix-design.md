# SafeLine CE on Kubernetes — APISIX data plane (design)

**Date:** 2026-06-02
**Status:** implemented (2026-06). The scaffolding and validation work
described below is committed; see `k8s/apisix-controller/README.md` for
the up-to-date operational quick-start and `k8s/apisix-controller/tier3-test/`
for the working manifests (the only place the SafeLine control-plane yaml
lives now — the old `k8s/README.md` has been removed).

## Why

`ingress-nginx` was officially retired by Kubernetes SIG Network on 2025-11-11
and best-effort maintenance ended in March 2026. New k8s data-plane work in this
repo should target APISIX, which is actively maintained, built on OpenResty (so
`sdk/lua-resty-t1k` is reusable as-is), and has an official ingress controller
(`apisix-ingress-controller`).

Apache APISIX also ships a **first-party `chaitin-waf` plugin** in its plugin
hub, maintained upstream by the APISIX project in collaboration with Chaitin.
This means we ship **no new SDK code** — the plugin is already loaded into the
official `apache/apisix` Docker image and the official Helm chart.

## Goals / non-goals

Goals:
- Replace ingress-nginx + custom `sdk/ingress-nginx` plugin with APISIX + built-in
  `chaitin-waf` plugin.
- Reuse the existing SafeLine control-plane manifests (now living in
  `k8s/apisix-controller/tier3-test/`) verbatim.
- End state: a `k8s/apisix-controller/` directory with helm values,
  ApisixPlugin examples, demo app, and a short migration doc.
- Match the APISIX project's idiomatic patterns: ApisixPlugin CRD for per-route
  opt-in, helm chart values for cluster-wide plugin metadata.

Non-goals:
- Custom Lua plugin. The built-in `chaitin-waf` plugin is sufficient; we are not
  shipping `sdk/ingress-nginx` analog for APISIX.
- Changes to `sdk/lua-resty-t1k/`. It remains the portable core.
- Multi-tenant or multi-cluster WAF orchestration. Out of scope for v1.
- East-west (service-to-service) traffic. APISIX is the north-south data plane;
  service mesh or sidecar is a separate workstream.

## Architecture

```
Internet
   │
   ▼
[Cloud LB / NodePort :80/:443]
   │
   ▼
[Apache APISIX Pods (2+) — service: apisix-gateway, type LoadBalancer]
   │  ├─ built-in chaitin-waf plugin (loaded by chart, not custom)
   │  ├─ plugin metadata (WAF node list, defaults) via chart values
   │  └─ ApisixPlugin CRD per Ingress selects which routes get WAF
   │
   ├─ T1K (TCP/8000) ─→ [safeline-detect Service] ─→ [safeline-detect Pod]
   │                                              ↑
   └─ HTTP ──→ [应用 Service] ──→ [应用 Pod]          │
                                                    │
[运维 / API] ──→ [safeline-mgt Service :1443] ──────┘
                       │
                       ├─→ [safeline-pg (StatefulSet)]
                       ├─→ [safeline-fvm]
                       └─→ [safeline-luigi]
[可选] [mcp_server Pod] ──→ [safeline-mgt Service :1443]
```

## Components

| Component | Kind | Replicas | Image / chart | Source |
| --- | --- | --- | --- | --- |
| `safeline-pg` | StatefulSet | 1 | `chaitin/safeline-postgres:15.2` | unchanged |
| `safeline-detect` | Deployment | 1 | `chaitin/safeline-detector:<ver>` | unchanged (TCP/8000 mode) |
| `safeline-mgt` | Deployment | 1 | `chaitin/safeline-mgt:<ver>` | unchanged |
| `safeline-fvm` | Deployment | 1 | `chaitin/safeline-fvm:<ver>` | unchanged |
| `safeline-luigi` | Deployment | 1 | `chaitin/safeline-luigi:<ver>` | unchanged |
| `safeline-chaos` | Deployment | 1 | `chaitin/safeline-chaos:<ver>` | unchanged |
| `safeline-mcp` | Deployment | 0..1 | `chaitin/safeline-mcp:latest` | unchanged |
| `apisix` (gateway) | Deployment/DS | 2+ | `apache/apisix:3.16.0` from `apisix` chart | **new** |
| `apisix-ingress-controller` | Deployment | 2 | `apache/apisix-ingress-controller:1.10.0` from `apisix-ingress-controller` chart | **new** |
| `apisix-etcd` | StatefulSet | 3 | `bitnami/etcd:3.5` (sub-chart) | **new** |

APISIX and `apisix-ingress-controller` charts are both published from the same
project (`https://apache.github.io/apisix-helm-chart`).

## Plugin configuration model

The APISIX `chaitin-waf` plugin has three configuration layers, and we map them
to k8s resources deliberately. Conflating them is the easiest way to ship a
broken WAF, so this section is intentionally explicit.

1. **Plugin metadata** (cluster-wide, required): the WAF node list. The
   `chaitin-waf` plugin has no built-in discovery; if `nodes` is unset, every
   WAF check fails open. In APISIX, plugin metadata is set via
   `plugin_attr.<name>` in `conf/config.yaml`. The Helm chart exposes this as
   `apisix.set.plugin_attr.chaitin-waf` (or `apisix.pluginAttr` in newer
   chart versions — implementation phase will pin the right key).
2. **Per-route plugin config** (applies to a specific Ingress): `mode`,
   `match`, `append_waf_resp_header`, `append_waf_debug_header`, `config.*`.
   This is what the `ApisixPlugin` CRD carries. It overrides the metadata
   defaults.
3. **Cluster-wide per-route config** (applies to all routes): same as #2 but
   via `ApisixGlobalRule`. **We do not use this** for the WAF, because it
   would also apply to the mgt control-panel Ingress and block operator
   access to its own console.

| Setting | Lives in | Why |
| --- | --- | --- |
| `nodes` (WAF addresses) | Helm value (`set.plugin_attr.chaitin-waf`) | Required; only changes with the SafeLine release / cluster rename |
| `mode` default | Helm value (plugin metadata) | Set once per cluster; rarely changes |
| `append_waf_resp_header` | Helm value (plugin metadata) | Set once per cluster |
| `append_waf_debug_header` | Helm value (plugin metadata) | Set once per cluster (off in production) |
| `config.connect_timeout` / `send_timeout` / `read_timeout` | Helm value (plugin metadata) | Set once per cluster |
| `config.req_body_size` | Helm value (plugin metadata) | Set once per cluster |
| `config.keepalive_size` / `keepalive_timeout` | Helm value (plugin metadata) | Set once per cluster |
| `config.real_client_ip` | Helm value (plugin metadata) | Critical — `true` to honor `X-Forwarded-For` |
| `match` (per-route var filters) | `ApisixPlugin` | Per-route, rare |
| `mode` override per route | `ApisixPlugin` | Allow a specific Ingress to enforce `block` while cluster default is `monitor` |

## Failure modes

- **Detector down:** APISIX plugin returns `X-APISIX-CHAITIN-WAF: unhealthy`
  header and **fails open** (request forwarded to upstream). Same default
  behavior as the ingress-nginx + t1k plugin. To fail closed, a custom plugin
  would be needed — out of scope.
- **APISIX pod down:** `replicaCount >= 2` behind LoadBalancer; the ingress
  controller reconciles routes to healthy pods.
- **etcd down:** APISIX can serve traffic with cached config for a short
  window; new route updates block until etcd recovers. 3-replica etcd gives us
  quorum-1 failure tolerance.
- **Mgt UI access:** expose `safeline-mgt` via a separate Ingress with its own
  IngressClass and **no** `chaitin-waf` plugin, or via NodePort. Do not let the
  WAF block operator access to its own management console.

## Data flow (WAF hot path)

1. Client → cloud LB → `apisix-gateway` Service → APISIX Pod.
2. APISIX matches the request to a route, translated from an `Ingress` by
   `apisix-ingress-controller`.
3. If the route has an `ApisixPlugin` with `chaitin-waf.enabled=true`, APISIX
   runs the plugin's `rewrite` phase:
   - Reads plugin metadata (set via the chart's `set.plugin_attr.chaitin-waf`
     value) for the WAF node list
     (`safeline-detect.safeline-ce.svc.cluster.local:8000`).
   - Opens a T1K connection to detector, sends method / URI / headers / body /
     client IP (from `X-Forwarded-For` first hop when `real_client_ip=true`).
   - Detector returns `pass` or `reject` (HTTP-style verdict, not a TCP stream).
4. On `pass`: APISIX forwards to the upstream Service and copies the response.
5. On `reject`: APISIX short-circuits with `403` + JSON
   `{"code":403,"success":false,"message":"blocked by Chaitin SafeLine Web Application Firewall","event_id":"..."}`,
   and the `X-APISIX-CHAITIN-WAF*` debug headers when configured.
6. Mgt console (port 1443, exposed separately) reads attack events from the
   detector's T1K log and renders them in the UI. MCP server is unchanged.

## Repository changes (as actually shipped)

### New directory: `k8s/apisix-controller/`

Contents:

| File | Purpose |
| --- | --- |
| `README.md` | Operational quick-start (this doc, condensed and updated) |
| `helm-values.yaml` | Recommended values for the `apisix` and `apisix-ingress-controller` charts (carries the plugin metadata, including the WAF node list) |
| `waf-plugin.yaml` | `ApisixPlugin` templates for `monitor` / `block` / `off` modes |
| `example-app.yaml` | Demo `nginx` app + `Ingress` + `ApisixPlugin` to verify WAF |
| `waf-plugin-metadata.json` | Body for the `PUT /apisix/admin/plugin_metadata/chaitin-waf` call (chart's `pluginAttrs` is silently ignored by chaitin-waf, this is the real config) |
| `upgrade-from-ingress-nginx.md` | Step-by-step migration from a running ingress-nginx + t1k setup |
| `tier3-test/` | Working manifests for the full SafeLine stack on k8s (control plane + APISIX data plane), validated on arm64 OrbStack |

### Removed

- `k8s/t1k-controller/` — the build harness for the legacy `safeline-t1k-controller`
  container image is gone. The `sdk/ingress-nginx/` rockspec stays in the tree
  for the rare case someone still runs ingress-nginx; the upstream image
  receives no security patches and the local build path is no longer wired.
- `k8s/README.md` — the old top-level k8s deployment doc. The SafeLine
  control-plane yaml that used to live in its §3–§8 has been consolidated into
  `k8s/apisix-controller/tier3-test/` (production = amd64, drop the arm64
  qemu hacks).

### Unchanged

- `sdk/lua-resty-t1k/`
- `sdk/kong/`, `sdk/traefik-safeline/`
- `sdk/ingress-nginx/` (frozen, not removed)
- `compose.yaml`
- `scripts/manage.py`
- `management/`, `mcp_server/`, `yanshi/`

## File contents (sketch — full versions in implementation phase)

### `k8s/apisix-controller/helm-values.yaml`

```yaml
apisix:
  replicaCount: 2
  image:
    repository: apache/apisix
    tag: 3.16.0
  service:
    type: LoadBalancer
  # The chart ships with the chaitin-waf plugin enabled. We pin the plugin
  # metadata (WAF node list + cluster-wide defaults) here. The exact key
  # is `set.plugin_attr.chaitin-waf` in the v2.x chart; later chart
  # versions may rename to `pluginAttr`. Implementation phase will pin.
  set:
    plugin_attr:
      chaitin-waf:
        nodes:
          - host: safeline-detect.safeline-ce.svc.cluster.local
            port: 8000
        mode: monitor
        config:
          connect_timeout: 1000
          send_timeout: 1000
          read_timeout: 1000
          req_body_size: 1024
          keepalive_size: 256
          keepalive_timeout: 60000
          real_client_ip: true

etcd:
  replicaCount: 3
  auth:
    rbac:
      rootPassword: <from secret>

apisix-ingress-controller:
  config:
    apisix:
      serviceNamespace: ingress-apisix
```

### `k8s/apisix-controller/waf-plugin.yaml`

Three example ApisixPlugin templates (one per mode). Users copy the block
matching their policy into their app's namespace:

```yaml
apiVersion: apisix.apache.org/v1alpha1
kind: ApisixPlugin
metadata:
  name: waf-monitor
spec:
  ingressRefs:
    - name: my-app
  plugins:
    - name: chaitin-waf
      enable: true
      config:
        mode: monitor
        append_waf_resp_header: true
        append_waf_debug_header: true
```

`mode: off` produces the "skip WAF for this Ingress" escape hatch, replacing
ingress-nginx's `safeline.nginx.org/disable: "true"` annotation.

## Migration from ingress-nginx

1. Install APISIX and the ingress controller alongside the existing
   ingress-nginx setup. Detector / mgt / pg / luigi / fvm / chaos are untouched.
2. The WAF node list comes from the chart values; `helm install` registers it.
3. Migrate one canary Ingress first: create an `ApisixPlugin` with `mode: monitor`
   pointing at the same upstream; point a test DNS record at the APISIX
   LoadBalancer; run smoke tests (curl a known-bad payload, check mgt attack
   log).
4. Once clean for ≥48 hours, flip the canary to `mode: block` and migrate the
   rest of the Ingresses in batches.
5. Remove the ingress-nginx helm release. The `k8s/t1k-controller/` build
   harness and `safeline-t1k-controller` image have already been removed from
   this repo; no further cleanup is needed there.

`k8s/apisix-controller/upgrade-from-ingress-nginx.md` carries the full
playbook, including the gotchas (controller duplication, dangling
annotations, default-backend conflicts).

## Testing & verification

1. Pods all ready: `kubectl -n safeline-ce get pods` and
   `kubectl -n ingress-apisix get pods`.
2. APISIX routes reconciled: `kubectl -n ingress-apisix get apisixroutes` or
   `curl http://<apisix-admin>:9180/apisix/admin/routes -H 'X-API-KEY: ...'`.
3. Detector reachable from APISIX: `kubectl -n ingress-apisix exec -it
   <apisix-pod> -- nc -zv safeline-detect.safeline-ce.svc.cluster.local 8000`.
4. SQLi blocked:
   `curl -i 'http://demo.example.com/?id=1%27%20OR%20%271%27%3D%271'`
   → 403 + JSON body, headers `X-APISIX-CHAITIN-WAF-ACTION: reject` and
   `X-APISIX-CHAITIN-WAF-STATUS: 403`.
5. Real client IP visible in mgt: from the mgt UI's attack log, check
   `src_ip` matches the client (not the LB IP). Verify with
   `X-APISIX-CHAITIN-WAF-SERVER` debug header.
6. Monitor mode produces 200 + a log line in mgt instead of a 403.

## Operational notes

- **Upgrades:** `helm upgrade apisix apisix/apisix --reuse-values` for the
  gateway; same for the ingress controller. APISIX hot-reloads plugin config
  changes; chart value changes (e.g. replicas) need a pod restart.
- **Trust chain:** APISIX must be configured to trust `X-Forwarded-For` from
  the LB (`nginx.http.serverConfigurationOption.trustedAddress` or chart
  equivalent). The mgt control panel (separate Ingress with no WAF plugin) is
  the canonical place to read attack logs.
- **Backups:** pg PVC snapshots; SafeLine rule data lives in pg.
- **Capacity:** `requests: { cpu: 500m, memory: 1Gi }` for mgt / detector;
  APISIX gateway `requests: { cpu: 1, memory: 512Mi }` and `replicas: 2+`.
- **Pinned versions:** `apache/apisix:3.16.0` and
  `apache/apisix-ingress-controller:1.10.0` at launch. Bump in step with
  `version.json` when cutting SafeLine releases.

## Out of scope

- No `hostNetwork: true` on the data plane.
- No unix-socket detector (cross-Pod doesn't work; use TCP/8000).
- No multi-replica detector (SafeLine detector is single-instance by design).
- No splitting mgt / detector / luigi / fvm / chaos across multiple namespaces.
- No WAF plugin on the mgt Ingress.

## Risks

- **APISIX upstream changes:** the `chaitin-waf` plugin is in APISIX plugin
  hub. The CRD shape (`ApisixPlugin` v1alpha1 → v2) and the chart's
  `set` schema for plugin defaults have changed between minor versions. We
  pin to a specific chart version and document the upgrade path in
  `upgrade-from-ingress-nginx.md`.
- **`real_client_ip` misconfiguration:** if the LB is not in
  `apisix.trusted_addresses`, APISIX overrides `X-Forwarded-For` and
  downstream IP-based rules see the wrong address. This is the single most
  common WAF misconfiguration in any data plane; we call it out in the README.
- **Plugin metadata drift:** if `safeline-detect` Service is renamed, the
  chart's `plugin_attr.chaitin-waf.nodes` keeps the old name and silently
  fails open. The upgrade doc includes a "renaming check" step.
