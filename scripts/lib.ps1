<#
.SYNOPSIS
    Xiaomi EDL/9008 救砖工具库(共享函数)

.DESCRIPTION
    被 01~04 号脚本 dot-source 引用。提供:
      - 9008 端口自动发现
      - QSaharaServer / fh_loader 封装
      - CRC32 / SHA256
      - GPT 解析与校验
      - read/program XML 生成

.NOTES
    依赖 MiFlash 安装目录下的 QSaharaServer.exe 与 fh_loader.exe
    典型路径: C:\MiFlash\ 或 G:\MiFlash Prime Edition xxx\MiFlash\
#>

# ---------- 环境 ----------

if (-not $env:MIFLASH_DIR) {
    $candidates = @(
        "C:\MiFlash",
        "C:\Program Files (x86)\Xiaomi\MiPhone\MiFlash",
        "C:\Program Files\Xiaomi\MiFlash"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "fh_loader.exe")) { $env:MIFLASH_DIR = $c; break }
    }
}

if (-not $env:MIFLASH_DIR -or -not (Test-Path (Join-Path $env:MIFLASH_DIR "fh_loader.exe"))) {
    Write-Warning "MIFLASH_DIR 未设置或找不到 fh_loader.exe。请先: `$env:MIFLASH_DIR='<MiFlash 目录>'"
}

$script:Sahara   = Join-Path $env:MIFLASH_DIR "QSaharaServer.exe"
$script:FhLoader = Join-Path $env:MIFLASH_DIR "fh_loader.exe"

# fh_loader 的参数里不能带空格路径,统一用这个临时工作目录
$script:Work = Join-Path $env:TEMP "edl_work"
if (-not (Test-Path $script:Work)) { New-Item -ItemType Directory -Force -Path $script:Work | Out-Null }

# ---------- 端口发现 ----------

function Find-EdlPort {
    <#
      轮询等待 Qualcomm 9008 出现,返回 '\\.\COMx'
      -TimeoutSec 默认 600 秒
    #>
    param([int]$TimeoutSec = 600)

    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $dev = Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -like "*QDLoader 9008*" } |
               Select-Object -First 1
        if ($dev -and $dev.FriendlyName -match "\((COM\d+)\)") {
            $port = '\\.\' + $Matches[1]
            Write-Host "[+] 9008 已连接: $($Matches[1])" -ForegroundColor Green
            return $port
        }
        Start-Sleep -Seconds 1
    }
    throw "等待 9008 超时($TimeoutSec 秒)。请按住组合键后插线。"
}

# ---------- 与设备通信 ----------

function Invoke-SaharaLoad {
    <#
      用 QSaharaServer 把 firehose 编程器送进设备 RAM
      -Loader 编程器文件(*.melf / prog_firehose_ddr.elf)
    #>
    param(
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Loader
    )
    if (-not (Test-Path $Loader)) { throw "找不到编程器文件: $Loader" }

    Write-Host "[*] 加载编程器: $(Split-Path $Loader -Leaf)"
    $out = & $script:Sahara -p $Port -s "13:$Loader" 2>&1
    $text = ($out | Out-String)
    if ($text -match "Sahara protocol completed") {
        Write-Host "[+] Sahara 完成" -ForegroundColor Green
        return $true
    }
    Write-Warning "Sahara 未正常完成。输出:`n$text"
    return $false
}

function Invoke-FhLoader {
    <#
      调用 fh_loader,返回 @{ ExitCode; Output }
      -Arguments 字符串数组,例如 @('--nop'), @('--sendxml=C:\x.xml','--noprompt')
    #>
    param(
        [Parameter(Mandatory)][string]$Port,
        [string[]]$Arguments = @(),
        [string]$MemoryName = "ufs",
        [int]$TimeoutSec = 600
    )

    $all = @("--port=$Port", "--memoryname=$MemoryName") + $Arguments
    $log = Join-Path $script:Work ("fh_" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".log")

    $p = Start-Process -FilePath $script:FhLoader -ArgumentList $all `
         -WorkingDirectory $env:MIFLASH_DIR -NoNewWindow -PassThru `
         -RedirectStandardOutput $log -RedirectStandardError ($log + ".err")

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill()
        return @{ ExitCode = -1; Output = "TIMEOUT"; Log = $log }
    }
    $text = (Get-Content $log -ErrorAction SilentlyContinue | Out-String)
    return @{ ExitCode = $p.ExitCode; Output = $text; Log = $log }
}

function Test-EdlReady {
    param([Parameter(Mandatory)][string]$Port)
    $r = Invoke-FhLoader -Port $Port -Arguments @('--nop') -TimeoutSec 40
    return ($r.ExitCode -eq 0 -and $r.Output -match "TARGET SAID")
}

function Get-StorageInfo {
    param([Parameter(Mandatory)][string]$Port)
    $out = Join-Path $script:Work "storageinfo.txt"
    $r = Invoke-FhLoader -Port $Port -Arguments @("--getstorageinfo=$out") -TimeoutSec 60
    $info = [ordered]@{}
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match "TARGET SAID: 'INFO: ufs: (\S+)'")                    { $info.Vendor = $Matches[1] }
        if ($line -match "Device Total Physical Partitions: 0x([0-9a-fA-F]+)") { $info.LunCount = [Convert]::ToInt32($Matches[1], 16) }
        if ($line -match "Supported Functions \((\d+)\)")                       { $info.FuncCount = [int]$Matches[1] }
        if ($line -match "'INFO: (program|erase|patch|read|nop|configure)'")    {
            if (-not $info.Functions) { $info.Functions = @() }
            $info.Functions += $Matches[1]
        }
    }
    return $info
}

# ---------- 哈希 / 校验 ----------

$script:Polynomial = [uint32]3988292384    # 0xEDB88320
$script:CrcTable = New-Object 'uint32[]' 256
for ($i = 0; $i -lt 256; $i++) {
    $c = [uint32]$i
    for ($k = 0; $k -lt 8; $k++) {
        if (($c -band [uint32]1) -eq [uint32]1) { $c = [uint32]($script:Polynomial -bxor ($c -shr 1)) }
        else { $c = [uint32]($c -shr 1) }
    }
    $script:CrcTable[$i] = $c
}

function Get-Crc32 {
    <#
      注意:PowerShell 里 0xFFFFFFFF 会被解析成 Int32 的 -1,
      [uint32]0xFFFFFFFF 会直接抛异常 —— 必须用 [uint32]::MaxValue
    #>
    param([byte[]]$Bytes, [int]$Start = 0, [int]$Length = -1)
    if ($Length -lt 0) { $Length = $Bytes.Length - $Start }
    $crc = [uint32]::MaxValue
    $end = $Start + $Length
    for ($i = $Start; $i -lt $end; $i++) {
        $idx = [int](($crc -bxor [uint32]$Bytes[$i]) -band [uint32]255)
        $crc = [uint32](($crc -shr 8) -bxor $script:CrcTable[$idx])
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Test-Crc32Implementation {
    $t = [System.Text.Encoding]::ASCII.GetBytes("123456789")
    $v = Get-Crc32 $t
    return [uint64]$v -eq [uint64]3417065814   # 0xCBF43926
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
}

function Test-AllZero {
    param([byte[]]$Bytes)
    foreach ($b in $Bytes) { if ($b -ne 0) { return $false } }
    return $true
}

# ---------- GPT ----------

function Read-Gpt {
    <#
      从已读出的 LUN 前 N 个扇区数据里解析 GPT 头并校验 CRC
      注意:UFS 扇区是 4096 字节,GPT 头在偏移 4096,条目在 8192
    #>
    param([byte[]]$Buf)

    $h = 4096
    if ($Buf.Length -lt ($h + 92)) { return $null }
    $sig = [System.Text.Encoding]::ASCII.GetString($Buf[$h..($h + 7)])
    if ($sig -ne "EFI PART") { return [pscustomobject]@{ Valid = $false; Reason = "no EFI PART signature" } }

    $hdrSize  = [BitConverter]::ToUInt32($Buf, $h + 12)
    $hdrCrcSt = [BitConverter]::ToUInt32($Buf, $h + 16)
    $myLba    = [BitConverter]::ToUInt64($Buf, $h + 24)
    $altLba   = [BitConverter]::ToUInt64($Buf, $h + 32)
    $entLba   = [BitConverter]::ToUInt64($Buf, $h + 72)
    $numEnt   = [BitConverter]::ToUInt32($Buf, $h + 80)
    $entSize  = [BitConverter]::ToUInt32($Buf, $h + 84)
    $entCrcSt = [BitConverter]::ToUInt32($Buf, $h + 88)

    $copy = [byte[]]$Buf.Clone()
    $copy[$h + 16] = 0; $copy[$h + 17] = 0; $copy[$h + 18] = 0; $copy[$h + 19] = 0
    $hdrCrcCalc = Get-Crc32 $copy $h ([int]$hdrSize)

    $entOff = [int64]$entLba * 4096
    $entBytes = [int64]$numEnt * [int64]$entSize
    $entCrcCalc = [uint32]0
    $entOk = $false
    if (($entOff -ge 0) -and (($entOff + $entBytes) -le $Buf.Length)) {
        $entCrcCalc = Get-Crc32 $Buf ([int]$entOff) ([int]$entBytes)
        $entOk = ($entCrcCalc -eq $entCrcSt)
    }

    # 前几个分区名
    $names = @()
    if ($entOff -ge 0) {
        for ($i = 0; $i -lt [Math]::Min(4, $numEnt); $i++) {
            $o = [int]$entOff + $i * [int]$entSize
            if (($o + 128) -gt $Buf.Length) { break }
            $empty = $true
            for ($k = 0; $k -lt 16; $k++) { if ($Buf[$o + $k] -ne 0) { $empty = $false; break } }
            if (-not $empty) {
                $names += [System.Text.Encoding]::Unicode.GetString($Buf[($o + 56)..($o + 127)]).Trim([char]0)
            }
        }
    }

    return [pscustomobject]@{
        Valid        = $true
        MyLba        = $myLba
        AltLba       = $altLba
        EntryLba     = $entLba
        NumEntries   = $numEnt
        EntrySize    = $entSize
        HeaderCrcOk  = ($hdrCrcCalc -eq $hdrCrcSt)
        EntriesCrcOk = $entOk
        FirstParts   = $names
    }
}

# ---------- XML 生成 ----------

function New-ReadXml {
    <#
      -Jobs: @( @{ Lun=0; Start=0; Sectors=8; Out='C:\x\g0.bin' }, ... )
      会预创建输出文件(fh_loader 用 rb/rb+ 打开,必须先存在)
    #>
    param(
        [Parameter(Mandatory)][array]$Jobs,
        [Parameter(Mandatory)][string]$OutXml
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" ?>')
    [void]$sb.AppendLine('<data>')
    foreach ($j in $Jobs) {
        if (-not (Test-Path $j.Out)) {
            $fs = [System.IO.File]::Create($j.Out)
            $fs.SetLength([int64]$j.Sectors * 4096)
            $fs.Close()
        }
        [void]$sb.AppendLine('<read SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0" filename="' + $j.Out + '" label="" num_partition_sectors="' + $j.Sectors + '" physical_partition_number="' + $j.Lun + '" size_in_KB="' + ([double]$j.Sectors * 4) + '" sparse="false" start_sector="' + $j.Start + '" />')
    }
    [void]$sb.AppendLine('</data>')
    Set-Content -Path $OutXml -Value $sb.ToString() -Encoding ascii
    return $OutXml
}

function New-ProgramXml {
    <#
      -Jobs: @( @{ Lun=4; Start=130566; Sectors=2048; Label='abl_a'; File='C:\rom\abl.elf'; KB=8192 }, ... )
    #>
    param(
        [Parameter(Mandatory)][array]$Jobs,
        [Parameter(Mandatory)][string]$OutXml
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" ?>')
    [void]$sb.AppendLine('<data>')
    foreach ($j in $Jobs) {
        if (-not (Test-Path $j.File)) { Write-Warning "缺少文件: $($j.File)"; continue }
        [void]$sb.AppendLine('<program SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0" filename="' + $j.File + '" label="' + $j.Label + '" num_partition_sectors="' + $j.Sectors + '" physical_partition_number="' + $j.Lun + '" size_in_KB="' + $j.KB + '" sparse="false" start_sector="' + $j.Start + '" />')
    }
    [void]$sb.AppendLine('</data>')
    Set-Content -Path $OutXml -Value $sb.ToString() -Encoding ascii
    return $OutXml
}

function Get-RawprogramMap {
    <#
      解析官方包里的 rawprogramN.xml,返回 hash[label] = @{Lun;Start;Sectors;File}
    #>
    param(
        [Parameter(Mandatory)][string]$ImagesDir,
        [int[]]$Luns = @(0, 1, 2, 3, 4, 5)
    )
    $map = @{}
    foreach ($n in $Luns) {
        $p = Join-Path $ImagesDir "rawprogram$n.xml"
        if (-not (Test-Path $p)) { continue }
        $x = [xml](Get-Content $p -Raw)
        foreach ($e in $x.data.program) {
            $map[$e.label] = [pscustomobject]@{
                Lun     = $n
                Start   = [int64]($e.start_sector.ToString().TrimEnd("."))
                Sectors = [int64]($e.num_partition_sectors.ToString().TrimEnd("."))
                File    = if ([string]::IsNullOrWhiteSpace($e.filename)) { $null } else { $e.filename }
                KB      = if ($e.size_in_KB) { [double]$e.size_in_KB } else { 0 }
            }
        }
    }
    return $map
}

Write-Host "[lib] MiFlash: $env:MIFLASH_DIR" -ForegroundColor DarkGray
Write-Host "[lib] CRC32 自检: $(if (Test-Crc32Implementation) { 'PASS' } else { 'FAIL' })" -ForegroundColor DarkGray
