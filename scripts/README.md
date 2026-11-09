# scripts —— 可直接运行的诊断与修复脚本

这些脚本是上面那套流程的可执行版本。全部基于 **Redmi K70(vermeer)** 实机验证。

```
lib.ps1                  共享函数(端口发现、Sahara、fh_loader、CRC32、GPT 解析、XML 生成)
01-diagnose.ps1          只读诊断:存储厂商 + 6 个 LUN 的 GPT 结构/CRC
02-verify-partitions.ps1 只读比对:分区内容 vs 固件包(MATCH / ALL-ZERO / DIFF)
03-flash.ps1             刷写:从 rawprogramN.xml 取偏移,支持 A/B 双槽、DryRun
04-readback-verify.ps1   读回校验:证明写入真的落盘
05-auto-recover.ps1      一条龙:守候 9008 → 加载 → 刷 → 复位 → 探测
```

## 前置

1. Windows + Qualcomm 9008 驱动(`qcser.inf`,多数刷机包自带)
2. MiFlash 安装目录(里面有 `QSaharaServer.exe` / `fh_loader.exe`)
3. 对应机型的**官方 fastboot 线刷包**(解压出 `images/` 目录)
4. 一个可用的 firehose 编程器文件(`*.melf` / `prog_firehose_ddr.elf`)

```powershell
$env:MIFLASH_DIR = "G:\MiFlash Prime Edition 2024.08.01.0\MiFlash"
```

> `lib.ps1` 会自动在常见路径找 MiFlash;找不到就要求你设置这个变量。

## 典型流程

```powershell
cd scripts

# 0) 先看笔记本能不能跟 9008 说话(只读)
.\01-diagnose.ps1 -Loader C:\edl\loader.melf

# 1) 找出哪些分区被抹了(只读)
.\02-verify-partitions.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot

# 2) 先 DryRun 看计划,确认无误再真刷(A/B 两个槽)
.\03-flash.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot -Slots a,b -DryRun
.\03-flash.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot -Slots a,b

# 3) 读回校验(必做)
.\04-readback-verify.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Preset Boot -Slots a,b

# 4) 复位
#    fh_loader 的 --reset 会弹交互确认,脚本里已带 --noprompt
```

一条龙版(适合要反复重试的场景):

```powershell
.\05-auto-recover.ps1 -ImagesDir G:\rom\images -Loader C:\edl\loader.melf -Slots a,b
# 启动后再去按键进 9008,检测到就自动干活
```

## 常见问题

**`fh_loader` 报 `Option 'xxx' does not begin with --`**
参数里的路径**含空格**。fh_loader 会把 `MiFlash Prime Edition` 拆成独立参数。
→ 中间文件一律放 `C:\Users\<你>\AppData\Local\Temp\edl_work\`(脚本已这么做)。

**读的时候报 `Could not access ... with acess mode 'rb'`**
fh_loader 用 `rb`/`rb+` 打开目标文件,文件必须**预先存在**。
→ `New-ReadXml` 会自动预创建;手工写 XML 时记得先建空文件。

**`--reset` 没生效**
它会问 `Send RESET ... (y|n)`,无 stdin 时默认 `n`。必须加 `--noprompt`。

**CRC 算出来永远是 MISMATCH**
PowerShell 把 `0xFFFFFFFF` 解析成 `Int32 -1`,`[uint32]0xFFFFFFFF` 直接抛异常。
→ 用 `[uint32]::MaxValue` 和 `[uint32]3988292384`。`lib.ps1` 里有 `Test-Crc32Implementation` 自检。

**GPT 读出来 `EFI PART` 找不到**
UFS 扇区是 **4096** 字节,不是 512。GPT 头在偏移 **4096**,条目在 **8192**。

## 安全约束(代码里已强制执行)

- `persist` / `modemst1` / `modemst2` / `fsg` / `fsc` / `devinfo` 在 `03-flash.ps1` 里被**硬性拒绝写入**
- `-DryRun` 可以在不碰设备的前提下预览完整刷写计划
