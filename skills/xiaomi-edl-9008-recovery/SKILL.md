---
name: xiaomi-edl-9008-recovery
description: 用 Qualcomm 9008(EDL)模式救砖小米/红米机型——黑屏、只能进 9008、系统损坏、bootloader 分区被抹、刷机后不开机。覆盖 K70 实战验证过的完整链路:进入 EDL、QSaharaServer + fh_loader 工具链、只读诊断(GPT/CRC/分区内容比对)、官方固件与原厂签名差异、逐分区修复、读回校验。当用户提到 9008、EDL、救砖、黑屏、QDLoader、fh_loader、QSaharaServer、xbl/abl 分区、firehose、免授权 loader 时使用。
license: MIT
---

# 小米机型 9008(EDL) 救砖手册

基于 **Redmi K70(vermeer / 23113RKC6C / SM8550)** 一次真实救砖的完整复盘。所有命令、偏移、判定标准均来自实机验证。

---

## 0. 什么时候用这个

- 手机黑屏、无震动、进不了系统也进不了 fastboot
- 但可以进 **9008(QDLoader 9008)**
- 系统提示损坏 / 刷机后不开机 / 分区被抹
- 需要绕开 BL 锁直接写入分区

**前置判断**:能不能进 9008。能进 → 有救;进不了 → 先查供电(见 §9)。

---

## 1. 进入 EDL(9008)

不同机型组合键不同,**必须实测**,不要照抄网上说法:

| 组合 | 说明 |
|---|---|
| **音量下 + 电源** | ✅ **K70 实测有效** |
| 音量上 + 音量下 + 插线 | 常见通用组合 |
| 电源 + 音量上 + 音量下 | 强制复位后再试 |
| 电源键 60 秒 | 强制断电,再按组合 |

成功标志(设备管理器 → 端口):

```
Qualcomm HS-USB QDLoader 9008 (COM3)
USB\VID_05C6&PID_9008
```

**失败的典型表现**:先插线再按键。**顺序必须是"按住按键 → 再插线"**,插线后保持 10~15 秒。

> 补充判据:如果设备**从来不会自己**出现 9008(拔掉按键就消失),说明 PBL 只在强制下才跑 —— 这指向供电问题,而不是分区问题。

---

## 2. 工具链

MiFlash 安装目录(`MiFlash Prime Edition` 等魔改版都自带):

```
MiFlash\QSaharaServer.exe      ← Sahara 阶段:把 firehose 编程器送进 RAM
MiFlash\fh_loader.exe          ← Firehose 阶段:执行 XML(读/写/擦/补丁)
```

比 GUI 好用得多:可脚本化、有逐条返回、能只读。

### 2.1 加载编程器

```powershell
& "QSaharaServer.exe" -p '\\.\COM3' -s "13:C:\path\to\loader.melf"
```

成功输出:

```
Sahara protocol completed
```

> `13:` 是 firehose 的 image ID,不能省。

### 2.2 验证通信(只读,零风险)

```powershell
& "fh_loader.exe" "--port=\\.\COM3" --memoryname=ufs --nop
```

成功会看到:

```
TARGET SAID: 'INFO: Calling handler for configure'
TARGET SAID: 'INFO: Storage type set to value UFS'
TARGET SAID: 'INFO: Calling handler for NOP'
```

### 2.3 参数坑

- `--getstorageinfo=<路径>` 等带路径的参数,**路径不能有空格**。否则 fh_loader 会把 `MiFlash Prime Edition` 拆成独立参数,报 `Option 'Prime' does not begin with --`
- `<read>/<program>` 的 `filename` 目标文件**必须预先存在**(它用 `rb`/`rb+` 打开)。读之前先建好同样大小的占位文件
- `--reset` 会弹交互确认 `Send RESET ... (y|n)`,无 stdin 时默认 **n**。必须加 `--noprompt`

---

## 3. 存储厂商:先查再决定用哪个 loader

```powershell
& "fh_loader.exe" "--port=\\.\COM3" --memoryname=ufs --getstorageinfo=<无空格路径>
```

关键返回:

```
TARGET SAID: 'INFO: ufs: SKhynix'          ← 或 Kioxia / Micron / Samsung
TARGET SAID: 'INFO: Device Total Physical Partitions: 0x6'
TARGET SAID: 'INFO: Supported Functions (16): program / read / patch / erase / ...'
```

> ⚠️ 社区流传的"免授权 9008 引导文件"常标注 **"东芝/铠侠存储切勿使用,否则会被格机"**。
> **用之前必须核对厂商 ID**(JEDEC):`0x1AD = SK Hynix`、`0x198 = Kioxia/Toshiba`。
> 厂商不匹配就用,真的会把机器刷死。

`Supported Functions` 里出现 `program` / `erase` 才说明有写权限。

---

## 4. 只读诊断(先诊断,再动手)

### 4.1 读 GPT(6 个 LUN)

UFS 设备有多个 LUN(K70 是 6 个),**每个 LUN 都有独立 GPT**。

> **注意扇区大小是 4096 字节,不是 512。** GPT 头在偏移 **4096**,分区项在 **8192**。用 512 去算会得出"GPT 损坏"的错误结论。

XML(每个 LUN 只读前 8 个扇区就够):

```xml
<?xml version="1.0" ?>
<data>
<read SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0" filename="C:\temp\g0.bin" label="" num_partition_sectors="8" physical_partition_number="0" size_in_KB="32.0" sparse="false" start_sector="0" />
<read SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0" filename="C:\temp\g1.bin" label="" num_partition_sectors="8" physical_partition_number="1" size_in_KB="32.0" sparse="false" start_sector="0" />
<!-- ... 2..5 -->
</data>
```

```powershell
& "fh_loader.exe" "--port=\\.\COM3" --memoryname=ufs "--sendxml=C:\temp\gptall.xml" --noprompt
```

### 4.2 GPT 头字段偏移(相对头起始)

| 字段 | 偏移 | 长度 |
|---|---|---|
| Signature `EFI PART` | 0 | 8 |
| HeaderSize | 12 | 4 |
| **HeaderCRC32** | **16** | 4 |
| MyLBA | 24 | 8 |
| AlternateLBA | 32 | 8 |
| FirstUsableLBA | 40 | 8 |
| LastUsableLBA | 48 | 8 |
| DiskGUID | 56 | 16 |
| PartitionEntryLBA | 72 | 8 |
| NumberOfPartitionEntries | 80 | 4 |
| SizeOfPartitionEntry | 84 | 4 |
| **PartitionEntryArrayCRC32** | **88** | 4 |

**只检查结构是不够的,必须验 CRC**:

- HeaderCRC32 = CRC32(头的 HeaderSize 字节,且 CRC 字段置零)
- PartitionEntryArrayCRC32 = CRC32(从 `PartitionEntryLBA*4096` 开始、`NumEntries*EntrySize` 字节)

> ⚠️ PowerShell 里 `0xFFFFFFFF` 会被解析成 `Int32 -1`,`[uint32]0xFFFFFFFF` 直接抛异常,CRC 从第一步就错。**用 `[uint32]::MaxValue` 和 `[uint32]3988292384`**。写完先用标准值自检:`crc32("123456789") == 0xCBF43926`。

### 4.3 分区内容是否被抹

读每个分区的**前 64KB**,和固件包里的对应文件比 SHA256:

- **MATCH** → 内容正确
- **ALL-ZERO** → 分区被清空(典型:erase 过)
- **DIFF** → 有内容但不是这个版本的

> 实测案例:22 个引导相关分区里,17 个不一致,其中 **8 个是全零**(含 `boot_a`、`vendor_boot_a`、`dtbo_a`、`init_boot_a`)。GPT 完好、CRC 全通过,但分区内容是空的 —— **"分区坏了"多数时候指的是内容,不是分区表**。

---

## 5. 固件包的选择(最关键的坑)

| | 工程包 / FACTORY 包 | 官方线刷包 |
|---|---|---|
| 来源 | 泄露的工厂包 | 官方 fastboot ROM |
| `xbl_s.melf` | 8,388,608 B(填充到分区大小) | **1,198,964 B(真实体积)** |
| `abl.elf` | 8,388,608 B | **233,272 B** |
| 签名 | 工厂调试签名 | **零售签名,与 eFuse 配对** |
| 结果 | **PBL 拒绝,起不来** | 可以启动 |

**结论:救砖必须用官方零售固件。** 工程包只能让设备停在 EDL,不能让它启动。

判别方法:看文件大小。真实映像通常只有几百 KB ~ 几 MB;如果每个都是 8 MB / 2 MB 这种整数且完全相等,基本是填充过的工程镜像。

### 官方包要什么

- 类型:**fastboot 线刷包(`.tgz`,6~8 GB)**,不是 recovery 卡刷包
- 内容要有 `images/` 目录:`xbl_s.melf`、`abl.elf`、`tz.mbn`、`devcfg.mbn`、`hyp*.mbn`、`uefi.elf`、`NON-HLOS.bin`、`rawprogram0-5.xml`、`patch0-5.xml`、`gpt_*.bin`
- 版本尽量与设备当前系统一致(`ro.build.version.incremental`)
- `images/anti_version.txt` 必须 **≥ 设备 eFuse 的 anti**(`fastboot getvar anti`)

---

## 6. 修复流程

### 6.1 只刷不一致的分区,不要整包刷

整包刷会遇到两个问题:

1. 工程包常常缺 `super.img`(9 GB)和 `NON-HLOS.bin`(448 MB),刷到一半必失败
2. 整包会写 `userdata`,数据全没

做法:对比后只刷 MATCH 之外的分区。

### 6.2 `_a` / `_b` 两个槽都要处理

```powershell
# 只刷 A 槽 = 只修一半
# 激活槽可能是 b,修 A 槽等于白修
```

判断当前槽:`fastboot getvar current-slot`(能进 fastboot 时),或从 `misc`(BCB)读。

两个槽都要补齐,或者刷官方 `misc.img` 重置槽位选择。

### 6.3 程序化生成刷写 XML

```powershell
# 从官方 rawprogramN.xml 取 label/start_sector/num_partition_sectors
# 映射到实际文件,生成 <program> 条目
```

```xml
<program SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0"
         filename="C:\rom\images\abl.elf" label="abl_a"
         num_partition_sectors="2048" physical_partition_number="4"
         size_in_KB="8192.0" sparse="false" start_sector="130566" />
```

```powershell
& "fh_loader.exe" "--port=\\.\COM3" --memoryname=ufs "--sendxml=flash.xml" --noprompt
```

成功标志:

```
TARGET SAID: 'INFO: Calling handler for program'
==================== {SUCCESS} ========================
{All Finished Successfully}
```

实测速率约 **22 MB/s**(UFS)。

### 6.4 绝对不要碰 `persist`

`persist` 存的是**这台设备独有的校准数据**(传感器校准、基带参数等)。刷错 = 永久丢失,刷机包补不回来。

同理谨慎对待:`modemst1` / `modemst2` / `fsg` / `fsc`(IMEI 相关)、`devinfo`(BL 锁状态)。

---

## 7. 验证(必须做)

刷完**读回**关键分区,和源文件比 SHA256:

```powershell
# 读 xbl_a(LUN1@6)、abl_a(LUN4@130566)、boot_a(LUN4@149126) 前 64KB
# 与官方文件对比
```

只有 `MATCH` 才说明写入真的落盘了。**"日志说 SUCCESS" 不等于 "数据在正确位置"。**

---

## 8. 复位与启动

```powershell
& "fh_loader.exe" "--port=\\.\COM3" --memoryname=ufs --noprompt --reset
```

> `--reset` 走的是 **power handler**,可能是"复位"也可能是"断电"。不加 `--noprompt` 它默认不发。

复位后探测:

```powershell
fastboot devices
adb devices
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_05C6|VID_18D1' }
```

---

## 9. 分区全对还是不开机 → 查供电

**这是最容易被忽略的一环。**

推理链:

```
XBL 加载失败 → PBL 会自动掉进 EDL(Sahara)→ 设备自己出现 9008
设备从不自己出现 9008,只有按键才出现
  ⇒ PBL 没在跑
  ⇒ 不是分区问题,是没上电
```

**EDL 模式下 SoC 全速运行,耗电很快;而电脑 USB 只有 0.5A,基本充不进去。**

所以长时间 EDL 操作后会出现:

- 按住组合键 → 靠 USB 供电能拉起 PBL → 能进 9008 ✅
- 正常按电源 → 电流不足 → 全黑 ✅

**处理:原装充电器插墙,充 1~2 小时,摸机身是否温热,再按电源。**

> 本次 K70 就是刷完全部官方固件后仍不自启,充电 / 重新上电后才正常启动。

---

## 10. 完整实战时间线(Redmi K70 / vermeer)

| 阶段 | 结果 |
|---|---|
| 现象 | 黑屏、无震动、adb/fastboot 全空、连充电提示都没有 |
| 进 EDL | 音量下 + 电源键 ✅ |
| 存储 | UFS / SK Hynix / 6 LUN / 253 GB |
| GPT | 6 个 LUN 结构和 CRC **全部通过**(不是分区表损坏) |
| 分区内容 | 22 个引导分区中 17 个不一致,**8 个全零**(含 `boot_a`) |
| 第一次修复 | 用工程包补 A 槽 → 仍不启动 |
| 第二次修复 | 补 B 槽 → 仍不启动 |
| 第三次修复 | 换 **官方零售固件** + 重置 `misc` → 仍不启动 |
| 校验 | 读回 `xbl_a`/`abl_a`/`boot_a`,SHA256 **MATCH** |
| 推理 | 设备从不自动进 EDL ⇒ PBL 未运行 ⇒ 供电问题 |
| 最终 | **充电 / 重新上电后正常启动** ✅ |

### 教训

1. **"分区坏了"要先分清是分区表还是分区内容** —— 本次是内容(被抹),表是好的
2. **工程包 ≠ 官方包** —— 填充镜像 + 调试签名,PBL 直接拒
3. **`_a`/`_b` 两个槽都要管**,只修一个可能白忙
4. **日志 SUCCESS ≠ 写对了**,必须读回比对
5. **分区全对还开不了机,先怀疑没电**

---

## 11. 一键自动化骨架

```powershell
# 1. 等 9008 出现(用户按键,脚本守候)
for ($i=0; $i -lt 600; $i++) {
    $d = Get-PnpDevice -PresentOnly -Class Ports | Where-Object { $_.FriendlyName -like "*QDLoader 9008*" }
    if ($d -and $d.FriendlyName -match "\((COM\d+)\)") { $port = '\\.\' + $Matches[1]; break }
    Start-Sleep -Seconds 1
}
# 2. 加载 loader → 3. --nop 验证 → 4. 刷 XML → 5. --reset → 6. 探测
```

把这条链做成后台脚本,用户只需要按键插线,其余自动完成 —— 大幅降低来回沟通成本。
