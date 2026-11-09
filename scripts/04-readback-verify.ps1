<#
.SYNOPSIS
    步骤 4:读回校验 —— 证明写入真的落到了正确位置

.DESCRIPTION
    日志里出现 SUCCESS 不代表数据写对了(偏移错、LUN 错、被截断都可能显示成功)。
    这个脚本把刚刷过的分区读回来,和源文件做 SHA256 比对。

    只读。

.EXAMPLE
    .\04-readback-verify.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Labels xbl_a,abl_a,boot_a

.EXAMPLE
    .\04-readback-verify.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot -Slots a
#>
param(
    [Parameter(Mandatory)][string]$ImagesDir,
    [Parameter(Mandatory)][string]$Loader,
    [string[]]$Labels,
    [ValidateSet("Boot", "Custom")][string]$Preset = "Custom",
    [ValidateSet("a", "b")][string[]]$Slots = @("a"),
    [switch]$SkipLoad,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib.ps1")

$bootBase = [ordered]@{
    "xbl" = "xbl_s.melf"; "xbl_config" = "xbl_config.elf"; "abl" = "abl.elf"
    "uefi" = "uefi.elf"; "tz" = "tz.mbn"; "hyp" = "hypvmperformance.mbn"
    "aop" = "aop.mbn"; "aop_config" = "aop_devcfg.mbn"; "devcfg" = "devcfg.mbn"
    "cpucp" = "cpucp.elf"; "qupfw" = "qupv3fw.elf"; "shrm" = "shrm.elf"
    "keymaster" = "keymint.mbn"; "featenabler" = "featenabler.mbn"
    "storsec" = "storsec.mbn"; "xbl_ramdump" = "XblRamdump.elf"
    "imagefv" = "imagefv.elf"; "boot" = "boot.img"; "vendor_boot" = "vendor_boot.img"
    "dtbo" = "dtbo.img"; "vbmeta" = "vbmeta.img"; "init_boot" = "init_boot.img"
}

$map = Get-RawprogramMap -ImagesDir $ImagesDir

$targets = @()
if ($Preset -eq "Boot") {
    foreach ($slot in $Slots) { foreach ($b in $bootBase.Keys) { $targets += "$($b)_$slot" } }
} else {
    if (-not $Labels) { throw "Preset=Custom 需要 -Labels" }
    $targets = $Labels
}

$port = Find-EdlPort -TimeoutSec $TimeoutSec
if (-not $SkipLoad) {
    if (-not (Invoke-SaharaLoad -Port $port -Loader $Loader)) { throw "编程器加载失败" }
    Start-Sleep -Seconds 1
}
if (-not (Test-EdlReady -Port $port)) { throw "loader 无响应" }

$jobs = @()
$plan = @()
$i = 0
foreach ($l in $targets) {
    if (-not $map.ContainsKey($l)) { continue }
    $m = $map[$l]
    $pkgFile = $null
    if ($m.File) { $pkgFile = Join-Path $ImagesDir $m.File }
    if (-not $pkgFile -or -not (Test-Path $pkgFile)) {
        # 包里没有对应文件时,从 bootBase 反查
        $base = $l -replace "_(a|b)$", ""
        if ($bootBase.Contains($base)) { $pkgFile = Join-Path $ImagesDir $bootBase[$base] }
    }
    if (-not $pkgFile -or -not (Test-Path $pkgFile)) { Write-Warning "找不到 $l 的源文件,跳过"; continue }

    $out = Join-Path $script:Work ("rb_$i.bin")
    $jobs += @{ Lun = $m.Lun; Start = $m.Start; Sectors = 16; Out = $out }
    $plan += [pscustomobject]@{ Label = $l; Out = $out; Pkg = $pkgFile }
    $i++
}

if ($jobs.Count -eq 0) { throw "没有可校验的目标" }

Write-Host "[*] 读回 $($jobs.Count) 个分区 ..."
$xml = New-ReadXml -Jobs $jobs -OutXml (Join-Path $script:Work "readback.xml")
$r = Invoke-FhLoader -Port $port -Arguments @("--sendxml=$xml", "--noprompt") -TimeoutSec 300
if ($r.ExitCode -ne 0) { throw "读取失败: $($r.Log)" }

Write-Host "`n=== 读回校验(前 64KB) ===" -ForegroundColor Cyan
$bad = 0
foreach ($p in $plan) {
    if (-not (Test-Path $p.Out)) { Write-Host ("  {0,-16} 读取失败" -f $p.Label) -ForegroundColor Red; $bad++; continue }
    $db = [System.IO.File]::ReadAllBytes($p.Out)
    $pb = [System.IO.File]::ReadAllBytes($p.Pkg)
    $n = [Math]::Min(65536, [Math]::Min($db.Length, $pb.Length))
    $dh = Get-Sha256Hex $db[0..($n - 1)]
    $ph = Get-Sha256Hex $pb[0..($n - 1)]

    if ($dh -eq $ph) {
        Write-Host ("  {0,-16} MATCH" -f $p.Label) -ForegroundColor Green
    } else {
        $tag = if (Test-AllZero $db) { "ALL-ZERO(写入未落盘)" } else { "DIFF(内容不符)" }
        Write-Host ("  {0,-16} {1}" -f $p.Label, $tag) -ForegroundColor Red
        Write-Host ("      device={0}  source={1}" -f $dh.Substring(0, 16), $ph.Substring(0, 16)) -ForegroundColor DarkGray
        $bad++
    }
}

Write-Host ""
if ($bad -eq 0) {
    Write-Host "结论: 全部 MATCH,写入正确落盘。" -ForegroundColor Green
    Write-Host "      → 如果仍不开机:先充电 1~2 小时再按电源(见 README §9)" -ForegroundColor Green
} else {
    Write-Host "结论: $bad 个分区校验失败。" -ForegroundColor Red
    Write-Host "      → 检查 LUN 编号、start_sector 是否取自【同一版本】的 rawprogramN.xml" -ForegroundColor Red
}
