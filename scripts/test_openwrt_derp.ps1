$files = Get-ChildItem -Path config/*.json
$allSuccess = $true

Write-Host "=== 1. 所有配置文件 JSON 语法校验 ===" -ForegroundColor Cyan
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

Write-Host "`n=== 2. 深度校验 config/openwrt.json ===" -ForegroundColor Cyan
$cfgPath = 'config/openwrt.json'
$cfg = ConvertFrom-Json (Get-Content -Raw -Encoding utf8 $cfgPath)

# 校验 1：route.rules 首部两条规则
$rule0 = $cfg.route.rules[0]
$rule1 = $cfg.route.rules[1]

if ($rule0.domain_suffix -contains 'luokinging.com' -and $rule0.outbound -eq '🎯 Direct' -and $rule0.action -eq 'bypass') {
    Write-Host "[OK] route.rules[0] 正确置顶: domain_suffix luokinging.com -> Direct bypass" -ForegroundColor Green
} else {
    Write-Error "[FAIL] route.rules[0] 未正确配置: $($rule0 | ConvertTo-Json -Compress)"
    $allSuccess = $false
}

if ($rule1.ip_cidr -contains '8.134.36.157/32' -and $rule1.outbound -eq '🎯 Direct' -and $rule1.action -eq 'bypass') {
    Write-Host "[OK] route.rules[1] 正确置顶: ip_cidr 8.134.36.157/32 -> Direct bypass" -ForegroundColor Green
} else {
    Write-Error "[FAIL] route.rules[1] 未正确配置: $($rule1 | ConvertTo-Json -Compress)"
    $allSuccess = $false
}

# 校验 2：inbounds tun-in 的 route_exclude_address
$tun = $cfg.inbounds | Where-Object { $_.tag -eq 'tun-in' }
if ($tun.route_exclude_address -contains '8.134.36.157/32') {
    Write-Host "[OK] inbounds[tun-in].route_exclude_address 成功包含 8.134.36.157/32 (终极内核排除生效)" -ForegroundColor Green
} else {
    Write-Error "[FAIL] tun-in.route_exclude_address 缺少 8.134.36.157/32"
    $allSuccess = $false
}

# 校验 3：dns.rules 中对 luokinging.com 的直连 DNS 解析
$dnsRule = $cfg.dns.rules | Where-Object { $_.domain_suffix -contains 'luokinging.com' }
if ($dnsRule -and $dnsRule.server -eq 'ali') {
    Write-Host "[OK] dns.rules 包含 luokinging.com -> server: ali (避免 Fake-IP 污染)" -ForegroundColor Green
} else {
    Write-Error "[FAIL] dns.rules 缺少 luokinging.com 直连 DNS 配置"
    $allSuccess = $false
}

# 校验 4：确认已清理重复的 mesh.luokinging.com 旧规则
$oldRules = $cfg.route.rules | Where-Object { $_.domain -contains 'mesh.luokinging.com' }
if ($null -eq $oldRules -or $oldRules.Count -eq 0) {
    Write-Host "[OK] 确认已移除重复旧规则 domain: mesh.luokinging.com" -ForegroundColor Green
} else {
    Write-Error "[FAIL] 仍存在重复规则"
    $allSuccess = $false
}

if ($allSuccess) {
    Write-Host "`n所有 OpenWrt Tailscale DERP 双重优化校验项全部通过！" -ForegroundColor Cyan
    exit 0
} else {
    Write-Error "`n部分校验失败，请检查配置！"
    exit 1
}
