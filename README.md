# 小米 9008(EDL) 救砖实战手册 · Redmi K70

> 一次真实的救砖全记录:Redmi K70 黑屏变砖 → **用 9008 工程线进入 EDL** → 分区诊断 → 官方固件修复 → 成功开机。
>
> 仓库里是两个可直接被 AI Agent(Claude Code / OpenCode / Codex 等)加载的 Skill,以及完整的排查思路与命令。

---

## 背景

一台 **Redmi K70(vermeer / 23113RKC6C / SM8550 / HyperOS 3.0.307)** 在使用第三方解锁工具的过程中,分区被大量抹除,随后:

- 黑屏,无震动,无充电提示
- `adb devices` 空、`fastboot devices` 空
- Windows 设备管理器里连"未知设备"都没有
- 只有按住 **音量下 + 电源键** 时,才会出现 `Qualcomm HS-USB QDLoader 9008`

**用 9008 工程线/组合键进入 EDL 后,完成了完整修复。**

---

## 这个仓库有什么

| Skill | 用途 |
|---|---|
| [`xiaomi-edl-9008-recovery`](skills/xiaomi-edl-9008-recovery/SKILL.md) | **9008 / EDL 救砖主流程**:进 EDL、QSaharaServer + fh_loader 工具链、只读诊断、GPT/CRC 校验、分区内容比对、官方固件修复、读回验证 |
| [`xiaomi-flash-toolkit-triage`](skills/xiaomi-flash-toolkit-triage/SKILL.md) | **刷机工具箱闪退排查**:`NoDefaultCurrentDirectoryInExePath` 导致 `adb.exe` 解析失败、exe 解密壳结构、驱动缺失、USB 链路不稳 |

Skill 说明:加载对应 `SKILL.md` 即可,里面是可直接执行的 PowerShell 命令、GPT 字段偏移表、判定标准和踩坑记录。

---

## 关键结论(TL;DR)

1. **"分区坏了"要先分清是分区表还是分区内容。**
   本次 GPT 六个 LUN 的结构和 CRC **全部通过**,坏的是**内容** —— 22 个引导分区里 17 个不一致,其中 8 个**全零**(含 `boot_a`)。

2. **工程包 / FACTORY 包不能用来救砖。**
   里面的 `xbl_s.melf`、`abl.elf` 都被**填充到整个分区大小**(8 MB),签名是工厂调试签名,**PBL 会直接拒绝**。
   必须用**官方零售签名**的固件(真实体积只有几百 KB ~ 几 MB)。

3. **`_a` / `_b` 两个槽都要处理。**
   只刷 A 槽,如果设备从 B 槽启动,等于白刷。

4. **日志 `SUCCESS` ≠ 写对了。**
   必须**读回**分区、和源文件做 SHA256 比对。

5. **分区全对还开不了机 → 先怀疑没电。**
   EDL 下 SoC 全速运行耗电很快,电脑 USB 只有 0.5A 基本充不进。
   判据:**如果设备从不"自己"出现 9008(只有按键才出现),说明 PBL 没在跑,是供电问题。**
   本次就是刷完全部官方固件后仍然黑屏,**充电 / 重新上电后才正常启动**。

---

## 修复流程概览

```
1. 进 EDL(音量下 + 电源键,按住再插线)
2. QSaharaServer 加载 firehose 编程器
3. fh_loader --getstorageinfo        ← 确认存储厂商/LUN 数量(决定能不能用免授权 loader)
4. fh_loader 读 6 个 LUN 的 GPT      ← 结构 + CRC32 双重校验
5. fh_loader 读各分区前 64KB         ← 和固件包比对,找出被抹/不一致的分区
6. 用官方线刷包(零售签名)补齐        ← 不要用工程包
7. 两个槽都补 / 刷官方 misc.img      ← 复位槽位选择
8. 读回校验(SHA256 MATCH)
9. fh_loader --reset
10. 仍不开机 → 充电 1~2 小时后按电源
```

---

## 环境要求

- Windows + Qualcomm 9008 驱动(`qcser.inf`,多数刷机工具包自带)
- MiFlash 安装目录下的 `QSaharaServer.exe` + `fh_loader.exe`
- 对应机型的**官方 fastboot 线刷包**(`.tgz`)
- 部分机型需要 **9008 工程线**或按键组合才能进入 EDL

---

## ⚠️ 安全须知

- **绝对不要写 `persist` 分区** —— 那是设备独有的校准数据,写错永久丢失、刷机包补不回来
- `modemst1` / `modemst2` / `fsg` / `fsc`(IMEI)、`devinfo`(BL 状态)谨慎操作
- 使用社区流传的"免授权 loader"前,**必须核对存储厂商**:
  `0x1AD = SK Hynix`、`0x198 = Kioxia/Toshiba` —— 标称"铠侠勿用"的文件用在铠侠上真的会格机
- 分区写入不可逆,操作前先备份关键分区

---

## License

MIT
