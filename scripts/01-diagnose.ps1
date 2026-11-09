<#
.SYNOPSIS
    步骤 1:只读诊断 —— 确认 EDL 可用、存储厂商、6 个 LUN 的 GPT 结构与 CRC

.DESCRIPTION
    全程只读,不写任何分区。用来回答三个问题:
      1. 这个 loader 能不能用(存储厂商对不对)
      2. GPT 是"结构坏了"还是"内容坏了"
      3. 有没有写权限(看 Supported Functions)

.EXAMPLE
    .\01-diagnose.ps1 -Loader C:\edl\xbl_s_devprg_ns.melf

.EXAMPLE
    .\01-diagnose.ps1 -Loader C:\edl\loader.melf -SkipLoad
    # 已经加载过编程器、设备仍在 firehose 阶段时用
#>
param(
    [Parameter(Mandatory)][string]$Loader,
    [switch]$SkipLoad,
    [int]$LunCount = 6,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib.ps1")

$port = Find-EdlPort -TimeoutSec $TimeoutSec

if (-not $SkipLoad) {
    if (-not (Invoke-SaharaLoad -Port $port -Loader $Loader)) {
        throw "编程器加载失败。检查:文件是否匹配该 SoC、是不是 Sahara 阶段(换个端口/重插)、线材。"
    }
    Start-Sleep -Seconds 1
}

if (-not (Test-EdlReady -Port $port)) {
    throw "loader 没有响应。可能仍在 Sahara 阶段,或编程器与平台不匹配。"
}
Write-Host "[+] loader 响应正常" -ForegroundColor Green

# ---------- 存储信息 ----------
Write-Host "`n=== 存储信息 ===" -ForegroundColor Cyan
$info = Get-StorageInfo -Port $port
$info.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-12} {1}" -f $_.Key, $_.Value) }

if ($info.Vendor) {
    $vendorNote = switch -Regex ($info.Vendor) {
        'Kioxia|Toshiba' { "⚠️ 铠侠/东芝存储:社区流传的'免授权 loader'常标注此类存储会格机,务必确认来源" }
        'Hynix'          { "SK Hynix —— 可安全使用标注'铠侠勿用'的 loader" }
        default          { "" }
    }
    if ($vendorNote) { Write-Host "  $vendorNote" -ForegroundColor Yellow }
}

$canWrite = $info.Functions -and ($info.Functions -contains "program")
Write-Host ("  写权限      {0}" -f $(if ($canWrite) { "有(program 在支持列表)" } else { "未知/无 —— 只能读" })) -ForegroundColor $(if ($canWrite) { "Green" } else { "Yellow" })

# ---------- 读 GPT ----------
Write-Host "`n=== GPT 校验(每个 LUN 前 8 扇区) ===" -ForegroundColor Cyan

$jobs = @()
for ($i = 0; $i -lt $LunCount; $i++) {
    $jobs += @{ Lun = $i; Start = 0; Sectors = 8; Out = (Join-Path $script:Work "g$i.bin") }
}
$xml = New-ReadXml -Jobs $jobs -OutXml (Join-Path $script:Work "read_gpt.xml")

$r = Invoke-FhLoader -Port $port -Arguments @("--sendxml=$xml", "--noprompt") -TimeoutSec 180
if ($r.ExitCode -ne 0) { throw "读取 GPT 失败,退出码 $($r.ExitCode)。日志: $($r.Log)" }

$bad = 0
for ($i = 0; $i -lt $LunCount; $i++) {
    $f = Join-Path $script:Work "g$i.bin"
    if (-not (Test-Path $f)) { Write-Host ("  LUN{0}  无数据" -f $i) -ForegroundColor Red; $bad++; continue }
    $b = [System.IO.File]::ReadAllBytes($f)
    $g = Read-Gpt -Buf $b
    if (-not $g -or -not $g.Valid) {
        Write-Host ("  LUN{0}  ❌ {1}" -f $i, $(if ($g) { $g.Reason } else { "无法解析" })) -ForegroundColor Red
        $bad++
        continue
    }
    $ok = $g.HeaderCrcOk -and $g.EntriesCrcOk
    $mark = if ($ok) { "✅" } else { "❌" }
    if (-not $ok) { $bad++ }
    Write-Host ("  LUN{0}  {1} MyLBA={2} AltLBA={3} Entries={4} size={5}  hdrCRC={6} entCRC={7}" -f `
        $i, $mark, $g.MyLba, $g.AltLba, $g.NumEntries, $g.EntrySize, `
        $(if ($g.HeaderCrcOk) { "OK" } else { "BAD" }), $(if ($g.EntriesCrcOk) { "OK" } else { "BAD" }))
    if ($g.FirstParts.Count) { Write-Host ("        前几个分区: " + ($g.FirstParts -join ", ")) -ForegroundColor DarkGray }
}

Write-Host ""
if ($bad -eq 0) {
    Write-Host "结论: 6 个 LUN 的 GPT 结构和 CRC 全部正常。" -ForegroundColor Green
    Write-Host "      → 如果有问题,不是分区表损坏,而是【分区内容】被抹/写坏。" -ForegroundColor Green
    Write-Host "      → 下一步:02-verify-partitions.ps1 比对分区内容。" -ForegroundColor Green
} else {
    Write-Host "结论: $bad 个 LUN 的 GPT 异常。" -ForegroundColor Yellow
    Write-Host "      → 需要用官方 rawprogramN.xml + patchN.xml 重写 GPT(不要只写 gpt_bothN.bin)。" -ForegroundColor Yellow
}
