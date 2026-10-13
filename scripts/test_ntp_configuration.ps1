# test_ntp_configuration.ps1
# 验证五端配置与规则集的 NTP 配置正确性与直连出站合规性

$ErrorActionPreference = "Stop"

Write-Host "================ NTP 配置自动化验证开始 ================" -ForegroundColor Cyan

# 1. 验证五端配置文件的 JSON 语法与平台 NTP 行为
$desktopAndRouterConfigs = @("windows.json", "linux.json", "openwrt.json")
$mobileConfigs = @("android.json", "iphone.json")

foreach ($cfg in $desktopAndRouterConfigs) {
    $path = Join-Path "config" $cfg
    if (-not (Test-Path $path)) {
        throw "配置文件未找到: $path"
    }

    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "JSON 语法解析失败: $path - $_"
    }

    Write-Host "[OK] JSON 解析语法正确: $cfg" -ForegroundColor Green

    # 验证 ntp 模块存在
    if ($null -eq $json.ntp) {
        throw "$cfg 缺失顶层 ntp 模块配置"
    }

    # 验证 ntp.enabled
    if ($json.ntp.enabled -ne $true) {
        throw "$cfg 的 ntp.enabled 不是 true"
    }

    # 验证 ntp.server
    if ($json.ntp.server -ne "cn.pool.ntp.org") {
        throw "$cfg 的 ntp.server 期望为 cn.pool.ntp.org，实际为 $($json.ntp.server)"
    }

    # 验证 ntp.detour
    if ($json.ntp.detour -ne "🎯 Direct") {
        throw "$cfg 的 ntp.detour 期望为 '🎯 Direct'，实际为 '$($json.ntp.detour)'"
    }

    # 验证引用的 detour 必须存在于 outbounds 中
    $directOutbound = $json.outbounds | Where-Object { $_.tag -eq "🎯 Direct" }
    if ($null -eq $directOutbound) {
        throw "$cfg 的 outbounds 中未找到 tag 为 '🎯 Direct' 的出站规则"
    }

    Write-Host "[OK] $cfg ntp 配置合规 (server=cn.pool.ntp.org, detour=🎯 Direct)" -ForegroundColor Green
}

foreach ($cfg in $mobileConfigs) {
    $path = Join-Path "config" $cfg
    if (-not (Test-Path $path)) {
        throw "移动端配置文件未找到: $path"
    }

    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "JSON 语法解析失败: $path - $_"
    }

    Write-Host "[OK] JSON 解析语法正确: $cfg" -ForegroundColor Green

    # 移动端保持无内置 ntp 模块
    if ($null -ne $json.ntp) {
        throw "$cfg 作为移动端沙盒设备，不应包含顶层 ntp 模块"
    }

    Write-Host "[OK] $cfg 维持移动端轻量沙盒设计，无多余 ntp 模块" -ForegroundColor Green
}

# 2. 验证 rules/fakeipfilter-cn.json 中收录了 cn.pool.ntp.org，确保直连不分配 FakeIP
$fakeipCnPath = "rules/fakeipfilter-cn.json"
if (-not (Test-Path $fakeipCnPath)) {
    throw "未找到国内 FakeIP 规则集: $fakeipCnPath"
}
$fakeipCnRaw = Get-Content -Path $fakeipCnPath -Raw -Encoding UTF8
$fakeipCnJson = $fakeipCnRaw | ConvertFrom-Json
$domains = $fakeipCnJson.rules[0].domain
if ($domains -notcontains "cn.pool.ntp.org") {
    throw "rules/fakeipfilter-cn.json 未收录 cn.pool.ntp.org，可能导致 FakeIP 污染！"
}
Write-Host "[OK] rules/fakeipfilter-cn.json 正确收录 cn.pool.ntp.org 真实 IP 过滤" -ForegroundColor Green

# 3. 验证 README.md 同步更新
$readmePath = "README.md"
$readmeContent = Get-Content -Path $readmePath -Raw -Encoding UTF8
if ($readmeContent -match "time\.apple\.com") {
    throw "README.md 中仍遗留旧版 time.apple.com"
}
if ($readmeContent -notmatch "cn\.pool\.ntp\.org") {
    throw "README.md 未更新 cn.pool.ntp.org"
}
Write-Host "[OK] README.md 速查表已同步更新" -ForegroundColor Green

Write-Host "================ NTP 配置全部验证通过 ================" -ForegroundColor Cyan
