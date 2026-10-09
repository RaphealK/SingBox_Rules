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

    # 4. 验证 Direct 出站符合官方规范（使用 domain_resolver: local，无非法 strategy 字段）
    $direct = $cfg.outbounds | Where-Object { $_.tag -eq '🎯 Direct' }
    if ($direct.PSObject.Properties['strategy']) {
        Write-Error "[FAIL] ${cfgPath}: 🎯 Direct 出站包含非法的 strategy 字段"
        $allSuccess = $false
    } elseif ($direct.domain_resolver -ne 'local') {
        Write-Error "[FAIL] ${cfgPath}: 🎯 Direct 出站缺少 domain_resolver: local"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: 🎯 Direct 出站符合官方规范（无 strategy，使用 domain_resolver）" -ForegroundColor Green
    }

    # 5. 验证 tun-in 包含 strict_route
    $tun = $cfg.inbounds | Where-Object { $_.tag -eq 'tun-in' }
    if (-not $tun.strict_route) {
        Write-Error "[FAIL] ${cfgPath}: tun-in 未启用 strict_route"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: tun-in strict_route 启用正常" -ForegroundColor Green
    }

    # 6. 验证 tun-in 为纯 IPv4（彻底移除 IPv6 地址）
    if ($tun.address.Count -ne 1 -or $tun.address[0] -ne '172.19.0.1/30') {
        Write-Error "[FAIL] ${cfgPath}: tun-in 不是纯 IPv4 地址 (当前地址: $($tun.address -join ', '))"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: tun-in 为纯 IPv4 单栈 (已彻底关闭 IPv6 地址)" -ForegroundColor Green
    }

    # 7. 验证 Tailscale 路由为纯 IPv4 网段
    $tsRule = $cfg.route.rules | Where-Object { $_.outbound -eq 'tailscale-ep' }
    if (-not $tsRule -or $tsRule.ip_cidr -contains 'fd7a:115c:a1e0::/48') {
        Write-Error "[FAIL] ${cfgPath}: Tailscale 路由未转为纯 IPv4"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: Tailscale 路由为纯 IPv4 (100.64.0.0/10)" -ForegroundColor Green
    }

    # 8. 验证 route.rules 包含 IPv6 全局 reject 拦截规则
    $v6RejectRule = $cfg.route.rules | Where-Object { $_.ip_version -eq 6 -and $_.action -eq 'reject' -and $_.no_drop -eq $true }
    if (-not $v6RejectRule) {
        Write-Error "[FAIL] ${cfgPath}: 缺少 ip_version: 6 的 reject 阻断规则"
        $allSuccess = $false
    } else {
        Write-Host "[OK] ${cfgPath}: 全局 IPv6 瞬时 reject 阻断规则生效" -ForegroundColor Green
    }
}

if ($allSuccess) {
    Write-Host "`n所有移动端 IPv6 优化校验项全部通过！" -ForegroundColor Cyan
    exit 0
} else {
    Write-Error "`n部分校验失败，请检查配置！"
    exit 1
}
