<#
.SYNOPSIS
    步骤 2:比对分区内容 —— 找出被抹空或被改写的分区

.DESCRIPTION
    读每个候选分区的前 64KB,和固件包里的对应文件比 SHA256,给出三种判定:
      MATCH     内容正确
      ALL-ZERO  分区被清空(典型:执行过 erase)
      DIFF      有内容但不是这个版本

    只读,不写任何分区。

.EXAMPLE
    .\02-verify-partitions.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf

.EXAMPLE
    # 只查引导相关的默认列表
    .\02-verify-partitions.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot
#>
param(
    [Parameter(Mandatory)][string]$ImagesDir,
    [Parameter(Mandatory)][string]$Loader,
    [string[]]$Labels,
    [ValidateSet("Boot", "All", "Custom")][string]$Preset = "Boot",
    [switch]$SkipLoad,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib.ps1")

# 引导相关分区 -> 包内文件名(不同版本文件名可能不同,匹配不上会跳过)
$bootPreset = [ordered]@{
    "xbl_a" = "xbl_s.melf";         "xbl_config_a" = "xbl_config.elf"
    "abl_a" = "abl.elf";            "uefi_a" = "uefi.elf"
    "tz_a" = "tz.mbn";              "hyp_a" = "hypvmperformance.mbn"
    "aop_a" = "aop.mbn";            "aop_config_a" = "aop_devcfg.mbn"
    "devcfg_a" = "devcfg.mbn";      "cpucp_a" = "cpucp.elf"
    "qupfw_a" = "qupv3fw.elf";      "shrm_a" = "shrm.elf"
    "keymaster_a" = "keymint.mbn";  "featenabler_a" = "featenabler.mbn"
    "storsec" = "storsec.mbn";      "xbl_ramdump_a" = "XblRamdump.elf"
    "imagefv_a" = "imagefv.elf";    "boot_a" = "boot.img"
    "vendor_boot_a" = "vendor_boot.img"; "dtbo_a" = "dtbo.img"
    "vbmeta_a" = "vbmeta.img";      "init_boot_a" = "init_boot.img"
}

$map = Get-RawprogramMap -ImagesDir $ImagesDir

if ($Preset -eq "Boot") { $targets = $bootPreset }
elseif ($Preset -eq "Custom") {
    if (-not $Labels) { throw "Preset=Custom 需要 -Labels" }
    $targets = [ordered]@{}
    foreach ($l in $Labels) { if ($map.ContainsKey($l)) { $targets[$l] = $map[$l].File } }
}
else {
    $targets = [ordered]@{}
    foreach ($k in $map.Keys) { if ($map[$k].File) { $targets[$k] = $map[$k].File } }
}

$port = Find-EdlPort -TimeoutSec $TimeoutSec
if (-not $SkipLoad) {
    if (-not (Invoke-SaharaLoad -Port $port -Loader $Loader)) { throw "编程器加载失败" }
    Start-Sleep -Seconds 1
}
if (-not (Test-EdlReady -Port $port)) { throw "loader 无响应" }

# ---------- 读取 ----------
$jobs = @()
$plan = @()
$i = 0
foreach ($label in $targets.Keys) {
    if (-not $map.ContainsKey($label)) { continue }
    $m = $map[$label]
    $pkgFile = Join-Path $ImagesDir $targets[$label]
    if (-not (Test-Path $pkgFile)) { Write-Warning "包内缺少 $($targets[$label]),跳过 $label"; continue }
    $out = Join-Path $script:Work ("p_$i.bin")
    $jobs += @{ Lun = $m.Lun; Start = $m.Start; Sectors = 16; Out = $out }
    $plan += [pscustomobject]@{ Label = $label; Lun = $m.Lun; Start = $m.Start; Out = $out; Pkg = $pkgFile }
    $i++
}

if ($jobs.Count -eq 0) { throw "没有可比对的分区" }

Write-Host "[*] 读取 $($jobs.Count) 个分区的前 64KB ..."
$xml = New-ReadXml -Jobs $jobs -OutXml (Join-Path $script:Work "read_parts.xml")
$r = Invoke-FhLoader -Port $port -Arguments @("--sendxml=$xml", "--noprompt") -TimeoutSec 300
if ($r.ExitCode -ne 0) { throw "读取失败: $($r.Log)" }

# ---------- 比对 ----------
Write-Host "`n=== 分区内容比对(前 64KB)× ===" -ForegroundColor Cyan
$mismatch = @()
foreach ($p in $plan) {
    if (-not (Test-Path $p.Out)) { Write-Host ("  {0,-16} 读取失败" -f $p.Label) -ForegroundColor Red; continue }
    $db = [System.IO.File]::ReadAllBytes($p.Out)
    $pb = [System.IO.File]::ReadAllBytes($p.Pkg)
    $n = [Math]::Min(65536, [Math]::Min($db.Length, $pb.Length))
    $dh = Get-Sha256Hex $db[0..($n - 1)]
    $ph = Get-Sha256Hex $pb[0..($n - 1)]

    if ($dh -eq $ph) {
        Write-Host ("  {0,-16} MATCH" -f $p.Label) -ForegroundColor Green
    } else {
        $tag = if (Test-AllZero $db) { "ALL-ZERO" } else { "DIFF" }
        $color = if ($tag -eq "ALL-ZERO") { "Red" } else { "Yellow" }
        Write-Host ("  {0,-16} {1}" -f $p.Label, $tag) -ForegroundColor $color
        $mismatch += $p.Label
    }
}

Write-Host ""
if ($mismatch.Count -eq 0) {
    Write-Host "结论: 全部分区内容正确。" -ForegroundColor Green
    Write-Host "      → 如果仍不开机,先查供电/电池(见 README §9)" -ForegroundColor Green
} else {
    Write-Host "结论: $($mismatch.Count) 个分区需要修复:" -ForegroundColor Yellow
    Write-Host ("      " + ($mismatch -join ", ")) -ForegroundColor Yellow
    Write-Host "      → 下一步:03-flash.ps1 用【官方零售固件】补齐这些分区" -ForegroundColor Yellow
    Write-Host "      → 注意:A/B 两个槽都要处理" -ForegroundColor Yellow
}
