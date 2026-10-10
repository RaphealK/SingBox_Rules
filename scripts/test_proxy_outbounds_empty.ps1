# test_proxy_outbounds_empty.ps1
# 验证全平台 5 端配置中 🌍 Proxy 策略组的 outbounds 均已成功清空为 []

$ErrorActionPreference = "Stop"

Write-Host "================ 验证开始 ================" -ForegroundColor Cyan

$configs = @("android.json", "iphone.json", "linux.json", "openwrt.json", "windows.json")

foreach ($cfg in $configs) {
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

    $proxyOutbound = $json.outbounds | Where-Object { $_.tag -eq "🌍 Proxy" }
    if ($null -eq $proxyOutbound) {
        throw "$cfg 缺失 🌍 Proxy 出站组"
    }

    if ($proxyOutbound.type -ne "selector") {
        throw "$cfg 的 🌍 Proxy 类型不是 selector"
    }

    if ($null -ne $proxyOutbound.outbounds -and $proxyOutbound.outbounds.Count -ne 0) {
        throw "$cfg 的 🌍 Proxy outbounds 期望为空数组 []，实际包含: $($proxyOutbound.outbounds -join ', ')"
    }

    Write-Host "[OK] $cfg 策略组 🌍 Proxy 的 outbounds 为空数组 [] 断言通过！" -ForegroundColor Green
}

Write-Host "================ 核心断言全部通过 ================" -ForegroundColor Cyan
