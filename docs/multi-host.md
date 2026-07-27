# 多台机器共用一台 UPS

一台 UPS 通常能带多台设备。让它们都在断电时自动关机，需要区分两种角色：

- **primary（主机）** —— UPS 用 USB 直连的那台，负责读取 UPS 状态并对外提供服务
- **secondary（从机）** —— 通过网络向 primary 查询状态，收到关机信号后关闭自己

> NUT 2.8 之前这两个角色叫 `master` / `slave`，老教程里看到的是旧名称。

## Primary 端配置

先按主 [README](../README.md) 或[手工步骤](manual-setup.md)完成 primary 的配置，然后做两处修改。

### 1. 允许从网络访问

```bash
vim /etc/nut/upsd.conf
```

```ini
LISTEN 0.0.0.0 3493
```

默认只监听 127.0.0.1，从机连不上。

如果只需要局域网内特定网段访问，也可以指定本机的局域网 IP：

```ini
LISTEN 192.168.1.10 3493
```

### 2. 添加从机用户

```bash
vim /etc/nut/upsd.users
```

在已有的 `[upsmon]` 之后追加：

```ini
[upsslave]
    password = 给从机用的密码
    upsmon secondary
```

注意是 `secondary`，不是 `primary`。从机不需要 `actions = SET`。

### 3. 重启并放行防火墙

```bash
systemctl restart nut-server

# 如果 PVE 开了防火墙，放行 3493 端口
# 在 PVE 网页界面 → 数据中心 → 防火墙 中添加规则，或：
iptables -A INPUT -p tcp --dport 3493 -s 192.168.1.0/24 -j ACCEPT
```

验证从机能否连上（在从机上执行）：

```bash
upsc bk650m2@192.168.1.10
```

能看到状态输出就说明通了。

## Secondary 端配置

从机只需要 `nut-client`，不需要 nut-server。

```bash
apt install -y nut-client
```

### 1. 设置模式

```bash
echo "MODE=netclient" > /etc/nut/nut.conf
```

### 2. 配置监控

```bash
vim /etc/nut/upsmon.conf
```

```ini
RUN_AS_USER nut

MONITOR bk650m2@192.168.1.10 1 upsslave 从机密码 secondary

MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15

NOTIFYFLAG ONBATT   SYSLOG+WALL
NOTIFYFLAG LOWBATT  SYSLOG+WALL
NOTIFYFLAG FSD      SYSLOG+WALL
NOTIFYFLAG SHUTDOWN SYSLOG+WALL
NOTIFYFLAG COMMBAD  SYSLOG+WALL
NOTIFYFLAG NOCOMM   SYSLOG+WALL

FINALDELAY 5
```

要点：

- MONITOR 行指向 **primary 的 IP**，角色写 `secondary`
- 从机如果也是 PVE，把 `SHUTDOWNCMD` 换成分级关机脚本（把 primary 上的 `/usr/local/bin/pve-ups-shutdown.sh` 复制过去，按本机的 VMID 改分组）

### 3. 启动

```bash
systemctl enable --now nut-monitor
systemctl status nut-monitor
```

## 关机顺序

从机会**先于** primary 关机 —— NUT 的设计如此：primary 会等所有从机断开连接（或超过 `HOSTSYNC` 秒）后才关闭自己。

这个顺序通常是对的：primary 往往是主力服务器，让它多撑一会儿。如果你需要相反的顺序（比如从机是不能中断的服务），得靠调整各自的延迟时间来实现，NUT 没有直接的优先级设置。

## 排查

**从机连不上 primary**

```bash
# 从机上测试网络可达性
nc -zv 192.168.1.10 3493

# primary 上确认监听
ss -tlnp | grep 3493
```

监听地址是 `127.0.0.1:3493` 说明 `upsd.conf` 的 LISTEN 没生效，检查是否漏了重启 nut-server。

**从机日志报 ACCESS-DENIED**

primary 的 `upsd.users` 里从机用户名/密码与从机 `upsmon.conf` 不一致，或角色写成了 `primary`。

**primary 关机了但从机没关**

检查从机的 `nut-monitor` 是否在运行，以及 `DEADTIME` 设置。从机与 primary 失联超过 `DEADTIME` 秒会触发告警，但**失联本身不会触发关机** —— 这是设计如此，避免网络故障导致误关机。

如果你希望「与 primary 失联即关机」，需要在从机上另外写监控逻辑，NUT 本身不提供。

## 非 Linux 从机

- **Windows**：用 [WinNUT-Client](https://github.com/nutdotnet/WinNUT-Client)
- **群晖 / 威联通**：控制面板里有原生的 UPS 设置，选「网络 UPS」并填 primary 的 IP 即可，无需命令行
- **ESXi**：需要装 vMA 或第三方 VIB，配置较复杂，不在本文范围
