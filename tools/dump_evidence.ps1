#Requires -Version 5.1
<#
.SYNOPSIS
    从已连接设备上取证提取 SystemHelper 已采集的数据（判断你被收走了什么）

.DESCRIPTION
    1. 用 run-as / su 把 /data/data/com.mobiletools.systemhelper 下的
       databases/systemhelper 与 shared_prefs 拉到本机 evidence\ 目录
    2. 若本机有 python，直接把 history 表里每一条上报 JSON 解码成可读文本
    3. 输出 summary.txt：统计上报次数、时间跨度、出现的 IMEI/IMSI/号码/基站/应用数

.PARAMETER Adb
    adb 路径，默认 PATH 中的 adb。

.PARAMETER OutDir
    取证输出目录，默认 .\evidence

.EXAMPLE
    .\dump_evidence.ps1
#>
[CmdletBinding()]
param(
    [string]$Adb = "adb",
    [string]$OutDir = ".\evidence"
)

$ErrorActionPreference = 'Continue'
$PKG = 'com.mobiletools.systemhelper'

function Write-Step($n, $t) { Write-Host ""; Write-Host ("[{0}] {1}" -f $n, $t) -ForegroundColor Cyan }
function Write-Ok($t)  { Write-Host "    OK   $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "    WARN $t" -ForegroundColor Yellow }
function Write-Bad($t) { Write-Host "    FAIL $t" -ForegroundColor Red }

Write-Host "================================================================" -ForegroundColor White
Write-Host " SystemHelper 取证提取" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White

$adbCmd = Get-Command $Adb -ErrorAction SilentlyContinue
if (-not $adbCmd) { Write-Bad "找不到 adb：$Adb"; exit 1 }

$devices = & $Adb devices 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' }
if (-not $devices) { Write-Bad "无已授权设备"; & $Adb devices; exit 1 }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path
Write-Ok "输出目录 = $OutDir"

# ---------------------------------------------------------------- 1. 尝试 run-as
Write-Step 1 "尝试 run-as 读取应用私有目录"

$dbLocal = Join-Path $OutDir 'systemhelper.db'
$prefLocal = Join-Path $OutDir 'prefs.xml'
$fetched = $false

$null = & $Adb shell run-as $PKG true 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "run-as 可用（应用为 debuggable 或已 root）"
    # 用 cmd 重定向，避免 PS 管道破坏二进制（PS5.1 / PS7 通用）
    & cmd /c "`"$Adb`" exec-out run-as $PKG cat databases/systemhelper > `"$dbLocal`" 2>nul"
    & cmd /c "`"$Adb`" exec-out run-as $PKG cat shared_prefs/com_mobiletools_systemhelper_preference.xml > `"$prefLocal`" 2>nul"
    if ((Test-Path $dbLocal) -and ((Get-Item $dbLocal).Length -gt 0)) { $fetched = $true }
} else {
    Write-Warn2 "run-as 不可用，尝试 su"
}

# ---------------------------------------------------------------- 2. su 回退
if (-not $fetched) {
    Write-Step 2 "尝试 su（root）"
    $tmp = "/sdcard/sh_$([guid]::NewGuid().ToString('N')).db"
    & $Adb shell su -c "cp /data/data/$PKG/databases/systemhelper $tmp" 2>&1 | Out-Null
    & $Adb pull $tmp $dbLocal 2>&1 | Out-Null
    & $Adb shell su -c "rm -f $tmp" 2>&1 | Out-Null
    if ((Test-Path $dbLocal) -and ((Get-Item $dbLocal).Length -gt 0)) {
        $fetched = $true
        Write-Ok "su 提取成功"
        & $Adb shell su -c "cp /data/data/$PKG/shared_prefs/com_mobiletools_systemhelper_preference.xml /sdcard/sh_pref.xml" 2>&1 | Out-Null
        & $Adb pull /sdcard/sh_pref.xml $prefLocal 2>&1 | Out-Null
        & $Adb shell su -c "rm -f /sdcard/sh_pref.xml" 2>&1 | Out-Null
    } else {
        Write-Bad "su 也不可用"
    }
}

if (-not $fetched) {
    Write-Host ""
    Write-Host "无法直接读取 /data/data 下的数据库。可选路径：" -ForegroundColor Yellow
    Write-Host "  A) 手机已 root：确认 Magisk 授权后重跑本脚本" -ForegroundColor Yellow
    Write-Host "  B) 未 root：用 PCAPdroid 抓包，重启手机后观察是否向 dm.wo.com.cn 发起 POST" -ForegroundColor Yellow
    Write-Host "  C) 未 root：TWRP recovery 下挂载 /data 后 adb pull 整个目录" -ForegroundColor Yellow
    Write-Host "  D) 已处置（disable/卸载）后数据库可能已被系统清理，属正常" -ForegroundColor Yellow
    exit 2
}

Write-Ok ("DB 大小 = " + (Get-Item $dbLocal).Length + " 字节")

# ---------------------------------------------------------------- 3. 解码
Write-Step 3 "解码 history 表（每条 = 一次上报快照）"

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Warn2 "本机无 python，跳过自动解码。用 DB Browser for SQLite 打开：$dbLocal"
    exit 0
}

$pyScript = Join-Path $OutDir 'decode.py'
@'
import json, sqlite3, sys, collections
db, out = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
rows = []
try:
    rows = [r[0] for r in con.execute("select jsonString from history")]
except Exception as e:
    print("read error:", e)
    sys.exit(1)

lines = []
lines.append("history 记录数: %d" % len(rows))
keys = collections.Counter()
imes, imsis, iccids, msisdns, cells, models = set(), set(), set(), set(), set(), set()
apps = set()
times = []
for i, r in enumerate(rows, 1):
    try:
        o = json.loads(r)
    except Exception:
        continue
    keys.update(o.keys())
    times.append(o.get("Time", ""))
    for k in ("IMEI1","IMEI2"):
        if o.get(k): imes.add(str(o[k]))
    for k in ("IMSI1","IMSI2"):
        if o.get(k): imsis.add(str(o[k]))
    for k in ("ICCID1","ICCID2"):
        if o.get(k): iccids.add(str(o[k]))
    for k in ("MSISDN1","MSISDN2"):
        if o.get(k): msisdns.add(str(o[k]))
    for k in ("CellID1","CellID2"):
        if o.get(k): cells.add(str(o[k]))
    if o.get("Model"): models.add(str(o["Model"]))
    ai = o.get("AppInfo")
    if isinstance(ai, list):
        for a in ai:
            if isinstance(a, dict) and a.get("pkgName"): apps.add(a["pkgName"])

lines.append("时间跨度: %s -> %s" % (times[0] if times else "-", times[-1] if times else "-"))
lines.append("IMEI:   " + ", ".join(sorted(imes)))
lines.append("IMSI:   " + ", ".join(sorted(imsis)))
lines.append("ICCID:  " + ", ".join(sorted(iccids)))
lines.append("MSISDN: " + ", ".join(sorted(msisdns)))
lines.append("CellID: " + ", ".join(sorted(cells)))
lines.append("机型:   " + ", ".join(sorted(models)))
lines.append("上报过的不同应用数: %d" % len(apps))
lines.append("")
lines.append("字段出现频次:")
for k, v in keys.most_common():
    lines.append("  %-16s %d" % (k, v))
lines.append("")
lines.append("=" * 60)
lines.append("逐条报文（原样 JSON，已格式化）")
lines.append("=" * 60)
for i, r in enumerate(rows, 1):
    try:
        o = json.loads(r)
        lines.append("--- #%d  Time=%s RegType=%s ---" % (i, o.get("Time"), o.get("RegType")))
        lines.append(json.dumps(o, ensure_ascii=False, indent=2, sort_keys=True))
    except Exception:
        lines.append("--- #%d (parse failed) ---" % i)
        lines.append(r)

open(out, "w", encoding="utf-8").write("\n".join(lines))
print("wrote", out)
'@ | Set-Content -Path $pyScript -Encoding UTF8

$summary = Join-Path $OutDir 'summary.txt'
& python $pyScript $dbLocal $summary
if ($LASTEXITCODE -eq 0) { Write-Ok "已生成 $summary" } else { Write-Warn2 "解码失败，见上方输出" }

Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host " 取证完成。查看 summary.txt 里的 IMEI/IMSI/MSISDN/CellID/AppInfo 统计。" -ForegroundColor White
Write-Host " 这些就是已经离开你设备、发往 dm.wo.com.cn 的数据。" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
