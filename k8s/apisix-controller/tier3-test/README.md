# Tier 3 test manifests (k8s on arm64 OrbStack, chaitin amd64 images via qemu)

This directory contains the working manifests used to validate Tier 3
("full SafeLine stack on k8s + APISIX chaitin-waf plugin"). They live
here as a reference for anyone running the validation themselves.

**Cluster setup:** OrbStack 1 node, k8s 1.33.9+orb1, **arm64**.
**Image tag:** `9.3.6` (matches the registry; `version.json` in repo root
still says `v9.2.7` — bump when cutting a release).

## Files

| File | What |
| --- | --- |
| `00-namespace.yaml` | Creates the `safeline-ce` namespace. |
| `01-secrets-config.yaml` | DB password Secrets + detector config (TCP bind, mgt/luigi URLs). |
| `10-pg.yaml` | `chaitin/safeline-postgres:15.2` StatefulSet with a privileged init container to chown the local-path PVC. |
| `20-detector.yaml` | `chaitin/safeline-detector:9.3.6` Deployment. **Bypasses the koopa wrapper** and runs `/detector/snserver` directly — see "Known limitations" in `AGENTS.md` for why. |
| `30-mgt.yaml` | `chaitin/safeline-mgt:9.3.6` Deployment. On arm64 OrbStack the mgt Go binary runs under qemu-user-static and the qemu listener for port 8000 isn't visible in the host network namespace; this blocks the mgt UI but does NOT block the WAF end-to-end flow (APISIX talks to the detector directly, mgt is only needed for rule push). |
| `40-fvm-luigi-chaos.yaml` | `chaitin/safeline-fvm`, `chaitin/safeline-chaos`. luigi is split into its own file because the multi-doc YAML parser sometimes chokes on luigi; apply `40-` first then `41-luigi.yaml`. |
| `41-luigi.yaml` | `chaitin/safeline-luigi:9.3.6`. Stuck in Init on arm64 because it can't reach the mgt API (qemu limitation). Non-blocking for WAF. |

## Port map (chaitin defaults are NOT 1:1 with the compose.yaml)

| Service | Container port(s) | Notes |
| --- | --- | --- |
| postgres | 5432 | `chaitin/safeline-postgres:15.2`. chown'd in init container; initdb happens in entrypoint. |
| detector | 8000 (T1K) + 8001 (health) | mgt talks to `:8001/update/policy`; APISIX chaitin-waf talks to `:8000`. |
| mgt | 1443 (HTTPS via nginx) + 9002 (gRPC) | Nginx upstream is `http://localhost:8000` (the mgt Go binary's MGT_PORT). |
| fvm | 80 (HTTP, custom protocol — mgt's `http://safeline-fvm/skynetinfo` hits this) + 9004 (gRPC) | Compose.yaml claims 9002 — that's wrong, the image's `config.yml` says 9004. |
| chaos | 8080 (challenge-server) + 8088 (auth-serve, `yaml:"addr" default:":8088"`) + 9000 (chaos-serve) | mgt hits `:8088/auth/api/key` and `:8080/challenge/v2/api/auth/keys`. |
| luigi | (worker, no listen port) | Connects to mgt and pg. |
| mcp | 5678 | Skipped in this run. |

## Network / DNS gotchas

- **k8s env vars do NOT do `$(...)` expansion.** Compose.yaml's
  `postgres://user:$(POSTGRES_PASSWORD)@host/db` is interpreted as the
  literal string `$(POSTGRES_PASSWORD)` in k8s. Inline the password or
  template the env at apply time.
- **mgt hardcodes `safeline-detector`** (with the `r`). The detector
  Service must be named `safeline-detector` exactly, not
  `safeline-detect`. Same for the mgt URL inside detector.yml's
  `mgt_server_addr`.
- **chaitin-waf plugin metadata must use a FQDN** (e.g.
  `safeline-detector.safeline-ce.svc.cluster.local`), not a pod IP.
  Pod IPs change on restart; FQDNs don't.

## WAF integration commands (for replay)

```bash
# 1. Apply the test manifests
for f in 0*.yaml 1*.yaml 2*.yaml 3*.yaml 4*.yaml; do
  kubectl apply -f "$f"
done
kubectl apply -f 41-luigi.yaml   # separately

# 2. Install APISIX + ingress controller
helm install apisix apisix/apisix --namespace ingress-apisix --create-namespace --version 2.14.1 \
  -f k8s/apisix-controller/helm-values.yaml
helm install apisix-ingress-controller apisix/apisix-ingress-controller \
  --namespace ingress-apisix --version 1.2.0 \
  --set config.apisix.serviceNamespace=ingress-apisix

# 3. Seed the chaitin-waf plugin metadata in etcd (NOT pluginAttrs in
# the chart — that's a known chart 2.14.1 trap, see AGENTS.md).
ADMIN_KEY=edd1c9f034335f136f87ad84b625c8f1   # chart 2.14.1 default
kubectl -n ingress-apisix port-forward svc/apisix-admin 9180:9180 &
curl -X PUT -H "X-API-KEY: $ADMIN_KEY" \
  -d '{"nodes":[{"host":"safeline-detector.safeline-ce.svc.cluster.local","port":8000,"weight":1}],"mode":"block","config":{...}}' \
  http://127.0.0.1:9180/apisix/admin/plugin_metadata/chaitin-waf

# 4. Deploy the demo app and create the APISIX route
kubectl apply -f k8s/apisix-controller/example-app.yaml
DEMO_IP=$(kubectl -n demo-app get svc demo-app -o jsonpath='{.spec.clusterIP}')
curl -X PUT -H "X-API-KEY: $ADMIN_KEY" -d '{
  "uri":"/*","host":"demo.example.com",
  "upstream":{"type":"roundrobin","nodes":[{"host":"'$DEMO_IP'","port":80,"weight":1}]},
  "plugins":{"chaitin-waf":{"enable":true,"config":{"mode":"block","append_waf_resp_header":true,"append_waf_debug_header":true}}}
}' http://127.0.0.1:9180/apisix/admin/routes/demo-app

# 5. Smoke test
NODE_PORT=$(kubectl -n ingress-apisix get svc apisix-gateway -o jsonpath='{.spec.ports[0].nodePort}')
curl -i -H "Host: demo.example.com" "http://127.0.0.1:$NODE_PORT/?id=1%27%20OR%20%271%27%3D%271"
# Expected: HTTP/1.1 403 Forbidden + SafeLine JSON body + X-APISIX-CHAITIN-WAF-ACTION: reject
```

## Tier 3 results (recorded in AGENTS.md "Validation status")

- Detector Service discoverable on TCP: PASS
- APISIX blocks SQLi / XSS / path traversal in `block` mode: PASS
- `monitor` mode logs and forwards: PASS
- mgt UI Ingress stays unprotected: PASS (verified by route without chaitin-waf)
- End-to-end migration dry-run against real ingress-nginx: not run, but
  the steps match `k8s/apisix-controller/upgrade-from-ingress-nginx.md` exactly
