---
name: xiaomi-flash-toolkit-triage
description: 排查中文 bat→exe 封装的刷机/解锁工具箱(如 Xiaomi-QC解锁BL工具、莫离然然工具箱)双击闪退、秒退、菜单选完就关窗、"adb.exe 不是内部或外部命令"、"未检测到设备"、USB 驱动时有时无、临时 root(LKM/ksu)重启后消失等问题。当用户提到解锁BL、一键解锁、刷机工具闪退、fastboot 检测不到设备、ADB 驱动时有时无、KernelSU 临时 root、或要在动 abl/xbl 分区前做只读核验时使用。
license: MIT
---

# Xiaomi 刷机/解锁工具箱 故障排查

针对「bat 脚本被封装成 exe」的中文刷机/解锁工具箱(典型:Xiaomi-QC解锁BL工具、莫离然然工具箱)。这类工具的共同结构:一个极小的 exe 壳 + 内置加密载荷 + `Tools\` 下的 adb/fastboot + 一堆隐藏属性的脚本。

## 排查顺序总览

```
闪退
 ├─ 启动就退 ──→ ① PATH / NoDefaultCurrentDirectoryInExePath
 │                 ② 杀软删文件(完整性校验分支)
 │                 ③ 未正确解压(隐藏+系统属性文件丢失)
 └─ 菜单选完就退 ──→ ④ 分支调裸 adb.exe/fastboot.exe 失败
                    ⑤ 设备不在要求的模式(fastboot/9008/adb)
                    ⑥ 提权(root)掉了
设备掉线 ──→ ⑦ USB Hub / 选择性暂停 / 线材
准备刷写 ──→ ⑧ 只读核验(product/slot/anti/分区/映像)
```

---

## ① 头号杀手:`NoDefaultCurrentDirectoryInExePath=1`

**这是最容易漏、症状最像"工具坏了"的一条。**

Windows 的这个用户级环境变量会让 `cmd.exe` **不再搜索当前目录**下的可执行文件。而这类工具的脚本习惯写裸命令名:

```bat
adb.exe devices
fastboot.exe flash ...
```

它默认"我站在 `Tools\` 里,直接敲 adb.exe 就行"。变量一开,**无论 cwd 在哪都找不到** → 分支走不下去 → `exit` → 窗口关闭,且**不产生任何崩溃事件**。

### 复现与确认

```powershell
# 症状复现:站在 adb.exe 所在目录,依然报"不是内部或外部命令"
cmd /c "cd /d `<工具目录>\Tools` && adb.exe version"

# 确认元凶
cmd /c "echo [%NoDefaultCurrentDirectoryInExePath%]"      # 输出 [1] 即命中
[Environment]::GetEnvironmentVariable('NoDefaultCurrentDirectoryInExePath','User')
```

### 修复(不要删这个变量,它是安全加固)

实测**只把 Tools 加进 PATH 就够了**:

```powershell
$tools = '<工具目录>\Tools'
$cur = [Environment]::GetEnvironmentVariable('PATH','User')
if($cur -notlike "*$tools*"){
  [Environment]::SetEnvironmentVariable('PATH', "$tools;$cur", 'User')
}
```

并在工具根目录放一个**双击启动器**(内容纯 ASCII,避免 GBK 编码把中文路径搞坏):

```bat
@echo off
chcp 936 >nul
set "PATH=%~dp0Tools;%PATH%"
"%~dp0Tools\adb.exe" version
for %%f in ("%~dp0*.exe") do start "" "%%~ff"
```

> 关键提醒用户:**`set PATH=` 只对同一个 cmd 窗口生效**。只跑 `cmd /k "xxx.exe"` 而不带前缀,等于没修。绝大多数"我按你说的做了还是不行"都是漏了第一行。

---

## ② 启动器结构:先搞清楚它在干什么

这类 exe 是**解密壳**,不是程序本体:

- PE32 / console 子系统 / 未签名 / 无版本信息
- `.rsrc` 里 RCDATA 是一段加密载荷(名字常是 MD5)
- 运行时解密到 `%TEMP%\<4hex>.tmp\<4hex>.bat`,再 `CreateProcess cmd.exe` 执行

确认方法:

```powershell
Get-ChildItem "$env:TEMP\*.tmp" -Directory | % { Get-ChildItem $_.FullName -Filter *.bat }
```

解出来的 bat 通常几百 KB ~ 几 MB,**前几千行是 `::` 随机垃圾**,用来躲杀软特征码。真实逻辑在后面。
脚本里的字符串常用 `%':~N,1%` 逐字符还原(变量名是一个单引号),直接 grep 关键字往往搜不到——**不要浪费时间硬解,先按行为排查**。

### 完整性校验分支

杀软删掉 `Tools\adb.exe`、`fastboot.exe`、`mlrr*.exe`(隐藏+系统属性)会触发:

```
工具箱完整性校验未通过！！！
原因：缺失重要运行组件
解决：关闭所有杀毒后包括自带安全中心病毒威胁，然后重新解压运行
请按任意键退出
```

核对命令:

```powershell
Get-ChildItem '<工具目录>\Tools' -Force | Select-Object Name,Length,Attributes
```

`Attributes` 里应有 `Hidden,System`。缺文件 → 关杀软 + 加白 + **重新解压**(不是覆盖)。

---

## ③ 官方给出的"闪退"标准答案

大多数这类工具作者的唯一口径:**关闭所有杀软 → 整目录加白 → 删除旧目录 → 重新解压**。
先让用户做这一步,再谈其他。

---

## ④ 看到报错:让窗口别关

控制台程序 `exit` 时窗口一起销毁,报错活不过 200ms,用户会说"没有报错"。

```cmd
cmd /k "<启动器或 exe>"
```

`/k` 保证退出后窗口保留。**这是把"闪退"变成可诊断问题的第一步,优先级最高。**

---

## ⑤ 设备状态核验(全部只读)

### ADB 侧

```powershell
adb devices -l
adb shell id                    # 期望 uid=0(root) + u:r:ksu:s0 才算有 root
adb shell su -c id
adb shell getprop ro.boot.slot_suffix
adb shell getprop ro.boot.flash.locked
adb shell getenforce
```

### Fastboot 侧

```powershell
fastboot devices
fastboot getvar product          # 必须与线刷包机型一致
fastboot getvar current-slot     # A/B 槽,决定写哪个分区
fastboot getvar anti             # 必须 <= 包内 images\anti_version.txt
fastboot getvar unlocked
fastboot oem device-info         # Device unlocked: true/false
```

> `anti` 比包内版本大 → 回滚保护会拒绝,`flash_all.bat` 直接 `exit /B 1`。

### 分区映射

```powershell
adb shell ls -l /dev/block/by-name/ | findstr /i "abl xbl vbmeta gpt"
adb shell blockdev --getsize64 /dev/block/sde41
```

**A/B 机型没有裸 `abl`,只有 `abl_a` / `abl_b`。** 写错槽 = 白写;写裸名 = `No such file or directory`。

---

## ⑥ 动分区之前:必须先备份

```powershell
adb shell "dd if=/dev/block/by-name/abl_b of=/sdcard/abl_b_stock.img bs=1M; sync"
adb shell "md5sum /sdcard/abl_b_stock.img"
adb pull /sdcard/abl_b_stock.img <本地备份目录>
Get-FileHash <本地文件> -Algorithm MD5        # 双向必须一致
```

**A/B 两槽的 MD5 通常不同**(OTA 后旧版本留在非激活槽)。备份要两槽都做,并记下哪个是激活槽。

---

## ⑦ 红线(重要)

1. **不要盲驱动交互式破坏脚本。** 这类一键工具靠菜单编号 + 多次 y/n,喂错一位就走到别的机型分支,后果完全不同。可以替用户跑只读核验,不要在看不见屏幕的情况下替按。
2. **不要只写 abl。** ABL 由 XBL 加载,版本必须配套。工程 abl 配原厂 xbl 是经典半砖组合。让工具跑它自己测过的完整序列。
3. **`flash_all.bat` 不是"解锁",是"整机刷成工程包"**:会覆盖 userdata(清数据)、重写 20+ 个分区、`set_active` 切槽。说清楚再让人按。
4. **刷机阶段 USB 掉线 = 砖。** 先解决链路稳定性再动手。

---

## ⑧ USB 驱动"时有时无"

### 判断是否挂在外部 Hub 上

```powershell
$c = Get-PnpDevice -PresentOnly | ? { $_.InstanceId -like 'USB\VID_2717&PID_*' -and $_.Class -eq 'USB' } | Select -First 1
(Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName 'DEVPKEY_Device_Parent').Data
```

- 上级是 `USB\VID_05E3&PID_*`(Genesys Logic)等 → **经过外置 Hub,必须让用户换到主板后置口**
- 上级是 `ROOT_HUB30` / `ROOT_HUB` → 直连,OK

### 关闭 USB 选择性暂停(不需要管理员)

```powershell
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setactive SCHEME_CURRENT
```

### 稳定性压测(动手前必做)

```powershell
# 轻载:30 次,必须 0 失败
1..30 | % { adb shell "echo ok" ; Start-Sleep -Milliseconds 700 }
# 重载:推 100~200MB(注意全零文件会被 adb 压缩,要拿真实数据测)
adb push <真实大文件> /sdcard/t.bin
```

> 没有弹"允许 USB 调试"不代表失败 —— 之前勾过「一律允许」就不会再问。以 `adb devices` 和 `MI_01 ADB Interface` 是否 `CM_PROB_NONE` 为准。

---

## ⑨ 临时 root(LKM / KernelSU)的存活规则

锁 BL 的机器上,KernelSU 只可能是 **LKM 模式**(`insmod kernelsu.ko`),因为 GKI 模式要改 boot.img。而 `insmod` 本身**需要 root** —— 所以 KSU 是 root 的**消费者**,不是生产者。第一次 root 必然来自别处(漏洞/工程包/别人的工具),KSU 只是接管它。

| 操作 | 内核 | LKM 模块 | root |
|---|---|---|---|
| **热重启(soft reboot)** | 不重载 | 保留 | ✅ 还在 |
| **完整重启 / 进 fastboot / 断电** | 重载 | 卸载 | ❌ 消失 |

判断方法:

```powershell
adb shell id              # uid=0 + u:r=ksu:s0 → 在
adb shell cat /proc/uptime # 判断内核是否真的重载过
```

root 掉了的表现:`su` 在 `/system/bin`、`/system/xbin`、`/sbin`、`/debug_ramdisk` 全部不存在;`/data/adb` Permission denied(以 shell 身份)。

**要点:所有需要 root 的动作必须在"提权之后、重启之前"一次做完。** 写 abl 在重启之前完成,重启本身不影响已写入的分区。

---

## ⑩ 典型排障对话骨架

1. "窗口在哪一步消失?" 四选一:双击就没了 / 到免责声明 / 输密码后 / 进菜单选功能后
2. 一律先 `cmd /k` 重跑,拿到那行报错 —— 没有这行字,后面全是猜
3. 见到 `'adb.exe' 不是内部或外部命令` → 直接查 `NoDefaultCurrentDirectoryInExePath`,给启动器
4. 见到 `未检测到设备` → 查 USB 链路(父设备链)+ 设备模式 + 驱动
5. 能走到"写分区"前 → 只读核验 product / slot / anti / 分区尺寸 / 映像完整性 / 双向备份
6. 让用户自己按最后那一下;你负责读日志、判断、给回滚命令

---

## 关键命令速查

```powershell
# 工具箱三件套
cmd /c "cd /d <dir>\Tools && adb.exe version"        # 复现 PATH 问题
cmd /k "<exe>"                                        # 保留窗口看报错
Get-ChildItem '<dir>\Tools' -Force | Select Name,Length,Attributes

# 设备
adb devices -l ; adb shell id ; adb shell getprop ro.boot.slot_suffix
fastboot devices ; fastboot getvar product/current-slot/anti/unlocked
fastboot oem device-info

# USB
Get-PnpDevice -PresentOnly | ? { $_.InstanceId -match 'VID_2717|VID_18D1|VID_05E3' }
powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3

# 备份 (A/B 两槽都做)
adb shell "dd if=/dev/block/by-name/abl_b of=/sdcard/abl_b_stock.img bs=1M; sync"
adb shell "md5sum /sdcard/abl_b_stock.img" ; adb pull /sdcard/abl_b_stock.img .
```

---

## 案例记录(2026-11-06,Redmi K70 / vermeer / HyperOS 3.0.307)

**症状**:双击能开、菜单正常、选「小米骁龙8gen2一键解锁BL」输 `y` 后窗口秒关,无报错,事件日志无崩溃。

**根因**:`NoDefaultCurrentDirectoryInExePath=1`(用户级)。脚本调裸 `adb.exe` → 解析失败 → 分支 `exit`。

**排除项**:文件完整(隐藏+系统属性都在)、GBK 代码页 936 正常、32 位程序运行正常、manifest 无强制管理员、不需要 .NET/VC++。

**并行发现**:设备挂在 Genesys Logic Hub(05E3:0608)下 + USB 选择性暂停开启 → adb 驱动反复消失。改直连主板 + 关选择性暂停后,30/30 通过,200MB push 无掉线。

**设备事实**:`product=vermeer`、`current-slot=b`、`anti=1`(= 包内值)、`unlocked=no`、`abl_a/abl_b` 各 8,388,608 B(与包内 `abl.elf` 完全对齐,但两槽 MD5 不同)。

**未做**:未写 abl。ABL 需与 XBL 配套,单写风险高;且一键分支为交互式,盲喂输入可能走错机型分支。

### 后续(同一台机器,同一天)

这台机器随后因分区被抹变成**黑屏,只有 9008 可达**。最终通过 **9008/EDL + 官方零售固件**修复成功。

完整救砖流程见同仓库的 **[`xiaomi-edl-9008-recovery`](../xiaomi-edl-9008-recovery/SKILL.md)**。

一句话教训:**闪退排查解决的是"工具跑不起来",不等于"手机能安全刷"。工具跑通之后,才是真正危险的开始。**
