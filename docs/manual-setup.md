# 手工配置完整步骤

如果你想理解每一步在做什么，或者需要针对特殊环境定制，可以按这份文档手工配置。
所有命令在 PVE 9.2.2 / Debian 13 / NUT 2.8.1 上实测通过。

## 第 0 步：确认硬件连接

UPS 必须用 **USB 数据线**连到 PVE 主机。只接电源线是不够的 —— 服务器无法知道市电状态。

```bash
lsusb | grep -i -E "UPS|American Power|051d"
```

预期输出：

```
Bus 001 Device 059: ID 051d:0002 American Power Conversion Uninterruptible Power Supply
```

看不到设备就先解决物理连接，后面都是白搭。

## 第 1 步：清理 apcupsd

如果之前装过 apcupsd，它会抢占 UPS 的 USB 设备，导致 NUT 无法读取。

```bash
systemctl disable --now apcupsd 2>/dev/null
```

（这也是很多人从 apcupsd 迁移到 NUT 时第一个卡住的地方。）

## 第 2 步：安装 NUT

```bash
apt update
apt install -y nut usbutils
```

验证版本：

```bash
upsd -V
# Network UPS Tools upsd 2.8.1
```

## 第 3 步：扫描 UPS

```bash
nut-scanner -U
```

输出示例（这些参数下一步要用）：

```
[nutdev1]
	driver = "usbhid-ups"
	port = "auto"
	vendorid = "051D"
	productid = "0002"
	product = "Back-UPS BK650M2-CH"
	serial = "XXXXXXXXXXXX"
	vendor = "American Power Conversion"
```

开头几行 `Cannot load SNMP library` 之类的提示可以忽略 —— 那是网络型 UPS 才需要的库，USB 直连用不上。

**扫不到怎么办：**

```bash
# 确认没有其他程序占用设备
systemctl stop 'nut-driver@*' 2>/dev/null
fuser -v /dev/bus/usb/001/* 2>&1 | head

# 重新插拔 USB 线后再扫
nut-scanner -U
```

**如果没有 serial 字段**：部分 UPS 不上报序列号，或驱动正占用设备。不影响使用，下一步跳过 serial 行即可，靠 vendorid + productid 匹配。

## 第 4 步：配置 UPS 设备

```bash
vim /etc/nut/ups.conf
```

把扫描到的参数填进去。`[bk650m2]` 是你自己取的名字，后面 `upsc` 命令要用：

```ini
pollinterval = 5

[bk650m2]
    driver = "usbhid-ups"
    port = "auto"
    vendorid = "051D"
    productid = "0002"
    serial = "XXXXXXXXXXXX"
    desc = "APC Back-UPS BK650M2-CH"
```

> **为什么写 serial**：如果机器上接了多台 UPS，或 USB 重新枚举后端口号变了，靠序列号能确保匹配到正确的设备。只有一台 UPS 且不上报序列号的话，删掉这行也行。

## 第 5 步：配置认证用户

```bash
vim /etc/nut/upsd.users
```

```ini
[upsmon]
    password = 换成你自己的随机密码
    upsmon primary
    actions = SET
    instcmds = ALL
```

几个要点：

- `[upsmon]` 是用户名，**第 7 步的 MONITOR 行必须写同一个名字**。原教程这里一处写 `upsuser`、另一处写 `upsduser`，不一致会导致认证失败 —— 这是最容易踩的坑。
- `primary` 表示这台机器直连 UPS 并负责关机（NUT 2.8 之前叫 `master`）。
- `actions = SET` 是修改 UPS 参数所必需的，第 10 步调整低电量阈值会用到。少了这行会报 `ERR ACCESS-DENIED`。

生成一个随机密码：

```bash
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24
```

## 第 6 步：设置运行模式

```bash
echo "MODE=standalone" > /etc/nut/nut.conf
```

`standalone` = UPS 直连本机，只服务本机。如果不设这个，NUT 会拒绝启动并提示 "upsmon disabled"。

## 第 7 步：配置监控

```bash
vim /etc/nut/upsmon.conf
```

```ini
RUN_AS_USER nut

MONITOR bk650m2@localhost 1 upsmon 第5步的密码 primary

MINSUPPLIES 1
SHUTDOWNCMD "/usr/local/bin/pve-ups-shutdown.sh"
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower

NOTIFYFLAG ONLINE   SYSLOG+WALL+EXEC
NOTIFYFLAG ONBATT   SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG FSD      SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK   SYSLOG+WALL
NOTIFYFLAG COMMBAD  SYSLOG+WALL
NOTIFYFLAG SHUTDOWN SYSLOG+WALL
NOTIFYFLAG REPLBATT SYSLOG+WALL
NOTIFYFLAG NOCOMM   SYSLOG+WALL
NOTIFYFLAG NOPARENT SYSLOG+WALL

RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
```

MONITOR 行的格式：

```
MONITOR <UPS名>@<主机> <供电数> <用户名> <密码> <角色>
         第4步取的名     1        第5步的用户名      primary
```

关键项说明：

- `NOTIFYCMD /usr/sbin/upssched` + `NOTIFYFLAG ... EXEC` —— 把事件交给 upssched 处理，这是实现「延迟关机 + 市电恢复取消」的关键。只用 `SHUTDOWNCMD` 的话，检测到断电会立即关机，无法延迟。
- `DEADTIME 15` —— 与 UPS 失联超过 15 秒判定为异常。
- `FINALDELAY 5` —— 执行关机前的最后缓冲。

## 第 8 步：配置延迟与取消逻辑

这一步是原教程没有的，用于防止电网瞬时抖动导致误关机。

```bash
vim /etc/nut/upssched.conf
```

```ini
CMDSCRIPT /usr/local/bin/upssched-cmd.sh
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

# 市电中断：启动 120 秒倒计时
AT ONBATT * START-TIMER onbatt-shutdown 120
# 市电恢复：取消倒计时
AT ONLINE * CANCEL-TIMER onbatt-shutdown online-back
# 电池电量低：跳过倒计时立即关机
AT LOWBATT * EXECUTE lowbatt-now
# 强制关机信号
AT FSD * EXECUTE forced-shutdown
```

事件回调脚本：

```bash
cat > /usr/local/bin/upssched-cmd.sh <<'EOF'
#!/bin/bash
LOG=/var/log/ups-shutdown.log
case "$1" in
    onbatt-shutdown)
        echo "$(date '+%F %T') [upssched] 断电持续超时, 开始关机流程" >>"$LOG"
        /usr/local/bin/pve-ups-shutdown.sh
        ;;
    online-back)
        echo "$(date '+%F %T') [upssched] 市电已恢复, 取消关机倒计时" >>"$LOG"
        ;;
    lowbatt-now)
        echo "$(date '+%F %T') [upssched] 电池电量过低, 立即关机" >>"$LOG"
        /usr/local/bin/pve-ups-shutdown.sh
        ;;
    forced-shutdown)
        echo "$(date '+%F %T') [upssched] 收到 FSD 强制关机信号" >>"$LOG"
        /usr/local/bin/pve-ups-shutdown.sh
        ;;
esac
EOF
chmod +x /usr/local/bin/upssched-cmd.sh
```

## 第 9 步：编写分级关机脚本

先看看你有哪些虚拟机：

```bash
qm list
pct list
```

然后决定关机顺序。经验法则：

1. **普通虚拟机**先关 —— 桌面、应用、开发机
2. **NAS / 存储**其次 —— 给足时间落盘，避免文件系统损坏
3. **软路由 / 网络**最后 —— 尽量保留网络到最后一刻

```bash
vim /usr/local/bin/pve-ups-shutdown.sh
```

```bash
#!/bin/bash
# 格式 "VMID:超时秒数"，同组并行，组间串行
GROUP1="103:120 105:120"    # 普通虚拟机
GROUP2="104:90"             # NAS
GROUP3="102:60"             # 软路由

LOG=/var/log/ups-shutdown.log
exec >>"$LOG" 2>&1
echo "===== $(date '+%F %T') 触发 UPS 关机流程 ====="

shutdown_group() {
    local group="$1" label="$2"
    local pids=() any=0
    [[ -z "${group// }" ]] && return 0
    echo "--- 关闭 $label ---"
    for item in $group; do
        local vm="${item%%:*}" tmo="${item##*:}"
        [[ "$tmo" == "$vm" ]] && tmo=120
        if qm status "$vm" 2>/dev/null | grep -q running; then
            any=1
            (
                echo "  [VM $vm] 发送 shutdown, 超时 ${tmo}s"
                if qm shutdown "$vm" --timeout "$tmo" 2>&1; then
                    echo "  [VM $vm] 已正常关闭"
                else
                    echo "  [VM $vm] 超时未响应, 强制 stop"
                    qm stop "$vm" 2>&1
                fi
            ) &
            pids+=($!)
        else
            echo "  [VM $vm] 未运行, 跳过"
        fi
    done
    if [[ "$any" -eq 1 ]]; then wait "${pids[@]}"; fi
    echo "--- $label 处理完毕 ---"
    return 0
}

shutdown_group "$GROUP1" "第1组 普通虚拟机"
shutdown_group "$GROUP2" "第2组 存储/NAS"
shutdown_group "$GROUP3" "第3组 软路由/网络"

# 兜底：停止任何仍在运行的 VM
echo "--- 兜底检查 ---"
for vm in $(qm list 2>/dev/null | awk '$3=="running"{print $1}'); do
    echo "  [VM $vm] 仍在运行, 强制 stop"
    qm stop "$vm" 2>&1
done

for ct in $(pct list 2>/dev/null | awk '$2=="running"{print $1}'); do
    echo "  [LXC $ct] shutdown"
    pct shutdown "$ct" --forceStop 1 --timeout 60 2>&1
done

echo "所有虚拟机已停止, $(date '+%F %T') 关闭宿主机"
sync
/sbin/poweroff
```

```bash
chmod +x /usr/local/bin/pve-ups-shutdown.sh
bash -n /usr/local/bin/pve-ups-shutdown.sh   # 语法检查
touch /var/log/ups-shutdown.log
```

> **为什么不调用 `upsdrvctl shutdown`**
>
> 不少教程会在关机前加这条命令，让 UPS 在延迟后切断输出。但部分 UPS 的 `ups.delay.shutdown` 出厂值很短（BK650M2-CH 是 20 秒），可能在宿主机还没关完时就断电，反而造成非正常关机。除非你明确知道自己的 UPS 延迟足够长，否则不要加。

## 第 10 步：启动服务

顺序有讲究，驱动要先起来：

```bash
systemctl enable --now nut-driver-enumerator.service
sleep 3
systemctl enable --now nut-server.service
sleep 3
systemctl enable --now nut-monitor.service
systemctl enable nut.target nut-driver.target
systemctl start nut.target nut-driver.target
```

检查：

```bash
systemctl is-active nut-server nut-monitor
systemctl list-units 'nut-driver@*'
```

`nut-driver-enumerator` 显示 `inactive` 是正常的 —— 它是 oneshot 类型，跑完就退出。

## 第 11 步：验证

```bash
upsc bk650m2
```

关键字段：

```
battery.charge: 100          ← 电量百分比
battery.charge.low: 30       ← 低电量阈值
battery.runtime: 3618        ← 估算续航（秒）
input.voltage: 220.0         ← 市电电压
ups.load: 5                  ← 负载百分比
ups.status: OL               ← OL = 市电正常
```

**看到 `OL` 就说明成功了。** apcupsd 在 BK650M2-CH 上误报的正是这个状态。

确认 upsmon 认证通过（不应出现 ACCESS-DENIED）：

```bash
journalctl -u nut-monitor -n 20 | grep -iE "UPS:|ACCESS-DENIED"
# 预期：UPS: bk650m2@localhost (primary) (power value 1)
```

## 第 12 步：修正低电量阈值

这一步很容易被忽略，但很关键。

```bash
upsc bk650m2 battery.charge.low
```

很多 UPS 的出厂值高得离谱。实测 BK650M2-CH 是 **93** —— 意味着电量从 100% 掉到 93% 就报 LOWBATT 立即关机，第 8 步设的 120 秒延迟完全被架空。

改成合理值：

```bash
upsrw -s battery.charge.low=30 -u upsmon -p '你的密码' bk650m2
```

验证：

```bash
upsc bk650m2 battery.charge.low   # 应显示 30
```

报 `ERR ACCESS-DENIED` 说明第 5 步漏了 `actions = SET`。

部分 UPS 不支持修改该值，那就只能反过来缩短第 8 步的延迟时间去适应它。

## 第 13 步：真实断电演练

前面所有验证都只能证明各环节单独正常，**不能证明完整链路可靠**。必须实测。

挑一个虚拟机都空闲的时段：

```bash
# 终端 1
tail -f /var/log/ups-shutdown.log

# 终端 2
watch -n 2 'upsc bk650m2 ups.status'
```

**测试 A — 验证取消机制（安全）**

拔掉 UPS 市电输入插头，观察状态变为 `OB`，然后在延迟期满前插回去。日志应出现「市电已恢复，取消关机倒计时」，虚拟机不受影响。

**测试 B — 验证完整关机（会真的关机）**

拔掉市电后不插回，观察虚拟机是否按组依次关闭、宿主机是否正常 poweroff。

测试前确认：所有虚拟机没有正在进行的重要读写；你有物理接触服务器的条件（关机后需要手动开机）。

## 附：单独测试某台虚拟机的 ACPI 关机

没装 qemu-guest-agent 的虚拟机靠 ACPI 关机，但有些系统默认不响应 ACPI 信号。可以单独测：

```bash
time qm shutdown <VMID> --timeout 60
```

正常响应的话几秒到几十秒内会关闭（实测 fnOS 约 10 秒）。如果一直等到超时，说明该虚拟机不响应 ACPI，断电时只能被强制停止 —— 建议给它装上 guest agent：

```bash
# 虚拟机内部执行
apt install qemu-guest-agent
systemctl enable --now qemu-guest-agent

# PVE 宿主机上执行
qm set <VMID> --agent 1
```

## 附：回滚

```bash
cd /etc/nut
for f in *.orig; do cp "$f" "${f%.orig}"; done
systemctl restart nut-server nut-monitor
```

彻底移除：

```bash
systemctl disable --now nut-monitor nut-server
apt purge nut nut-server nut-client
rm -f /usr/local/bin/pve-ups-shutdown.sh /usr/local/bin/upssched-cmd.sh
```
