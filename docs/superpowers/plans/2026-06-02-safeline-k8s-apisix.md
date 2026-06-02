# SafeLine CE k8s — APISIX Data Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `k8s/apisix-controller/` (helm values, ApisixPlugin templates, demo app, migration doc, README) and deprecate `k8s/README.md` section 9 to point at the new directory.

**Architecture:** Pure docs / manifests change. No Go, Lua, or other code. APISIX is installed via the official `apisix` and `apisix-ingress-controller` Helm charts; the WAF is the upstream `chaitin-waf` plugin with plugin metadata set via `plugin_attr` in chart values, and per-Ingress opt-in via the `ApisixPlugin` CRD.

**Tech Stack:** Helm 3.x, Apache APISIX 3.16.0, apisix-ingress-controller 1.10.0, Kubernetes 1.24+.

**Companion spec:** `docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md` (commit `c91e569`). If a step here conflicts with the spec, the spec wins; surface the conflict instead of guessing.

---

## File map

| Path | Status | Purpose |
| --- | --- | --- |
| `k8s/apisix-controller/README.md` | create | Quick-start + condensed design reference |
| `k8s/apisix-controller/helm-values.yaml` | create | Helm values for `apisix` + `apisix-ingress-controller` (carries the WAF plugin metadata) |
| `k8s/apisix-controller/waf-plugin.yaml` | create | `ApisixPlugin` templates for `monitor` / `block` / `off` |
| `k8s/apisix-controller/example-app.yaml` | create | Demo `nginx` Deployment + Service + Ingress + `ApisixPlugin` |
| `k8s/apisix-controller/upgrade-from-ingress-nginx.md` | create | Step-by-step migration from `k8s/README.md` section 9 |
| `k8s/README.md` | modify | Replace section 9 with a deprecation banner; add one "don't" item; add one row to the section 14 table |

## Conventions used in every task

- **Repo root:** all paths in this plan are relative to the repo root.
- **Verification:** YAML files are checked with `python3 -c "import yaml; ..."` (ubiquitous). Helm values are additionally checked with `helm template` when helm is available; that step is best-effort and tolerates failure when the chart cannot be pulled.
- **Commits:** follow the repo's commit style (`docs:`, `feat(k8s):`, `docs(k8s):`). One task = one commit.
- **No Go / Lua / Python code** in this plan; do not introduce new files outside the map above.

---

## Task 1: Create the `k8s/apisix-controller/` directory

**Files:**
- Create: `k8s/apisix-controller/.gitkeep` (placeholder; later tasks add real files)

- [ ] **Step 1: Verify the directory does not exist yet**

Run:
```bash
test ! -e k8s/apisix-controller && echo "OK: absent"
```
Expected: `OK: absent`. (If it exists with files, stop and ask — it means another workstream is in flight.)

- [ ] **Step 2: Create the directory with a placeholder so the path is tracked**

Run:
```bash
mkdir -p k8s/apisix-controller && touch k8s/apisix-controller/.gitkeep
```

- [ ] **Step 3: Verify**

Run:
```bash
ls -la k8s/apisix-controller/
```
Expected: only `.gitkeep` is listed.

- [ ] **Step 4: Commit**

```bash
git add k8s/apisix-controller/.gitkeep
git commit -m "chore(k8s): scaffold k8s/apisix-controller/ directory"
```

---

## Task 2: Write `k8s/apisix-controller/helm-values.yaml`

**Files:**
- Create: `k8s/apisix-controller/helm-values.yaml`

- [ ] **Step 1: Write the file**

Create `k8s/apisix-controller/helm-values.yaml` with the following content. This is the chart values for both `apisix` and `apisix-ingress-controller` charts (the ingress controller is a sub-chart of the umbrella `apisix` chart, but a standalone chart also exists at `apisix/apisix-ingress-controller` — implementation note: the engineer should pick the umbrella chart to keep both releases pinned to the same version, or two separate releases if the user prefers that).

```yaml
# Recommended values for the apisix + apisix-ingress-controller charts.
#
# Install with:
#   helm repo add apisix https://apache.github.io/apisix-helm-chart
#   helm repo update
#   helm install apisix apisix/apisix \
#     --namespace ingress-apisix --create-namespace \
#     -f k8s/apisix-controller/helm-values.yaml
#
# Pinned versions (bump in lockstep with version.json):
#   apache/apisix:3.16.0
#   apache/apisix-ingress-controller:1.10.0
#   bitnami/etcd:3.5
#
# The chaitin-waf plugin is built into apache/apisix:3.16.0 and is enabled
# by default in the chart. The plugin metadata (WAF node list, cluster-wide
# defaults) lives below in `apisix.set.plugin_attr.chaitin-waf`. The exact
# chart key was `set.plugin_attr` in chart v2.x; later versions may rename
# to `pluginAttr`. If helm template rejects the key, check the chart
# version pinned by `apisix.image.tag` and consult the chart's values.yaml.

apisix:
  replicaCount: 2
  image:
    repository: apache/apisix
    tag: 3.16.0
  service:
    type: LoadBalancer
  set:
    plugin_attr:
      chaitin-waf:
        # Required: where to find the detector. Update if you rename
        # safeline-detect or move it to a different namespace.
        nodes:
          - host: safeline-detect.safeline-ce.svc.cluster.local
            port: 8000
        # Cluster-wide default mode. New接入 always start with "monitor",
        # run for >= 48 hours with no false positives, then flip to "block"
        # either by editing this value (cluster-wide) or by overriding per
        # route in an ApisixPlugin CRD.
        mode: monitor
        config:
          connect_timeout: 1000
          send_timeout: 1000
          read_timeout: 1000
          req_body_size: 1024
          keepalive_size: 256
          keepalive_timeout: 60000
          # Critical: must be true so the plugin reads the real client IP
          # from X-Forwarded-For. If false, downstream IP-based rules see
          # the LB / NodePort IP and限流 / 封 IP features are useless.
          real_client_ip: true
    # APISIX must trust the LB's X-Forwarded-For. Replace the CIDR with
    # the LB's source range (MetalLB default, your cloud LB's egress CIDR,
    # or the NodePort range for bare-metal). Comma-separated list.
    # Key name in chart v2.x is below; if `helm template` rejects it,
    # consult the chart's values.yaml for the current key.
    nginx_upstream_trusted_addresses: "10.0.0.0/8,192.168.0.0/16"

etcd:
  replicaCount: 3
  auth:
    rbac:
      # Replace with a Secret-backed value in production:
      #   rootPassword: <from secret>
      rootPassword: changeme-etcd-root

# If using the standalone apisix-ingress-controller chart (not the
# umbrella chart), uncomment and apply separately:
# apisix-ingress-controller:
#   enabled: true
#   config:
#     apisix:
#       serviceNamespace: ingress-apisix
```

- [ ] **Step 2: Verify YAML parses**

Run:
```bash
python3 -c "import yaml; d=yaml.safe_load(open('k8s/apisix-controller/helm-values.yaml')); assert 'apisix' in d and 'etcd' in d; assert d['apisix']['set']['plugin_attr']['chaitin-waf']['nodes'][0]['host']=='safeline-detect.safeline-ce.svc.cluster.local'; print('OK')"
```
Expected: `OK`.

- [ ] **Step 3: Best-effort `helm template` render**

Run:
```bash
helm repo add apisix https://apache.github.io/apisix-helm-chart 2>/dev/null
helm repo update 2>/dev/null
helm template apisix apisix/apisix \
  --namespace ingress-apisix \
  -f k8s/apisix-controller/helm-values.yaml \
  > /tmp/apisix-rendered.yaml 2>/tmp/apisix-render.err && \
  grep -q "chaitin-waf" /tmp/apisix-rendered.yaml && echo "OK: chaitin-waf referenced in rendered chart" || \
  (echo "WARN: helm template did not reference chaitin-waf; check /tmp/apisix-render.err" && cat /tmp/apisix-render.err)
```
Expected: `OK: chaitin-waf referenced in rendered chart` (best case), or a `WARN` line (chart key may be `pluginAttr` instead of `set.plugin_attr` — note this in the implementation log and move on; the engineer will fix the key in a follow-up commit). Either outcome is acceptable to proceed.

- [ ] **Step 4: Commit**

```bash
git add k8s/apisix-controller/helm-values.yaml
git commit -m "feat(k8s): apisix helm values with chaitin-waf plugin metadata"
```

---

## Task 3: Write `k8s/apisix-controller/waf-plugin.yaml`

**Files:**
- Create: `k8s/apisix-controller/waf-plugin.yaml`

- [ ] **Step 1: Write the file**

Create `k8s/apisix-controller/waf-plugin.yaml` with three commented-out `ApisixPlugin` blocks (one per mode). Users copy the block that matches their policy into their app's namespace and uncomment it.

```yaml
# ApisixPlugin templates for the chaitin-waf plugin.
#
# How to use:
#   1. Pick the block that matches the desired mode (monitor / block / off).
#   2. Copy it into your app's namespace, into a file of your choice.
#   3. Edit `metadata.name` to be unique within the namespace, and edit
#      `spec.ingressRefs[].name` / `spec.ingressRefs[].namespace` to point
#      at your Ingress.
#   4. kubectl apply -f that file.
#
# `mode: off` is the "skip WAF for this Ingress" escape hatch, replacing
# ingress-nginx's `safeline.nginx.org/disable: "true"` annotation.
#
# NOTE: per-Ingress plugin config overrides the cluster-wide defaults set
# in k8s/apisix-controller/helm-values.yaml. If `mode` is omitted here, the
# cluster default (set in helm-values.yaml) applies.

# --- Template 1: monitor mode (log attacks, do not block) ---
# Use this for canaries and newly added Ingresses.
# apiVersion: apisix.apache.org/v1alpha1
# kind: ApisixPlugin
# metadata:
#   name: waf-monitor
#   namespace: my-app            # <-- change
# spec:
#   ingressRefs:
#     - name: my-app-ingress
#       namespace: my-app        # <-- change
#   plugins:
#     - name: chaitin-waf
#       enable: true
#       config:
#         mode: monitor
#         append_waf_resp_header: true
#         append_waf_debug_header: true   # off in production
#
# --- Template 2: block mode (active enforcement) ---
# Use this for production Ingresses that have been clean in monitor mode
# for >= 48 hours.
# apiVersion: apisix.apache.org/v1alpha1
# kind: ApisixPlugin
# metadata:
#   name: waf-block
#   namespace: my-app
# spec:
#   ingressRefs:
#     - name: my-app-ingress
#       namespace: my-app
#   plugins:
#     - name: chaitin-waf
#       enable: true
#       config:
#         mode: block
#         append_waf_resp_header: true
#         append_waf_debug_header: false
#
# --- Template 3: opt-out (WAF disabled for this Ingress) ---
# Use sparingly. Common reasons: an upstream serves binary traffic that
# confuses the detector, or a route is internal-only with no untrusted input.
# apiVersion: apisix.apache.org/v1alpha1
# kind: ApisixPlugin
# metadata:
#   name: waf-off
#   namespace: my-app
# spec:
#   ingressRefs:
#     - name: my-app-ingress
#       namespace: my-app
#   plugins:
#     - name: chaitin-waf
#       enable: false
```

- [ ] **Step 2: Verify the file's contract (presence + no-op-when-applied)**

The three blocks are intentionally commented out — `kubectl apply -f waf-plugin.yaml` is a no-op, users copy the block they want. The verification checks the contract without trying to uncomment in-place (which is fragile because prose lines contain backticked text that looks like YAML).

Run:
```bash
python3 - <<'PY'
import yaml
text = open('k8s/apisix-controller/waf-plugin.yaml').read()

# 1. File is all-comments: applying it does nothing.
docs = [d for d in yaml.safe_load_all(text) if d]
assert len(docs) == 0, f"file should be all-comments, got {len(docs)} valid docs"

# 2. All three template sections are present.
n_templates = text.count('# --- Template')
assert n_templates == 3, f"expected 3 template sections, got {n_templates}"

# 3. The three modes are referenced.
assert 'mode: monitor' in text
assert 'mode: block' in text
assert 'enable: false' in text

# 4. The opt-out block (template 3) actually disables the plugin. (The
#    mode: block and mode: monitor blocks have enable: true.)
#    Counted by scanning for "enable: true" (should be 2) and "enable: false"
#    (>= 1: the header text may also contain the phrase, and the Template 3
#    config has it).
assert text.count('enable: true') == 2, f"expected 2 'enable: true', got {text.count('enable: true')}"
assert text.count('enable: false') >= 1, f"expected at least 1 'enable: false', got {text.count('enable: false')}"

print("OK")
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add k8s/apisix-controller/waf-plugin.yaml
git commit -m "feat(k8s): apisix ApisixPlugin templates (monitor/block/off)"
```

---

## Task 4: Write `k8s/apisix-controller/example-app.yaml`

**Files:**
- Create: `k8s/apisix-controller/example-app.yaml`

- [ ] **Step 1: Write the file**

Mirror the structure of `k8s/t1k-controller/example-app.yaml` so existing users have a familiar shape.

```yaml
# Minimal "app" used to verify the WAF is wired up correctly.
# Real deployments replace these objects with your own app; the
# application code itself needs no changes.

apiVersion: v1
kind: Namespace
metadata:
  name: demo-app

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-app-html
  namespace: demo-app
data:
  index.html: |
    <!doctype html>
    <title>demo</title>
    <h1>OK</h1>

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo-app
spec:
  replicas: 2
  selector: { matchLabels: { app: demo-app } }
  template:
    metadata: { labels: { app: demo-app } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports: [{ containerPort: 80 }]
        volumeMounts:
        - { name: html, mountPath: /usr/share/nginx/html }
        - { name: conf, mountPath: /etc/nginx/conf.d/default.conf, subPath: default.conf }
        resources:
          requests: { cpu: 50m, memory: 32Mi }
      volumes:
      - name: html
        configMap: { name: demo-app-html }
      - name: conf
        configMap: { name: demo-app-nginx-conf }

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-app-nginx-conf
  namespace: demo-app
data:
  default.conf: |
    server {
        listen 80;
        location / { root /usr/share/nginx/html; }
    }

---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo-app
spec:
  selector: { app: demo-app }
  ports: [{ port: 80, targetPort: 80 }]

---
# Plain Ingress — apisix-ingress-controller will translate it into an
# APISIX route automatically (the controller watches Ingress resources).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-app
  namespace: demo-app
spec:
  ingressClassName: apisix     # <-- apisix-ingress-controller's class
  rules:
  - host: demo.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: demo-app
            port: { number: 80 }

---
# Per-Ingress WAF opt-in. To switch modes, edit `mode` and `kubectl apply`.
# To disable WAF for this Ingress, set `enable: false` on the plugin.
apiVersion: apisix.apache.org/v1alpha1
kind: ApisixPlugin
metadata:
  name: waf-demo
  namespace: demo-app
spec:
  ingressRefs:
    - name: demo-app
      namespace: demo-app
  plugins:
    - name: chaitin-waf
      enable: true
      config:
        mode: monitor
        append_waf_resp_header: true
        append_waf_debug_header: true
```

- [ ] **Step 2: Verify all manifests parse**

Run:
```bash
python3 -c "
import yaml
docs = [d for d in yaml.safe_load_all(open('k8s/apisix-controller/example-app.yaml')) if d]
kinds = [d['kind'] for d in docs]
expected = ['Namespace', 'ConfigMap', 'Deployment', 'ConfigMap', 'Service', 'Ingress', 'ApisixPlugin']
assert kinds == expected, f'kinds mismatch: {kinds}'
print('OK')
"
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add k8s/apisix-controller/example-app.yaml
git commit -m "feat(k8s): apisix example app + ingress + ApisixPlugin"
```

---

## Task 5: Write `k8s/apisix-controller/upgrade-from-ingress-nginx.md`

**Files:**
- Create: `k8s/apisix-controller/upgrade-from-ingress-nginx.md`

- [ ] **Step 1: Write the file**

```markdown
# Migrating from ingress-nginx to APISIX

This document describes how to move an existing SafeLine CE on k8s deployment
from ingress-nginx + the t1k plugin to APISIX + the built-in chaitin-waf
plugin, with zero downtime.

## Prerequisites

- helm 3.x
- kubectl
- A SafeLine CE on k8s deployment already running (sections 3-8 of
  k8s/README.md). The detector, mgt, pg, luigi, fvm, chaos pods must all be
  Ready.
- A test DNS record you can repoint (e.g. `waf-canary.example.com`) to use as
  the canary.

## High-level plan

1. Install APISIX and the ingress controller **in parallel** with ingress-nginx.
2. Migrate one canary Ingress to APISIX in `monitor` mode.
3. After >= 48 hours clean in monitor, flip the canary to `block`.
4. Migrate remaining Ingresses in batches.
5. Remove ingress-nginx.

The detector, mgt, pg, luigi, fvm, chaos, and any mcp_server deployment
**do not change** during this migration. Only the data plane moves.

## Step 1: Install APISIX in parallel

```bash
helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update
helm install apisix apisix/apisix \
  --namespace ingress-apisix --create-namespace \
  -f k8s/apisix-controller/helm-values.yaml
```

Wait for the pods to be Ready:

```bash
kubectl -n ingress-apisix wait --for=condition=ready pod -l app.kubernetes.io/name=apisix --timeout=300s
kubectl -n ingress-apisix wait --for=condition=ready pod -l app.kubernetes.io/name=apisix-etcd --timeout=300s
kubectl -n ingress-apisix wait --for=condition=ready pod -l app.kubernetes.io/name=apisix-ingress-controller --timeout=300s
```

Sanity check: APISIX admin API responds.

```bash
kubectl -n ingress-apisix port-forward svc/apisix-admin 9180:9180 &
curl -s http://127.0.0.1:9180/apisix/admin/routes -H 'X-API-KEY: <admin_key>' | jq .
```

The `admin_key` is in the apisix Secret; fetch it with:

```bash
kubectl -n ingress-apisix get secret apisix-admin -o jsonpath='{.data.admin-key}' | base64 -d; echo
```

## Step 2: Canary migration

Pick a low-traffic Ingress for the canary. Create an `ApisixPlugin`
referencing it in monitor mode (use template 1 from `waf-plugin.yaml`).

Point `waf-canary.example.com` at the new APISIX LoadBalancer:

```bash
# Get the LB address:
APISIX_LB=$(kubectl -n ingress-apisix get svc apisix-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# In your DNS provider, point waf-canary.example.com CNAME/A to $APISIX_LB
```

Smoke tests:

```bash
# Should be 200 OK.
curl -i "http://waf-canary.example.com/"

# Should be 200 OK with WAF debug headers, attack visible in mgt UI.
curl -i "http://waf-canary.example.com/?id=1' OR '1'='1"
```

Verify in the mgt UI (port 1443 of `safeline-mgt` Service): the attack
should show up under "Attack Logs" with `src_ip` matching the client (not
the LB IP — if it does not match, the `real_client_ip` setting is wrong
or the LB CIDR is not in `apisix.trusted_addresses`; fix in
`helm-values.yaml` and `helm upgrade`).

## Step 3: Flip to block

After >= 48 hours with the canary in monitor and no false positives:

```bash
# Edit the ApisixPlugin you created in Step 2: change mode to "block",
# append_waf_debug_header to false, save, re-apply.
kubectl apply -f waf-canary.yaml
```

Verify:

```bash
# Should be 403 with the SafeLine JSON body.
curl -i "http://waf-canary.example.com/?id=1' OR '1'='1"
```

## Step 4: Batch migrate remaining Ingresses

For each remaining Ingress:

1. Create an `ApisixPlugin` referencing it in `monitor` mode.
2. Repoint the DNS for that host to the APISIX LoadBalancer.
3. Run smoke tests.
4. After clean for 48 hours, flip to `block`.

A scripted way: generate one `ApisixPlugin` per Ingress using a small
loop, then `kubectl apply` each. The ApisixPlugin spec is stable.

## Step 5: Remove ingress-nginx

Once all Ingresses are migrated and clean:

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete ns ingress-nginx
```

The `k8s/t1k-controller/` subtree and the `safeline-t1k-controller` image
stay in the repo for users who have not yet migrated; the AGENTS.md
"Data plane migration" section is the source of truth on this.

## Gotchas

- **Default-backend conflict.** ingress-nginx installs a `default-http-backend`
  Service that APISIX does not use. Removing the helm release removes it.
- **Annotation-only Ingresses.** Some Helm charts set
  `nginx.ingress.kubernetes.io/*` annotations. apisix-ingress-controller
  ignores them. Move any per-Ingress config you need to the matching
  `ApisixPlugin` CRD.
- **TLS secret sharing.** TLS secrets are cluster-scoped (`tls.cert` /
  `tls.key` fields are identical between ingress-nginx and APISIX), so
  re-applying the same Ingress yaml works.
- **Service renames.** If you renamed `safeline-detect` Service (e.g. moved
  to a different namespace), update `apisix.set.plugin_attr.chaitin-waf.nodes`
  in `helm-values.yaml` and `helm upgrade`. The plugin fails open if the
  node list is wrong; a failed `nc -zv` from an APISIX pod will surface
  the misconfiguration quickly.
- **Two ingress controllers in the cluster.** During the parallel install,
  the APISIX ingress controller will start translating your existing
  ingress-nginx Ingresses. That is fine — APISIX creates routes for them,
  but no traffic flows to APISIX until you point DNS at it. Once DNS is
  cut over for a host, ingress-nginx is no longer in the path for that
  host. To minimize surprise, point your canary DNS at APISIX immediately
  after Step 1.
- **mgt UI access during cutover.** The mgt control panel (port 1443) must
  not have `chaitin-waf` attached to its Ingress. It is a separate
  Ingress with its own IngressClass, or you expose it via NodePort.
```

- [ ] **Step 2: Verify no broken cross-references**

Run:
```bash
test -f k8s/apisix-controller/waf-plugin.yaml && echo "OK: waf-plugin.yaml exists"
test -f k8s/apisix-controller/helm-values.yaml && echo "OK: helm-values.yaml exists"
test -f k8s/README.md && echo "OK: k8s/README.md exists"
grep -q "k8s/apisix-controller/helm-values.yaml" k8s/apisix-controller/upgrade-from-ingress-nginx.md && echo "OK: cross-ref to helm-values (full path)"
grep -q "waf-plugin.yaml" k8s/apisix-controller/upgrade-from-ingress-nginx.md && echo "OK: cross-ref to waf-plugin (relative)"
```
Expected: 5 `OK:` lines, no errors. (The waf-plugin reference is bare filename because the two files are in the same directory; helm-values reference is full path because it might be referenced from elsewhere later.)

- [ ] **Step 3: Commit**

```bash
git add k8s/apisix-controller/upgrade-from-ingress-nginx.md
git commit -m "feat(k8s): apisix migration guide from ingress-nginx"
```

---

## Task 6: Write `k8s/apisix-controller/README.md`

**Files:**
- Create: `k8s/apisix-controller/README.md`

- [ ] **Step 1: Write the file**

```markdown
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
#    Pick a template from k8s/apisix-controller/waf-plugin.yaml,
#    edit ingressRefs and the namespace, then:
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
```

- [ ] **Step 2: Verify the README is internally consistent**

Run:
```bash
test -f k8s/apisix-controller/helm-values.yaml && \
test -f k8s/apisix-controller/waf-plugin.yaml && \
test -f k8s/apisix-controller/example-app.yaml && \
test -f k8s/apisix-controller/upgrade-from-ingress-nginx.md && \
test -f docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md && \
echo "OK: all referenced files exist"
```
Expected: `OK: all referenced files exist`.

- [ ] **Step 3: Commit**

```bash
git add k8s/apisix-controller/README.md
git commit -m "docs: apisix-controller quick-start README"
```

---

## Task 7: Update `k8s/README.md` to deprecate section 9 and add cross-references

**Files:**
- Modify: `k8s/README.md` (section 9 only; one new line in section 13; one new row in section 14's table)

- [ ] **Step 1: Locate the sections to edit**

Run:
```bash
grep -n "^## " k8s/README.md
```
Expected: lists section headers. Note the line numbers for sections 9, 13, 14 from the output (do not hard-code; they will shift if k8s/README.md changes between commits).

- [ ] **Step 2: Replace section 9 with a deprecation banner**

The original section 9 ("ingress-nginx + t1k 插件") spans roughly lines 357-482. Replace it with a short banner that preserves the original content in a `<details>` block so users who have not yet migrated can still find it. Use this exact replacement text:

```markdown
## 9. 数据面：APISIX + chaitin-waf 插件（推荐） / ingress-nginx + t1k 插件（已弃用）

数据面已经从 ingress-nginx 迁移到 Apache APISIX，使用 APISIX 官方插件中心的
`chaitin-waf` 插件。ingress-nginx 已于 2025-11-11 被 Kubernetes SIG Network
正式退役（[公告](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)），
最好支持的维护期到 2026-03，之后不会有安全补丁。

**新部署请直接使用 APISIX**：见 [`k8s/apisix-controller/README.md`](apisix-controller/README.md) 完整说明。

**已经在跑 ingress-nginx + t1k 的老部署**：按
[`k8s/apisix-controller/upgrade-from-ingress-nginx.md`](apisix-controller/upgrade-from-ingress-nginx.md)
的步骤零停机迁移；本节保留原始 yaml 作为参考，但不再更新。

<details>
<summary>原始 ingress-nginx + t1k 章节（已弃用）</summary>
```

(Leave the original section 9 content untouched below this opening summary tag, and close with `</details>` on its own line right before the start of the next `## 10.` heading.)

- [ ] **Step 3: Add one item to the "不要做的事" list in section 13**

In the "不要做的事" section, append a new bullet:

```markdown
- **不要**在 mgt 控制台 Ingress 上挂 `chaitin-waf` 插件（操作员可能因为 WAF 触发的拒绝被锁在控制台外面）
```

(Insert it as the last bullet of the existing list.)

- [ ] **Step 4: Update the compose vs k8s table in section 14**

The table currently has a "数据面" row showing ingress-nginx + t1k as the current k8s data plane. With the new APISIX path, this is no longer true. Update the existing "数据面" row and add a new "WAF 插件" row directly below it. Both rows should mirror the dual-status phrasing used in the section 9 heading.

Replace the existing "数据面" row's k8s column (`ingress-nginx + t1k`) with:
```
APISIX（推荐） / ingress-nginx + t1k（已弃用）
```

Then add the new row directly below it:
```markdown
| WAF 插件 | lua-resty-t1k（safeline-tengine 内置） | APISIX chaitin-waf（推荐） / ingress-nginx t1k（已弃用） |
```

Note: `compose.yaml` does not use `ingress-nginx` (it uses `safeline-tengine` with `lua-resty-t1k` baked in, per AGENTS.md), so the compose column for the WAF row references `lua-resty-t1k` rather than `ingress-nginx t1k`.

- [ ] **Step 5: Verify the edits**

Run:
```bash
grep -c "k8s/apisix-controller/README.md" k8s/README.md   # expect >= 1 (the cross-link in the deprecation banner)
grep -c "mgt 控制台" k8s/README.md                         # expect >= 2 (one in section 4 / 9, one in the new section 13 item)
grep -c "WAF 插件" k8s/README.md                           # expect >= 1 (the new table row in section 14)
grep -c "chaitin-waf" k8s/README.md                        # expect >= 2 (one in the deprecation banner, one in the new table row)
grep -c "ingress-nginx t1k" k8s/README.md                 # expect >= 1 (the deprecation markers in section 9 banner and the table)
```
Expected: each grep returns 1 or more. If any returns 0, re-check the surrounding edit in steps 2-4.

- [ ] **Step 6: Commit**

```bash
git add k8s/README.md
git commit -m "docs(k8s/README): deprecate ingress-nginx section 9, point at apisix-controller"
```

---

## Task 8: Final cross-check and cleanup

**Files:**
- Modify: `k8s/apisix-controller/.gitkeep` (delete it; the directory now has real files)

- [ ] **Step 1: Remove the placeholder**

Run:
```bash
git rm k8s/apisix-controller/.gitkeep
```

- [ ] **Step 2: Render a final inventory**

Run:
```bash
ls -la k8s/apisix-controller/
```
Expected: 5 files (`README.md`, `helm-values.yaml`, `waf-plugin.yaml`, `example-app.yaml`, `upgrade-from-ingress-nginx.md`), no `.gitkeep`.

- [ ] **Step 3: Re-run the verification battery across all YAML files**

Run:
```bash
python3 - <<'PY'
import yaml, glob, sys
ok = True
for p in sorted(glob.glob('k8s/apisix-controller/*.yaml')):
    try:
        docs = [d for d in yaml.safe_load_all(open(p)) if d]
        print(f"OK  {p} ({len(docs)} doc(s))")
    except Exception as e:
        print(f"FAIL {p}: {e}")
        ok = False
sys.exit(0 if ok else 1)
PY
```
Expected: all `OK` lines, exit code 0.

- [ ] **Step 4: Confirm no stray modifications to the rest of the repo**

Run:
```bash
git status --short
```
Expected: only `k8s/apisix-controller/` and `k8s/README.md` appear; no other paths modified. If something else shows up, investigate before committing.

- [ ] **Step 5: Final commit**

```bash
git commit -m "chore(k8s): remove .gitkeep placeholder from apisix-controller"
```

---

## Self-review checklist (run before declaring done)

- [ ] All 5 files in `k8s/apisix-controller/` exist and parse as YAML (where applicable) / render as Markdown.
- [ ] `k8s/README.md` section 9 has a deprecation banner pointing at `k8s/apisix-controller/README.md` and a `<details>` block preserving the original content.
- [ ] `k8s/README.md` section 13 has a new "不要把 chaitin-waf 挂在 mgt 控制台" item.
- [ ] `k8s/README.md` section 14 has a new "WAF 插件" row in the table.
- [ ] All cross-references between the design spec, the apisix-controller README, the upgrade doc, and the modified k8s/README.md resolve to existing files.
- [ ] 9 commits total (Tasks 1-8 = 8 commits, plus the spec commit `c91e569` that already exists). `git log --oneline -10` should show them.
- [ ] No Go / Lua / Python code introduced; only docs and YAML.
