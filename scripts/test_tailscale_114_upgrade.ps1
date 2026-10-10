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

$tsConfigs = @("windows.json", "linux.json", "android.json", "iphone.json")

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

    # 2. 验证 MagicDNS
    $tsDns = $json.dns.servers | Where-Object { $_.tag -eq "ts-dns" }
    if ($null -eq $tsDns -or $tsDns.type -ne "tailscale" -or $tsDns.accept_search_domain -ne $true) {
        throw "$cfg 的 ts-dns 配置不正确"
    }
    $tsDnsRule = $json.dns.rules | Where-Object { $_.preferred_by -eq "tailscale-ep" -and $_.server -eq "ts-dns" }
    if ($null -eq $tsDnsRule) {
        throw "$cfg 的 dns.rules 缺失 preferred_by: tailscale-ep 规则"
    }

    # 3. 验证已移除重复冗余的 Tailscale 路由规则，仅保留 preferred_by 动态路由
    $prefRoute = $json.route.rules | Where-Object { $_.preferred_by -contains "tailscale-ep" -and $_.outbound -eq "tailscale-ep" }
    if ($null -eq $prefRoute) {
        throw "$cfg 缺失 preferred_by: [tailscale-ep] 路由规则"
    }
    $dupCidrRoute = $json.route.rules | Where-Object { $_.ip_cidr -contains "100.64.0.0/10" }
    if ($null -ne $dupCidrRoute) {
        throw "$cfg 仍存在冗余的 100.64.0.0/10 ip_cidr 路由规则"
    }

    Write-Host "[OK] $cfg 精简无硬编码模板与规则去重断言通过！" -ForegroundColor Green
}

# 4. 验证 substore-endpoint.js 动态传参控制
Write-Host "`n--- 验证 substore-endpoint.js 动态传参注入 ---" -ForegroundColor Cyan
$nodeTest = @'
const fs = require('fs');
const raw = fs.readFileSync('config/windows.json', 'utf8');

// 测试 1: 不传参数时默认不生成 control_url / hostname / advertise_tags
global.$content = raw;
global.$arguments = '';
delete require.cache[require.resolve('./scripts/substore-endpoint.js')];
require('./scripts/substore-endpoint.js');
const resEmpty = JSON.parse(global.$content);
const epEmpty = resEmpty.endpoints[0];
if (epEmpty.control_url || epEmpty.hostname || epEmpty.advertise_tags) {
  throw new Error('未传参时不应生成 control_url / hostname / advertise_tags');
}

// 测试 2: 传入 control_url, hostname, 4 个 tags 时精准注入
global.$content = raw;
global.$arguments = 'control_url=https://mesh.luokinging.com&hostname=win-pc&tags=tag:luoking,tag:luoking-share,tag:relay,tag:rephael&auth_key=tskey-test&relay_server_port=40000';
delete require.cache[require.resolve('./scripts/substore-endpoint.js')];
require('./scripts/substore-endpoint.js');
const resFull = JSON.parse(global.$content);
const epFull = resFull.endpoints[0];

if (epFull.control_url !== 'https://mesh.luokinging.com') throw new Error('control_url 注入失败');
if (epFull.hostname !== 'win-pc') throw new Error('hostname 注入失败');
if (epFull.auth_key !== 'tskey-test') throw new Error('auth_key 注入失败');
if (epFull.relay_server_port !== 40000) throw new Error('relay_server_port 注入失败');
const expected = ['tag:luoking', 'tag:luoking-share', 'tag:relay', 'tag:rephael'];
if (JSON.stringify(epFull.advertise_tags) !== JSON.stringify(expected)) {
  throw new Error('advertise_tags 注入不匹配: ' + JSON.stringify(epFull.advertise_tags));
}
const hasControlDns = resFull.dns.rules.some(r => Array.isArray(r.domain) && r.domain.includes('mesh.luokinging.com') && r.server === 'ali');
if (!hasControlDns) throw new Error('control_url 域名未自动注入直连 DNS 规则');
console.log('[OK] substore-endpoint.js 空参默认不配置 & 动态传参注入 100% 验证通过！');
'@

node -e $nodeTest
if ($LASTEXITCODE -ne 0) {
    throw "Node.js 动态传参测试失败"
}

Write-Host "================ 所有精简去重与动态传参验证 100% 通过 ================" -ForegroundColor Cyan
