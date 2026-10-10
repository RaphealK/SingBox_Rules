# test_tailscale_114_upgrade.ps1
# 验证 Sing-Box 1.14 规则去重精简、默认不配置 tag/control_url/hostname 以及 Sub-Store 动态传参注入

$ErrorActionPreference = "Stop"

Write-Host "================ Sing-Box 1.14 精简与动态传参验证开始 ================" -ForegroundColor Cyan

$allConfigs = @("android.json", "iphone.json", "linux.json", "openwrt.json", "windows.json")
foreach ($cfg in $allConfigs) {
    $path = Join-Path "config" $cfg
    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    Write-Host "[OK] JSON 语法解析正确: $cfg" -ForegroundColor Green

    # 验证已去除重复冗余的规则集 geosite-apple@cn, geosite-binance, geosite-okx
    $geositeSet = $json.route.rule_set | Where-Object { $_.tag -is [array] -and $_.tag -contains "geosite-apple" }
    foreach ($redundant in @("geosite-apple@cn", "geosite-binance", "geosite-okx")) {
        if ($geositeSet.tag -contains $redundant) {
            throw "$cfg 的 route.rule_set 仍包含冗余规则集: $redundant"
        }
    }
}

$tsConfigs = @("windows.json", "linux.json", "openwrt.json", "android.json", "iphone.json")

foreach ($cfg in $tsConfigs) {
    $path = Join-Path "config" $cfg
    $json = (Get-Content -Path $path -Raw -Encoding UTF8) | ConvertFrom-Json

    # 1. 验证 endpoints[tailscale-ep] 默认不配置 advertise_tags, control_url, hostname, auth_key
    $ep = $json.endpoints | Where-Object { $_.tag -eq "tailscale-ep" -and $_.type -eq "tailscale" }
    if ($null -eq $ep) {
        throw "$cfg 缺失 tailscale-ep 端点"
    }

    foreach ($forbidden in @("advertise_tags", "control_url", "hostname", "auth_key", "on_demand")) {
        if ($null -ne $ep.PSObject.Properties[$forbidden]) {
            throw "$cfg 的 tailscale-ep 默认不应包含字段: $forbidden"
        }
    }

    if ($ep.accept_routes -ne $true -or $ep.listen_port -ne 41641) {
        throw "$cfg 的 tailscale-ep 基础属性 (accept_routes / listen_port) 不正确"
    }

    if ($cfg -eq "iphone.json") {
        if ($null -ne $ep.PSObject.Properties["ssh_server"]) {
            throw "iphone.json 不应包含 ssh_server"
        }
    } else {
        if ($ep.ssh_server -ne $true) {
            throw "$cfg 的 ssh_server 期望为精简布尔值 true"
        }
    }

    # 2. 验证 MagicDNS 与已清理冗余 tx / hosts DNS 服务器
    $tsDns = $json.dns.servers | Where-Object { $_.tag -eq "ts-dns" }
    if ($null -eq $tsDns -or $tsDns.type -ne "tailscale" -or $tsDns.accept_search_domain -ne $true) {
        throw "$cfg 的 ts-dns 配置不正确"
    }
    foreach ($deadDns in @("tx", "hosts")) {
        $foundDead = $json.dns.servers | Where-Object { $_.tag -eq $deadDns }
        if ($null -ne $foundDead) {
            throw "$cfg 的 dns.servers 仍存在未使用的冗余服务器: $deadDns"
        }
    }
    $tsDnsRule = $json.dns.rules | Where-Object { $_.preferred_by -eq "ts-dns" -and $_.server -eq "ts-dns" }
    if ($null -eq $tsDnsRule) {
        throw "$cfg 的 dns.rules 缺失 preferred_by: ts-dns 规则"
    }

    # 3. 验证已移除重复冗余的 Tailscale 路由规则，仅保留 preferred_by 动态路由，且 sniff 排除了 tailscale-ep
    $prefRoute = $json.route.rules | Where-Object { $_.preferred_by -contains "tailscale-ep" -and $_.outbound -eq "tailscale-ep" }
    if ($null -eq $prefRoute) {
        throw "$cfg 缺失 preferred_by: [tailscale-ep] 路由规则"
    }
    $sniffRule = $json.route.rules | Where-Object { $_.action -eq "sniff" }
    $sniffExcludesTs = $sniffRule.rules | Where-Object { $_.preferred_by -contains "tailscale-ep" }
    if ($null -eq $sniffExcludesTs) {
        throw "$cfg 的 sniff 规则未排除 preferred_by: [tailscale-ep]"
    }
    $dupCidrRoute = $json.route.rules | Where-Object { $_.ip_cidr -contains "100.64.0.0/10" }
    if ($null -ne $dupCidrRoute) {
        throw "$cfg 仍存在冗余的 100.64.0.0/10 ip_cidr 路由规则"
    }

    Write-Host "[OK] $cfg 精简无硬编码模板与规则去重断言通过！" -ForegroundColor Green
}

# 4. 验证 substore-endpoint.js 动态传参控制（以 openwrt.json 测试子网路由与控制面注入）
Write-Host "`n--- 验证 substore-endpoint.js 动态传参注入 ---" -ForegroundColor Cyan
$nodeTest = @'
const fs = require('fs');
const raw = fs.readFileSync('config/openwrt.json', 'utf8');

// 测试 1: 不传参数时默认不生成 control_url / hostname / advertise_tags / advertise_routes / relay_server_port
global.$content = raw;
global.$arguments = '';
delete require.cache[require.resolve('./scripts/substore-endpoint.js')];
require('./scripts/substore-endpoint.js');
const resEmpty = JSON.parse(global.$content);
const epEmpty = resEmpty.endpoints[0];
if (epEmpty.control_url || epEmpty.hostname || epEmpty.advertise_tags || epEmpty.advertise_routes || epEmpty.relay_server_port) {
  throw new Error('未传参时不应生成 control_url / hostname / advertise_tags / advertise_routes / relay_server_port');
}
if (epEmpty.accept_routes !== true) {
  throw new Error('默认 accept_routes 应为 true');
}

// 测试 2: 开启广播内网地址 (advertise_routes)、开启接收地址 (accept_routes=true)、开启作为 Peer Relay 节点 (peer_relay=true)，且带 #noCache 尾缀
global.$content = raw;
global.$arguments = 'control_url=https://mesh.luokinging.com&advertise_routes=192.168.31.0/24&accept_routes=true&peer_relay=true&relay_endpoints=8.134.36.157:40000&tags=tag:luoking,tag:luoking-share,tag:relay,tag:rephael&auth_key=tskey-test#noCache';
delete require.cache[require.resolve('./scripts/substore-endpoint.js')];
require('./scripts/substore-endpoint.js');
const resFull = JSON.parse(global.$content);
const epFull = resFull.endpoints[0];

if (epFull.control_url !== 'https://mesh.luokinging.com') throw new Error('control_url 注入失败');
if (epFull.hostname !== undefined) throw new Error('未传 hostname 时应保持 undefined 由设备自动获取');
if (epFull.auth_key !== 'tskey-test') throw new Error('auth_key 注入失败或未剥离 #noCache: ' + epFull.auth_key);
if (epFull.accept_routes !== true) throw new Error('accept_routes=true 注入失败');
if (epFull.relay_server_port !== 40000) throw new Error('peer_relay=true 自动端口 40000 注入失败');
if (JSON.stringify(epFull.relay_server_static_endpoints) !== JSON.stringify(['8.134.36.157:40000'])) {
  throw new Error('relay_endpoints 注入失败');
}
if (JSON.stringify(epFull.advertise_routes) !== JSON.stringify(['192.168.31.0/24'])) {
  throw new Error('advertise_routes 注入不匹配: ' + JSON.stringify(epFull.advertise_routes));
}
const expected = ['tag:luoking', 'tag:luoking-share', 'tag:relay', 'tag:rephael'];
if (JSON.stringify(epFull.advertise_tags) !== JSON.stringify(expected)) {
  throw new Error('advertise_tags 注入不匹配: ' + JSON.stringify(epFull.advertise_tags));
}
const hasControlDns = resFull.dns.rules.some(r => Array.isArray(r.domain) && r.domain.includes('mesh.luokinging.com') && r.server === 'ali');
if (!hasControlDns) throw new Error('control_url 域名未自动注入直连 DNS 规则');

// 测试 3: 显式关闭接收地址 (accept_routes=false)、不广播内网地址 (advertise_routes=false)、不作为 Peer Relay (peer_relay=false)
global.$content = JSON.stringify(resFull);
global.$arguments = 'accept_routes=false&advertise_routes=false&peer_relay=false';
delete require.cache[require.resolve('./scripts/substore-endpoint.js')];
require('./scripts/substore-endpoint.js');
const resOff = JSON.parse(global.$content);
const epOff = resOff.endpoints[0];
if (epOff.accept_routes !== false) throw new Error('accept_routes=false 未生效');
if (epOff.advertise_routes !== undefined) throw new Error('advertise_routes=false 未清理');
if (epOff.relay_server_port !== undefined || epOff.relay_server_static_endpoints !== undefined) {
  throw new Error('peer_relay=false 未清理 relay_server_port / relay_server_static_endpoints');
}

console.log('[OK] substore-endpoint.js 广播内网地址、接收地址、Peer Relay 节点动态开关与 #noCache 过滤 100% 验证通过！');
'@

node -e $nodeTest
if ($LASTEXITCODE -ne 0) {
    throw "Node.js 动态传参测试失败"
}

Write-Host "================ 所有精简去重与动态传参验证 100% 通过 ================" -ForegroundColor Cyan
