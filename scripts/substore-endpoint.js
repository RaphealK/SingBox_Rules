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
 * - accept_routes: 是否接收子网路由广播，true 或 false（默认：true）
 * - listen_port: WireGuard P2P 监听 UDP 端口（默认：41641）
 * - relay_server_port: Peer Relay 对等中继监听端口（如 40000）
 * - relay_server_static_endpoints: 逗号分隔的对等中继静态公网端点（如 8.134.36.157:40000）
 * - ssh_server: 是否启用内置 Tailscale SSH/SFTP 服务端，true 或 false
 * - taildrop_directory / taildrop: Taildrop 隔空传文件保存目录
 * - state_directory: 状态持久化目录
 * - advertise_routes: 逗号分隔的广播子网路由 CIDR（如 192.168.1.0/24）
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
  if (rawTags) {
    tsEndpoint.advertise_tags = normalizeTags(rawTags);
  } else {
    delete tsEndpoint.advertise_tags;
  }
  if (args.accept_routes !== undefined) {
    tsEndpoint.accept_routes = args.accept_routes !== "false";
  }
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
    if (args.ssh_server === "false") {
      delete tsEndpoint.ssh_server;
    } else {
      tsEndpoint.ssh_server = true;
    }
  }
  if (args.relay_server_port !== undefined && args.relay_server_port !== "") {
    tsEndpoint.relay_server_port = parseInt(args.relay_server_port, 10);
  }
  if (args.relay_server_static_endpoints) {
    tsEndpoint.relay_server_static_endpoints = parseList(args.relay_server_static_endpoints);
  }
  if (args.advertise_routes) {
    tsEndpoint.advertise_routes = parseList(args.advertise_routes);
  }
  if (args.advertise_exit_node !== undefined && args.advertise_exit_node !== "") {
    tsEndpoint.advertise_exit_node = args.advertise_exit_node === "true";
  }
  if (args.exit_node) {
    tsEndpoint.exit_node = args.exit_node;
  }
  if (args.exit_node_allow_lan_access !== undefined && args.exit_node_allow_lan_access !== "") {
    tsEndpoint.exit_node_allow_lan_access = args.exit_node_allow_lan_access === "true";
  }
  if (args.ephemeral !== undefined && args.ephemeral !== "") {
    tsEndpoint.ephemeral = args.ephemeral === "true";
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
