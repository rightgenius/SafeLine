# SafeLine CE on Kubernetes 部署说明

本文档说明如何将 SafeLine Community Edition 部署到 Kubernetes 集群。
**不要直接把 `compose.yaml` 翻译成 k8s manifest**：原 compose 中的 `safeline-tengine` 用了 `network_mode: host`，在 k8s 中不适用。推荐做法：

- 把 SafeLine 的**控制面 / 检测面**（mgt、detector、fvm、luigi、pg、chaos）跑在 k8s 里
- 用 **ingress-nginx + t1k 插件** 替代 `safeline-tengine` 作为数据面
- mcp_server 独立部署，调用 mgt-api

仓库里相关的入口：
- `compose.yaml` — 原始 compose 拓扑（不是 k8s manifest）
- `sdk/lua-resty-t1k/` — OpenResty t1k 客户端
- `sdk/ingress-nginx/` — ingress-nginx 插件
- `sdk/kong/` — Kong 插件
- `scripts/manage.py` — compose 部署脚本（k8s 不用）

## 1. 架构拓扑

```
Internet
   │
   ▼
[Cloud LB / NodePort :80/:443]
   │
   ▼
[ingress-nginx Controller Pod]  ← lua-resty-t1k 插件
   │
   ├─ T1K (TCP/8000) ──→ [safeline-detect Service] ──→ [safeline-detect Pod]
   │                                              ↑
   └─ HTTP ──→ [应用 Service] ──→ [应用 Pod]        │
                                                   │
[运维 / API] ──→ [safeline-mgt Service :1443] ─────┘
                       │
                       ├─→ [safeline-pg (StatefulSet)]
                       ├─→ [safeline-fvm]
                       └─→ [safeline-luigi]
[可选] [mcp_server Pod] ──→ [safeline-mgt Service :1443]
```

## 2. 前置条件

- Kubernetes 1.24+
- helm 3.x（装 ingress-nginx）
- kubectl
- 一个 LoadBalancer 类型的 Service（云厂商或 MetalLB）
- 默认 StorageClass（给 pg 用）
- SafeLine 版本号（参考根目录的 `version.json`）

## 3. 命名空间与 detector 配置

```yaml
# 00-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: safeline-ce
```

**关键改动**：detector 默认走 unix socket（`/resources/detector/snserver.sock`），k8s 跨 Pod 用不了，必须改成 TCP：

```yaml
# 01-detector-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: safeline-detector-config
  namespace: safeline-ce
data:
  detector.yml: |
    bind_addr: 0.0.0.0
    listen_port: 8000
    # 其它参数按需
```

## 4. postgres（StatefulSet）

```yaml
# 10-pg-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: safeline-pg-secret
  namespace: safeline-ce
type: Opaque
stringData:
  password: <change-me-pg-password>

---
# 10-pg.yaml
apiVersion: v1
kind: Service
metadata:
  name: safeline-pg
  namespace: safeline-ce
spec:
  clusterIP: None
  selector: { app: safeline-pg }
  ports: [{ port: 5432, targetPort: 5432 }]

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: safeline-pg
  namespace: safeline-ce
spec:
  serviceName: safeline-pg
  replicas: 1
  selector:
    matchLabels: { app: safeline-pg }
  template:
    metadata: { labels: { app: safeline-pg } }
    spec:
      containers:
      - name: postgres
        image: chaitin/safeline-postgres:15.2
        env:
        - name: POSTGRES_USER
          value: safeline-ce
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef: { name: safeline-pg-secret, key: password }
        ports: [{ containerPort: 5432 }]
        args: ["postgres", "-c", "max_connections=600"]
        volumeMounts:
        - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      resources: { requests: { storage: 20Gi } }
      storageClassName: <your-storage-class>
```

## 5. detector

```yaml
# 20-detector.yaml
apiVersion: v1
kind: Service
metadata:
  name: safeline-detect
  namespace: safeline-ce
spec:
  selector: { app: safeline-detect }
  ports:
  - { name: t1k, port: 8000, targetPort: 8000 }

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safeline-detect
  namespace: safeline-ce
spec:
  replicas: 1
  selector: { matchLabels: { app: safeline-detect } }
  template:
    metadata: { labels: { app: safeline-detect } }
    spec:
      containers:
      - name: detector
        image: chaitin/safeline-detector:<version>   # 与 version.json 保持一致
        ports: [{ containerPort: 8000 }]
        env:
        - name: LOG_DIR
          value: /logs/detector
        volumeMounts:
        - { name: cfg, mountPath: /resources/detector }
        - { name: logs, mountPath: /logs/detector }
        resources:
          requests: { cpu: 500m, memory: 1Gi }
          limits:   { memory: 2Gi }
      volumes:
      - name: cfg
        configMap: { name: safeline-detector-config }
      - name: logs
        emptyDir: {}
```

## 6. mgt-api

mgt-api 容器内听 `:1443`，需要的环境变量跟 compose 一致（参考 `compose.yaml` 第 30-56 行）。

```yaml
# 30-mgt.yaml
apiVersion: v1
kind: Secret
metadata:
  name: safeline-mgt-secret
  namespace: safeline-ce
stringData:
  POSTGRES_PASSWORD: <change-me-pg-password>   # 跟 pg 密码保持一致

---
apiVersion: v1
kind: Service
metadata:
  name: safeline-mgt
  namespace: safeline-ce
spec:
  selector: { app: safeline-mgt }
  ports:
  - { name: api, port: 1443, targetPort: 1443 }

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safeline-mgt
  namespace: safeline-ce
spec:
  replicas: 1
  selector: { matchLabels: { app: safeline-mgt } }
  template:
    metadata: { labels: { app: safeline-mgt } }
    spec:
      initContainers:
      - name: wait-for-pg
        image: busybox:1.36
        command: ['sh', '-c', 'until nc -z safeline-pg 5432; do sleep 2; done']
      containers:
      - name: mgt
        image: chaitin/safeline-mgt:<version>
        env:
        - name: MGT_PG
          value: postgres://safeline-ce:$(POSTGRES_PASSWORD)@safeline-pg/safeline-ce?sslmode=disable
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef: { name: safeline-mgt-secret, key: POSTGRES_PASSWORD }
        ports: [{ containerPort: 1443, name: api }]
        resources:
          requests: { cpu: 500m, memory: 1Gi }
          limits:   { memory: 2Gi }
```

如果用的是国际版（`scripts/manage.py --en`），镜像换成 `chaitin/safeline-mgt-en:<version>`。

## 7. luigi / fvm / chaos

镜像 tag 与 mgt/detector 保持一致。

```yaml
# 40-fvm.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safeline-fvm
  namespace: safeline-ce
spec:
  replicas: 1
  selector: { matchLabels: { app: safeline-fvm } }
  template:
    metadata: { labels: { app: safeline-fvm } }
    spec:
      containers:
      - name: fvm
        image: chaitin/safeline-fvm:<version>

---
# 41-luigi.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safeline-luigi
  namespace: safeline-ce
spec:
  replicas: 1
  selector: { matchLabels: { app: safeline-luigi } }
  template:
    metadata: { labels: { app: safeline-luigi } }
    spec:
      containers:
      - name: luigi
        image: chaitin/safeline-luigi:<version>
        env:
        - name: MGT_IP
          value: safeline-mgt
        - name: LUIGI_PG
          value: postgres://safeline-ce:$(POSTGRES_PASSWORD)@safeline-pg/safeline-ce?sslmode=disable
        envFrom:
        - secretRef: { name: safeline-mgt-secret }
        resources:
          requests: { cpu: 200m, memory: 256Mi }
---
# 42-chaos.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safeline-chaos
  namespace: safeline-ce
spec:
  replicas: 1
  selector: { matchLabels: { app: safeline-chaos } }
  template:
    metadata: { labels: { app: safeline-chaos } }
    spec:
      containers:
      - name: chaos
        image: chaitin/safeline-chaos:<version>
        env:
        - name: DB_ADDR
          value: postgres://safeline-ce:$(POSTGRES_PASSWORD)@safeline-pg/safeline-ce?sslmode=disable
        envFrom:
        - secretRef: { name: safeline-mgt-secret }
```

## 8. mcp_server（可选，给 AI agent 用）

```yaml
# 50-mcp.yaml
apiVersion: v1
kind: Secret
metadata:
  name: safeline-mcp-secret
  namespace: safeline-ce
stringData:
  token: <safeline-api-token>   # 从 mgt 控制台 /api/open/token 申请

---
apiVersion: v1
kind: Service
metadata:
  name: safeline-mcp
  namespace: safeline-ce
spec:
  selector: { app: safeline-mcp }
  ports: [{ port: 5678, targetPort: 5678 }]

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safeline-mcp
  namespace: safeline-ce
spec:
  replicas: 1
  selector: { matchLabels: { app: safeline-mcp } }
  template:
    metadata: { labels: { app: safeline-mcp } }
    spec:
      containers:
      - name: mcp
        image: chaitin/safeline-mcp:latest
        env:
        - name: SAFELINE_ADDRESS
          value: https://safeline-mgt.safeline-ce.svc.cluster.local:1443
        - name: SAFELINE_API_TOKEN
          valueFrom: { secretKeyRef: { name: safeline-mcp-secret, key: token } }
        - name: LISTEN_PORT
          value: "5678"
        - name: LISTEN_ADDRESS
          value: "0.0.0.0"
        ports: [{ containerPort: 5678 }]
```

## 9. ingress-nginx + t1k 插件

### 9.1 安装 ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer
```

`--set controller.service.type=LoadBalancer` 适用于云厂商；自建集群用 MetalLB 时同样；裸机可以用 `NodePort`。

### 9.2 启用 t1k 插件

Chaitin 官方已经发布了一个预装 safeline 插件的 controller 镜像（`docker.io/chaitin/ingress-nginx-controller:v1.10.1`），**不需要自己 build**。`k8s/t1k-controller/build.sh` 默认做的就是 `docker pull` + `docker tag` 这件事。

如果你需要定制（比如改 rockspec 版本、加自定义 lua），可以 `BUILD_FROM_SOURCE=true` 走源码构建（见 `k8s/t1k-controller/README.md`）。

```bash
# 默认：从官方 Chaitin 镜像拉取
./k8s/t1k-controller/build.sh

# 或者：源码构建（需要联网到 luarocks.org，必要时用 LUAROCKS_SERVER 改镜像）
BUILD_FROM_SOURCE=true ./k8s/t1k-controller/build.sh

# 打 tag 并推到自己的仓库
PUSH=true REGISTRY=ghcr.io/your-org ./k8s/t1k-controller/build.sh
```

### 9.3 让 helm 装出来的 controller 用上这个镜像

`build.sh` 输出的本地 tag 是 `safeline-t1k-controller:v1.10.1`。装 ingress-nginx 时指定 image：

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.image.repository=safeline-t1k-controller \
  --set controller.image.tag=v1.10.1 \
  --set controller.image.pullPolicy=IfNotPresent
```

### 9.4 配置插件

创建两个 ConfigMap：一个给 safeline 插件，一个给 ingress-nginx controller 启用插件。完整 yaml 在 `k8s/t1k-controller/controller-config.yaml`，这里贴关键部分：

```yaml
# 插件配置（host/port/mode 都在这里）
apiVersion: v1
kind: ConfigMap
metadata:
  name: safeline-plugin
  namespace: ingress-nginx
data:
  host: "safeline-detect.safeline-ce.svc.cluster.local"
  port: "8000"
  mode: "monitor"           # 新接入先 monitor 跑几天再切 block
  remote-addr: "http_x_forwarded_for: 1"   # 关键：拿真实客户端 IP
---
# 启用插件
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  plugins: "safeline"
  allow-snippet-annotations: "false"
```

然后给 controller Deployment 注入 env（参考 `k8s/t1k-controller/controller-config.yaml` 里的 patch 段）：

```yaml
env:
- name: SAFELINE_HOST
  valueFrom: { configMapKeyRef: { name: safeline-plugin, key: host } }
- name: SAFELINE_PORT
  valueFrom: { configMapKeyRef: { name: safeline-plugin, key: port } }
- name: SAFELINE_MODE
  valueFrom: { configMapKeyRef: { name: safeline-plugin, key: mode } }
- name: SAFELINE_REMOTE_ADDR
  valueFrom: { configMapKeyRef: { name: safeline-plugin, key: remote-addr } }
```

### 9.5 业务 Ingress 接入示例

插件被 controller 全局启用后，**所有 Ingress 默认都会走 WAF**。想给单个 Ingress 关掉，加 annotation：

```yaml
# 应用自己的 namespace 里
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    # 想跳过 WAF 就打开这个
    safeline.nginx.org/disable: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts: [app.example.com]
    secretName: app-example-com-tls
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app-svc
            port: { number: 80 }
```

被拦时的响应是 200 + 一段 JSON（不是 403）：

```json
{"code": 403, "success": false, "message": "blocked by Chaitin SafeLine Web Application Firewall", "event_id": "..."}
```

应用 Deployment / Service / 代码**一行都不用改**。

## 10. 部署顺序

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-detector-config.yaml
kubectl apply -f 10-pg.yaml
# 等 pg ready
kubectl -n safeline-ce wait --for=condition=ready pod -l app=safeline-pg --timeout=300s
kubectl apply -f 20-detector.yaml
kubectl apply -f 30-mgt.yaml
# 等 mgt ready
kubectl -n safeline-ce wait --for=condition=ready pod -l app=safeline-mgt --timeout=300s
kubectl apply -f 40-fvm.yaml
kubectl apply -f 41-luigi.yaml
kubectl apply -f 42-chaos.yaml
kubectl apply -f 50-mcp.yaml
# 装 ingress-nginx（用 helm，见 9.1）
# 部署 t1k controller 镜像和 ConfigMap
# 应用自己的 Ingress
```

## 11. 验证

```bash
# 1. pod 都跑起来
kubectl -n safeline-ce get pods

# 2. detector 健康检查（detector 健康端点以实际镜像为准）
kubectl -n safeline-ce exec deploy/safeline-detect -- curl -s 127.0.0.1:8000/ping
# 期望：pong（具体协议以 T1K 文档为准）

# 3. mgt-api 健康
kubectl -n safeline-ce exec deploy/safeline-mgt -- curl -k -s https://localhost:1443/api/open/health

# 4. 模拟一次 SQL 注入
curl -i "http://app.example.com/?id=1' OR '1'='1"
# block 模式：期望 403 或拦截页面
# monitor 模式：期望 200 + 在 mgt 日志里看到一条攻击记录

# 5. 真实 IP 验证：在 mgt 日志里看 src_ip 字段是不是真客户端地址
```

## 12. 运维要点

- **规则配置**：mgt 控制台（暴露 mgt Service 给运维）或调用 mgt-api REST（端口 1443）；mcp_server 也可以。
- **数据库备份**：定期 `pg_dump` safeline-pg 的 PVC，或者用云厂商的快照能力。
- **升级版本**：先改镜像 tag。升级顺序 `pg → fvm → detector → mgt → luigi → chaos → mcp`。tcd 在 k8s 中不部署。
- **detector 故障行为**：t1k 客户端在 detector 不可达时决定 fail-open（放行）/ fail-closed（全拦）。Lua t1k 默认行为请参考 `sdk/lua-resty-t1k/README.md`；这是安全/可用性的业务决策，没有标准答案。
- **ingress-nginx 高可用**：`replicaCount >= 2`，配 `podAntiAffinity`；`--max-workers` 适当调大。
- **资源建议**：mgt/detector 至少 1Gi 内存，pg 至少 2Gi。
- **mgt gRPC :9002**：tcd 用的端口，k8s 部署里用不到，**不要**给外部访问。
- **数据卷迁移**：compose → k8s 时要把 `/data/safeline/resources/` 里的站点证书、规则数据等迁到 PVC 里。
- **监控指标**：mgt/detector 镜像没有自带 Prometheus exporter，需要自己加 sidecar 或者用日志聚合。

## 13. 不要做的事

- **不要**把 `safeline-tengine` 跑在 k8s（`hostNetwork: true` 会让 Service / Ingress 失效）
- **不要**用 unix socket 模式跑 detector（k8s 跨 Pod 无法共享 unix socket）
- **不要**把 safeline-pg 用 `emptyDir`（数据丢失）
- **不要**把 mgt / detector / luigi / fvm / chaos 拆到多个 namespace（DNS 互通简单很多）
- **不要**把 detector 多副本（v1 设计是单点，多副本会出现规则竞态）
- **不要**在 t1k 客户端使用默认 `remote_addr`（拿不到真实客户端 IP，限流/封 IP 失效）

## 14. 与 compose 部署的对比

| 项 | compose | k8s |
| --- | --- | --- |
| 数据面 | safeline-tengine | ingress-nginx + t1k |
| detector 监听 | unix socket | TCP :8000 |
| 状态 | 单机 | 多副本（除 detector） |
| 规则下发 | tcd → nginx reload | mgt-api + ingress-nginx reload |
| 运维入口 | `scripts/manage.py` | kubectl / helm |
| tcd | 需要 | 不需要 |
| chaos | 跟 tengine 同 host network | 独立 Pod |
| pg | bind volume | StatefulSet + PVC |
| mgt UI 端口 | `${MGT_PORT:-9443}` | LoadBalancer / NodePort / Ingress |

## 15. 后续扩展

- **东西向流量**：ingress-nginx 只能管南北向。service-to-service 防护需要 sidecar（每个业务 Pod 加一个 lua 容器）或 service mesh 配 Wasm filter。
- **Helm Chart**：仓库内**没有**官方 helm chart；社区有几个非官方的。
- **GitOps**：所有 manifest 推到 git，用 ArgoCD / Flux 部署；mgt 的规则用 mcp_server 配合 git workflow 同步。
- **多租户**：每个租户一个 Ingress + 一个 mgt namespace（重），或者共用 mgt、用 Ingress annotation 区分域名策略（轻）。
