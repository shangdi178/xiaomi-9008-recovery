<#
.SYNOPSIS
    步骤 3:用官方固件刷写指定的分区(支持 A/B 双槽)

.DESCRIPTION
    从官方包的 rawprogramN.xml 取偏移,按 label 映射到实际文件,生成 program XML 再刷入。

    设计原则:
      - 默认排除 persist / modemst / fsg / fsc 等设备私有分区
      - 支持 -DryRun:只生成 XML 并打印,不写入
      - 支持 -Slots a,b:同时修两个槽

.EXAMPLE
    # 先看会刷什么(不写入)
    .\03-flash.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot -DryRun

.EXAMPLE
    # 正式刷,两个槽都补齐
    .\03-flash.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot -Slots a,b

.EXAMPLE
    # 只修指定分区
    .\03-flash.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Labels boot_a,vendor_boot_a,dtbo_a,init_boot_a
#>
param(
    [Parameter(Mandatory)][string]$ImagesDir,
    [Parameter(Mandatory)][string]$Loader,
    [string[]]$Labels,
    [ValidateSet("Boot", "Custom")][string]$Preset = "Boot",
    [ValidateSet("a", "b")][string[]]$Slots = @("a"),
    [switch]$IncludeModem,
    [switch]$DryRun,
    [switch]$SkipLoad,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib.ps1")

# 绝对不允许写的分区
$forbidden = @("persist", "modemst1", "modemst2", "fsg", "fsc", "devinfo")

# 引导固件:label(不含槽位) -> 包内文件名
$bootBase = [ordered]@{
    "xbl"         = "xbl_s.melf"
    "xbl_config"  = "xbl_config.elf"
    "multiimgqti" = "multi_image_qti.mbn"
    "multiimgoem" = "multi_image.mbn"
    "uefi"        = "uefi.elf"
    "aop"         = "aop.mbn"
    "aop_config"  = "aop_devcfg.mbn"
    "tz"          = "tz.mbn"
    "hyp"         = "hypvmperformance.mbn"
    "abl"         = "abl.elf"
    "dsp"         = "dspso.bin"
    "bluetooth"   = "BTFM.bin"
    "keymaster"   = "keymint.mbn"
    "boot"        = "boot.img"
    "devcfg"      = "devcfg.mbn"
    "qupfw"       = "qupv3fw.elf"
    "vbmeta"      = "vbmeta.img"
    "dtbo"        = "dtbo.img"
    "uefisecapp"  = "uefi_sec.mbn"
    "imagefv"     = "imagefv.elf"
    "shrm"        = "shrm.elf"
    "cpucp"       = "cpucp.elf"
    "featenabler" = "featenabler.mbn"
    "vendor_boot" = "vendor_boot.img"
    "recovery"    = "recovery.img"
    "xbl_ramdump" = "XblRamdump.elf"
    "init_boot"   = "init_boot.img"
}
if ($IncludeModem) { $bootBase["modem"] = "NON-HLOS.bin" }

$map = Get-RawprogramMap -ImagesDir $ImagesDir

# ---------- 组装目标 ----------
$jobs = @()
if ($Preset -eq "Boot") {
    foreach ($slot in $Slots) {
        foreach ($base in $bootBase.Keys) {
            $label = "$($base)_$slot"
            if (-not $map.ContainsKey($label)) { continue }
            $pkgFile = Join-Path $ImagesDir $bootBase[$base]
            if (-not (Test-Path $pkgFile)) { Write-Warning "缺少 $($bootBase[$base])($label)"; continue }
            $m = $map[$label]
            $jobs += [pscustomobject]@{ Label = $label; Lun = $m.Lun; Start = $m.Start; Sectors = $m.Sectors
                                        File = $pkgFile; KB = [math]::Round((Get-Item $pkgFile).Length / 1KB, 1) }
        }
    }
} else {
    if (-not $Labels) { throw "Preset=Custom 需要 -Labels" }
    foreach ($l in $Labels) {
        if ($forbidden -contains $l) { throw "拒绝写入受保护分区: $l" }
        if (-not $map.ContainsKey($l)) { Write-Warning "包里没有 $l"; continue }
        $m = $map[$l]
        if (-not $m.File) { Write-Warning "$l 在包里没有对应文件(多为 GPT 条目或空占位)"; continue }
        $pkgFile = Join-Path $ImagesDir $m.File
        if (-not (Test-Path $pkgFile)) { Write-Warning "缺少文件 $($m.File)"; continue }
        $jobs += [pscustomobject]@{ Label = $l; Lun = $m.Lun; Start = $m.Start; Sectors = $m.Sectors
                                    File = $pkgFile; KB = [math]::Round((Get-Item $pkgFile).Length / 1KB, 1) }
    }
}

if ($jobs.Count -eq 0) { throw "没有可刷写的目标" }

# ---------- 预览 ----------
$totalMB = ($jobs | Measure-Object -Property KB -Sum).Sum / 1024
Write-Host "`n=== 刷写计划 ===" -ForegroundColor Cyan
$jobs | Sort-Object Lun, Start | ForEach-Object {
    Write-Host ("  LUN{0}  {1,-16} <- {2,-24} {3,8:N0} KB" -f $_.Lun, $_.Label, (Split-Path $_.File -Leaf), $_.KB)
}
Write-Host ("  合计: {0} 个分区 / {1:N0} MB" -f $jobs.Count, $totalMB) -ForegroundColor Cyan

if ($DryRun) {
    $preview = Join-Path $script:Work "flash_preview.xml"
    New-ProgramXml -Jobs $jobs -OutXml $preview | Out-Null
    Write-Host "`n[DryRun] 已生成预览 XML: $preview (未写入设备)" -ForegroundColor Yellow
    return
}

# ---------- 执行 ----------
$port = Find-EdlPort -TimeoutSec $TimeoutSec
if (-not $SkipLoad) {
    if (-not (Invoke-SaharaLoad -Port $port -Loader $Loader)) { throw "编程器加载失败" }
    Start-Sleep -Seconds 1
}
if (-not (Test-EdlReady -Port $port)) { throw "loader 无响应" }

$xml = Join-Path $script:Work "flash.xml"
New-ProgramXml -Jobs $jobs -OutXml $xml | Out-Null

Write-Host "`n[*] 开始刷写 ..." -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-FhLoader -Port $port -Arguments @("--sendxml=$xml", "--noprompt") -TimeoutSec 1800
$sw.Stop()

$succ = ([regex]::Matches($r.Output, "SUCCESS")).Count
$errs = ([regex]::Matches($r.Output, "ERROR|Failed")).Count
Write-Host ("    退出码 {0} / 耗时 {1:N0}s / SUCCESS {2} / ERROR {3}" -f $r.ExitCode, $sw.Elapsed.TotalSeconds, $succ, $errs) `
    -ForegroundColor $(if ($errs -eq 0 -and $r.ExitCode -eq 0) { "Green" } else { "Red" })

if ($errs -gt 0) {
    Write-Host "`n错误行:" -ForegroundColor Red
    ($r.Output -split "`n") | Where-Object { $_ -match "ERROR|Failed" } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
}

Write-Host "`n下一步:04-readback-verify.ps1 读回校验(必做)" -ForegroundColor Yellow
