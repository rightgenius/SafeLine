# Migrating from ingress-nginx to APISIX

This document describes how to move an existing SafeLine CE on k8s deployment
from ingress-nginx + the t1k plugin to APISIX + the built-in chaitin-waf
plugin, with zero downtime.

## Prerequisites

- helm 3.x
- kubectl
- A SafeLine CE on k8s deployment already running (the control-plane
  manifests in `k8s/apisix-controller/tier3-test/` adapted to amd64 nodes;
  see the main README §7 for what carries over as-is and what arm64-only
  hacks to drop). The detector, mgt, pg, luigi, fvm, chaos pods must all be
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

The `sdk/ingress-nginx/` Lua plugin and the `safeline-t1k-controller`
container image are still useful in the rare case someone runs an old
ingress-nginx deployment that has not yet been migrated, but the upstream
image receives no security patches and the `k8s/t1k-controller/` build
harness has been removed. Treat any remaining ingress-nginx deployment as
on-deck for migration.

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
