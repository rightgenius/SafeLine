# t1k-controller 镜像构建与配置

本目录放的是把 SafeLine 的 t1k 插件装进 ingress-nginx controller 镜像的**一站式脚本和样例 yaml**。

## 30 秒快速开始

```bash
# 1. 拉官方 Chaitin 镜像（默认行为，零编译）
./build.sh

# 2. 用这个镜像装 ingress-nginx（helm 路径）
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.image.repository=safeline-t1k-controller \
  --set controller.image.tag=v1.10.1 \
  --set controller.image.pullPolicy=IfNotPresent

# 3. 配置插件（host / port / mode 等）和启用插件
kubectl apply -f controller-config.yaml

# 4. 给 controller Deployment 注入 env（参考 controller-config.yaml 末尾的 env 段）

# 5. 部署测试应用
kubectl apply -f example-app.yaml

# 6. 验证（SQL 注入）
curl -i "http://demo.example.com/?id=1' OR '1'='1"
# monitor 模式：200 + 攻击记录出现在 mgt 控制台
# block 模式：200 + JSON {"code":403, "success":false, "message":"blocked by Chaitin..."}
```

## 在 GHA 上构建（推荐 / 国内网络环境）

如果本地拉不到 `registry.k8s.io`（国内常见），让 GitHub Actions 海外 runner 帮你 build，然后推到你的阿里云 ACR：

```bash
# 1. fork chaitin/SafeLine
# 2. 在 fork 里设 4 个 secret（Settings → Secrets and variables → Actions）：
#    ALIYUN_REGISTRY    例：registry.cn-hangzhou.aliyuncs.com
#    ALIYUN_NAMESPACE   例：hehealth
#    ALIYUN_USERNAME    阿里云账号邮箱
#    ALIYUN_PASSWORD    ACR 访问凭证密码（不是阿里云主账号密码）
# 3. 在 fork 触发 workflow：
#    Actions → Build SafeLine t1k Controller → Run workflow
#    填 upstream_tag=controller-v1.15.1，image_tag 留空
# 4. 等几分钟，输出镜像就在
#    $ALIYUN_REGISTRY/$ALIYUN_NAMESPACE/safeline-t1k-controller:controller-v1.15.1
# 5. 本地跑：
#    UPSTREAM_IMAGE=$ALIYUN_REGISTRY/$ALIYUN_NAMESPACE/ingress-nginx/controller \
#    UPSTREAM_TAG=controller-v1.15.1 \
#    ./build.sh
```

详细步骤见 `.github/workflows/build-t1k-controller.yml` 顶部的注释。

## 跟上 nginx / ingress-nginx 0day

```bash
# 看自己离最新版差多远
./build.sh --check-upstream

# 真的落后了，交互式一键 rebuild（要 TTY）
./build.sh --check-upstream --upgrade

# 不想被提示？source build 时跳过
UPSTREAM_CHECK=skip BUILD_FROM_SOURCE=true ./build.sh
```

`--check-upstream` 走 GitHub API 拉 `kubernetes/ingress-nginx` 的最新 stable release，跟你当前 `UPSTREAM_TAG` 对比。落后时会打印：精确的 rebuild 命令、helm 升级命令、相关的 nginx / ingress-nginx advisory 链接。`--upgrade` 在 TTY 下会直接问"rebuild now? [y/N]"，回 y 就 `exec` 重跑一遍。

注意：ingress-nginx 从某个版本开始 tag 命名变成了 `vcontroller-vX.Y.Z`（区别于 chart 的 `vX.Y.Z`），脚本会原样用这个 tag 名。

## 文件清单

| 文件 | 用途 |
| --- | --- |
| `build.sh` | 拉/构建 controller 镜像的入口脚本 |
| `Dockerfile` | 源码构建用的 Dockerfile（`BUILD_FROM_SOURCE=true` 时使用） |
| `controller-config.yaml` | 插件配置 ConfigMap + controller ConfigMap patch + env 段 |
| `example-app.yaml` | 一个 nginx demo 应用 + Ingress，用来验证 WAF |

## 两种构建模式

### 默认：拉官方 Chaitin 镜像（推荐）

Chaitin 已经在 DockerHub 发布了预装 safeline 插件的 controller：

```
docker.io/chaitin/ingress-nginx-controller:v1.10.1
```

`build.sh` 做的只是 `docker pull` + `docker tag`：

```bash
./build.sh
# 输出：safeline-t1k-controller:v1.10.1
```

优势：
- 0 编译，秒级完成
- tag 跟官方 controller 严格对齐（v1.10.1）
- 不需要装 luarocks / gcc / 网络到 luarocks.org

### 源码构建：自定义

要改 rockspec 版本、加自己的 lua 模块、或者想完全掌控镜像内容时使用：

```bash
BUILD_FROM_SOURCE=true ./build.sh
```

源码构建做了什么：
1. 起 `registry.k8s.io/ingress-nginx/controller:v1.10.1` 当基础
2. 装 luarocks
3. 用 luarocks 安装 `sdk/ingress-nginx/` 里最新版的 rockspec（顺带装 `lua-resty-t1k` 依赖）
4. 把装好的 `safeline` lua 模块 symlink 到 `/etc/nginx/lua/plugins/`（ingress-nginx 插件框架的发现路径）
5. 跑 `luarocks list` 做冒烟测试

需要的工具：
- docker（>= 19.03，要支持 buildkit secrets/build args）
- 多平台构建还需要 `docker buildx`
- 能联网到 `luarocks.org`（国内可以用 `LUAROCKS_SERVER=https://luarocks.cn`）

## 常用环境变量

`build.sh` 一切配置都走 env。常用的几个：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BUILD_FROM_SOURCE` | `false` | `true` 走源码构建 |
| `IMAGE_NAME` | `safeline-t1k-controller` | 输出镜像名 |
| `IMAGE_TAG` | `v1.10.1` | 输出 tag |
| `REGISTRY` | 空 | 镜像名前缀（如 `ghcr.io/your-org`） |
| `PUSH` | `false` | 构建完是否 push |
| `PLATFORMS` | 空（native arch） | 源码构建时多平台，如 `linux/amd64,linux/arm64` |
| `UPSTREAM_TAG` | `v1.10.1` | 基础 controller 镜像 tag |
| `LUAROCKS_SERVER` | `https://luarocks.org` | 国内可换 `https://luarocks.cn` |
| `ROCKSPEC` | 自动选最新版 | 指定 rockspec 文件名 |
| `UPSTREAM_CHECK` | `auto` | `skip` 关掉源构建时的滞后提示 |

## 工作流示例

### 本地开发（Mac arm64，单平台）

```bash
cd k8s/t1k-controller
./build.sh
# 装 ingress-nginx（参考上面"30 秒快速开始"）
```

### 推到自己的 registry

```bash
PUSH=true REGISTRY=ghcr.io/your-org \
  IMAGE_NAME=safeline-t1k-controller \
  IMAGE_TAG=v1.10.1-mybuild1 \
  ./build.sh
```

### 完全自定义（不同 controller 版本 + 自己的 rockspec）

```bash
BUILD_FROM_SOURCE=true \
  UPSTREAM_TAG=v1.11.2 \
  ROCKSPEC=../sdk/ingress-nginx/ingress-nginx-safeline-1.0.4-1.rockspec \
  ./build.sh
```

### 国内构建

```bash
BUILD_FROM_SOURCE=true \
  LUAROCKS_SERVER=https://luarocks.cn \
  ./build.sh
```

## 跟 k8s/README.md 配套

- `k8s/README.md` 的第 9 节（"ingress-nginx + t1k 插件"）是完整的部署文档
- 本目录的脚本是"如何得到一个能用的 controller 镜像"以及"如何配置它"
- `k8s/README.md` 的第 5-8 节是 SafeLine 自身（mgt / detector / pg / ...）的部署，跟本目录互补

## 已知限制

- 插件被 controller 全局启用后，**所有 Ingress 默认都过 WAF**。想给单个 Ingress 关掉，加 annotation `safeline.nginx.org/disable: "true"`（具体注解名以你 controller 版本为准；查 ingress-nginx 插件框架文档确认）
- 拦截时返回 200 + JSON，不是 403（这是插件设计，不是错）
- Lua t1k 只能看请求侧，**响应侧清洗 / cookie 防护 / bot challenge** 这些要做得上企业版 C T1K
- detector 挂掉时插件行为是 fail-open（请求放行）。要做 fail-closed 需要自己改 `sdk/ingress-nginx/lib/safeline/main.lua` 的 `rewrite()` 逻辑，然后走源码构建
- ingress-nginx 插件框架的 annotation 名字在版本之间可能变；升级 controller 时需要查对应版本的 changelog
