# SafeLine CE on Kubernetes — APISIX data plane

This directory contains everything you need to put Apache APISIX in front of
the SafeLine detector on Kubernetes, using the **official first-party
`chaitin-waf` plugin** that ships in the Apache APISIX plugin hub. No custom
SDK or controller image is required.

The full design rationale lives in
`docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md`. This file
is the operational quick-start.

## 30-second quick start

```bash
# 0. Deploy the control plane (detector, mgt, pg, luigi, fvm, chaos, mcp)
#    from k8s/README.md sections 3-8. The detector Service must be on
#    TCP/8000 (not unix socket); section 5 of k8s/README.md shows how.

# 1. Install APISIX + the ingress controller + etcd in one go.
helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update
helm install apisix apisix/apisix \
  --namespace ingress-apisix --create-namespace \
  --version 0.16.0 \
  -f k8s/apisix-controller/helm-values.yaml

# 2. Wait for pods to be Ready.
kubectl -n ingress-apisix wait --for=condition=ready pod -l app.kubernetes.io/name=apisix --timeout=300s
kubectl -n ingress-apisix wait --for=condition=ready pod -l app.kubernetes.io/name=apisix-etcd --timeout=300s
kubectl -n ingress-apisix wait --for=condition=ready pod -l app.kubernetes.io/name=apisix-ingress-controller --timeout=300s

# 3. Deploy the demo app to verify the WAF is wired up.
kubectl apply -f k8s/apisix-controller/example-app.yaml

# 4. Smoke tests.
#    Point demo.example.com at the APISIX LoadBalancer, then:
curl -i "http://demo.example.com/"            # expect 200 OK
curl -i "http://demo.example.com/?id=1' OR '1'='1"   # expect 403 + JSON body

# 5. Attach WAF to your real Ingress(es).
#    Copy a template, edit it, and apply:
cp k8s/apisix-controller/waf-plugin.yaml waf-my-app.yaml
#    Edit waf-my-app.yaml: uncomment the block you want (monitor / block
#    / off), and update the three marked lines: `metadata.name`,
#    `metadata.namespace`, and `spec.ingressRefs[0].name`.
kubectl apply -f waf-my-app.yaml
```

## What's in this directory

| File | What it is |
| --- | --- |
| `helm-values.yaml` | Helm values for the `apisix` and `apisix-ingress-controller` charts. Carries the WAF plugin metadata (node list, cluster-wide defaults). |
| `waf-plugin.yaml` | `ApisixPlugin` templates for `monitor` / `block` / `off` modes. |
| `example-app.yaml` | A minimal nginx demo + Ingress + `ApisixPlugin` to verify the WAF. |
| `upgrade-from-ingress-nginx.md` | Step-by-step migration guide if you are moving off ingress-nginx. |

## How the WAF fits in

```
client -> cloud LB -> apisix-gateway Service (LoadBalancer)
                            |
                            |  chaitin-waf plugin (built-in)
                            |     metadata: detector address + cluster defaults (from helm-values.yaml)
                            |     per-route config: mode/match/headers (from ApisixPlugin CRD)
                            |
                            +-> safeline-detect Service :8000 (T1K)
                            +-> your upstream Service
```

The plugin is fail-open by default: if the detector is unreachable, the
request is forwarded to the upstream and a `X-APISIX-CHAITIN-WAF: unhealthy`
header is set. To fail-closed would require a custom plugin — out of scope
for this directory.

## Modes

| Mode | Behavior | When to use |
| --- | --- | --- |
| `off` | Plugin disabled. Request forwarded. | Internal-only routes; routes with binary traffic that confuses the detector. |
| `monitor` | Plugin enabled; matches are logged, request forwarded. | Canaries; newly added Ingresses; first >= 48 hours after attach. |
| `block` | Plugin enabled; matches return 403 + JSON body. | Production enforcement, only after monitor has been clean for >= 48 hours. |

The cluster-wide default is set in `helm-values.yaml` under
`apisix.set.plugin_attr.chaitin-waf.mode`; an `ApisixPlugin` can override
it per-Ingress.

## Verification

```bash
# Pods healthy.
kubectl -n safeline-ce get pods
kubectl -n ingress-apisix get pods

# APISIX can reach the detector.
kubectl -n ingress-apisix exec -it deploy/apisix -- \
  nc -zv safeline-detect.safeline-ce.svc.cluster.local 8000
# Expected: safeline-detect.safeline-ce.svc.cluster.local (172.x.x.x:8000) open

# Routes reconciled.
kubectl -n ingress-apisix get apisixroutes

# SQL injection blocked.
curl -i "http://demo.example.com/?id=1' OR '1'='1"
# Expected: 403 + body {"code":403,"success":false,"message":"blocked by Chaitin SafeLine Web Application Firewall",...}
# Headers: X-APISIX-CHAITIN-WAF-ACTION: reject
#          X-APISIX-CHAITIN-WAF-STATUS: 403
#          X-APISIX-CHAITIN-WAF-SERVER: <detector address>

# Real client IP visible in mgt.
# Open the mgt UI (port 1443 of safeline-mgt), navigate to Attack Logs,
# and confirm src_ip is the real client address (not the LB IP).
```

## Troubleshooting

- **All requests pass through with `X-APISIX-CHAITIN-WAF: unhealthy`.** The
  detector is unreachable from the APISIX pods. Check
  `apisix.set.plugin_attr.chaitin-waf.nodes` in `helm-values.yaml` matches
  the actual `safeline-detect` Service DNS name.

- **All requests pass through with `X-APISIX-CHAITIN-WAF: no`.** The plugin
  is enabled in the chart but the `ApisixPlugin` for the route is missing
  or has `enable: false`. Re-check the per-Ingress ApisixPlugin.

- **WAF blocks legitimate traffic.** Switch the route's `mode` to
  `monitor` to see what's being flagged (the mgt UI shows the rule that
  fired). Add a rule exemption in the mgt UI's policy editor, then flip
  back to `block`.

- **mgt UI is blocked / slow.** Make sure the mgt Ingress does **not** have
  an `ApisixPlugin` with `chaitin-waf` attached, or use a separate
  IngressClass for operator traffic.

- **`src_ip` in mgt logs is the LB IP, not the client.** Either
  `real_client_ip: true` is missing from the plugin metadata, or the LB
  CIDR is not in `apisix.trusted_addresses`. Update `helm-values.yaml` and
  `helm upgrade`.

## Versions

- `apache/apisix:3.16.0` (includes `chaitin-waf` plugin)
- `apache/apisix-ingress-controller:1.10.0`
- `bitnami/etcd:3.5` (sub-chart)

Bump in lockstep with `version.json` at release time. The chaitin-waf
plugin is upstream; the SafeLine release cycle is decoupled from the
APISIX release cycle.

## Companion documents

- `docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md` — design rationale
- `k8s/README.md` sections 3-8 — control plane (detector, mgt, pg, luigi, fvm, chaos, mcp)
- `k8s/README.md` section 9 — legacy ingress-nginx setup (deprecated)
- `k8s/apisix-controller/upgrade-from-ingress-nginx.md` — migration playbook
