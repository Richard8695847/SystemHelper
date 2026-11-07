#Requires -Version 5.1
<#
.SYNOPSIS
    SystemHelper (com.mobiletools.systemhelper) 终端处置脚本

.DESCRIPTION
    对已连接 ADB 的 Android 设备执行分层处置：
      1. 定位安装位置（data / system / product）
      2. 停用或移除当前用户副本
      3. 逐项撤销运行时权限与 AppOps
      4. 清理本地采集数据
      5. 处置后验证
    另可选：在 Windows 本机 hosts 中黑洞化上报域名（需管理员）。

.PARAMETER Adb
    adb 可执行文件路径。默认从 PATH 查找。

.PARAMETER Remove
    使用 pm uninstall --user 0 彻底移除当前用户副本（默认只 disable-user，可逆）。

.PARAMETER PurgeData
    清除该应用的本地数据库/SharedPreferences（需 root 或 run-as 可用）。

.PARAMETER BlockHosts
    在 Windows hosts 中追加黑洞记录（需管理员权限）。

.EXAMPLE
    .\kill_systemhelper.ps1
    仅停用 + 撤权限 + 验证（最安全，可逆）。

.EXAMPLE
    .\kill_systemhelper.ps1 -Remove -PurgeData
    彻底移除当前用户副本并清本地数据。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\kill_systemhelper.ps1 -BlockHosts
    额外在 Windows 本机拦截上报域名（管理员）。
#>
[CmdletBinding()]
param(
    [string]$Adb = "adb",
    [switch]$Remove,
    [switch]$PurgeData,
    [switch]$BlockHosts
)

$ErrorActionPreference = 'Continue'
$PKG = 'com.mobiletools.systemhelper'
$DOMAINS = @(
    'dm.wo.com.cn',
    'cnc-labs.eicp.net',
    'webservice.chinaunicom.com'
)
$PERMS = @(
    'android.permission.READ_PHONE_STATE',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.ACCESS_BACKGROUND_LOCATION',
    'android.permission.READ_EXTERNAL_STORAGE'
)
$APPOPS = @(
    'READ_PHONE_STATE',
    'GET_USAGE_STATS',
    'COARSE_LOCATION',
    'FINE_LOCATION',
    'READ_EXTERNAL_STORAGE'
)

function Write-Step($n, $text) {
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $n, $text) -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host "    OK   $text" -ForegroundColor Green }
function Write-Warn2($text){ Write-Host "    WARN $text" -ForegroundColor Yellow }
function Write-Bad($text)  { Write-Host "    FAIL $text" -ForegroundColor Red }

function Invoke-Adb {
    param([string[]]$Arguments, [switch]$Quiet)
    $out = & $Adb @Arguments 2>&1
    if (-not $Quiet -and $out) { $out | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray } }
    return $out
}

Write-Host "================================================================" -ForegroundColor White
Write-Host " SystemHelper 处置脚本  (com.mobiletools.systemhelper)" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White

# ---------------------------------------------------------------- 0. 环境检查
Write-Step 0 "检查 adb 与设备连接"

$adbCmd = Get-Command $Adb -ErrorAction SilentlyContinue
if (-not $adbCmd) {
    Write-Bad "找不到 adb：$Adb"
    Write-Host "    请安装 Android SDK platform-tools，或指定路径：" -ForegroundColor Yellow
    Write-Host "    .\kill_systemhelper.ps1 -Adb 'C:\Android\platform-tools\adb.exe'" -ForegroundColor Yellow
    exit 1
}
Write-Ok "adb = $($adbCmd.Source)"

$devices = & $Adb devices 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' }
if (-not $devices) {
    Write-Bad "没有已授权的设备。请开启 USB 调试并在手机上点『允许』。"
    & $Adb devices
    exit 1
}
foreach ($d in $devices) { Write-Ok ("设备: " + ($d -split "`t")[0]) }

$sdk = (& $Adb shell getprop ro.build.version.sdk 2>&1) -join '' -replace '\s',''
Write-Ok "Android SDK = $sdk"

# ---------------------------------------------------------------- 1. 定位
Write-Step 1 "定位安装位置"

$pmPath = (& $Adb shell pm path $PKG 2>&1) -join "`n"
if ($pmPath -match 'package:') {
    $codePath = ($pmPath -split "`n" | Where-Object { $_ -match 'package:' } | Select-Object -First 1) -replace 'package:','' -replace '\s',''
    Write-Ok "codePath = $codePath"
    if ($codePath -like '/data/*') {
        $kind = 'USER'
        Write-Ok "判定：用户安装（可直接卸载）"
    } elseif ($codePath -like '/system/priv-app/*') {
        $kind = 'PRIV'
        Write-Warn2 "判定：系统 priv-app 预装（持有 READ_PRIVILEGED_PHONE_STATE）"
    } elseif ($codePath -like '/system/*' -or $codePath -like '/product/*' -or $codePath -like '/vendor/*') {
        $kind = 'SYSTEM'
        Write-Warn2 "判定：系统分区预装（--user 0 移除，恢复出厂会复活）"
    } else {
        $kind = 'OTHER'
        Write-Warn2 "判定：其他路径，按系统预装处理"
    }
} else {
    Write-Warn2 "设备上未找到 $PKG（可能已移除）。继续检查残留权限/闹钟/进程。"
    $kind = 'ABSENT'
}

# 共享 UID 宿主检查
$shared = (& $Adb shell dumpsys package $PKG 2>&1) -join "`n"
if ($shared -match 'sharedUser=([^\s]+)') {
    Write-Warn2 ("sharedUserId = " + $Matches[1] + "  ← 同 UID 的其他预装应用可绕过隔离")
} else {
    Write-Warn2 "sharedUserId: 读取不到（可能已移除或 dumpsys 受限）"
}

# ---------------------------------------------------------------- 2. 停用 / 移除
Write-Step 2 "停用或移除组件"

if ($kind -ne 'ABSENT') {
    & $Adb shell am force-stop $PKG 2>&1 | Out-Null
    Write-Ok "已 force-stop"

    if ($Remove) {
        $r = (& $Adb shell pm uninstall --user 0 $PKG 2>&1) -join ' '
        if ($r -match 'Success') { Write-Ok "pm uninstall --user 0 成功" }
        else {
            Write-Bad "uninstall 失败：$r"
            Write-Warn2 "回退到 disable-user"
            $r2 = (& $Adb shell pm disable-user --user 0 $PKG 2>&1) -join ' '
            if ($r2 -match 'new state: disabled') { Write-Ok "已 disable-user" } else { Write-Bad "disable 失败：$r2" }
        }
    } else {
        $r = (& $Adb shell pm disable-user --user 0 $PKG 2>&1) -join ' '
        if ($r -match 'new state: disabled') {
            Write-Ok "已 disable-user（可随时用 pm enable 恢复）"
        } else {
            Write-Bad "disable 失败：$r"
            Write-Warn2 "系统签名保护时需 root：adb shell su -c 'pm disable com.mobiletools.systemhelper'"
        }
    }
} else {
    Write-Warn2 "跳过（未安装）"
}

# ---------------------------------------------------------------- 3. 撤销权限
Write-Step 3 "撤销运行时权限与 AppOps"

if ($kind -ne 'ABSENT') {
    foreach ($p in $PERMS) {
        $r = (& $Adb shell pm revoke $PKG $p 2>&1) -join ' '
        if ([string]::IsNullOrWhiteSpace($r) -or $r -notmatch 'Error|Exception|Unknown') {
            Write-Ok "revoke $p"
        } else {
            Write-Warn2 "revoke $p -> $r"
        }
    }
    foreach ($op in $APPOPS) {
        $r = (& $Adb shell appops set $PKG $op ignore 2>&1) -join ' '
        if ([string]::IsNullOrWhiteSpace($r) -or $r -notmatch 'Error|Exception') {
            Write-Ok "appops $op = ignore"
        } else {
            Write-Warn2 "appops $op -> $r"
        }
    }
} else {
    Write-Warn2 "跳过（未安装）"
}

# ---------------------------------------------------------------- 4. 清本地数据
Write-Step 4 "清理本地采集数据"

if ($PurgeData) {
    $null = & $Adb shell run-as $PKG true 2>&1
    $runAsOk = ($LASTEXITCODE -eq 0)
    if ($runAsOk) {
        & $Adb shell run-as $PKG rm -rf databases shared_prefs 2>&1 | Out-Null
        Write-Ok "已删除 databases/ 与 shared_prefs/（含 history 表与 iccid 明文）"
    } else {
        Write-Warn2 "run-as 不可用（非 debuggable）。尝试 root 路径："
        & $Adb shell su -c "rm -rf /data/data/$PKG/databases /data/data/$PKG/shared_prefs" 2>&1 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        $chk = (& $Adb shell su -c "ls /data/data/$PKG/databases" 2>&1) -join ' '
        if ($chk -notmatch 'No such file') { Write-Warn2 "未能清理，需手动（TWRP/recovery 下删除 data/data/$PKG）" }
        else { Write-Ok "已通过 su 清理" }
    }
} else {
    Write-Warn2 "未指定 -PurgeData，跳过。加 -PurgeData 可清除 history 表与 iccid 明文缓存。"
}

# ---------------------------------------------------------------- 5. 关闭使用情况访问
Write-Step 5 "关闭『使用情况访问权限』（PACKAGE_USAGE_STATS）"

Write-Host "    该项不走运行时权限，需在系统设置里关：" -ForegroundColor Yellow
Write-Host "    设置 → 应用 → 特殊权限 → 使用情况访问权限 → 找到 SystemHelper → 关闭" -ForegroundColor Yellow
if ($sdk -ge 30) {
    & $Adb shell am start -a android.settings.USAGE_ACCESS_SETTINGS 2>&1 | Out-Null
    Write-Ok "已尝试跳转到该设置页"
}

# ---------------------------------------------------------------- 6. hosts 拦截
Write-Step 6 "Windows 本机 hosts 黑洞化上报域名"

if ($BlockHosts) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Bad "需要管理员权限。请以管理员身份重开 PowerShell 后重跑 -BlockHosts。"
    } else {
        $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $content = Get-Content $hosts -ErrorAction SilentlyContinue
        foreach ($d in $DOMAINS) {
            if ($content -match [regex]::Escape($d)) {
                Write-Warn2 "$d 已存在，跳过"
            } else {
                Add-Content -Path $hosts -Value "0.0.0.0 $d" -Encoding ASCII
                Write-Ok "已拦截 $d"
            }
        }
        ipconfig /flushdns | Out-Null
        Write-Ok "已刷新 DNS 缓存"
    }
} else {
    Write-Warn2 "未指定 -BlockHosts，跳过（路由器/NetGuard 层拦截更有效，见报告 §11-C）"
}

# ---------------------------------------------------------------- 7. 验证
Write-Step 7 "处置结果验证"

$still = (& $Adb shell pm list packages $PKG 2>&1) -join ' '
if ($still -match [regex]::Escape($PKG)) {
    $en = (& $Adb shell pm list packages -d 2>&1) -join ' '
    if ($en -match [regex]::Escape($PKG)) { Write-Ok "包仍在但已 disabled" }
    else { Write-Warn2 "包仍在且未 disabled —— 需要 root 或刷机才能移除" }
} else {
    Write-Ok "包已不在当前用户可见列表"
}

$ps = (& $Adb shell ps -A 2>&1) -join "`n"
if ($ps -match 'systemhelper') { Write-Bad "仍有进程在跑（重启后复查）" } else { Write-Ok "无运行中进程" }

$grants = (& $Adb shell dumpsys package $PKG 2>&1) -join "`n"
if ($grants -match [regex]::Escape($PKG)) {
    $bad = ($grants -split "`n" | Where-Object { $_ -match 'READ_PHONE_STATE|ACCESS_FINE_LOCATION|ACCESS_BACKGROUND_LOCATION' -and $_ -match 'granted=true' })
    if ($bad) { Write-Warn2 ("仍有已授权权限：" + ($bad -join '; ')) } else { Write-Ok "关键权限均已非 granted" }
} else {
    Write-Ok "无包信息可查（已移除）"
}

$alarms = (& $Adb shell dumpsys alarm 2>&1) -join "`n"
if ($alarms -match 'systemhelper') { Write-Warn2 "仍有待触发闹钟（重启后复查）" } else { Write-Ok "无残留闹钟" }

Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host " 处置完成。建议重启设备后再跑一次本脚本做复查。" -ForegroundColor White
Write-Host " 若包为 /system/priv-app 预装：恢复出厂会复活，需刷非定制固件。" -ForegroundColor White
Write-Host " 网络层拦截（NetGuard / 私有 DNS / 路由器 hosts）是最后一道闸。" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
