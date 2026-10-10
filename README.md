# Sing-Box 配置与分流规则维护参考

本仓库维护适用于 **Sing-Box 官方内核（1.14+）** 的五端（Windows / Linux / OpenWrt / Android / iPhone）配置与配套 FakeIP 过滤规则集。

---

## 1. 目录结构

```text
├── config/
│   ├── windows.json          # Windows 桌面端配置（支持 Bridge 驱动级直连）
│   ├── linux.json            # Linux 桌面/旁路由端配置（支持内核级 action: bypass）
│   ├── openwrt.json          # OpenWrt 路由器配置（含 Tailscale/BlockAD/Game 等专属规则）
│   ├── android.json          # Android 移动端配置（针对 Root 设备，支持内核 bypass + App 包名分流）
│   └── iphone.json           # iPhone / iPad 移动端配置（适配 iOS 沙盒与原生 Headscale 端点）
├── rules/
│   ├── fakeipfilter-cn.json  # 国内 FakeIP 过滤规则集（走 ali H3 解析真实 IP）
│   └── fakeipfilter-!cn.json # 海外 FakeIP 过滤规则集（走 google DoH 解析真实 IP）
├── scripts/
│   └── substore-endpoint.js  # Sub-Store 动态注入 Headscale / Tailscale Endpoint 的专用脚本
└── README.md                 # 配置差异对照与维护速查文档
```

---

## 2. 五端配置差异速查表

五端配置的 **`dns` 核心逻辑、`http_clients`、`route.rule_set` 基础集以及核心分流规则一致**，仅在底层网络栈适配、后台管理服务与特有分流规则上存在平台差异：

| 模块 / 配置项 | `windows.json` (Windows) | `linux.json` (Linux) | `openwrt.json` (OpenWrt) | `android.json` (Android Root) | `iphone.json` (iPhone) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **特殊出站 (`outbounds`)** | 额外包含 `🌉 Bridge` (bridge) | 无 | 无 | 无 | 无 |
| **首条路由 (`route.rules[0]`)** | `preferred_by: ["🌉 Bridge"]` 走桥接（含内网/国内 IP） | `tun-in` 非全局下私有/非 Tailscale/国内 IP `bypass` | `tun-in` 非全局下私有/非 Tailscale/国内 IP `bypass` | 非全局下私有/非 Tailscale/国内 IP `bypass` | 无（直接从 sniff 开始） |
| **TUN 入站** | `platform.http_proxy` (`127.0.0.1:7890`) | `auto_redirect: true` | `auto_redirect: true` | `auto_redirect: true` (支持 Root 内核重定向) | `platform.http_proxy` (`127.0.0.1:7890`) |
| **混合入站** | `0.0.0.0:7890` | `0.0.0.0:7890` | `0.0.0.0:7890` | `127.0.0.1:7890`（移动安全绑定） | `127.0.0.1:7890`（移动安全绑定） |
| **API 服务 (`services[api]`)** | `0.0.0.0:9090`（纯 API，供自建统一面板连接） | `0.0.0.0:9090`（纯 API，供自建统一面板连接） | `0.0.0.0:7714`（纯 API，供自建统一面板连接） | 无（由安卓客户端 UI 接管） | 无（由 iOS 客户端接管） |
| **缓存文件** | `store_dns: true` | `path: /etc/sing-box/cache.db`, `store_dns: true` | `path: /etc/sing-box/cache.db`, `store_dns: true` | `store_fakeip: true` | `store_fakeip: true` |
| **NTP 同步** | 启用 (`time.apple.com`) | 启用 (`time.apple.com`) | 启用 (`time.apple.com`) | 无 | 无 |
| **Headscale / Tailscale** | ✅ 原生端点 (`tailscale-ep`) | ✅ 原生端点 (`tailscale-ep`) | ✅ 原生端点 (`tailscale-ep`) | ✅ 原生端点 (`tailscale-ep`) | ✅ 原生端点 (`tailscale-ep`) |
| **应用包名分流 (`package_name`)** | 无 | 无 | 无 | ✅ 微信/支付宝/网银/高德 App 强制直连防风控 | 无（iOS 系统沙盒限制） |
| **策略组命名风格** | **统一 Emoji + 英文**（支持各业务组独立选节点） | **统一 Emoji + 英文**（支持各业务组独立选节点） | **统一 Emoji + 英文**（支持各业务组独立选节点） | **统一 Emoji + 英文**（支持各业务组独立选节点） | **统一 Emoji + 英文**（支持各业务组独立选节点） |
| **DNS 架构** | **HTTP/3 (`ali`)** + `prefer_ipv4` + FakeIP 双栈 | **HTTP/3 (`ali`)** + `prefer_ipv4` + FakeIP 双栈 | **HTTP/3 (`ali`)** + `prefer_ipv4` + FakeIP 双栈 | **HTTP/3 (`ali`)** + 纯 IPv4（TUN 仅 IPv4，拦截 AAAA 与 IPv6） | **HTTP/3 (`ali`)** + 纯 IPv4（TUN 仅 IPv4，拦截 AAAA 与 IPv6） |
| **Game & Steam 规则** | **三层优化**（国服/下载直连，联机直连，社区/商店代理） | **三层优化**（国服/下载直连，联机直连，社区/商店代理） | **三层优化**（国服/下载直连，联机直连，社区/商店代理） | **三层优化**（国服/下载直连，联机直连，社区/商店代理） | **三层优化**（国服/下载直连，联机直连，社区/商店代理） |
| **Apple 服务** | 统一直连（`🎯 Direct`） | 统一直连（`🎯 Direct`） | 统一直连（`🎯 Direct`） | 统一直连（`🎯 Direct`） | 统一直连（`🎯 Direct`） |
| **家庭透明代理与直连模式** | 直连模式（`Direct`）下 DNS 走 `local`（局域网 DHCP），流量走桥接 | 直连模式（`Direct`）下 DNS 走 `local`（局域网 DHCP），流量内核 bypass 直通 | 本机即为透明代理宿主机 | 连入 `KsRouter` 自动内核 bypass + local DNS；支持 Direct 模式 | 连入 `KsRouter` 自动走直连 + local DNS；支持 Direct 模式 |

---

## 3. 公共核心架构与日常维护指南

修改以下公共模块时，请保持 `windows.json`、`linux.json`、`openwrt.json`、`android.json`、`iphone.json` 五端同步更新：

### 3.1 DNS 解析流水线 (`dns`)
1. **屏蔽 HTTPS/SVCB 与移动端彻底关闭 IPv6**：拒绝 `HTTPS` 和 `SVCB` 查询防止客户端绕过分流；在移动端（`iphone.json` / `android.json`）TUN 入站仅配置 IPv4 地址，前置拒绝 `AAAA` 查询且使用 `ipv4_only` 策略，路由规则拦截所有 `ip_version: 6` 流量，从系统内核层彻底关闭移动端 IPv6 协议族，根治移动网络/公共 Wi-Fi 无公网 IPv6 导致的 Happy Eyeballs 超时与网络假死（Tailscale 走 `100.64.0.0/10` IPv4 互联）。
2. **模式优先**：`Direct` 模式 DNS 默认走 `local`（局域网 DHCP/原生 DNS，不污染不二次转发），`Global` 模式返回 `fakeip`。连入家庭部署透明代理的 Wi-Fi（如 `KsRouter`）时，客户端切换为直连（Direct）模式即可获得最高性能与原生局域网 DNS。
3. **FakeIP 过滤**：
   - 命中 `fakeipfilter-cn`、`geosite-cn`、`geosite-microsoft@cn`、`geosite-apple@cn`、`geosite-private` $\rightarrow$ 走 `ali` 解析真实国内 IP。
   - 命中 `fakeipfilter-!cn`（STUN、NTP、游戏联机等不可用 FakeIP 的海外域名） $\rightarrow$ 走 `google`（通过 `默认代理` 出站）解析真实海外 IP。
4. **未知域名探测**：对非 `geosite-geolocation-!cn` 的 `A/AAAA` 查询，先通过 `google` 携带 `client_subnet: 223.5.5.0/24` 进行 `evaluate` 评估；若返回 IP 命中 `geoip-cn` 则交由 `ali` 解析，否则分配 `fakeip`（`198.19.0.0/16`，`rewrite_ttl: 1`）。

### 3.2 新增或调整分流规则
当需要新增一个业务分流（例如新增规则集与对应策略组）时，按顺序在五端同步修改 3 处：
1. **`outbounds`**：
   - 在业务策略组区域新增 `{"tag": "策略名", "type": "selector", "outbounds": ["日本手动", "狮城手动", "香港手动", "美国手动", "手动选择", "自动选择"]}`。
   - 将 `"策略名"` 同步加入 `"GLOBAL"` 策略组的 `outbounds` 列表中。
2. **`route.rules`**：
   - 在 `geosite-geolocation-!cn` 兜底代理规则**之前**插入对应的 `{"rule_set": "geosite-xxx", "outbound": "策略名"}`。
3. **`route.rule_set`**：
   - 将 `"geosite-xxx"` 标签添加至 `SagerNet/sing-geosite` 远程规则集对象的 `tag` 数组中。

### 3.3 维护 FakeIP 过滤列表 (`rules/`)
- 若国内应用/网银/本地服务因 FakeIP 异常，将域名补充至 [`rules/fakeipfilter-cn.json`](file:///d:/Git/SingBox_Rules/rules/fakeipfilter-cn.json)。
- 若海外游戏/语音/STUN/NTP 服务因 FakeIP 异常，将域名补充至 [`rules/fakeipfilter-!cn.json`](file:///d:/Git/SingBox_Rules/rules/fakeipfilter-!cn.json)。
- 若 Fork 到个人仓库使用，请将五端配置 `route.rule_set` 中 `fakeipfilter-cn` / `fakeipfilter-!cn` 的 `url` 替换为自己的仓库地址。

---

## 4. Sub-Store 节点填充脚本参考

五端配置文件中的 `🌍 Proxy` 核心代理策略组默认留空 `"outbounds": []`，杜绝自动更新时默认回退到直连，统一通过 **Sub-Store** 远程脚本自动填充节点：

```text
https://gh-proxy.com/https://raw.githubusercontent.com/xream/scripts/main/surge/modules/sub-store-scripts/sing-box/template.js#type=组合订阅&name=singbox&outbound=🕳ℹ️手动选择|自动选择🏷ℹ️^(?!.*(?:官网|剩余|流量|套餐|免费|订阅|到期时间|直连|GB|Expire Date|Traffic|ExpireDate)).*🕳ℹ️香港手动🏷ℹ️^(?!.*(?:ZJ|zijian|自建)).*(🇭🇰|HK|hk|香港|港|HongKong)🕳ℹ️日本手动🏷ℹ️^(?!.*(?:ZJ|zijian|自建)).*(🇯🇵|JP|jp|日本|日|Japan)🕳ℹ️狮城手动🏷ℹ️^(?!.*(?:ZJ|zijian|自建)).*(新加坡|坡|狮城|SG|Singapore)🕳ℹ️美国手动🏷ℹ️^(?!.*(?:ZJ|zijian|自建|AUS|RUS)).*(🇺🇸|US|us|美国|美|United States)
```

### 参数修改说明
- `type=组合订阅`：若使用单条订阅请改为 `type=单条订阅`（或省略 `type` 参数）。
- `name=singbox`：需与你在 Sub-Store 中创建的订阅/组合订阅名称一致。
- `🕳ℹ️策略组名称🏷ℹ️正则表达式`：用于将匹配的节点注入对应策略组，如需排除或包含自建节点，可按需调整正则中的 `(?!.*(?:ZJ|zijian|自建))` 条件。

> [!TIP]
> **五端 Sub-Store 节点注入参考（支持业务组独立选节点）**：
> 当前配置已精简为统一 Emoji 英文命名，若希望 `🌍 Proxy` 拥有全部节点，且 `🤖 AI`、`📹 YouTube`、`🔍 Google` 等业务组也能单独点选具体节点，可在 Sub-Store 模板参数中指定：
> ```text
> #outbound=🕳ℹ️🌍 Proxy|🤖 AI|📹 YouTube|🔍 Google|🐙 GitHub|✈️ Telegram|💳 Wallet|🎮 Steam|Ⓜ️ Microsoft|☁️ OneDrive🏷ℹ️^(?!.*(?:官网|剩余|流量|套餐|免费|订阅|到期时间|直连|GB|Expire Date|Traffic|ExpireDate)).*
> ```
> 这样在 Web 面板中，每个业务组既能默认选择跟随 `🌍 Proxy`，也能直接勾选某个特定国家或线路的独立节点。

---

## 5. Sub-Store 动态配置 Tailscale / Headscale Endpoint (1.14 全特性) 脚本

五端配置文件模板中默认**不硬编码** `control_url`、`hostname`、`advertise_tags`、`auth_key`、`advertise_routes` 等私有信息与冗余规则，全部通过专属脚本 [`scripts/substore-endpoint.js`](file:///d:/Git/SingBox_Rules/scripts/substore-endpoint.js) 的 URL Hash 参数动态传入控制。

### 五端内置 1.14 精简架构与能力概览
- **零硬编码默认模板**：默认仅开启 `accept_routes: true`、`listen_port: 41641` 及平台对应的 `ssh_server: true`（`iphone.json` 因 iOS 沙盒限制不开启）。
- **原生 MagicDNS (`ts-dns`)**：启用 `accept_search_domain: true` 与 `preferred_by: "ts-dns"`，支持单标签短主机名直连。
- **动态子网路由 (`preferred_by`)**：移除硬编码的 `100.64.0.0/10` 等冗余规则，统一由 `preferred_by: ["tailscale-ep"]` 动态匹配 Tailscale 虚拟内网及所有远端子网路由；OpenWrt / Linux 同时支持异地设备入站访问局域网子网路由（自动用户态 SNAT 转发）。
- **全动态传参注入**：支持按需注入 `control_url`、`hostname`、`auth_key`、`advertise_routes` 及 4 个 ACL 标签（`tag:luoking`、`tag:luoking-share`、`tag:relay`、`tag:rephael`）。

### 使用方法
在 Sub-Store 的【订阅产物 (Artifact)】中，为对应 Sing-box 配置添加该脚本作为处理脚本，并通过 URL Hash 传递你的私有配置参数：

```text
https://gh-proxy.com/https://raw.githubusercontent.com/RaphealK/SingBox_Rules/main/scripts/substore-endpoint.js#control_url=https://mesh.luokinging.com&auth_key=tskey-auth-xxxxxx&advertise_routes=192.168.31.0/24&tags=tag:luoking,tag:luoking-share,tag:relay,tag:rephael
```

### 脚本参数说明
- **控制面与身份**：
  - `control_url` / `url`: Headscale 控制面完整地址（传入后自动注入控制面域名直连 DNS 规则防 FakeIP 污染）
  - `auth_key` / `key`: Headscale 预授权 Key（不传则通过客户端或 Web 面板交互式登录）
  - `hostname`: 节点在控制面板显示的名称（不传则由 Sing-Box 1.14 自动使用系统主机名/设备名）
  - `tags` / `advertise_tags`: 逗号分隔的 ACL 标签列表，如 `tag:luoking,tag:luoking-share,tag:relay,tag:rephael`（不传则作为个人设备，支持 Taildrop）
- **核心路由与中继控制**：
  - **是否广播内网地址** (`advertise_routes` / `routes`): 逗号分隔的广播内网子网 CIDR（如 `advertise_routes=192.168.31.0/24`）；不传或传 `false` 则不广播内网地址。
  - **是否接收地址** (`accept_routes` / `accept`): 是否接收其他节点广播的子网路由，传 `true` 或 `false`（默认 `true`）。
  - **是否作为 Peer Relay 节点** (`peer_relay` / `relay` / `relay_server_port`):
    - 传 `peer_relay=true`（或 `relay=true`）：启用 Peer Relay 并默认监听 `40000` 端口；
    - 传具体端口号如 `peer_relay=40000`（或 `relay_server_port=40000`）：启用并监听指定端口；
    - 配合 `relay_endpoints` / `relay_server_static_endpoints`（如 `relay_endpoints=8.134.36.157:40000`）：指定静态公网中继地址；
    - 不传或传 `false`：不作为 Peer Relay 节点。
- **其他可选参数**：
  - `listen_port`: WireGuard P2P 监听 UDP 端口（默认 `41641`）
  - `ssh_server`: 是否启用内置 Tailscale SSH/SFTP 服务端（`true` 或 `false`）
  - `taildrop_directory` / `taildrop`: Taildrop 文件接收保存目录
  - `state_directory`: 状态持久化目录
  - `advertise_exit_node`: 是否将本节点广播为出口节点（`true` 或 `false`）
  - `exit_node`: 指定使用的出口节点名称或 IP
  - `tag`: Endpoint 标签名（默认 `tailscale-ep`）

