/**
 * Sub-Store 脚本：动态配置与注入 Sing-box (1.14+) 的 Tailscale / Headscale Endpoint
 * 
 * 设计准则：
 * 1. 配置文件模板中默认不包含 control_url、hostname、advertise_tags、auth_key 等私有或设备特定参数
 * 2. 所有上述内容及 1.14 进阶特性完全通过 Sub-Store URL Hash 参数动态传入控制
 * 3. 自动同步 MagicDNS (dns.servers[ts-dns])、控制面直连 DNS 解析与 preferred_by 动态子网路由
 * 
 * 示例 URL 调用参数：
 * https://gh-proxy.com/https://raw.githubusercontent.com/RaphealK/SingBox_Rules/main/scripts/substore-endpoint.js#control_url=https://mesh.luokinging.com&auth_key=tskey-auth-xxxxxx&hostname=windows-singbox&tags=tag:luoking,tag:luoking-share,tag:relay,tag:rephael
 * 
 * 支持的动态参数：
 * - control_url / url: Headscale 协调服务器完整地址（传入后自动注入控制面域名直连 DNS 规则）
 * - hostname: 节点名称（不传则由 Sing-Box 1.14 自动使用系统主机名/设备名）
 * - tags / advertise_tags: 逗号分隔的 ACL 标签列表，支持：
 *     tag:luoking, tag:luoking-share, tag:relay, tag:rephael（可省略 tag: 前缀）
 * - auth_key / key: 预授权密钥（不传则通过客户端或 Web 面板交互式登录）
 * - advertise_routes / routes: 逗号分隔的广播内网子网路由 CIDR（如 192.168.31.0/24；不传或传 false 则不广播）
 * - accept_routes: 是否接收其他节点广播的子网路由，true 或 false（默认：true）
 * - peer_relay / relay / relay_server_port: 是否作为 Peer Relay 对等中继节点：
 *     传 true 默认监听 40000 端口；传具体数字（如 40000）则监听该端口；不传或传 false 则不作为 Peer Relay 节点
 * - relay_endpoints / relay_server_static_endpoints: 逗号分隔的 Peer Relay 静态公网端点（如 8.134.36.157:40000）
 * - listen_port: WireGuard P2P 监听 UDP 端口（默认：41641）
 * - ssh_server: 是否启用内置 Tailscale SSH/SFTP 服务端，true 或 false
 * - taildrop_directory / taildrop: Taildrop 隔空传文件保存目录
 * - state_directory: 状态持久化目录
 * - advertise_exit_node: 是否将本节点广播为出口节点，true 或 false
 * - exit_node: 指定使用的出口节点名称或 IP
 * - exit_node_allow_lan_access: 使用出口节点时是否允许局域网直连，true 或 false
 * - ephemeral: 是否注册为临时节点，true 或 false
 * - tag: Endpoint 标签名称（默认：tailscale-ep）
 */

function parseArguments() {
  let args = {};
  if (typeof $arguments === "object" && $arguments !== null) {
    args = { ...$arguments };
  } else if (typeof $arguments === "string") {
    $arguments.split("&").forEach(pair => {
      const idx = pair.indexOf("=");
      if (idx > 0) {
        const key = decodeURIComponent(pair.slice(0, idx));
        const value = decodeURIComponent(pair.slice(idx + 1) || "");
        args[key] = value;
      } else if (pair) {
        args[decodeURIComponent(pair)] = "";
      }
    });
  }
  return args;
}

function parseList(val) {
  if (!val) return [];
  if (Array.isArray(val)) return val;
  return String(val)
    .split(",")
    .map(s => s.trim())
    .filter(Boolean);
}

function parseBool(val, defaultVal) {
  if (val === undefined || val === "") return defaultVal;
  if (typeof val === "boolean") return val;
  const s = String(val).trim().toLowerCase();
  if (s === "true" || s === "1" || s === "yes") return true;
  if (s === "false" || s === "0" || s === "no") return false;
  return defaultVal;
}

function normalizeTags(tagsInput) {
  return parseList(tagsInput).map(t => (t.startsWith("tag:") ? t : `tag:${t}`));
}

function extractHostname(urlStr) {
  if (!urlStr) return "";
  try {
    return new URL(urlStr).hostname;
  } catch (e) {
    return urlStr.replace(/^https?:\/\//, "").split(/[:/]/)[0];
  }
}

function process() {
  const isString = typeof $content === "string";
  let config;
  try {
    config = isString ? JSON.parse($content) : $content;
  } catch (e) {
    console.log("解析 Sing-box 配置失败: " + e.message);
    return $content;
  }

  if (typeof config !== "object" || config === null) {
    return $content;
  }

  const args = parseArguments();

  const tag = args.tag || "tailscale-ep";
  const controlUrl = args.control_url || args.url || "";
  const authKey = args.auth_key || args.key || "";
  const hostname = args.hostname || "";
  const rawTags = args.advertise_tags || args.tags || "";

  // 1. 确保顶层 endpoints 数组存在
  if (!Array.isArray(config.endpoints)) {
    config.endpoints = [];
  }

  // 2. 查找已存在的 tailscale endpoint 或新建精简默认结构
  let tsEndpoint = config.endpoints.find(
    ep => ep.type === "tailscale" || ep.tag === tag
  );

  if (!tsEndpoint) {
    tsEndpoint = {
      type: "tailscale",
      tag: tag,
      accept_routes: true,
      listen_port: 41641
    };
    config.endpoints.push(tsEndpoint);
  } else {
    tsEndpoint.type = "tailscale";
    tsEndpoint.tag = tag;
  }

  // 3. 按需动态注入参数（未传参时主动清理，保持默认不配置）
  if (controlUrl) {
    tsEndpoint.control_url = controlUrl;
  } else {
    delete tsEndpoint.control_url;
  }
  if (authKey) {
    tsEndpoint.auth_key = authKey;
  } else {
    delete tsEndpoint.auth_key;
  }
  if (hostname) {
    tsEndpoint.hostname = hostname;
  } else {
    delete tsEndpoint.hostname;
  }
  if (rawTags && rawTags !== "false") {
    tsEndpoint.advertise_tags = normalizeTags(rawTags);
  } else {
    delete tsEndpoint.advertise_tags;
  }

  // 3.1 是否接收地址（accept_routes，默认保留模板值 true，可通过 accept_routes=false 关闭）
  const acceptRoutesArg = args.accept_routes !== undefined ? args.accept_routes : args.accept;
  if (acceptRoutesArg !== undefined && acceptRoutesArg !== "") {
    tsEndpoint.accept_routes = parseBool(acceptRoutesArg, true);
  }

  // 3.2 是否广播内网地址（advertise_routes / routes，不传或传 false 则不广播）
  const rawRoutes = args.advertise_routes !== undefined ? args.advertise_routes : args.routes;
  if (rawRoutes && rawRoutes !== "false" && rawRoutes !== "0") {
    const routeList = parseList(rawRoutes);
    if (routeList.length > 0) {
      tsEndpoint.advertise_routes = routeList;
    } else {
      delete tsEndpoint.advertise_routes;
    }
  } else {
    delete tsEndpoint.advertise_routes;
  }

  // 3.3 是否作为 Peer Relay 节点（peer_relay / relay / relay_server_port & relay_endpoints / relay_server_static_endpoints）
  const rawRelay =
    args.relay_server_port !== undefined
      ? args.relay_server_port
      : args.peer_relay !== undefined
      ? args.peer_relay
      : args.relay;
  const rawRelayEndpoints =
    args.relay_server_static_endpoints !== undefined
      ? args.relay_server_static_endpoints
      : args.relay_endpoints;
  const relayEndpointsList =
    rawRelayEndpoints && rawRelayEndpoints !== "false" && rawRelayEndpoints !== "0"
      ? parseList(rawRelayEndpoints)
      : [];

  if (rawRelay !== undefined && rawRelay !== "") {
    const relayStr = String(rawRelay).trim().toLowerCase();
    if (relayStr === "false" || relayStr === "0" || relayStr === "no") {
      delete tsEndpoint.relay_server_port;
      delete tsEndpoint.relay_server_static_endpoints;
    } else if (relayStr === "true" || relayStr === "yes") {
      // 若传 peer_relay=true，优先从静态端点提取端口，否则默认使用 40000
      let inferredPort = 40000;
      if (relayEndpointsList.length > 0) {
        const m = relayEndpointsList[0].match(/:(\d+)$/);
        if (m) inferredPort = parseInt(m[1], 10);
      }
      tsEndpoint.relay_server_port = inferredPort;
      if (relayEndpointsList.length > 0) {
        tsEndpoint.relay_server_static_endpoints = relayEndpointsList;
      } else {
        delete tsEndpoint.relay_server_static_endpoints;
      }
    } else {
      const parsedPort = parseInt(relayStr, 10);
      if (!isNaN(parsedPort) && parsedPort > 0) {
        tsEndpoint.relay_server_port = parsedPort;
        if (relayEndpointsList.length > 0) {
          tsEndpoint.relay_server_static_endpoints = relayEndpointsList;
        } else {
          delete tsEndpoint.relay_server_static_endpoints;
        }
      } else {
        delete tsEndpoint.relay_server_port;
        delete tsEndpoint.relay_server_static_endpoints;
      }
    }
  } else if (relayEndpointsList.length > 0) {
    // 仅传了 relay_endpoints 时也自动开启 Peer Relay
    const m = relayEndpointsList[0].match(/:(\d+)$/);
    tsEndpoint.relay_server_port = m ? parseInt(m[1], 10) : 40000;
    tsEndpoint.relay_server_static_endpoints = relayEndpointsList;
  } else {
    delete tsEndpoint.relay_server_port;
    delete tsEndpoint.relay_server_static_endpoints;
  }

  // 3.4 其他可选参数
  if (args.listen_port !== undefined && args.listen_port !== "") {
    tsEndpoint.listen_port = parseInt(args.listen_port, 10);
  }
  if (args.state_directory) {
    tsEndpoint.state_directory = args.state_directory;
  }
  if (args.taildrop_directory || args.taildrop) {
    tsEndpoint.taildrop_directory = args.taildrop_directory || args.taildrop;
  }
  if (args.ssh_server !== undefined && args.ssh_server !== "") {
    if ( !parseBool(args.ssh_server, true) ) {
      delete tsEndpoint.ssh_server;
    } else {
      tsEndpoint.ssh_server = true;
    }
  }
  if (args.advertise_exit_node !== undefined && args.advertise_exit_node !== "") {
    tsEndpoint.advertise_exit_node = parseBool(args.advertise_exit_node, false);
  }
  if (args.exit_node) {
    tsEndpoint.exit_node = args.exit_node;
  }
  if (args.exit_node_allow_lan_access !== undefined && args.exit_node_allow_lan_access !== "") {
    tsEndpoint.exit_node_allow_lan_access = parseBool(args.exit_node_allow_lan_access, false);
  }
  if (args.ephemeral !== undefined && args.ephemeral !== "") {
    tsEndpoint.ephemeral = parseBool(args.ephemeral, false);
  }

  // 4. 自动同步 MagicDNS 与控制面直连 DNS 解析
  const controlHost = extractHostname(controlUrl);
  if (config.dns) {
    if (Array.isArray(config.dns.servers)) {
      let tsDns = config.dns.servers.find(s => s.type === "tailscale" || s.tag === "ts-dns");
      if (tsDns) {
        tsDns.endpoint = tag;
        tsDns.accept_search_domain = true;
      } else {
        config.dns.servers.push({
          tag: "ts-dns",
          type: "tailscale",
          endpoint: tag,
          accept_search_domain: true
        });
      }
    }
    if (Array.isArray(config.dns.rules)) {
      let tsDnsRule = config.dns.rules.find(r => r.server === "ts-dns");
      if (tsDnsRule) {
        tsDnsRule.preferred_by = "ts-dns";
      }
      // 若传入了自定义 control_url，确保其域名通过 ali 直连解析防止 FakeIP 污染
      if (controlHost) {
        const hasHostRule = config.dns.rules.some(
          r =>
            (Array.isArray(r.domain) && r.domain.includes(controlHost)) ||
            (Array.isArray(r.domain_suffix) && r.domain_suffix.some(sfx => controlHost.endsWith(sfx)))
        );
        if (!hasHostRule) {
          const idx = config.dns.rules.findIndex(r => r.server === "ts-dns");
          const directDnsRule = { domain: [controlHost], server: "ali" };
          if (idx >= 0) {
            config.dns.rules.splice(idx, 0, directDnsRule);
          } else {
            config.dns.rules.unshift(directDnsRule);
          }
        }
      }
    }
  }

  // 5. 自动同步路由规则 (route.rules)
  if (config.route && Array.isArray(config.route.rules)) {
    // 同步首条逻辑规则中的 preferred_by 排除项与动态子网路由规则
    config.route.rules.forEach(r => {
      if (Array.isArray(r.preferred_by) && r.outbound === "tailscale-ep") {
        r.preferred_by = [tag];
        r.outbound = tag;
      }
      if (r.type === "logical" && Array.isArray(r.rules)) {
        r.rules.forEach(sub => {
          if (Array.isArray(sub.preferred_by) && sub.invert === true) {
            sub.preferred_by = [tag];
          }
        });
      }
    });
  }

  return isString ? JSON.stringify(config, null, 2) : config;
}

// Sub-Store 官方执行入口
if (typeof $content !== "undefined") {
  $content = process();
}
