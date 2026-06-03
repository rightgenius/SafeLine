# SafeLine CE on Kubernetes — APISIX 数据面部署指南

> 面向读者的画像：**懂开发、k8s 是小白**。你应该知道 Pod / Service / Deployment 这些概念，但可能没有亲手装过 APISIX 或者完整部署过 SafeLine。本文档会从"为什么"讲到"怎么做"，把每一步的意图都说清楚；最后会把每一步映射回 `tier3-test/` 里实际跑通过的 yaml 和命令，确保你照着做就能成功。

---

## 0. 这份文档是什么 / 不是什么

**是什么**：在 k8s 上把 SafeLine CE 跑起来，并把 **Apache APISIX** 作为对外网关（数据面），让所有外部 HTTP 流量在到达你的业务 Pod 之前先过 WAF 检测。APISIX 通过官方插件中心的 `chaitin-waf` 插件和 SafeLine 检测引擎通信，整个过程不需要你写一行 Lua，不需要自己编译 controller 镜像。

**不是什么**：不是 control plane（控制面）的部署说明。控制面就是 SafeLine 自己那一坨服务（detector / mgt / pg / fvm / luigi / chaos / mcp），它们的部署文档在 [`k8s/README.md`](../README.md)，实际 yaml 在 `k8s/apisix-controller/tier3-test/` 目录里，**本文档不重复**——本文档假设控制面已经按那里跑起来了，只专注于**在控制面之上加一层 APISIX 数据面**。如果控制面还没装，请先看 `k8s/README.md` §3。

**和 `tier3-test/` 的关系**：`tier3-test/` 是我们在 OrbStack 1 节点 k8s 集群上跑过一遍的真实清单（参考用、不是产品级推荐），里面有些 hack 是为了绕过 arm64 qemu 模拟的限制。生产部署请用本文档的步骤，不要照抄 `tier3-test/`。本文档最后一节会逐一指出 `tier3-test/` 里哪些 hack 是为什么、哪些生产不需要。

---

## 1. 整体架构

### 1.1 请求流：从互联网到你的应用

```
                            ┌─────────────────────────────────────────────┐
                            │              互联网 / 客户端                  │
                            └──────────────────┬──────────────────────────┘
                                               │ HTTP/HTTPS
                                               ▼
                            ┌─────────────────────────────────────────────┐
                            │  云厂商 LB / MetalLB / NodePort (:80 / :443) │
                            └──────────────────┬──────────────────────────┘
                                               │
                                               ▼
    ┌──────────────────────────────────────────────────────────────────────────┐
    │  Namespace: ingress-apisix                                                │
    │  ┌────────────────────────────────────────────────────────────────────┐   │
    │  │  APISIX Gateway Pod (apache/apisix:3.16.0)                        │   │
    │  │  ──────────────────────────────────────────────────────────────  │   │
    │  │  • 内置 chaitin-waf 插件（不需要自己装）                            │   │
    │  │  • 插件元数据来自 helm-values.yaml → plugin_attrs（节点列表等）      │   │
    │  │  • 单条路由的开关来自 ApisixPlugin CRD                              │   │
    │  │                                                                    │   │
    │  │  请求处理流程：                                                      │   │
    │  │   1) 根据 Host + Path 匹配到一条 route（由 Ingress 翻译）            │   │
    │  │   2) 如果该 route 关联了 ApisixPlugin(name=chaitin-waf, enable=true)│   │
    │  │      → 把请求通过 T1K 协议发给 detector，等 verdict                 │   │
    │  │   3) verdict = pass     → 转发到后端 Service                         │   │
    │  │      verdict = reject   → 直接 403 + SafeLine JSON 体               │   │
    │  │      detector 不可达   → fail-open（透传 + 标记 unhealthy）          │   │
    │  └──────────────────┬───────────────────────────┬─────────────────────┘   │
    │                     │ T1K (TCP)                 │ HTTP                    │
    │                     │ :8000                     │                         │
    └─────────────────────┼───────────────────────────┼─────────────────────────┘
                          │                           │
                          ▼                           ▼
   ┌─────────────────────────────────────┐  ┌────────────────────────────┐
   │ Namespace: safeline-ce              │  │ 你的业务 Namespace         │
   │ ┌──────────────────────────────┐    │  │ (例如 demo-app)            │
   │ │ safeline-detector Pod        │    │  │                            │
   │ │ T1K 检测引擎                 │    │  │ ┌────────────────────────┐ │
   │ │                              │    │  │ │ 业务 Pod               │ │
   │ │ 把 verdict 同步回:           │    │  │ │ (nginx / java / go…)  │ │
   │ │  • safeline-mgt（攻击日志）  │    │  │ └────────────────────────┘ │
   │ │  • safeline-fvm（规则字节码）│    │  └────────────────────────────┘
   │ └──────────────────────────────┘    │
   │                                      │
   │ 同时还跑着:                          │
   │  • safeline-mgt    (管理 API + UI)   │
   │  • safeline-pg     (PostgreSQL)      │
   │  • safeline-fvm    (规则字节码服务)  │
   │  • safeline-luigi  (后台 worker)     │
   │  • safeline-chaos  (人机验证服务)    │
   │  • safeline-mcp    (可选, AI agent)  │
   └─────────────────────────────────────┘
```

**关键点：**
- **APISIX 才是对外网关**，它和 detector 之间是**纯 TCP 内部通信**（T1K 协议在 8000 端口），所以 detector 不需要暴露到集群外。
- **你的应用 Pod 不变**，只是上游多了一道 WAF 关卡。
- **mgt API/UI 必须**走一个**不带** `chaitin-waf` 插件的独立 Ingress（或者直接 NodePort），否则管理员连自己的管理界面都进不去——这是最常踩的坑，详见 [`k8s/README.md` §6](../README.md#6-mgt-的访问不挂-waf)（为什么 + 三种方案 + 示例）。

### 1.2 命名空间划分

| Namespace | 放什么 | 数量 | 备注 |
| --- | --- | --- | --- |
| `safeline-ce` | 全部 SafeLine 控制面（pg、detector、mgt、fvm、luigi、chaos、mcp） | 7 个 Service | 部署说明见 [`k8s/README.md`](../README.md)，yaml 在 `k8s/apisix-controller/tier3-test/` |
| `ingress-apisix` | APISIX gateway + apisix-etcd + apisix-ingress-controller | 3 个组件 | 由 helm 装在同一个 namespace |
| 你的业务 ns | 你的应用 + 你的 Ingress + 你的 ApisixPlugin | 任意 | 一个业务一个 ns 是惯例 |

### 1.3 三个名词先讲清楚

读到后面你会反复看到这三个词，先把概念钉死：

- **Ingress**：k8s 标准的"外部流量入口声明"，声明"域名 X 的请求转发到 Service Y"。APISIX 自家的 controller 会监听这个资源并翻译成 APISIX 内部的 route。
- **ApisixPlugin CRD**：APISIX 提供的 k8s 自定义资源，作用是"给某个 Ingress 挂一组 APISIX 插件配置"。我们要给业务 Ingress 挂的就是 `chaitin-waf` 插件，所以这个资源是必填的。
- **plugin metadata（插件元数据）**：APISIX 集群级别的、不是某条路由独有的配置。通过 Helm 装的时候写在 `helm-values.yaml` 里的 `pluginAttrs` 字段。但 chaitin-waf 这个插件有个坑——**它不读 Helm 写进去的 pluginAttrs，而是从 etcd 读**，所以装完之后还要手动 `PUT` 一次到 Admin API，详见 §4.2.4。

---

## 2. 组件详解

### 2.1 控制面（这部分不在本文档部署范围，但要懂）

| 组件 | 干什么 | 关键端口 | 备注 |
| --- | --- | --- | --- |
| `safeline-pg` | PostgreSQL，存规则、事件、用户数据 | 5432 | **有状态**，用 StatefulSet + PVC |
| `safeline-detector` | WAF 检测引擎本体，T1K 协议服务端 | **8000 (T1K)**、8001 (健康) | **必须 TCP/8000**，compose 默认 unix socket 在 k8s 里跨 Pod 不行 |
| `safeline-mgt` | 管理 API + Web UI + gRPC（给 tcd 用） | 1443 (HTTPS) | mgt 会反向调用 detector 的 `:8001/update/policy` 推规则 |
| `safeline-fvm` | 规则字节码服务，mgt 启动时拉 | 9004（HTTP + gRPC 都走这个） | **注意**：compose 写的是 9002，**是错的**，实际是 9004 |
| `safeline-luigi` | 后台 worker，处理异步任务、统计、攻击日志落库 | 不暴露端口 | 必须能连 mgt:1443 和 pg:5432 |
| `safeline-chaos` | 人机验证 / 验证码服务 | 8080（挑战页）、8088（认证）、9000（管理） | 触发验证码时被 APISIX 反向调用 |
| `safeline-mcp` | 给 AI agent（Claude / Cursor 之类）用的 MCP server | 5678 | 可选，不影响主流程 |

### 2.2 数据面（本节是本文档的核心）

#### 2.2.1 Apache APISIX Gateway

- **镜像**：`apache/apisix:3.16.0`
- **角色**：所有外部 HTTP 流量入口；内置 `chaitin-waf` 插件。
- **副本数**：生产 ≥ 2；测试 1 也行。
- **Service 类型**：默认 `LoadBalancer`（云厂商环境）。自建集群没 LB 的话用 `NodePort` 也能跑。
- **它从哪里知道要连哪个 detector**？答：从 etcd 里读的 `plugin_metadata/chaitin-waf`，这玩意儿又得由我们手动 PUT 到 Admin API。

#### 2.2.2 etcd

- **镜像**：`bitnami/etcd:3.5`（APISIX helm chart 自带子 chart）
- **角色**：APISIX 的配置存储（routes、upstreams、plugin metadata 全在这）。
- **副本数**：生产 3（容忍 1 节点宕机）；测试 1。
- **重要警告**：helm chart 把 `rootPassword` 直接写进渲染后的 manifest，**不是 Secret 引用**。生产环境必须改成 Secret 引用或外部 etcd。

#### 2.2.3 apisix-ingress-controller

- **镜像**：`apache/apisix-ingress-controller:1.10.0`
- **角色**：把 k8s 原生的 Ingress / ApisixPlugin CRD 翻译成 APISIX 内部的 route / plugin 配置。
- **注意**：它和 APISIX gateway 是**两个独立的 chart**（虽然都在同一个 helm repo 下）。umbrella chart `apisix/apisix` **不包含** ingress controller，必须单独装。

---

## 3. 部署前置条件

| 依赖 | 版本 | 检查命令 |
| --- | --- | --- |
| k8s 集群 | 1.24+（任意发行版） | `kubectl version` |
| helm | 3.x | `helm version` |
| kubectl | 跟集群 API server 版本匹配 | `kubectl version --client` |
| 一个能跑通的控制面 | 已经按 [`k8s/README.md`](../README.md) §3 装好 | `kubectl -n safeline-ce get pods` 全部 Ready |
| detector 在 TCP 模式下运行 | 监听 `0.0.0.0:8000` | `kubectl -n safeline-ce get svc safeline-detector -o jsonpath='{.spec.ports}'` |
| 集群有 LoadBalancer | 云厂商自动分配；本地可用 MetalLB | `kubectl get svc -A` 看 External-IP 列 |

> **没有 LB 的开发机**？把后面 `helm install` 时 `apisix.service.type` 改成 `NodePort`，然后用 `kubectl -n ingress-apisix port-forward svc/apisix-gateway 9080:80` 转发出来用。本文档命令默认 LoadBalancer。

---

## 4. 部署步骤

### 4.1 步骤一：确认控制面 ready

```bash
# 7 个 Pod 全部 Running
kubectl -n safeline-ce get pods

# detector 的 Service 必须包含 8000 端口（不是 unix socket）
kubectl -n safeline-ce get svc safeline-detector -o yaml | grep -A3 ports
# 期望看到：
#   - name: t1k
#     port: 8000
#     targetPort: 8000

# 在集群内能 ping 通 detector
kubectl -n safeline-ce run -it --rm --restart=Never netcheck --image=busybox:1.36 -- \
  nc -zv safeline-detector.safeline-ce.svc.cluster.local 8000
# 期望：succeeded
```

> 这一步不通过别往下走。`tier3-test/20-detector.yaml` 里有 detector 监听 TCP 的具体配置可以参考。

### 4.2 步骤二：装 APISIX 数据面

#### 4.2.1 添加 helm 仓库

```bash
helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update
```

#### 4.2.2 安装 APISIX gateway

```bash
helm install apisix apisix/apisix \
  --namespace ingress-apisix \
  --create-namespace \
  --version 2.14.1 \
  -f k8s/apisix-controller/helm-values.yaml
```

`helm-values.yaml` 的关键内容（[文件](helm-values.yaml)）：

```yaml
apisix:
  replicaCount: 2
  image: { repository: apache/apisix, tag: 3.16.0 }
  service: { type: LoadBalancer }
  pluginAttrs:           # ← 注意：APISIX chart 2.14.1 接受这个 key
    chaitin-waf:
      nodes:
        - host: safeline-detector.safeline-ce.svc.cluster.local  # detector 的 K8s DNS（**带 r**，见 §7.2）
          port: 8000
      mode: monitor        # 集群默认：先 monitor
      config:
        real_client_ip: true   # ← 关键，要从 X-Forwarded-For 拿真实客户端 IP
        connect_timeout: 1000
        send_timeout: 1000
        read_timeout: 1000
        req_body_size: 1024
        keepalive_size: 256
        keepalive_timeout: 60000

etcd:
  replicaCount: 3
  auth:
    rbac:
      rootPassword: changeme-etcd-root  # 生产请改成 Secret 引用
```

> **这个 `pluginAttrs` 看起来很对，但 chaitin-waf 插件实际不读它。**这是 APISIX chart 2.14.1 + chaitin-waf 1.x 的一个真实坑：插件作者实现时是从 etcd 拉 `plugin_metadata/chaitin-waf`，**不是**从静态 `config.yaml` 的 `plugin_attr` 段读。所以下面 4.2.4 步是**必须**的。

等 Pod Ready：

```bash
kubectl -n ingress-apisix wait --for=condition=ready pod \
  -l app.kubernetes.io/name=apisix --timeout=300s
kubectl -n ingress-apisix wait --for=condition=ready pod \
  -l app.kubernetes.io/name=apisix-etcd --timeout=300s
```

#### 4.2.3 安装 apisix-ingress-controller

```bash
helm install apisix-ingress-controller apisix/apisix-ingress-controller \
  --namespace ingress-apisix \
  --version 1.2.0 \
  --set config.apisix.serviceNamespace=ingress-apisix
```

> chart 1.2.0 对应 controller 1.10.0（**注意**：这个 chart 只在 GitHub release，不在 helm 仓库列表里直接搜得到，命令里写的是 GitHub release 路径）。

```bash
kubectl -n ingress-apisix wait --for=condition=ready pod \
  -l app.kubernetes.io/name=apisix-ingress-controller --timeout=300s
```

#### 4.2.4 【必做】把 chaitin-waf 插件元数据写进 etcd

```bash
# 1) 取 APISIX admin API key（chart 2.14.1 默认 key；生产请覆盖）
ADMIN_KEY=$(kubectl -n ingress-apisix get secret apisix-admin \
  -o jsonpath='{.data.admin-key}' | base64 -d; echo)

# 2) 把 Admin API 端口转发出来（或者用 in-cluster 域名直接访问）
kubectl -n ingress-apisix port-forward svc/apisix-admin 9180:9180 &

# 3) PUT 元数据
curl -X PUT \
  -H "X-API-KEY: $ADMIN_KEY" \
  -d @k8s/apisix-controller/waf-plugin-metadata.json \
  http://127.0.0.1:9180/apisix/admin/plugin_metadata/chaitin-waf
```

`waf-plugin-metadata.json` 内容（[文件](waf-plugin-metadata.json)）：

```json
{
  "nodes": [
    { "host": "safeline-detector.safeline-ce.svc.cluster.local", "port": 8000, "weight": 1 }
  ],
  "mode": "monitor",
  "config": {
    "connect_timeout": 1000,
    "send_timeout": 1000,
    "read_timeout": 1000,
    "req_body_size": 1024,
    "keepalive_size": 256,
    "keepalive_timeout": 60000,
    "real_client_ip": true
  }
}
```

> **为什么 `host` 必须是 FQDN（带 namespace 和 svc.cluster.local）而不是 ClusterIP？** Pod IP 会在 Pod 重启后变，FQDN 不会。所以任何指向 Pod 的配置都要用 Service DNS 名称。

> **为什么必须用 FQDN 而不是短名 `safeline-detector`？** APISIX 解析 DNS 时只查完整域名；不写后缀会得到 NXDOMAIN，进而 fail-open（`X-APISIX-CHAITIN-WAF: unhealthy`）。

期望响应：

```json
{"key":"/apisix/plugin_metadata/chaitin-waf","value":{"nodes":[...]},"count":"1"}
```

**如果失败**：检查 (a) port-forward 是否通；(b) admin key 是否对；(c) `nodes[0].host` 是否能解析——`kubectl -n ingress-apisix run -it --rm --restart=Never --image=busybox:1.36 dnscheck -- nslookup safeline-detector.safeline-ce.svc.cluster.local`。

### 4.3 步骤三：部署示例应用，验证 WAF 真的在工作

```bash
kubectl apply -f k8s/apisix-controller/example-app.yaml
```

`example-app.yaml` 包含 6 个资源（[文件](example-app.yaml)）：

| 资源 | 作用 |
| --- | --- |
| Namespace `demo-app` | 隔离示例应用 |
| ConfigMap `demo-app-html` + `demo-app-nginx-conf` | 演示页面 + nginx 配置 |
| Deployment `demo-app` | 两个 nginx Pod |
| Service `demo-app` | ClusterIP |
| Ingress `demo-app` | 声明 `demo.example.com → demo-app:80`，**关键**：`ingressClassName: apisix` |
| ApisixPlugin `waf-demo` | 给上面这条 Ingress 挂 chaitin-waf 插件，mode=monitor |

`ApisixPlugin` 的关键字段（[文件](waf-plugin.yaml)）：

```yaml
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

字段解释：
- `spec.ingressRefs`：把这个插件挂到哪个 Ingress 上（按名字+namespace 引用）。
- `spec.plugins[].name`：插件名，固定写 `chaitin-waf`。
- `spec.plugins[].enable`：false 就是"该 Ingress 关掉 WAF"（对应 ingress-nginx 时代的 `safeline.nginx.org/disable: "true"`）。
- `spec.plugins[].config.mode`：`monitor`（记录但不拦截）/ `block`（真拦截）/ `off`。
- `append_waf_resp_header`：每个响应都加 `X-APISIX-CHAITIN-WAF-ACTION` / `X-APISIX-CHAITIN-WAF-STATUS`。
- `append_waf_debug_header`：额外加 `X-APISIX-CHAITIN-WAF-SERVER`（连的是哪个 detector）等调试头。

### 4.4 步骤四：smoke test

```bash
# 拿 LB IP
APISIX_LB=$(kubectl -n ingress-apisix get svc apisix-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# 如果是 NodePort：
# APISIX_LB=127.0.0.1:$(kubectl -n ingress-apisix get svc apisix-gateway -o jsonpath='{.spec.ports[0].nodePort}')

# 1) 干净请求
curl -i -H "Host: demo.example.com" "http://$APISIX_LB/"
# 期望：200 OK，body 是 <h1>OK</h1>
# 响应头里有：X-APISIX-CHAITIN-WAF-ACTION: pass

# 2) SQL 注入
curl -i -H "Host: demo.example.com" \
  "http://$APISIX_LB/?id=1%27%20OR%20%271%27%3D%271"
# 期望：HTTP 403 + 响应头 X-APISIX-CHAITIN-WAF-ACTION: reject
# body: {"code":403,"success":false,"message":"blocked by Chaitin SafeLine Web Application Firewall","event_id":"..."}
```

> 同样套路可以测 XSS、路径穿越：
> - `?q=<script>alert(1)</script>` → 403
> - `?file=../../../etc/passwd` → 403

**在 mgt UI 里能看到事件**：
1. 暴露 mgt（绕开 WAF）：用 `kubectl port-forward`、NodePort、或独立 Ingress——任选一种。**为什么必须绕开 WAF、怎么绕、为什么不能用 `ingressClassName: apisix`** 详见 [`k8s/README.md` §6](../README.md#6-mgt-的访问不挂-waf)。
2. 浏览器开 mgt 的 URL，登录，**注意**这个端口走的链路是绕过 APISIX 的（直接到 mgt），所以不会触发 chaitin-waf。
3. 进 "Attack Logs" 应该能看到刚才被 403 的那条记录，`src_ip` 是你**真实的客户端 IP**（不是 LB 的 IP）——这就证明 `real_client_ip: true` 配置生效了。

---

## 5. 模式选择

| Mode | 行为 | 什么时候用 |
| --- | --- | --- |
| `off` | 插件关掉，请求直接放行 | 仅内网路由；上游是二进制流量（detector 解析不了） |
| `monitor` | 插件跑、攻击会记日志、但请求**照样放行** | 新接入的 Ingress；生产切 `block` 之前的灰度期，**至少跑 48 小时无误报** |
| `block` | 攻击直接 403 + JSON 体 | 已经在 monitor 跑干净 ≥ 48 小时的 Ingress |

**集群默认** = `helm-values.yaml` 里写的；**单 Ingress 覆盖** = ApisixPlugin CRD 里写的；后者优先级高。

**生产路径**（推荐流程）：
1. 新 Ingress 上线 → ApisixPlugin mode=monitor
2. 跑 48 小时
3. 看 mgt 的 Attack Logs，确认真实攻击都被识别、没误报
4. 把 ApisixPlugin mode 改成 `block` 重新 `kubectl apply`
5. 重复直到所有 Ingress 切完

---

## 6. 故障排查

| 现象 | 原因 / 验证 | 修法 |
| --- | --- | --- |
| 所有请求 `X-APISIX-CHAITIN-WAF: unhealthy` | detector 不可达 | `kubectl -n ingress-apisix exec -it deploy/apisix -- nc -zv safeline-detector.safeline-ce.svc.cluster.local 8000`；不通就检查 Service 名字、namespace、`plugin_metadata` 里的 `nodes` |
| 所有请求 `X-APISIX-CHAITIN-WAF: no` | 插件根本没在 route 上挂 | 检查 ApisixPlugin 的 `spec.ingressRefs[].name` 是不是写错了；`kubectl -n <ns> get apisixplugin -o yaml` 看 status |
| 所有请求 `X-APISIX-CHAITIN-WAF: err` + HTTP 500 | plugin_metadata 没写进 etcd（**最常见的坑**） | 重新跑 §4.2.4 的 curl PUT |
| 误拦截正常请求 | 业务流量被规则误命中 | 临时把 ApisixPlugin mode 改成 `monitor`；去 mgt UI 的策略编辑器加白名单；稳定后改回 `block` |
| mgt UI 进不去 / 502 | mgt 的 Ingress 也被 chaitin-waf 挡了 | mgt 必须走**独立的 Ingress（无 ApisixPlugin）或 NodePort**——原因和三种方案（port-forward / NodePort / 独立 IngressClass）详见 [`k8s/README.md` §6](../README.md#6-mgt-的访问不挂-waf) |
| mgt Attack Logs 里 `src_ip` 是 LB IP | `real_client_ip: true` 没生效或 LB 网段不在 `trusted_addresses` | 改 `helm-values.yaml`，`helm upgrade`；同时把 LB CIDR 加到 `apisix.trusted_addresses` |
| APISIX Pod 起不来 / CrashLoopBackOff | etcd 还没起好就被 APISIX 连 | 等；或者降副本为 1 重试；新装一般 30 秒内恢复 |

---

## 7. tier3-test 跟本 README 的对应关系（重要）

`tier3-test/` 是我们在 arm64 Mac + OrbStack 1 节点 k8s + chaitin amd64 镜像（qemu 模拟）上**真实跑通过**的一组清单。它是验证集，**不是产品部署模板**。下面是它跟本 README 的精确对应，以及哪些 hack 是为什么、哪些生产不需要。

| README 步骤 | tier3-test 文件 | 一致性 / 偏离原因 |
| --- | --- | --- |
| §4.1 控制面 ready | `00-namespace.yaml` + `01-secrets-config.yaml` + `10-pg.yaml` + `20-detector.yaml` + `30-mgt.yaml` + `40-fvm-luigi-chaos.yaml` + `41-luigi.yaml` | **生产用 tier3-test 同样的 yaml 即可**（amd64 节点无需 §7.1 列出的 qemu 绕过）。详细部署步骤见 [`k8s/README.md`](../README.md) §3。 |
| §4.2.2 helm install apisix | `helm install apisix apisix/apisix --version 2.14.1 -f helm-values.yaml` | **一致**。tier3-test README 里的命令和本 README 一样。 |
| §4.2.3 helm install ingress controller | `helm install apisix-ingress-controller apisix/apisix-ingress-controller --version 1.2.0` | **一致**。 |
| §4.2.4 PUT plugin_metadata | `tier3-test/README.md` 步骤 3 | **一致**（admin key 都是 chart 2.14.1 默认 `edd1c9f...`）。 |
| §4.3 示例应用 | `example-app.yaml` | **一致**。 |

### 7.1 tier3-test 里**生产不需要**的 hack

读 tier3-test 时请忽略以下绕过，它们是 arm64 + qemu-user-static 模拟 amd64 镜像引入的环境问题：

1. **`10-pg.yaml` 里的 `initContainer fix-perms`**：OrbStack 用 local-path provisioner，PVC 是 root:root 拥有；`runAsUser: 999`（postgres 镜像默认用户）起不来，所以加一个特权 init 容器 chown。**生产用云厂商块存储或带 fsGroup 的 StorageClass 都不需要**。

2. **`10-pg.yaml` 里用 `args: ["-c", "max_connections=600"]` 而不是 `command:`**：postgres 镜像的 entrypoint 会跑 `initdb`（首次启动建库），一旦用 `command:` 整个覆盖了 entrypoint，`initdb` 不跑，库永远是空的。把 `postgres -c ...` 当作 `args:` 让 entrypoint 先跑、再把参数转给真正的 `postgres` 二进制。**这条规则任何时候都适用**，不只是 arm64。

3. **`20-detector.yaml` 的 initContainer + 完整 shell 脚本（不用 koopa）**：detector 镜像的入口是个 `koopa` 进程管理器，它会每 5 分钟跑一次健康检查，发现 detect engine 是 `de-0 offline`（意思是 mgt 还没把规则推过来）就自杀。在 amd64 节点上 mgt 能正常推规则、engine 上线、koopa 不杀；但 arm64 OrbStack 上 mgt 的 Go 二进制是 qemu 模拟的、监听 8000 的 socket 在 host netns 看不到，所以推规则这条链路断了、koopa 把 detector 杀了。**生产用 amd64 节点就不需要这个绕过**，直接用镜像默认 entrypoint 即可。

4. **`30-mgt.yaml` 里 mgt 在 arm64 上 Web UI 502**：同 #3，nginx upstream 拿不到 qemu 模拟的 `:8000`。**生产 amd64 节点没有这个问题**。即使 arm64 跑生产，也不影响 WAF 主链路（APISIX 是直连 detector 的 T1K 端口，不经过 mgt）。

5. **`41-luigi.yaml` 拆出来单独 apply**：tier3-test README 提到 luigi 的多文档 yaml 偶尔让 parser 卡住，所以拆成两个文件分别 apply。**生产一个文件 apply 即可**。

6. **`40-fvm-luigi-chaos.yaml` 里 luigi 部分和 `41-luigi.yaml` 重复**：是上面 #5 那个 hack 的副作用。生产不需要。

7. **detector Service 命名（带 r vs 无 r）**：mgt 的 Go 代码里硬编码的是 `http://safeline-detector:8001/update/policy`（**带 r**）。如果 Service 命名错了，mgt 推规则这条链路会断。本 README 全部示例都用带 r 的正确命名；老版本配置文件里如果有写 `safeline-detect`（无 r）的，详见 §7.2。

### 7.2 detector Service 的命名：必须带 `r`

`mgt` 的 Go 代码内部硬编码了 `http://safeline-detector:8001/update/policy`（**带 r**），用来推规则到 detector。所以 detector 的 Service **必须**叫 `safeline-detector`，不能叫 `safeline-detect`。本 README 的所有示例（§4.2.2、§4.2.4、§6 故障排查）都已经用了正确的带 r 命名；如果你看到任何文档或遗留配置文件写的是 `safeline-detect`（无 r），请改成带 r。

`tier3-test/20-detector.yaml` 已经用对了名字（带 r），是从 arm64 测试里踩出来的真坑。

### 7.3 tier3-test 验证过的结果（汇总）

- ✅ detector 通过 Service FQDN 在 APISIX 可达（用 pod IP 重启后失效，已避免）
- ✅ APISIX 在 `block` 模式下真的拦截 SQLi / XSS / 路径穿越
- ✅ `monitor` 模式放行 + 落日志
- ✅ mgt 走不带 chaitin-waf 的独立 Ingress 时不受 WAF 影响
- ⚠️ 已知遗留（arm64 专属）：mgt Web UI、luigi 启动、chaos 鉴权在 OrbStack 上受限（amd64 节点无此问题）

---

## 8. 进阶操作

### 8.1 给已有业务 Ingress 加 WAF

复制 `waf-plugin.yaml` 里模板 1（monitor 模式）的内容到新文件，改三个字段：

```yaml
metadata:
  name: waf-my-app                # ← 改：唯一即可
  namespace: my-app               # ← 改：你的业务 ns
spec:
  ingressRefs:
    - name: my-app-ingress        # ← 改：你已有的 Ingress 名
      namespace: my-app
  plugins:
    - name: chaitin-waf
      enable: true
      config:
        mode: monitor
        append_waf_resp_header: true
        append_waf_debug_header: true
```

`kubectl apply -f waf-my-app.yaml`。controller 会自动 reconcile 出一条新 route。

### 8.2 从 ingress-nginx 迁移

完整 playbook 见 [`upgrade-from-ingress-nginx.md`](upgrade-from-ingress-nginx.md)。核心流程：

1. 装 APISIX 和 ingress controller（**和现有的 ingress-nginx 并存**）
2. PUT plugin_metadata（§4.2.4）
3. 挑一个低流量 Ingress 做金丝雀：给它一个 ApisixPlugin (mode=monitor)，DNS 切到 APISIX 的 LB
4. 跑 ≥ 48 小时无误报
5. ApisixPlugin 改 mode=block
6. 剩下的 Ingress 批量迁移
7. `helm uninstall ingress-nginx`，删 `ingress-nginx` namespace

控制面**完全不动**——只换数据面。

### 8.3 升级

```bash
# 升级 APISIX gateway（保留 values）
helm upgrade apisix apisix/apisix \
  --namespace ingress-apisix \
  --reuse-values \
  --version <新版本>

# 升级 ingress controller
helm upgrade apisix-ingress-controller apisix/apisix-ingress-controller \
  --namespace ingress-apisix \
  --reuse-values \
  --version <新版本>

# 升级完成后**重新 PUT 一次 plugin_metadata**（保险起见）
# 命令见 §4.2.4
```

### 8.4 版本钉死建议

| 组件 | 钉死版本 | 来源 |
| --- | --- | --- |
| APISIX helm chart | 2.14.1 | 仓库根 `version.json` 同步 |
| APISIX 镜像 | 3.16.0 | chart 2.14.1 自带 |
| apisix-ingress-controller chart | 1.2.0 | 同上 |
| apisix-ingress-controller 镜像 | 1.10.0 | chart 1.2.0 自带 |
| bitnami/etcd | 3.5 | chart 2.14.1 子 chart |
| SafeLine 各镜像 | 见 `version.json` | `latest_version` / `rec_version` / `lts_version` |

chaitin-waf 插件是 APISIX 上游维护，跟 SafeLine 发版**解耦**——APISIX 升 3.x 不会影响 SafeLine 兼容性。

---

## 9. 安全提醒

- **APISIX admin API 必须不暴露到公网**。默认 `apisix-admin` Service 是 ClusterIP 9180，外部访问不到——**不要**手动改成 LoadBalancer 或 NodePort。
- **APISIX admin key 是 chart 默认值 `edd1c9f034335f136f87ad84b625c8f1`**——生产必须改。在 `helm-values.yaml` 加 `apisix.admin.credentials.admin: <新 key>` 然后 `helm upgrade`。
- **etcd `rootPassword` 在 chart 渲染后是明文**（不是 Secret 引用）——生产要么用外部 etcd，要么在 apply 前 grep 一下清单再决定要不要改。
- **mgt UI 不要挂 chaitin-waf**——这是真生产事故。给 mgt 一个独立 IngressClass（`ingressClassName: nginx` 之类）或者直接 NodePort / `kubectl port-forward`。原因和具体示例见 [`k8s/README.md` §6](../README.md#6-mgt-的访问不挂-waf)。
- **不要在生产给 detector 用 unix socket**——k8s 跨 Pod 不通。

---

## 10. 相关文档

- 设计文档：[`docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md`](../../docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md)
- 控制面部署（必读前置）：[`k8s/README.md`](../README.md)
- 控制面 yaml（产品级）：[`k8s/apisix-controller/tier3-test/`](tier3-test/)
- 从 ingress-nginx 迁移的 playbook：[`k8s/apisix-controller/upgrade-from-ingress-nginx.md`](upgrade-from-ingress-nginx.md)
- 顶层仓库说明（[`AGENTS.md`](../../AGENTS.md)）的 "Data plane migration" 段
