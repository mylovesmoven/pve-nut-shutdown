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
# nut-scanner 会漏报 serial/product 等字段。
# 注意: 停掉后 UPS 保护即失效, 因此注册 trap 保证中途退出(Ctrl+C / 报错)时能恢复。
DRIVER_WAS_STOPPED=0
restore_driver_on_exit() {
    if [[ "$DRIVER_WAS_STOPPED" -eq 1 ]]; then
        echo
        warn "安装未完成, 正在恢复原有的 UPS 驱动..."
        systemctl restart nut-driver-enumerator.service 2>/dev/null || true
        sleep 2
        systemctl start nut-driver.target 2>/dev/null || true
        sleep 3
        if systemctl list-units 'nut-driver@*' --no-legend 2>/dev/null | grep -q running; then
            ok "驱动已恢复, UPS 保护正常"
        else
            err "驱动恢复失败! 你的 UPS 保护当前处于失效状态"
            err "请手动执行: systemctl restart nut-driver-enumerator && systemctl start nut-driver.target"
        fi
    fi
}
trap restore_driver_on_exit EXIT INT TERM

if systemctl list-units 'nut-driver@*' --no-legend 2>/dev/null | grep -q running; then
    info "检测到 NUT 驱动正在运行, 临时停止以便完整扫描"
    systemctl stop 'nut-driver@*' 2>/dev/null || true
    DRIVER_WAS_STOPPED=1
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
echo
echo "给这台 UPS 起个代号, 以后查看状态时要用到, 比如: upsc ${DEFAULT_NAME}"
echo "只能用英文字母和数字。想省事就直接回车。"
UPSNAME=$(ask "UPS 代号" "$DEFAULT_NAME")
# 名称里有非法字符会让 NUT 起不来, 这里直接过滤掉
UPSNAME=$(echo "$UPSNAME" | tr -cd 'A-Za-z0-9_-')
[[ -n "$UPSNAME" ]] || UPSNAME="$DEFAULT_NAME"

# -----------------------------------------------------------------------------
# 3. 交互配置关机策略
# -----------------------------------------------------------------------------
title "关机策略"
echo "市电断了以后, 先等一会儿再关机 —— 因为大部分停电只是几秒钟的"
echo "跳闸或电压抖动, 等一等就恢复了, 没必要把整台服务器关掉。"
echo
echo "  等太短: 电网抖一下就误关机"
echo "  等太长: 白白消耗电池, 留给关虚拟机的时间变少"
echo
echo "不确定填多少就直接回车用默认值。"
ONBATT_DELAY=$(ask "断电后等待多少秒再关机" "120")

echo
echo "如果电池快没电了, 就不能再等上面那 ${ONBATT_DELAY} 秒了, 得立刻关机。"
echo "电量低于多少时立刻关机?"
echo
echo "  ${YELLOW}提示: 不少 UPS 出厂设的是 90% 以上, 意味着电量刚掉一点就立刻关机,${NC}"
echo "  ${YELLOW}      上面设的 ${ONBATT_DELAY} 秒等待就白设了。本脚本会帮你改成下面这个值。${NC}"
LOWBATT_PCT=$(ask "电量低于百分之几时立刻关机" "30")

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
    # 收集 VMID 与名称, 供后面校验和显示用
    declare -A VM_NAMES
    VALID_IDS=""
    while read -r id name st; do
        [[ -z "$id" ]] && continue
        VM_NAMES["$id"]="$name"
        VALID_IDS+="$id "
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1, $2, $3}')

    echo "这台 PVE 上的虚拟机:"
    echo
    printf "      %-8s %-20s %s\n" "VMID" "名称" "当前状态"
    printf "      %-8s %-20s %s\n" "------" "--------------------" "--------"
    qm list 2>/dev/null | awk 'NR>1{printf "      %-8s %-20s %s\n", $1, $2, $3}'

    if [[ -n "$CT_LIST" ]]; then
        echo
        echo "LXC 容器(会在虚拟机之后自动关闭, 无需手工分组):"
        pct list 2>/dev/null | sed 's/^/      /'
    fi

    # 用真实存在的 VMID 造两个例子, 比抽象说明好懂
    _ids=($VALID_IDS)
    VMID_EXAMPLE="${_ids[0]:-101}${_ids[1]:+ ${_ids[1]}}"
    VMID_TMO_EXAMPLE="${_ids[0]:-101}:180"

    echo
    echo "接下来给虚拟机排一个关机顺序。"
    echo "同一组里的虚拟机同时关闭; 一组全部停止后, 才开始关下一组。"
    echo
    echo "  第1组 —— 普通虚拟机(桌面/应用/开发机), 最先关"
    echo "  第2组 —— 存储类(NAS/文件服务器), 需要时间落盘"
    echo "  第3组 —— 网络类(软路由/旁路由), 最后关, 保住网络"
    echo
    echo "${BOLD}怎么填: 输入上面表格里的「VMID」那一列的数字, 多个用空格分隔。${NC}"
    echo "  例如: ${GREEN}${VMID_EXAMPLE}${NC}"
    echo "  不想给某一组安排虚拟机, 直接回车留空即可。"
    echo
    echo "每台虚拟机默认等 120 秒; 想单独指定就写成 ${GREEN}VMID:秒数${NC}, 例如 ${GREEN}${VMID_TMO_EXAMPLE}${NC}。"
    echo "没填进任何一组的虚拟机, 会在最后被强制停止(相当于硬断电, 尽量别漏)。"
    echo

    # 校验并规范化一组输入: 返回 "VMID:超时" 格式, 非法项会提示重填
    normalize_group() {
        local raw="$1" out="" item vm tmo
        for item in $raw; do
            vm="${item%%:*}"
            tmo="${item##*:}"
            [[ "$tmo" == "$vm" ]] && tmo=120
            if [[ ! "$vm" =~ ^[0-9]+$ ]]; then
                err "  「$item」不是有效的 VMID(必须是数字)"
                return 1
            fi
            if ! echo "$VALID_IDS" | grep -qw "$vm"; then
                err "  VMID $vm 不存在。可用的有: $(echo $VALID_IDS | tr '\n' ' ')"
                return 1
            fi
            if [[ ! "$tmo" =~ ^[0-9]+$ ]]; then
                err "  「$item」的超时值不是数字"
                return 1
            fi
            out+="$vm:$tmo "
        done
        echo "${out% }"
        return 0
    }

    # 反复询问直到输入合法
    ask_group() {
        local prompt="$1" default="$2" raw result
        while true; do
            raw=$(ask "$prompt" "$default")
            [[ -z "${raw// }" ]] && { echo ""; return; }
            if result=$(normalize_group "$raw" 2>/dev/tty); then
                echo "$result"
                return
            fi
            [[ $ASSUME_YES -eq 1 ]] && { echo ""; return; }   # 非交互模式不死循环
        done
    }

    # 默认只把「正在运行」的虚拟机放进第1组 —— 没开机的放进去没意义
    ALL_VMS=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{printf "%s ", $1}')
    G1=$(ask_group "第1组 普通虚拟机" "${ALL_VMS% }")
    G2=$(ask_group "第2组 存储/NAS" "")
    G3=$(ask_group "第3组 软路由/网络" "")

    # 只对「正在运行却没分组」的虚拟机告警 —— 没开机的本来就不用管
    ASSIGNED=$(echo "$G1 $G2 $G3" | tr ' ' '\n' | cut -d: -f1 | grep -v '^$' | sort -u)
    RUNNING_IDS=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
    MISSING=""
    for v in $RUNNING_IDS; do
        echo "$ASSIGNED" | grep -qw "$v" || MISSING+="$v "
    done

    echo
    echo "${BOLD}关机顺序确认:${NC}"
    print_group() {
        local g="$1" label="$2"
        if [[ -z "${g// }" ]]; then
            echo "  $label: (空)"
        else
            local line="  $label:"
            for item in $g; do
                local vm="${item%%:*}" tmo="${item##*:}"
                line+=" ${vm}(${VM_NAMES[$vm]:-?}, ${tmo}s)"
            done
            echo "$line"
        fi
    }
    print_group "$G1" "第1组"
    print_group "$G2" "第2组"
    print_group "$G3" "第3组"
    if [[ -n "${MISSING// }" ]]; then
        echo
        warn "以下虚拟机正在运行, 但没安排在任何组里 —— 断电时会被强制停止:"
        for v in $MISSING; do
            warn "    VM $v (${VM_NAMES[$v]:-?})"
        done
        warn "强制停止相当于直接拔电源, 有损坏数据的风险。建议把它们填进上面某一组。"
    fi
    echo
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
# Debian 的 tmpfiles 会预建 /run/nut/upssched (0770 nut:nut) 专门放这两个文件,
# 放在 /run/nut/ 根下 upsmon(以 nut 身份运行) 可能建不出来, 定时器会静默失效
PIPEFN /run/nut/upssched/upssched.pipe
LOCKFN /run/nut/upssched/upssched.lock

# 市电中断: 启动倒计时
AT ONBATT * START-TIMER onbatt-shutdown ${ONBATT_DELAY}
# 市电恢复: 取消倒计时
AT ONLINE * CANCEL-TIMER onbatt-shutdown online-back
# 电池低电量: 跳过倒计时立即关机
AT LOWBATT * EXECUTE lowbatt-now
# 注意: 不要写 AT FSD —— upsmon 收到 FSD 后会自己执行 SHUTDOWNCMD,
# 再从这里调一次会重复触发
EOF

chown root:nut /etc/nut/ups.conf /etc/nut/upsd.users /etc/nut/nut.conf \
               /etc/nut/upsmon.conf /etc/nut/upssched.conf
chmod 640 /etc/nut/ups.conf /etc/nut/upsd.users /etc/nut/nut.conf \
          /etc/nut/upsmon.conf /etc/nut/upssched.conf
ok "NUT 配置写入完成"

# ---- 事件回调脚本 ----
# UPS 名字要嵌进脚本, 所以这一段用可展开的 heredoc
cat > /usr/local/bin/upssched-cmd.sh <<EOF
#!/bin/bash
# upssched 事件回调 (由 install.sh 生成)
#
# 重要: 本脚本由 upssched 以 nut 用户身份执行, 权限很低 ——
# 既写不了 root 的日志文件, 也运行不了 qm(PVE 的集群 IPC 需要 root,
# 否则报 ipcc_send_rec failed)。所以这里绝不能直接调用关机脚本, 而是用
# \`upsmon -c fsd\` 通知以 root 运行的 upsmon 父进程, 由它执行 upsmon.conf
# 里 SHUTDOWNCMD 指定的分级关机脚本 —— 那才是有 root 权限的执行路径。
LOG=/var/log/ups-shutdown.log
UPSNAME_LOCAL="${UPSNAME}"
EOF

# 其余部分不需要变量替换, 用带引号的 heredoc 追加
cat >> /usr/local/bin/upssched-cmd.sh <<'EOF'

note() {
    logger -t ups-shutdown "$1"
    echo "$(date '+%F %T') [upssched] $1" >>"$LOG" 2>/dev/null || true
}

# 关机前确认供电状态, 三态判断:
#   POWER_STATE=onbatt   确认正在电池放电 -> 关机
#   POWER_STATE=online   确认市电正常(如 OL CHRG) -> 忽略误报
#   POWER_STATE=unknown  连续 3 次查询失败(每次间隔 3 秒) -> fail-safe 按断电处理, 照常关机
# 说明: UPS 充电或自检时可能瞬时误报 LB(实测: 市电正常、电量 99% 仍报过
# battery is low), 所以 online 时忽略; 但 upsd 瞬时不可达导致查询失败时,
# 绝不能当成"市电正常"跳过关机 —— 真断电时 START-TIMER 只触发一次,
# 错过就没有第二次机会, 所以 unknown 走 fail-safe 照常关机。
check_power() {
    local st try
    for try in 1 2 3; do
        st=$(upsc "$UPSNAME_LOCAL" ups.status 2>/dev/null)
        if [[ -n "$st" ]]; then
            UPS_STATUS="$st"
            if [[ "$st" == *OB* ]]; then POWER_STATE=onbatt; else POWER_STATE=online; fi
            return
        fi
        note "查询 UPS 状态失败 (第 ${try}/3 次)"
        [[ "$try" -lt 3 ]] && sleep 3
    done
    POWER_STATE=unknown
}

case "$1" in
    onbatt-shutdown)
        check_power
        case "$POWER_STATE" in
            onbatt)
                note "断电持续超时, 确认仍在电池放电(状态: $UPS_STATUS), 通知 upsmon 执行关机"
                /sbin/upsmon -c fsd
                ;;
            unknown)
                note "断电倒计时到期, 连续 3 次查询 UPS 状态失败 —— fail-safe: 按断电处理, 通知 upsmon 执行关机"
                /sbin/upsmon -c fsd
                ;;
            online)
                note "倒计时到期但市电已恢复(状态: $UPS_STATUS), 取消关机"
                ;;
        esac
        ;;
    online-back)
        note "市电已恢复, 取消关机倒计时"
        ;;
    lowbatt-now)
        check_power
        case "$POWER_STATE" in
            onbatt)
                note "电池电量过低且确认正在放电(状态: $UPS_STATUS), 通知 upsmon 立即关机"
                /sbin/upsmon -c fsd
                ;;
            unknown)
                note "收到低电量信号, 连续 3 次查询 UPS 状态失败 —— fail-safe: 按断电处理, 通知 upsmon 立即关机"
                /sbin/upsmon -c fsd
                ;;
            online)
                note "收到低电量信号, 但市电正常(状态: $UPS_STATUS), 忽略 —— 多为充电中的误报"
                ;;
        esac
        ;;
    *)
        note "未知事件: $1"
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
# upssched 以 nut 用户运行, 要让它也能往日志里留痕
chown root:nut /var/log/ups-shutdown.log
chmod 664 /var/log/ups-shutdown.log
bash -n /usr/local/bin/pve-ups-shutdown.sh || die "生成的关机脚本语法错误"
ok "关机脚本已生成并通过语法检查"

# -----------------------------------------------------------------------------
# 6. 启动服务
# -----------------------------------------------------------------------------
title "启动服务"
# 到这里配置已写完, 下面会正常拉起驱动, 无需再由 trap 兜底
DRIVER_WAS_STOPPED=0
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
