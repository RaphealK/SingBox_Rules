$files = Get-ChildItem -Path config/*.json
$allSuccess = $true

foreach ($f in $files) {
    try {
        $content = Get-Content -Raw -Encoding utf8 $f.FullName
        $null = ConvertFrom-Json $content
        Write-Host "[OK] JSON 语法正确: $($f.Name)" -ForegroundColor Green
    } catch {
        Write-Error "[FAIL] JSON 解析失败: $($f.Name) - $($_.Exception.Message)"
        $allSuccess = $false
    }
}

# 深度校验 iphone.json 与 android.json
$checkConfigs = @('config/iphone.json', 'config/android.json')
foreach ($cfgPath in $checkConfigs) {
    $cfg = ConvertFrom-Json (Get-Content -Raw -Encoding utf8 $cfgPath)
    
    # 1. 验证 dns.strategy 为 ipv4_only
    if ($cfg.dns.strategy -ne 'ipv4_only') {
        Write-Error "[FAIL] ${cfgPath}: dns.strategy 不是 ipv4_only"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: dns.strategy 为 ipv4_only" -ForegroundColor Green
    }

    # 2. 验证 fakeip 移除了 inet6_range
    $fakeip = $cfg.dns.servers | Where-Object { $_.tag -eq 'fakeip' }
    if ($fakeip.PSObject.Properties['inet6_range']) {
        Write-Error "[FAIL] ${cfgPath}: fakeip 仍包含 inet6_range"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: fakeip 的 inet6_range 已成功移除" -ForegroundColor Green
    }

    # 3. 验证 rules[0] 拦截 AAAA
    if ($cfg.dns.rules[0].query_type -notcontains 'AAAA') {
        Write-Error "[FAIL] ${cfgPath}: dns.rules[0] 未拦截 AAAA"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: dns.rules[0] 已成功拦截 AAAA" -ForegroundColor Green
    }

    # 4. 验证 Direct 出站包含 strategy: ipv4_only
    $direct = $cfg.outbounds | Where-Object { $_.tag -eq '🎯 Direct' }
    if ($direct.strategy -ne 'ipv4_only') {
        Write-Error "[FAIL] ${cfgPath}: 🎯 Direct 出站缺少 strategy: ipv4_only"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: 🎯 Direct 出站已配置 strategy: ipv4_only" -ForegroundColor Green
    }

    # 5. 验证 tun-in 包含 strict_route
    $tun = $cfg.inbounds | Where-Object { $_.tag -eq 'tun-in' }
    if (-not $tun.strict_route) {
        Write-Error "[FAIL] ${cfgPath}: tun-in 未启用 strict_route"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: tun-in strict_route 启用正常" -ForegroundColor Green
    }

    # 6. 验证 tun-in 保留 IPv6 ULA 地址供 Tailscale 使用
    if ($tun.address -notcontains 'fdfe:dcba:9876::1/126') {
        Write-Error "[FAIL] ${cfgPath}: tun-in 缺少 ULA 地址 fdfe:dcba:9876::1/126"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: tun-in 保留了底层 IPv6 ULA 地址" -ForegroundColor Green
    }

    # 7. 验证路由中包含本地链路 IPv6 fe80::/10 直连
    $localV6Rule = $cfg.route.rules | Where-Object { $_.ip_cidr -contains 'fe80::/10' -and $_.outbound -eq '🎯 Direct' }
    if (-not $localV6Rule) {
        Write-Error "[FAIL] ${cfgPath}: 缺少 fe80::/10 本地 IPv6 直连路由"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: 本地链路 IPv6 fe80::/10 直连规则生效" -ForegroundColor Green
    }

    # 8. 验证 Tailscale fd7a:115c:a1e0::/48 路由至 tailscale-ep
    $tsRule = $cfg.route.rules | Where-Object { $_.ip_cidr -contains 'fd7a:115c:a1e0::/48' -and $_.outbound -eq 'tailscale-ep' }
    if (-not $tsRule) {
        Write-Error "[FAIL] ${cfgPath}: 缺少 Tailscale IPv6 路由"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: Tailscale IPv6 路由规则生效" -ForegroundColor Green
    }
}

if ($allSuccess) {
    Write-Host "`n所有移动端 IPv6 优化校验项全部通过！" -ForegroundColor Cyan
    exit 0
} else {
    Write-Error "`n部分校验失败，请检查配置！"
    exit 1
}
