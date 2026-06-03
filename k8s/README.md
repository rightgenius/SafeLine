# SafeLine CE on Kubernetes 部署说明

> **数据面：从 2026-06 起统一为 Apache APISIX + 官方 `chaitin-waf` 插件**。ingress-nginx + t1k 方案已废弃（ingress-nginx 上游 2025-11 退役），相关 `k8s/t1k-controller/` 整个子树已从仓库移除。

本目录组织 SafeLine 在 k8s 上的完整部署，拆成**控制面**（SafeLine 自己的服务）和**数据面**（对外网关 + WAF）两块。两者装在不同 namespace、各自有自己的部署文档。

---

## 1. 组件全景

```
                        Internet / Clients
                              │  HTTP / HTTPS
                              ▼
              ┌──────────────────────────────────────┐
              │  Cloud LB / MetalLB / NodePort       │
              └──────────────────┬───────────────────┘
                                 │
                                 ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  Namespace: ingress-apisix                                 │
   │  Apache APISIX (chaitin-waf plugin)  ←  数据面 (本文档不写)│
   └──────────────────────────┬──────────────────────────────────┘
                              │  T1K (TCP/8000)
                              │  + 业务 HTTP
                              ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  Namespace: safeline-ce                                     │
   │  ┌──────────────────┐  ┌──────────────────────────────┐    │
   │  │ safeline-detector│  │ safeline-mgt (API + UI)      │    │
   │  │ T1K 检测引擎     │  │ + safeline-pg (DB)           │    │
   │  └──────────────────┘  │ + safeline-fvm (规则字节码)  │    │
   │                        │ + safeline-luigi (后台 worker)│    │
   │                        │ + safeline-chaos (人机验证)  │    │
   │                        │ + safeline-mcp (可选, AI)    │    │
   │                        └──────────────────────────────┘    │
   └─────────────────────────────────────────────────────────────┘
```

数据面的部署全部在 [`k8s/apisix-controller/README.md`](apisix-controller/README.md)，本文档只讲**控制面**。

---

## 2. 部署顺序

```bash
# 第 1 步：先装控制面（本文档 §3）
# 第 2 步：再装数据面（k8s/apisix-controller/README.md §4）
# 第 3 步：smoke test（本文档 §4 + k8s/apisix-controller/README.md §4.4）
```

控制面没起来就装数据面没有意义（APISIX 找不到 detector 会 fail-open）。

---

## 3. 控制面部署

控制面全部在 `safeline-ce` namespace，由 7 个 Service 组成。**所有可工作的 yaml 都在 `k8s/apisix-controller/tier3-test/` 目录下**（这个名字来源：该套清单最初用于 Tier 3 全栈验证，但是它就是产品级生产 yaml，只是去掉了若干 arm64 模拟环境的 hack）。

### 3.1 一键 apply

```bash
cd <repo root>

# 这些 yaml 命名有序（00/01/10/20/...），按编号 apply 即可
for f in k8s/apisix-controller/tier3-test/0*.yaml \
         k8s/apisix-controller/tier3-test/1*.yaml \
         k8s/apisix-controller/tier3-test/2*.yaml \
         k8s/apisix-controller/tier3-test/3*.yaml \
         k8s/apisix-controller/tier3-test/4*.yaml; do
  kubectl apply -f "$f"
done
# 41-luigi.yaml 拆出来单独 apply（multi-doc parser 偶尔对 luigi 部分敏感）
kubectl apply -f k8s/apisix-controller/tier3-test/41-luigi.yaml
```

> **生产用 amd64 节点时不需要改任何东西**。`k8s/apisix-controller/README.md` §7.1 列出了 7 处 arm64+qemu-user-static 引入的 hack（pg init 容器 chown、detector 绕过 koopa、luigi 拆分 apply 等），amd64 节点上**所有这些都可以忽略**——但 yaml 本身保持原样也能跑（hack 是"绕过去"的形式，不是"破坏性改写"）。

### 3.2 文件清单

| 文件 | 内容 |
| --- | --- |
| `00-namespace.yaml` | `safeline-ce` namespace |
| `01-secrets-config.yaml` | DB 密码 + detector / fvm 配置（ConfigMap） |
| `10-pg.yaml` | `chaitin/safeline-postgres:15.2` StatefulSet（pg） |
| `20-detector.yaml` | `chaitin/safeline-detector:<ver>` Deployment（detector） |
| `30-mgt.yaml` | `chaitin/safeline-mgt:<ver>` Deployment（mgt-api） |
| `40-fvm-luigi-chaos.yaml` | fvm + luigi + chaos 三个 Deployment |
| `41-luigi.yaml` | luigi 单文件（apply 顺序原因见上） |

镜像版本钉死在 yaml 里，跟着仓库根 `version.json` 走；切版本时把 yaml 里 `:9.3.6` 之类的 tag 一起改。

### 3.3 关键 Service 名

写 ApisixPlugin / 别的 yaml 时如果引用这些 Service，**必须用下面这些名字**（尤其注意 detector 是带 r 的全名）：

| Service | 用途 | 端口 |
| --- | --- | --- |
| `safeline-pg` | PostgreSQL | 5432 |
| `safeline-detector` | WAF 检测引擎（**带 r**） | 8000 (T1K), 8001 (health) |
| `safeline-mgt` | 管理 API + Web UI | 1443 (HTTPS) |
| `safeline-fvm` | 规则字节码服务 | 9004（注意：compose.yaml 写的 9002 是错的） |
| `safeline-luigi` | 后台 worker（无 listen 端口） | — |
| `safeline-chaos` | 人机验证 | 8080 / 8088 / 9000 |
| `safeline-mcp` | MCP server（可选） | 5678 |

> 端口差异详细表（chaitin 镜像默认 vs compose.yaml 标注）见 `k8s/apisix-controller/tier3-test/README.md` 的 "Port map" 段。

### 3.4 命名空间和 detector 命名

- **不要把 detector Service 重命名**。`safeline-mgt` 的 Go 代码硬编码 `http://safeline-detector:8001/update/policy`（**带 r**）来推规则。命名错了这条链路就断了。
- **不要把 detector Service 用 `ClusterIP: None` headless 模式**。`safeline-mgt` 解析不到 headless Service 的稳定 ClusterIP。
- **不要把 detector 跨 namespace 部署**。`safeline-mgt` 同样硬编码 Service 名字 + 短域名（只带 `safeline-` 前缀、不带 `.namespace`），跨 ns 解析不到。

### 3.5 网络 gotcha

- **k8s env 不会做 `$(...)` 展开**。`compose.yaml` 里形如 `postgres://user:$(POSTGRES_PASSWORD)@host/db` 的环境变量直接搬到 k8s 会把 `$(POSTGRES_PASSWORD)` 当字面量。yaml 已经在每个 env 里**内联**了实际密码（生产请改成 `valueFrom.secretKeyRef`）。
- **mgt 调 fvm 用 `http://safeline-fvm/skynetinfo`**（无端口），Service 把 80 映射到 fvm 容器的 9004。
- **mgt 调 chaos 用 8088（auth）和 8080（challenge）**。Service 都已暴露。

### 3.6 等控制面 ready

```bash
# 7 个 Pod 全部 Running
kubectl -n safeline-ce get pods

# detector Service 有 8000 端口（不是 unix socket）
kubectl -n safeline-ce get svc safeline-detector -o yaml | grep -A3 ports

# detector 在集群内可达
kubectl -n safeline-ce run -it --rm --restart=Never netcheck --image=busybox:1.36 -- \
  nc -zv safeline-detector.safeline-ce.svc.cluster.local 8000
# 期望：safeline-detector.safeline-ce.svc.cluster.local (172.x.x.x:8000) open
```

控制面 ready 之后，再去 [`k8s/apisix-controller/README.md`](apisix-controller/README.md) 装数据面。

---

## 4. 验证

```bash
# 1. 7 个 Pod 都 Running
kubectl -n safeline-ce get pods

# 2. mgt API 健康（绕过 APISIX，直接打到 mgt Service）
kubectl -n safeline-ce run -it --rm --restart=Never mgtcheck --image=curlimages/curl -- \
  curl -k https://safeline-mgt:1443/api/open/health
# 期望：返回 {"success":true, "data":...}

# 3. detector 端口活着
kubectl -n safeline-ce exec -it deploy/safeline-detector -- nc -zv 0.0.0.0 8000
# 期望：succeeded

# 4. detector 上报 mgt 规则（这条要等 koopa 推规则过来，amd64 上几秒钟就行）
kubectl -n safeline-ce logs deploy/safeline-detector --tail 50
# 找包含 "policy" / "rules" / "snserver" 的日志行
```

数据面验证（SQLi 拦截 / IP 透传 / mode 切换）见 `k8s/apisix-controller/README.md` §4.4 和 §6。

---

## 5. 不要做的事

- **不要把 detector Service 重命名**（§3.4 详述）。
- **不要让 detector 监听 unix socket**。compose 默认是 socket；k8s 跨 Pod 不通，必须 TCP/8000（yaml 已经配好）。
- **不要让 detector 多副本**。SafeLine detector 设计上就是单实例，`replicas > 1` 会导致两个 Pod 抢同一个 T1K 连接。`20-detector.yaml` 用 `strategy: Recreate` 强制每次只起一个。
- **不要给 mgt 的 Ingress 挂 `chaitin-waf` 插件**。详见下一节 §6。
- **不要把控制面服务拆到多个 namespace**。Service 短名是硬编码的（§3.4）。

---

## 6. mgt 的访问（不挂 WAF）

`safeline-mgt` 是**控制面**组件（管理 API + Web UI），不是被 WAF 保护的业务后端。它**绝对不能**走 APISIX + `chaitin-waf` 的入口。

### 6.1 为什么 mgt 必须绕开 WAF

| # | 原因 | 说明 |
| --- | --- | --- |
| 1 | **循环依赖** | chaitin-waf 用的规则是 mgt 推给 detector 的。mgt 自身也走 chaitin-waf → mgt 推规则的请求也被检测 → 推规则失败 → detector 永远没规则 → 启动死锁。 |
| 2 | **流量内容混淆** | mgt 自身的入站流量来自管理员操作（编辑白名单、查看日志），白名单内容里常常包含 SQL 注入 / XSS 等"恶意特征"作为**字符串**。这些会被 detector 误判为攻击。 |
| 3 | **锁死风险** | WAF 一旦误拦 mgt 的登录请求，**管理员进不去 mgt 改规则**。生产事故的常见原因。 |
| 4 | **拓扑错位** | mgt 是"管理平面"（谁管理这套系统），数据面是"业务平面"（谁访问应用）。WAF 解决"公网上谁在攻击我的应用"，管理平面应该用"网络层访问控制"（防火墙 / VPN / IP 白名单），而不是 WAF 插件。 |

### 6.2 三种访问方案

按推荐程度从低到高排：

#### 方案 A：`kubectl port-forward`（最简单，开发 / 堡垒机场景）

适合单管理员本地访问，不对外暴露任何端口。

```bash
# 启在前台（Ctrl-C 中断）
kubectl -n safeline-ce port-forward svc/safeline-mgt 1443:1443
# 浏览器：https://localhost:1443
# 默认证书是自签的，浏览器会警告；点 "Advanced" → "Proceed" 即可
```

> 默认用户是安装时设置的（compose 第一次启动会提示，k8s 部署则通过 `kubectl exec` 进 mgt Pod 跑 `mgt reset-user` 重置）。详见 `k8s/apisix-controller/README.md` §4.1 第一条注释里 mgt main.go 的 flag 列表。

#### 方案 B：`NodePort`（推荐，单节点 / 内部网络生产）

把 mgt Service 改成 `NodePort`，在集群节点上监听一个固定端口。配合网络层防火墙限制访问源 IP。

```bash
# 一次性 patch：把 mgt 改成 NodePort
kubectl -n safeline-ce patch svc safeline-mgt --type='json' -p='[
  {"op":"replace","path":"/spec/type","value":"NodePort"},
  {"op":"add","path":"/spec/ports/0/nodePort","value":31443}
]'

# 验证
kubectl -n safeline-ce get svc safeline-mgt
# 期望: TYPE=NodePort, PORT(S)=1443:31443/TCP

# 浏览器：https://<任一节点 IP>:31443
```

**生产必修**：用 NetworkPolicy / 云安全组 / 防火墙只允许运维 IP 段访问节点 31443。**不要**让 NodePort 直接暴露到公网。

```yaml
# 例：NetworkPolicy 限制只能从堡垒机 IP 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: safeline-mgt-admin-only
  namespace: safeline-ce
spec:
  podSelector:
    matchLabels:
      app: safeline-mgt
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 10.0.0.0/24    # 替换成你的堡垒机 / 办公网段
        except:
        - 10.0.0.1/32
    ports:
    - protocol: TCP
      port: 1443
```

#### 方案 C：独立 Ingress（用别的 IngressController，跟 APISIX 数据面完全分开）

集群里同时跑 APISIX（数据面）和**另一个** IngressController（管理面，比如 ingress-nginx / traefik / Kong）时，把 mgt 暴露在管理面的 Ingress 上，**永远不挂** chaitin-waf。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: safeline-mgt
  namespace: safeline-ce
  # 注意：没有 ApisixPlugin；apiserver 也明确指定别的 ingressClassName
spec:
  ingressClassName: nginx    # ← 关键的"分开"声明；apiserver 走 apisix，mgt 走 nginx
  rules:
  - host: mgt.internal.example.com   # 内部域名，不解析到公网
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: safeline-mgt
            port:
              number: 1443
  # 证书示例（如果 mgt 自己签证书就免了；浏览器会警告）
  tls:
  - hosts:
    - mgt.internal.example.com
    secretName: safeline-mgt-tls
```

`ingressClassName: nginx` 这条**至关重要**——它让 apisix-ingress-controller 不会去翻译这个 Ingress（因为它的 IngressClass 是 `apisix`），只有 nginx controller 才会处理。

### 6.3 不要做的事（mgt 访问专项）

- **不要**给 mgt 配 `ingressClassName: apisix`——即使不挂 ApisixPlugin，APISIX gateway 仍然会把流量代理过来，mgt 仍然在数据面网关上被管理。
- **不要**给 mgt 配 `type: LoadBalancer` 后直接暴露到公网——公网攻击者可以暴力登录尝试（即使 mgt 自带限流，这也不该是常态）。
- **不要**用 `kubectl port-forward` 做长期生产方案——port-forward 进程崩了 / 终端关了 mgt 就访问不到了；它的定位是"开发调试"。

### 6.4 验证 mgt 访问

任选一种方案后，验证流程：

```bash
# 1. 端口可达
curl -kI https://localhost:1443/api/open/health    # port-forward 方案
# 期望：HTTP/2 200，body 是 {"success":true, "data":...}

# 2. 登录
# 浏览器打开，按提示登录

# 3. 推规则链路正常（mgt 启动后会向 detector :8001/update/policy 推）
# 等 1-2 分钟后：
kubectl -n safeline-ce logs deploy/safeline-detector --tail 30
# 找包含 "policy" / "rules" / "online" 的日志行
# 期望：detector 进入 online 状态（不再 "de-0 offline"）
```

---

## 7. 运维要点

### 7.1 升级

```bash
# 改 yaml 里的镜像 tag（跟着 version.json 走），然后：
for f in k8s/apisix-controller/tier3-test/0*.yaml \
         k8s/apisix-controller/tier3-test/1*.yaml \
         k8s/apisix-controller/tier3-test/2*.yaml \
         k8s/apisix-controller/tier3-test/3*.yaml \
         k8s/apisix-controller/tier3-test/4*.yaml; do
  kubectl apply -f "$f"
done
kubectl apply -f k8s/apisix-controller/tier3-test/41-luigi.yaml
```

### 7.2 备份

- pg 是唯一有状态的服务，PVC 快照即可。SafeLine 的规则、用户、事件日志都存 pg。
- detector 的规则是从 mgt 拉的，**不需要单独备份**——pg 没丢规则就还在。

### 7.3 容量

| 组件 | request | limit（mem） | 备注 |
| --- | --- | --- | --- |
| postgres | 200m / 512Mi | 2Gi | 20Gi PVC |
| detector | 500m / 1Gi | 2Gi | 1 副本 |
| mgt | 500m / 1Gi | 2Gi | 1 副本 |
| fvm | 200m / 256Mi | 1Gi | 1 副本 |
| luigi | 200m / 256Mi | 1Gi | 1 副本 |
| chaos | 100m / 128Mi | 512Mi | 1 副本 |
| mcp | （可选） | — | 跟 data plane 的 chaitin-waf metadata 路径解耦 |

数据面 APISIX gateway 推荐 `1 CPU / 512Mi`，`replicas >= 2`。

---

## 8. 后续步骤

- **数据面**：[`k8s/apisix-controller/README.md`](apisix-controller/README.md) — helm install APISIX + PUT plugin_metadata + 部署示例应用
- **从 ingress-nginx 迁移**：[`k8s/apisix-controller/upgrade-from-ingress-nginx.md`](apisix-controller/upgrade-from-ingress-nginx.md) — 已废弃但还有人跑 ingress-nginx 的零停机迁移路径
- **设计文档**（历史）：[`docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md`](../docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md) — 为什么选 APISIX 的设计 reasoning
- **顶层仓库说明**：[`AGENTS.md`](../AGENTS.md) 的 "Data plane migration" 段
