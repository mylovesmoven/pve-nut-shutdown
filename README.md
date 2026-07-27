# PVE UPS 断电自动关机 (NUT)

给 Proxmox VE 配置 UPS 断电保护：市电中断后，按你指定的顺序依次关闭虚拟机，最后关闭宿主机。

一条命令部署，自动识别 UPS 型号、自动探测虚拟机、自动生成配置。

```bash
bash <(curl -4 -fsSL https://raw.githubusercontent.com/mylovesmoven/pve-nut-shutdown/main/install.sh)
```

## 为什么不用 apcupsd

APC 的中国特供型号（BK650M2-CH 等）在 apcupsd 下有个经典故障：**即使市电正常，状态也一直显示 `ONBATT`**，于是服务器莫名其妙自己关机。换成 NUT 后状态读取正常。

本项目在 [qiedd.com 的教程](https://qiedd.com/1887.html)基础上做了这些改进：

| | 原教程 | 本项目 |
|---|---|---|
| 关闭虚拟机 | 未处理，依赖 PVE 默认关机流程 | 分组分级关闭，可控顺序与超时 |
| 防误触发 | 无，检测到断电立即关机 | 延迟等待，期间市电恢复则自动取消 |
| 低电量阈值 | 未提及 | 自动修正（很多 UPS 出厂值高达 90+%，会架空延迟设置） |
| 配置用户名 | `upsd.users` 写 `upsuser`、`upsmon.conf` 写 `upsduser`，不一致导致认证失败 | 已统一 |
| 密码 | 明文示例 `password` | 随机生成 24 位 |
| 部署方式 | 手工逐条编辑 | 一键脚本，自动探测设备与虚拟机 |

## 断电后发生什么

```
市电中断
  │
  ├─ 等待 N 秒（默认 120）─── 市电恢复 ──▶ 取消关机，恢复正常
  │
  ├─ 第 1 组：普通虚拟机   （组内并行）
  ├─ 第 2 组：NAS / 存储   （等第 1 组全部停止后才开始）
  ├─ 第 3 组：软路由 / 网络
  │
  ├─ 兜底：强制停止任何仍在运行的 VM / LXC
  │
  └─ sync → PVE 宿主机 poweroff
```

**例外**：电池电量低于阈值（默认 30%）或剩余续航不足时，跳过等待直接进入关机流程。

分组的意义：软路由放最后，是为了在关机过程中尽可能保留网络；NAS 单独一组并给足超时，是为了让它有时间落盘。

## 前提条件

- Proxmox VE 7.x / 8.x / 9.x
- UPS 通过 **USB 数据线**直连 PVE 主机（不是仅接电源线）
- UPS 型号被 NUT 支持 — 查[兼容列表](https://networkupstools.org/stable-hcl.html)，主流 APC / 山特 / 施耐德 / 伊顿基本都支持

确认 USB 已连接：

```bash
lsusb | grep -i -E "UPS|American Power"
# 应有类似输出：
# Bus 001 Device 059: ID 051d:0002 American Power Conversion Uninterruptible Power Supply
```

## 安装

### 一键安装

```bash
bash <(curl -4 -fsSL https://raw.githubusercontent.com/mylovesmoven/pve-nut-shutdown/main/install.sh)
```

> `-4` 是强制走 IPv4。不少国内环境下 DNS 只返回 GitHub 的 IPv6 地址，
> 但本机又没有 IPv6 出口，不加这个参数 curl 会一直卡住且不报错。

拉不下来的话，直接复制 [install.sh](install.sh) 的内容存成文件再执行也一样。

### 或者克隆后安装

```bash
git clone https://github.com/mylovesmoven/pve-nut-shutdown.git
cd pve-nut-shutdown
bash install.sh
```

安装过程会问你三件事，直接回车用默认值即可：

1. **UPS 名称** — 用于 `upsc` 命令，默认按型号自动生成
2. **断电延迟秒数** — 默认 120
3. **低电量阈值** — 默认 30%
4. **虚拟机分组** — 会先列出你所有的 VM，然后让你填三组

分组填写格式是 `VMID:超时秒数`，空格分隔，例如：

```
第1组(普通VM)      : 103:120 105:120
第2组(NAS/存储)    : 104:90
第3组(软路由/网络) : 102:60
```

不确定怎么分？把所有 VM 都填在第 1 组（这是默认值），先能用起来，之后随时可以改。

### 非交互安装

```bash
bash install.sh --yes    # 全部使用默认值
```

### 卸载

```bash
bash install.sh --uninstall
```

会停止服务并从 `/etc/nut/*.orig` 恢复原始配置。

## 安装完成后

看到这样的输出就说明成功了：

```
=== 部署完成 ===

  UPS 名称     : backupsbk650m2ch  (Back-UPS BK650M2-CH)
  当前状态     : OL   电量 100%  负载 9%  估算续航 3618秒
  断电延迟     : 120 秒
  低电量阈值   : 30%
  关机顺序     : 103:120 105:120 | 104:90 | 102:60
```

`OL` = On Line，市电正常。这正是 apcupsd 会误报成 `ONBATT` 的那个状态。

### 一定要做真实断电演练

**所有自动化验证都无法替代一次真实拔电测试。**

这不是客套话。本项目开发过程中，有个 bug 骗过了全部自动化检查——服务状态正常、
UPS 读数正确、定时器准时到期，唯独最后关机那一步静默失败，四台虚拟机原封不动地
运行着，日志里连一条记录都没有。只有真拔电才暴露出来。详见
[测试记录](docs/tested-on.md)。

挑一个虚拟机都空闲的时段：

```bash
# 终端 1：盯着关机日志
tail -f /var/log/ups-shutdown.log

# 终端 2：盯着 UPS 状态
watch -n 2 'upsc 你的UPS名称 ups.status'
```

然后拔掉 UPS 的**市电输入插头**（不是拔服务器电源）。

**第一次先测取消机制**（安全，不会关机）：状态应在几秒内从 `OL` 变为 `OB`，
在等待期结束前把插头插回去，日志应出现「市电已恢复，取消关机倒计时」。

**确认没问题后再测完整关机**：拔掉后就不要管它，等待期满后应看到虚拟机按组
依次关闭，最后宿主机 poweroff。这一步会真的关机，需要你之后手动开机。

正常的日志长这样：

```
18:16:21 [upssched] 断电持续超时, 通知 upsmon 执行关机
===== 18:16:26 触发 UPS 关机流程 =====
--- 关闭 第1组 普通虚拟机 ---
  [VM 103] 发送 shutdown, 超时 120s
  [VM 105] 发送 shutdown, 超时 120s
  [VM 105] 已正常关闭
  [VM 103] 已正常关闭
--- 第1组 普通虚拟机 处理完毕 ---
...
所有虚拟机已停止, 18:17:16 关闭宿主机
```

留意每台虚拟机是「已正常关闭」还是「超时未响应, 强制 stop」。后者相当于
硬拔电源，说明那台虚拟机需要装 qemu-guest-agent 或调大超时。

## 日常使用

```bash
# 查看 UPS 完整状态
upsc 你的UPS名称

# 只看供电状态
upsc 你的UPS名称 ups.status

# 关机流程日志
tail -f /var/log/ups-shutdown.log

# 监控服务日志
journalctl -u nut-monitor -f
```

状态码含义：

| 状态 | 含义 |
|---|---|
| `OL` | 市电正常 |
| `OB` | 电池供电中（市电已断） |
| `LB` | 电池电量低 |
| `CHRG` | 充电中 |
| `DISCHRG` | 放电中 |
| `WAIT` | 驱动初始化中，稍等即可 |

## 调整配置

**改延迟时间：**

```bash
sed -i 's/START-TIMER onbatt-shutdown 120/START-TIMER onbatt-shutdown 180/' /etc/nut/upssched.conf
systemctl restart nut-monitor
```

**改虚拟机分组：** 编辑 `/usr/local/bin/pve-ups-shutdown.sh` 顶部的三个 GROUP 变量。新增虚拟机后记得加进去 —— 不加也会被兜底逻辑强制停止，但那等于硬断电。

**改低电量阈值：**

```bash
upsrw -s battery.charge.low=40 -u upsmon -p "$(cat /root/.ups_pass)" 你的UPS名称
```

## 常见问题

**nut-scanner 扫不到 UPS**

先确认 `lsusb` 能看到设备。如果能看到但 nut-scanner 扫不到，通常是 apcupsd 或旧的 NUT 驱动占用了设备：

```bash
systemctl stop apcupsd 2>/dev/null
systemctl stop 'nut-driver@*'
nut-scanner -U
```

**upsc 报 `Error: Unknown UPS`**

名称写错了。用 `upsc -l` 列出所有已配置的 UPS 名称。

**日志里有 `ACCESS-DENIED`**

`/etc/nut/upsd.users` 和 `/etc/nut/upsmon.conf` 里的用户名或密码不一致。这是手工配置最容易踩的坑，重新跑一遍 `install.sh` 即可。

**断电后没等够设定时间就关机了**

检查低电量阈值：

```bash
upsc 你的UPS名称 battery.charge.low
```

如果这个值很高（比如 93），电量稍降就会触发 LOWBATT 立即关机，架空延迟设置。安装脚本会自动修正，但部分 UPS 不支持修改该值 —— 这种情况下只能缩短延迟时间来适应。

**虚拟机没关干净就断电了**

看 `/var/log/ups-shutdown.log` 里哪台超时了。没装 qemu-guest-agent 的虚拟机靠 ACPI 关机，如果系统里禁用了 ACPI 响应就会一直等到超时被强制停止。给这类虚拟机装上 guest agent：

```bash
# Debian/Ubuntu 虚拟机内
apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent
# 然后在 PVE 上为该 VM 开启 agent
qm set <VMID> --agent 1
```

**电池续航够不够？**

```bash
upsc 你的UPS名称 battery.runtime   # 秒，按当前负载估算
upsc 你的UPS名称 ups.load          # 负载百分比
```

注意 `battery.runtime` 是按**当前**负载估算的。关机过程中虚拟机还在跑，实际负载更高，续航会明显短于这个数字。留足余量。

## 文件说明

| 路径 | 用途 |
|---|---|
| `/etc/nut/ups.conf` | UPS 设备定义 |
| `/etc/nut/upsd.users` | 认证用户与密码 |
| `/etc/nut/upsmon.conf` | 监控配置，指定关机命令 |
| `/etc/nut/upssched.conf` | 延迟与取消逻辑 |
| `/usr/local/bin/pve-ups-shutdown.sh` | 分级关机脚本 |
| `/usr/local/bin/upssched-cmd.sh` | 事件回调 |
| `/var/log/ups-shutdown.log` | 关机流程日志 |
| `/root/.ups_pass` | NUT 密码（600 权限） |
| `/etc/nut/*.orig` | 安装前的原始配置备份 |

## 进阶

- [多台机器共用一台 UPS](docs/multi-host.md)
- [完整手工配置步骤](docs/manual-setup.md)（想理解每一步在做什么的话）

## 致谢

- 思路参考 [qiedd.com/1887.html](https://qiedd.com/1887.html)
- [NUT 官方文档](https://networkupstools.org/docs/user-manual.chunked/index.html)
- [Arch Wiki: Network UPS Tools](https://wiki.archlinux.org/title/Network_UPS_Tools)

## License

MIT
