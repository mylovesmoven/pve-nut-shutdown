# 测试环境记录

本项目的脚本与文档在以下环境实测通过。

## 验证环境

| 项目 | 版本 |
|---|---|
| Proxmox VE | 9.2.2 (pve-manager/9.2.2/b9984c6d90a4bd80) |
| 内核 | 7.0.2-6-pve |
| Debian | 13.5 |
| NUT | 2.8.1 |
| UPS | APC Back-UPS BK650M2-CH (051d:0002) |
| 连接方式 | USB 直连 |
| 驱动 | usbhid-ups |

## 已验证项

- [x] `nut-scanner` 识别设备并正确提取驱动参数
- [x] 服务启动顺序与开机自启（nut-server / nut-monitor / nut-driver@）
- [x] `upsmon` 认证成功（无 ACCESS-DENIED）
- [x] `upsc` 正确读取状态为 `OL`（apcupsd 在此型号上误报 ONBATT）
- [x] `upsrw` 修改 `battery.charge.low` 从 93 → 30
- [x] 驱动重启后自动恢复
- [x] 关机脚本语法与分组解析（含空组、缺省超时等边界）
- [x] `upssched` 事件回调链路
- [x] VM 的 ACPI 关机响应（fnOS 实测 10 秒内干净关闭）
- [x] `install.sh` 端到端运行（首次安装 + 重复安装两种路径）

## 未验证项

- [ ] **真实断电演练** —— 拔掉市电观察完整关机链路
- [ ] 多机 primary/secondary 组网（docs/multi-host.md 基于 NUT 文档编写，未实测）
- [ ] 其他品牌 UPS（脚本按通用逻辑编写，但只在 APC 上测过）
- [ ] PVE 7.x / 8.x（只在 9.2.2 上测过）

如果你在其他环境跑通了（或踩了坑），欢迎提 issue 补充。

## 开发过程中修掉的坑

记录下来供参考，这些都是实测才暴露的：

**1. `tr < /dev/urandom | head -c 24` 在 `set -o pipefail` 下必然失败**

`head` 取够字节数就退出，`tr` 收到 SIGPIPE 返回非零，pipefail 让整条管道失败，`set -e` 静默终止脚本。改用 `openssl rand` 避免管道。

**2. `nut-scanner` 的输出字段不固定**

驱动正占用 USB 设备时，扫描结果里没有 `serial` / `product` 字段。`grep -oP` 无匹配返回非零，同样在 pipefail 下终止脚本。解决办法是扫描前先停驱动，且 `get_field` 加 `|| true` 容错。

很多 UPS 本身也不上报序列号，所以这个容错是必需的。

**3. `[[ ]] && cmd` 作为语句块最后一条命令会触发 `set -e`**

例如备份循环的最后一次迭代条件为假时，整个 `for` 返回非零导致脚本退出。全部改成显式 `if`。

**4. 驱动刚启动时 `ups.status` 是 `WAIT`**

立即读取会拿到 `WAIT` 和一堆空字段，让用户误以为配置失败。加了轮询等待。

**5. UPS 出厂的 `battery.charge.low` 可能高得离谱**

BK650M2-CH 出厂值是 93%，意味着电量掉 7% 就触发 LOWBATT 立即关机，会架空延迟设置。必须检查并修正。
