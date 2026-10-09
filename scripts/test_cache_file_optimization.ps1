# test_cache_file_optimization.ps1
# 验证所有配置文件的 cache_file 配置正确性与 OpenWrt 闪存防磨损调优

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

    $cache = $json.experimental.cache_file
    if ($null -eq $cache) {
        throw "$cfg 缺失 experimental.cache_file"
    }

    if ($cache.enabled -ne $true) {
        throw "$cfg 的 cache_file.enabled 不是 true"
    }

    if ($cache.store_fakeip -ne $true) {
        throw "$cfg 的 cache_file.store_fakeip 未开启 (期望为 true)"
    }

    # 检查是否存在废弃字段
    if ($null -ne $cache.store_rdrc) {
        throw "$cfg 包含已废弃的 store_rdrc 字段"
    }
    if ($null -ne $cache.rdrc_timeout) {
        throw "$cfg 包含已废弃的 rdrc_timeout 字段"
    }

    Write-Host "[OK] $cfg cache_file.enabled=true 且 store_fakeip=true" -ForegroundColor Green
}

# 针对 openwrt.json 进行深度设备特性断言 (红米 AX6000 闪存防磨损调优)
$openwrt = (Get-Content -Path "config/openwrt.json" -Raw -Encoding UTF8) | ConvertFrom-Json
$openwrtCache = $openwrt.experimental.cache_file

if ($openwrtCache.path -ne "/etc/sing-box/cache.db") {
    throw "openwrt.json 的 cache_file.path 期望为 /etc/sing-box/cache.db，实际为 $($openwrtCache.path)"
}

if ($openwrtCache.store_dns -ne $true) {
    throw "openwrt.json 的 cache_file.store_dns 期望为 true"
}

if ($openwrtCache.buffer_size -ne "2MB") {
    throw "openwrt.json 的 cache_file.buffer_size 期望为 2MB，实际为 $($openwrtCache.buffer_size)"
}

if ($openwrtCache.flush_interval -ne "5m") {
    throw "openwrt.json 的 cache_file.flush_interval 期望为 5m，实际为 $($openwrtCache.flush_interval)"
}

Write-Host "[OK] openwrt.json 闪存防磨损优化（2MB 缓冲 + 5m 刷盘 + 路径 + store_dns）断言通过！" -ForegroundColor Green

Write-Host "================ 所有验证通过 ================" -ForegroundColor Cyan
