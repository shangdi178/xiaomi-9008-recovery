<#
.SYNOPSIS
    一条龙:守候 9008 → 加载 loader → 刷写 → 复位 → 探测

.DESCRIPTION
    救砖时要反复"按键进 EDL → 跑命令 → 复位 → 看有没有起来",人要在旁边守着。
    这个脚本把整条链串起来:你先启动它,然后再去按键,它检测到设备就自动干活。

    适合:已经确定要刷什么、只需要重复执行的场景。

.EXAMPLE
    .\05-auto-recover.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Slots a,b

.EXAMPLE
    # 只刷不复位(想保持 EDL 会话继续做别的)
    .\05-auto-recover.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -NoReset
#>
param(
    [Parameter(Mandatory)][string]$ImagesDir,
    [Parameter(Mandatory)][string]$Loader,
    [ValidateSet("a", "b")][string[]]$Slots = @("a", "b"),
    [switch]$IncludeModem,
    [switch]$NoReset,
    [int]$WaitSec = 600
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib.ps1")

Write-Host "=== 等待设备进入 9008(最多 $WaitSec 秒)===" -ForegroundColor Cyan
Write-Host "    请:按住组合键(如 音量下 + 电源)→ 插线 → 保持 10 秒" -ForegroundColor Yellow
$port = Find-EdlPort -TimeoutSec $WaitSec
Start-Sleep -Seconds 2

# 1. 加载编程器
if (-not (Invoke-SaharaLoad -Port $port -Loader $Loader)) { throw "编程器加载失败" }
Start-Sleep -Seconds 1

# 2. 验证
if (-not (Test-EdlReady -Port $port)) { throw "loader 无响应" }
Write-Host "[+] loader 正常" -ForegroundColor Green

# 3. 刷写(复用 03 的逻辑)
Write-Host "`n=== 开始刷写 ===" -ForegroundColor Cyan
$mp = Join-Path $ImagesDir "rawprogram0.xml"
if (-not (Test-Path $mp)) { throw "ImagesDir 里没有 rawprogram0.xml: $ImagesDir" }

$argList = @("-ImagesDir", $ImagesDir, "-Loader", $Loader, "-Preset", "Boot", "-Slots", ($Slots -join ","), "-SkipLoad")
if ($IncludeModem) { $argList += "-IncludeModem" }
& (Join-Path $PSScriptRoot "03-flash.ps1") @argList

# 4. 复位
if (-not $NoReset) {
    Write-Host "`n=== 复位设备 ===" -ForegroundColor Cyan
    $r = Invoke-FhLoader -Port $port -Arguments @("--noprompt", "--reset") -TimeoutSec 60
    Write-Host "    复位退出码: $($r.ExitCode)"
} else {
    Write-Host "`n[!] 按 -NoReset 跳过复位,EDL 会话保留" -ForegroundColor Yellow
    return
}

# 5. 探测
Write-Host "`n=== 等待 20 秒后探测 ===" -ForegroundColor Cyan
Start-Sleep -Seconds 20

$fb = $null
$ad = $null
foreach ($c in @("C:\platform-tools\fastboot.exe", (Join-Path $env:MIFLASH_DIR "fastboot.exe"))) {
    if (Test-Path $c) { $fb = $c; break }
}

Write-Host "--- USB 设备 ---"
$any = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -match "VID_05C6|VID_18D1|VID_2717&PID_FF" }
if ($any) {
    $any | ForEach-Object { Write-Host ("  {0}  {1}  [{2}]" -f $_.Status, $_.FriendlyName, $_.InstanceId) -ForegroundColor Green }
} else {
    Write-Host "  无任何 Android/Qualcomm 设备" -ForegroundColor Yellow
}

if ($fb) {
    Write-Host "--- fastboot ---"
    $out = & $fb devices 2>&1
    if ($out) { $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Green } }
    else { Write-Host "  (空)" -ForegroundColor Yellow }
}

Write-Host ""
if ($any) {
    Write-Host "✅ 检测到设备 —— 引导链已恢复" -ForegroundColor Green
} else {
    Write-Host "⚠️ 仍然没有设备。检查顺序:" -ForegroundColor Yellow
    Write-Host "   1) 读回校验是否全 MATCH(04-readback-verify.ps1)" -ForegroundColor Yellow
    Write-Host "   2) 两个槽是否都刷了(-Slots a,b)" -ForegroundColor Yellow
    Write-Host "   3) 固件是否【官方零售包】而不是工程包" -ForegroundColor Yellow
    Write-Host "   4) 电量:插墙充 1~2 小时后再按电源(EDL 很耗电,PC USB 充不进)" -ForegroundColor Yellow
}
