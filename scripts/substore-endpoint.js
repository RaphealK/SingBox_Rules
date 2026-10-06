/**
 * Sub-Store 脚本：动态配置与注入 Sing-box 的 Tailscale / Headscale Endpoint
 * 
 * 功能：
 * 1. 允许在 Sub-Store 订阅生成时，通过 URL Hash 参数动态注入或更新 Tailscale / Headscale Endpoint 配置
 * 2. 避免在每个客户端配置文件中手动明文写死 Auth Key 与私有域名
 * 3. 自动同步路由分流规则，确保 Tailscale CGNAT 内网流量精准路由至该 Endpoint
 * 
 * 使用方法：
 * 在 Sub-Store 的【订阅产物 (Artifact)】中，为 Sing-box 订阅添加此脚本作为处理脚本。
 * 
 * 示例 URL 调用参数：
 * https://gh-proxy.com/https://raw.githubusercontent.com/RaphealK/SingBox_Rules/main/scripts/substore-endpoint.js#control_url=https://headscale.yourdomain.com&auth_key=tskey-auth-xxxxxx&hostname=iphone-box&accept_routes=true
 * 
 * 参数说明：
 * - control_url: Headscale 协调服务器完整地址（必须包含 https://）
 * - auth_key: Headscale 预授权密钥（可留空，留空则通过图形客户端手动认证）
 * - hostname: 节点在 Headscale 控制面板上显示的名称（默认：singbox-node）
 * - accept_routes: 是否接收子网路由广播，true 或 false（默认：true）
 * - tag: Endpoint 标签名称（默认：tailscale-ep）
 */

function parseArguments() {
  let args = {};
  if (typeof $arguments === "object" && $arguments !== null) {
    args = { ...$arguments };
  } else if (typeof $arguments === "string") {
    $arguments.split("&").forEach(pair => {
      const [key, value] = pair.split("=");
      if (key) args[decodeURIComponent(key)] = decodeURIComponent(value || "");
    });
  }
  return args;
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

  // 读取配置参数
  const tag = args.tag || "tailscale-ep";
  const controlUrl = args.control_url || args.url || "";
  const authKey = args.auth_key || args.key || "";
  const hostname = args.hostname || "singbox-node";
  const acceptRoutes = args.accept_routes !== "false";

  // 1. 确保顶层 endpoints 数组存在
  if (!Array.isArray(config.endpoints)) {
    config.endpoints = [];
  }

  // 2. 查找已存在的 tailscale endpoint 或新建
  let tsEndpoint = config.endpoints.find(
    ep => ep.type === "tailscale" || ep.tag === tag
  );

  if (tsEndpoint) {
    tsEndpoint.type = "tailscale";
    tsEndpoint.tag = tag;
    if (controlUrl) tsEndpoint.control_url = controlUrl;
    if (authKey) tsEndpoint.auth_key = authKey;
    if (hostname) tsEndpoint.hostname = hostname;
    tsEndpoint.accept_routes = acceptRoutes;
  } else {
    tsEndpoint = {
      type: "tailscale",
      tag: tag,
      control_url: controlUrl || "https://controlplane.tailscale.com",
      auth_key: authKey || "",
      hostname: hostname,
      accept_routes: acceptRoutes
    };
    config.endpoints.push(tsEndpoint);
  }

  // 3. 自动同步路由规则 (route.rules)
  if (config.route && Array.isArray(config.route.rules)) {
    // 确保虚拟内网 100.64.0.0/10 正确导向该 endpoint
    const internalCidrs = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"];
    let routeRule = config.route.rules.find(r => {
      if (!Array.isArray(r.ip_cidr)) return false;
      return internalCidrs.some(cidr => r.ip_cidr.includes(cidr));
    });

    if (routeRule) {
      routeRule.outbound = tag;
    }

    // 若提供了自定义 Headscale 域名，自动注入到控制面走代理分流规则中
    if (controlUrl) {
      try {
        const urlObj = new URL(controlUrl);
        const host = urlObj.hostname;
        let controlRule = config.route.rules.find(
          r => Array.isArray(r.domain) && r.domain.includes("controlplane.tailscale.com")
        );
        if (controlRule && !controlRule.domain.includes(host)) {
          // 替换掉占位符或追加域名
          controlRule.domain = controlRule.domain.filter(d => d !== "your-headscale-domain.com");
          controlRule.domain.unshift(host);
        }
      } catch (err) {
        // controlUrl 可能是纯域名格式
        const host = controlUrl.replace(/^https?:\/\//, "").split(/[:/]/)[0];
        if (host) {
          let controlRule = config.route.rules.find(
            r => Array.isArray(r.domain) && r.domain.includes("controlplane.tailscale.com")
          );
          if (controlRule && !controlRule.domain.includes(host)) {
            controlRule.domain = controlRule.domain.filter(d => d !== "your-headscale-domain.com");
            controlRule.domain.unshift(host);
          }
        }
      }
    }
  }

  return isString ? JSON.stringify(config, null, 2) : config;
}

// Sub-Store 官方执行入口
if (typeof $content !== "undefined") {
  $content = process();
}
