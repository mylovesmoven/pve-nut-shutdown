#!/bin/bash
# =============================================================================
# PVE UPS 断电自动关机一键部署脚本 (基于 NUT / Network UPS Tools)
#
# 功能: 市电中断 -> 延迟等待 -> 按序关闭所有 VM/LXC -> 关闭 PVE 宿主机
# 适用: Proxmox VE 7.x / 8.x / 9.x, USB 直连的 UPS
#
# 用法: bash install.sh          交互式安装
#       bash install.sh --yes    非交互(全部用默认值)
#       bash install.sh --uninstall  卸载
#
# 项目地址: https://github.com/YOUR_NAME/pve-nut-shutdown
# =============================================================================

set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

info()  { echo "${BLUE}[信息]${NC} $*"; }
ok()    { echo "${GREEN}[成功]${NC} $*"; }
warn()  { echo "${YELLOW}[警告]${NC} $*"; }
err()   { echo "${RED}[错误]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }
title() { echo; echo "${BOLD}${BLUE}=== $* ===${NC}"; }

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

# 询问, 带默认值
ask() {
    local prompt="$1" default="$2" answer
    if [[ $ASSUME_YES -eq 1 ]]; then echo "$default"; return; fi
    read -r -p "$prompt [$default]: " answer </dev/tty
    echo "${answer:-$default}"
}

confirm() {
    local prompt="$1" answer
    if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
    read -r -p "$prompt [y/N]: " answer </dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# 卸载
# -----------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    title "卸载 PVE UPS 关机配置"
    systemctl disable --now nut-monitor nut-server nut-driver-enumerator 2>/dev/null || true
    systemctl stop 'nut-driver@*' 2>/dev/null || true
    rm -f /usr/local/bin/pve-ups-shutdown.sh /usr/local/bin/upssched-cmd.sh
    if compgen -G "/etc/nut/*.orig" >/dev/null; then
        for f in /etc/nut/*.orig; do cp -f "$f" "${f%.orig}"; done
        ok "已从 .orig 恢复原始配置"
    fi
    rm -f /etc/killpower
    ok "卸载完成。如需彻底移除: apt purge nut nut-server nut-client"
    exit 0
fi

# -----------------------------------------------------------------------------
# 0. 环境检查
# -----------------------------------------------------------------------------
title "环境检查"

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo bash install.sh"
command -v qm >/dev/null || die "未检测到 qm 命令, 此脚本仅适用于 Proxmox VE"

PVE_VER=$(pveversion 2>/dev/null | head -1)
ok "PVE 版本: $PVE_VER"

# 检查 apcupsd 冲突 (会抢占 USB 设备)
if systemctl is-active --quiet apcupsd 2>/dev/null; then
    warn "检测到 apcupsd 正在运行, 它会抢占 UPS 的 USB 设备"
    if confirm "是否停止并禁用 apcupsd?"; then
        systemctl disable --now apcupsd
        ok "apcupsd 已停止"
    else
        die "请先手动处理 apcupsd 后重试"
    fi
fi

# 检查 USB 上是否有 UPS
title "检测 UPS 设备"
if command -v lsusb >/dev/null; then
    USB_LINE=$(lsusb 2>/dev/null | grep -iE "UPS|American Power|051d|0764|0463|06da" || true)
    if [[ -n "$USB_LINE" ]]; then
        ok "USB 总线上发现 UPS:"
        echo "$USB_LINE" | sed 's/^/      /'
    else
        warn "lsusb 未发现明显的 UPS 设备, 继续尝试 nut-scanner"
    fi
fi

# -----------------------------------------------------------------------------
# 1. 安装 NUT
# -----------------------------------------------------------------------------
title "安装 NUT"
if dpkg -l nut-server 2>/dev/null | grep -q '^ii'; then
    ok "NUT 已安装 ($(upsd -V 2>&1 | head -1))"
else
    info "正在安装 (可能需要几分钟)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nut usbutils
    ok "NUT 安装完成: $(upsd -V 2>&1 | head -1)"
fi

# -----------------------------------------------------------------------------
# 2. 扫描 UPS, 自动提取驱动参数
# -----------------------------------------------------------------------------
title "扫描 UPS"

# 若驱动已在运行(重复安装场景), 先停掉 —— 否则它占用 USB 设备,
# nut-scanner 会漏报 serial/product 等字段
if systemctl list-units 'nut-driver@*' --no-legend 2>/dev/null | grep -q running; then
    info "检测到 NUT 驱动正在运行, 临时停止以便完整扫描"
    systemctl stop 'nut-driver@*' 2>/dev/null || true
    sleep 2
fi

SCAN=$(nut-scanner -U 2>/dev/null | grep -v '^Cannot load' || true)

if ! echo "$SCAN" | grep -q 'driver'; then
    err "nut-scanner 未能识别任何 UPS 设备"
    echo
    echo "排查建议:"
    echo "  1. 确认 UPS 数据线(USB)已接到本机: lsusb"
    echo "  2. 若 UPS 接在其他机器上, 本脚本不适用(需配置 netclient 模式)"
    echo "  3. 部分 UPS 需要 root 之外的 udev 权限, 尝试重新插拔后再运行"
    exit 1
fi

echo "$SCAN" | sed 's/^/      /'

# 从扫描结果提取参数
# 注意: 很多 UPS 不上报 serial/product, 且驱动占用设备时 nut-scanner 也会少报字段。
# 因此这里必须容忍字段缺失 —— `|| true` 防止 grep 无匹配在 pipefail 下终止脚本。
get_field() {
    echo "$SCAN" | grep -oP "(?<=^\t$1 = \")[^\"]*" 2>/dev/null | head -1 || true
}
DRIVER=$(get_field driver)
PORT=$(get_field port)
VENDORID=$(get_field vendorid)
PRODUCTID=$(get_field productid)
SERIAL=$(get_field serial)
PRODUCT=$(get_field product)

[[ -n "$DRIVER" ]] || die "无法从扫描结果中提取驱动名"
ok "型号: ${PRODUCT:-未上报}  驱动: $DRIVER"

if [[ -z "$SERIAL" ]]; then
    warn "此次扫描未获取到序列号(UPS 未上报, 或驱动正占用设备)"
    warn "将改用 vendorid+productid 匹配设备 —— 若你有多台同型号 UPS 需手工区分"
fi

# UPS 在 NUT 中的名称(仅字母数字下划线)
DEFAULT_NAME=$(echo "${PRODUCT:-ups}" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z' | cut -c1-16)
[[ -n "$DEFAULT_NAME" ]] || DEFAULT_NAME="myups"
UPSNAME=$(ask "为这台 UPS 取个名字(用于 upsc 命令)" "$DEFAULT_NAME")

# -----------------------------------------------------------------------------
# 3. 交互配置关机策略
# -----------------------------------------------------------------------------
title "关机策略"
echo "市电中断后, 等待多久才开始关机?"
echo "  - 太短: 电网瞬时抖动/跳闸重合闸会导致误关机"
echo "  - 太长: 浪费电池续航, 留给关闭 VM 的时间变少"
ONBATT_DELAY=$(ask "断电延迟(秒)" "120")

echo
echo "电池电量低于多少百分比时, 跳过等待立即关机?"
echo "  注意: 很多 UPS 出厂值高达 90+%, 会架空上面的延迟设置"
LOWBATT_PCT=$(ask "低电量阈值(%)" "30")

# -----------------------------------------------------------------------------
# 4. 探测 VM/LXC, 生成关机顺序
# -----------------------------------------------------------------------------
title "探测虚拟机"

VM_LIST=$(qm list 2>/dev/null | awk 'NR>1{print $1":"$2}')
CT_LIST=$(pct list 2>/dev/null | awk 'NR>1{print $1":"$3}')

if [[ -z "$VM_LIST" && -z "$CT_LIST" ]]; then
    warn "未发现任何 VM 或 LXC"
    SHUTDOWN_GROUPS='GROUP1=""'
else
    echo "当前 VM:"
    qm list 2>/dev/null | sed 's/^/      /'
    if [[ -n "$CT_LIST" ]]; then
        echo "当前 LXC:"
        pct list 2>/dev/null | sed 's/^/      /'
    fi

    echo
    echo "关机顺序建议(组内并行, 组间串行):"
    echo "  第1组 - 普通虚拟机(桌面/应用/开发机)"
    echo "  第2组 - 存储类(NAS/文件服务器), 需要更长时间落盘"
    echo "  第3组 - 网络类(软路由/旁路由), 最后关闭"
    echo
    echo "格式: VMID:超时秒数, 多个用空格分隔。留空表示该组为空。"
    echo "未列出的 VM 会在最后被兜底强制停止。"
    echo

    # 默认: 全部放第1组, 各给 120 秒
    ALL_VMS=$(qm list 2>/dev/null | awk 'NR>1{printf "%s:120 ", $1}')
    G1=$(ask "第1组(普通VM)" "${ALL_VMS% }")
    G2=$(ask "第2组(NAS/存储)" "")
    G3=$(ask "第3组(软路由/网络)" "")
fi

# -----------------------------------------------------------------------------
# 5. 写入配置
# -----------------------------------------------------------------------------
title "写入配置文件"

# 备份原始配置(只备份一次, 重复运行不会覆盖首次备份)
for f in ups.conf upsd.users upsmon.conf upsd.conf nut.conf upssched.conf; do
    if [[ -f "/etc/nut/$f" && ! -f "/etc/nut/$f.orig" ]]; then
        cp "/etc/nut/$f" "/etc/nut/$f.orig"
    fi
done
ok "原始配置已备份为 /etc/nut/*.orig"

# 生成随机密码
# 注意: 不用 `tr < /dev/urandom | head -c N` —— head 提前退出会让 tr 收到
# SIGPIPE, 在 pipefail 下导致整条管道失败。这里用 openssl, 无管道。
UPSPASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)
if [[ ${#UPSPASS} -lt 16 ]]; then
    # 兜底: 没有 openssl 时用 urandom, 显式读固定长度而非靠 head 截断
    UPSPASS=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)
fi
[[ ${#UPSPASS} -ge 16 ]] || die "无法生成随机密码"
echo "$UPSPASS" > /root/.ups_pass
chmod 600 /root/.ups_pass

# ---- ups.conf ----
{
    echo "# 由 pve-nut-shutdown 自动生成"
    echo "pollinterval = 5"
    echo
    echo "[$UPSNAME]"
    echo "    driver = \"$DRIVER\""
    echo "    port = \"${PORT:-auto}\""
    if [[ -n "$VENDORID"  ]]; then echo "    vendorid = \"$VENDORID\""; fi
    if [[ -n "$PRODUCTID" ]]; then echo "    productid = \"$PRODUCTID\""; fi
    # 序列号绑定: 防止多设备或 USB 重新枚举后错配
    if [[ -n "$SERIAL" ]]; then echo "    serial = \"$SERIAL\""; fi
    echo "    desc = \"${PRODUCT:-UPS}\""
} > /etc/nut/ups.conf

# ---- upsd.users ----
cat > /etc/nut/upsd.users <<EOF
[upsmon]
    password = ${UPSPASS}
    upsmon primary
    actions = SET
    instcmds = ALL
EOF

# ---- nut.conf ----
echo "MODE=standalone" > /etc/nut/nut.conf

# ---- upsmon.conf ----
cat > /etc/nut/upsmon.conf <<EOF
# 由 pve-nut-shutdown 自动生成
RUN_AS_USER nut

MONITOR ${UPSNAME}@localhost 1 upsmon ${UPSPASS} primary

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
EOF

# ---- upssched.conf ----
cat > /etc/nut/upssched.conf <<EOF
# 由 pve-nut-shutdown 自动生成
CMDSCRIPT /usr/local/bin/upssched-cmd.sh
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

# 市电中断: 启动倒计时
AT ONBATT * START-TIMER onbatt-shutdown ${ONBATT_DELAY}
# 市电恢复: 取消倒计时
AT ONLINE * CANCEL-TIMER onbatt-shutdown online-back
# 电池低电量: 跳过倒计时立即关机
AT LOWBATT * EXECUTE lowbatt-now
# 强制关机信号
AT FSD * EXECUTE forced-shutdown
EOF

chown root:nut /etc/nut/ups.conf /etc/nut/upsd.users /etc/nut/nut.conf \
               /etc/nut/upsmon.conf /etc/nut/upssched.conf
chmod 640 /etc/nut/ups.conf /etc/nut/upsd.users /etc/nut/nut.conf \
          /etc/nut/upsmon.conf /etc/nut/upssched.conf
ok "NUT 配置写入完成"

# ---- 事件回调脚本 ----
cat > /usr/local/bin/upssched-cmd.sh <<'EOF'
#!/bin/bash
LOG=/var/log/ups-shutdown.log
case "$1" in
    onbatt-shutdown)
        echo "$(date '+%F %T') [upssched] 断电持续超时, 开始关机流程" >>"$LOG"
        logger -t upssched "断电超时, 触发 PVE 关机"
        /usr/local/bin/pve-ups-shutdown.sh
        ;;
    online-back)
        echo "$(date '+%F %T') [upssched] 市电已恢复, 取消关机倒计时" >>"$LOG"
        logger -t upssched "市电恢复, 关机已取消"
        ;;
    lowbatt-now)
        echo "$(date '+%F %T') [upssched] 电池电量过低, 立即关机" >>"$LOG"
        logger -t upssched "电池低电量, 立即关机"
        /usr/local/bin/pve-ups-shutdown.sh
        ;;
    forced-shutdown)
        echo "$(date '+%F %T') [upssched] 收到 FSD 强制关机信号" >>"$LOG"
        /usr/local/bin/pve-ups-shutdown.sh
        ;;
    *)
        logger -t upssched "未知事件: $1"
        ;;
esac
EOF
chmod +x /usr/local/bin/upssched-cmd.sh

# ---- 分级关机脚本 ----
cat > /usr/local/bin/pve-ups-shutdown.sh <<EOF
#!/bin/bash
# PVE UPS 断电分级关机脚本 (由 install.sh 生成)
# 顺序: 第1组 -> 第2组 -> 第3组 -> 兜底 -> 宿主机关机
# 格式: "VMID:超时秒数", 同组并行, 组间串行

GROUP1="${G1:-}"
GROUP2="${G2:-}"
GROUP3="${G3:-}"
EOF

cat >> /usr/local/bin/pve-ups-shutdown.sh <<'EOF'

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
        [[ "$tmo" == "$vm" ]] && tmo=120   # 没写超时则默认 120s
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

# 兜底: 停止任何仍在运行的 VM
echo "--- 兜底检查 ---"
for vm in $(qm list 2>/dev/null | awk '$3=="running"{print $1}'); do
    echo "  [VM $vm] 仍在运行, 强制 stop"
    qm stop "$vm" 2>&1
done

# LXC 容器
for ct in $(pct list 2>/dev/null | awk '$2=="running"{print $1}'); do
    echo "  [LXC $ct] shutdown"
    pct shutdown "$ct" --forceStop 1 --timeout 60 2>&1
done

echo "所有虚拟机已停止, $(date '+%F %T') 关闭宿主机"
sync

# 注意: 此处不调用 upsdrvctl shutdown
# 部分 UPS 的 offdelay 很短(如 20 秒), 会在宿主机关完前就切断输出
/sbin/poweroff
EOF

chmod +x /usr/local/bin/pve-ups-shutdown.sh
touch /var/log/ups-shutdown.log
bash -n /usr/local/bin/pve-ups-shutdown.sh || die "生成的关机脚本语法错误"
ok "关机脚本已生成并通过语法检查"

# -----------------------------------------------------------------------------
# 6. 启动服务
# -----------------------------------------------------------------------------
title "启动服务"
systemctl enable --now nut-driver-enumerator.service >/dev/null 2>&1 || true
sleep 3
systemctl restart nut-server.service; systemctl enable nut-server.service >/dev/null 2>&1
sleep 3
systemctl restart nut-monitor.service; systemctl enable nut-monitor.service >/dev/null 2>&1
systemctl enable nut.target nut-driver.target >/dev/null 2>&1 || true
systemctl start  nut.target nut-driver.target >/dev/null 2>&1 || true
sleep 3

for s in nut-server nut-monitor; do
    if systemctl is-active --quiet "$s"; then
        ok "$s 运行中"
    else
        err "$s 启动失败, 查看: journalctl -u $s -n 30"
    fi
done

# -----------------------------------------------------------------------------
# 7. 验证
# -----------------------------------------------------------------------------
title "验证"

# 驱动刚启动时会短暂处于 WAIT 状态, 轮询等待其就绪
STATUS=""
for i in $(seq 1 15); do
    STATUS=$(upsc "$UPSNAME" ups.status 2>/dev/null || true)
    case "$STATUS" in
        ""|WAIT*) sleep 2 ;;
        *) break ;;
    esac
done

if [[ -z "$STATUS" ]]; then
    err "无法读取 UPS 状态"
    echo "排查: journalctl -u nut-server -n 30; systemctl status nut-driver@$UPSNAME"
    exit 1
fi

ok "UPS 状态: $STATUS"
case "$STATUS" in
    *OL*)   ok "OL = 市电正常供电" ;;
    *OB*)   warn "OB = 当前由电池供电!" ;;
    WAIT*)  warn "驱动仍在初始化, 稍后用 upsc $UPSNAME 再确认一次" ;;
esac

# 调整低电量阈值
CUR_LOW=$(upsc "$UPSNAME" battery.charge.low 2>/dev/null || echo "")
if [[ -n "$CUR_LOW" && "$CUR_LOW" != "$LOWBATT_PCT" ]]; then
    if upsrw -s "battery.charge.low=$LOWBATT_PCT" -u upsmon -p "$UPSPASS" "$UPSNAME" >/dev/null 2>&1; then
        ok "低电量阈值: $CUR_LOW% -> $LOWBATT_PCT%"
    else
        warn "低电量阈值当前为 $CUR_LOW%, 此 UPS 不支持修改该值"
        if [[ "$CUR_LOW" =~ ^[0-9]+$ ]] && [[ "$CUR_LOW" -gt 80 ]]; then
            warn "该值偏高, 断电后可能很快触发 LOWBATT 而跳过 ${ONBATT_DELAY}秒 延迟"
        fi
    fi
fi

# 验证 upsmon 认证
if journalctl -u nut-monitor -n 30 --no-pager 2>/dev/null | grep -qi "ACCESS-DENIED\|Login.*failed"; then
    err "upsmon 认证失败, 请检查 /etc/nut/upsd.users 与 upsmon.conf 中的用户名密码是否一致"
    exit 1
fi
ok "upsmon 认证正常"

# 测试事件回调(安全, 不会关机)
/usr/local/bin/upssched-cmd.sh online-back
grep -q "市电已恢复" /var/log/ups-shutdown.log && ok "事件回调链路正常"

# -----------------------------------------------------------------------------
# 完成
# -----------------------------------------------------------------------------
RUNTIME=$(upsc "$UPSNAME" battery.runtime 2>/dev/null || echo "?")
CHARGE=$(upsc "$UPSNAME" battery.charge 2>/dev/null || echo "?")
LOAD=$(upsc "$UPSNAME" ups.load 2>/dev/null || echo "?")

title "部署完成"
cat <<EOF

  UPS 名称     : $UPSNAME  (${PRODUCT:-未知型号})
  当前状态     : $STATUS   电量 ${CHARGE}%  负载 ${LOAD}%  估算续航 ${RUNTIME}秒
  断电延迟     : ${ONBATT_DELAY} 秒
  低电量阈值   : ${LOWBATT_PCT}%
  关机顺序     : ${G1:-(空)} | ${G2:-(空)} | ${G3:-(空)}

  ${BOLD}断电后的流程:${NC}
    市电中断 -> 等待 ${ONBATT_DELAY}秒(期间恢复则取消)
      -> 第1组 VM 并行关闭 -> 第2组 -> 第3组
      -> 兜底强制停止残余 VM -> PVE 宿主机 poweroff
    电量低于 ${LOWBATT_PCT}% 时跳过等待, 立即关机

  ${BOLD}常用命令:${NC}
    upsc $UPSNAME                    # 查看 UPS 全部状态
    tail -f /var/log/ups-shutdown.log  # 查看关机流程日志
    journalctl -u nut-monitor -f       # 查看监控日志

  ${YELLOW}${BOLD}重要: 请做一次真实断电演练${NC}
    选一个所有 VM 空闲的时段, 拔掉 UPS 的市电输入插头,
    另开终端执行 tail -f /var/log/ups-shutdown.log 观察全过程。
    这是唯一能确认端到端可靠的方式。

EOF
