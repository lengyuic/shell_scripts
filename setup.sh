#!/bin/sh

# ================================================================
# Debian/Ubuntu VPS 一键配置脚本 (多级菜单整合版)
# 主菜单:
#   1. 安装常用软件
#   2. 配置 NTP        (子菜单)
#   3. Fail2Ban        (子菜单)
#   4. Sing-Box 配置   (子菜单)
#   5. 防火墙配置      (子菜单)
#   00. 退出
# 用法: sudo sh setup.sh
# ================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- 日志辅助函数 ---
log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# --- 全局常量 ---
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_DIR="/etc/sing-box"
NFT_CONF="/etc/nftables.conf"
NFT_TABLE="landing_whitelist"
NTP_SERVERS_FILE="/etc/ntp_servers.conf"
CHRONY_CONF="/etc/chrony/chrony.conf"
CHRONY_MARK_BEGIN="# === BEGIN setup.sh CUSTOM SOURCES ==="
CHRONY_MARK_END="# === END setup.sh CUSTOM SOURCES ==="
FAIL2BAN_JAILS_FILE="/etc/fail2ban_jails.conf"

# --- Root 检查 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限运行: sudo sh $0"
        exit 1
    fi
}

# --- 通用: 从 /dev/tty 读取一行 (无 tty 时回退到 stdin) ---
read_tty() {
    if [ -r /dev/tty ]; then
        read "$@" < /dev/tty
    else
        read "$@"
    fi
}

# --- 通用: 读取交互输入 ---
read_input() {
    prompt="$1"
    default="$2"
    varname="$3"

    if [ -n "$default" ]; then
        printf "${CYAN}%s [默认: %s]: ${NC}" "$prompt" "$default"
    else
        printf "${CYAN}%s: ${NC}" "$prompt"
    fi

    read_tty input

    if [ -z "$input" ]; then
        input="$default"
    fi
    eval "$varname=\"\$input\""
}

# --- 等待回车继续 ---
press_to_continue() {
    printf "\n${YELLOW}按回车键继续...${NC}"
    read_tty _dummy
}

# --- 菜单: 打印通用 返回/退出 脚注 ---
print_submenu_footer() {
    printf "\n  ${YELLOW}[回车]${NC} 返回上层    ${YELLOW}m${NC} 主菜单    ${YELLOW}q${NC} 退出\n"
}

# --- 菜单: 打印提示并把选项读入全局变量 choice ---
prompt_choice() {
    printf "${CYAN}%s${NC}" "${1:-请选择: }"
    read_tty choice
}

# --- 菜单: 通用增删改查 (CRUD) 子菜单 ---
# 用法: menu_crud <查看函数> <添加函数> <删除函数> <修改函数>
# 列表始终显示在顶部 (由查看函数输出, 自带标题), 故不再单列“查看”动作
menu_crud() {
    _view="$1"; _add="$2"; _del="$3"; _mod="$4"
    while true; do
        printf "\n"
        "$_view"
        printf "${BLUE}---------------- 操作 ----------------${NC}\n"
        printf "  ${GREEN}1)${NC} 添加    ${GREEN}2)${NC} 删除    ${GREEN}3)${NC} 修改\n"
        print_submenu_footer
        prompt_choice
        case "$choice" in
            1)   while "$_add"; do :; done; press_to_continue ;;
            2)   while "$_del"; do :; done; press_to_continue ;;
            3)   "$_mod"; press_to_continue ;;
            '')  return 0 ;;
            m|M) return 99 ;;
            q|Q) exit 0 ;;
            *)   log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 公共工具
# ================================================================

get_server_ip() {
    urls="http://icanhazip.com https://ifconfig.me https://api.ipify.org http://checkip.amazonaws.com"
    for url in $urls; do
        ip=$(curl -s4 -m 3 "$url" | tr -d '\n' | tr -d '\r')
        case "$ip" in
            *[0-9]*.*[0-9]*)
                if echo "$ip" | grep -q "<"; then continue; fi
                echo "$ip"
                return 0
                ;;
        esac
    done
    echo ""
}

get_best_domain() {
    log_info "正在筛选低延迟 Reality 目标域名..."
    DOMAINS="www.microsoft.com www.apple.com www.amazon.com www.nvidia.com www.amd.com www.intel.com www.google.com www.bing.com s0.awsstatic.com www.oracle.com www.cisco.com www.samsung.com www.ibm.com www.adobe.com www.dell.com www.tesla.com www.qualcomm.com azure.microsoft.com"

    BEST_DOMAIN=""
    MIN_TIME="10.000"

    for d in $DOMAINS; do
        raw_time=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 1 "https://$d" 2>/dev/null || true)
        time_cost=$(printf '%s' "$raw_time" | tr -dc '0-9.')
        case "$time_cost" in
            [0-9]*.[0-9]*) ;;
            *) time_cost="10.000" ;;
        esac

        is_faster=$(awk -v t="$time_cost" -v m="$MIN_TIME" 'BEGIN {print (t+0 < m+0) ? 1 : 0}')
        if [ "$is_faster" -eq 1 ]; then
            MIN_TIME=$time_cost
            BEST_DOMAIN=$d
            printf "   - %-25s : ${GREEN}%ss${NC}\n" "$d" "$time_cost"
        else
            printf "   - %-25s : %ss\n" "$d" "$time_cost"
        fi
    done

    if [ -z "$BEST_DOMAIN" ] || [ "$MIN_TIME" = "10.000" ]; then
        BEST_DOMAIN="www.microsoft.com"
        log_warn "所有域名测试超时, 回退默认: $BEST_DOMAIN"
    else
        log_info "🏆 最佳域名: $BEST_DOMAIN (延迟: ${MIN_TIME}s)"
    fi
}

get_ssh_port() {
    ssh_port=""
    if command -v sshd >/dev/null 2>&1; then
        ssh_port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -n 1)
    fi
    [ -z "$ssh_port" ] && ssh_port=22
    echo "$ssh_port"
}

validate_ipv4() {
    ip="$1"
    case "$ip" in
        *.*.*.*)
            ip_only=$(echo "$ip" | cut -d/ -f1)
            ok=1
            for octet in $(echo "$ip_only" | tr '.' ' '); do
                case "$octet" in
                    ''|*[!0-9]*) ok=0; break ;;
                    *)
                        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ] 2>/dev/null; then
                            ok=0; break
                        fi
                        ;;
                esac
            done
            [ "$ok" -eq 1 ] && return 0 || return 1
            ;;
        *) return 1 ;;
    esac
}

# ================================================================
# 主菜单任务 1: 安装常用软件
# ================================================================
task_install_common() {
    printf "${BLUE}=== 安装常用软件 (vim/git/curl/wget/tar/zsh + oh-my-zsh) ===${NC}\n"
    (
        set -e
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y vim git curl tar wget zsh

        if [ ! -d "$HOME/.oh-my-zsh" ]; then
            log_info "安装 oh-my-zsh..."
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            log_info "oh-my-zsh 已存在, 跳过安装"
        fi

        if [ -f "$HOME/.zshrc" ]; then
            sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="ys"/' "$HOME/.zshrc"
        fi

        usermod -s /bin/zsh root

        log_info "vim 鼠标禁用: 写入 $HOME/.vimrc"
        echo "set mouse=" > "$HOME/.vimrc"

        log_info "安装完成. 重新登录后 zsh 生效"
    )
}

# ================================================================
# NTP (chrony) 模块
# ================================================================
ntp_status() {
    printf "${MAGENTA}--- NTP (chrony) 状态 ---${NC}\n"

    if command -v chronyd >/dev/null 2>&1; then
        printf "  安装状态: ${GREEN}已安装${NC}\n"
        installed=1
    else
        printf "  安装状态: ${RED}未安装${NC}\n"
        installed=0
    fi

    if [ "$installed" -eq 1 ] && systemctl is-active --quiet chrony 2>/dev/null; then
        printf "  服务状态: ${GREEN}已启用${NC}\n"
        running=1
    else
        printf "  服务状态: ${YELLOW}未启用${NC}\n"
        running=0
    fi

    # 时区
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ -z "$tz" ] && tz=$(cat /etc/timezone 2>/dev/null)
    [ -z "$tz" ] && tz=$(date +%Z)
    printf "  当前时区: ${CYAN}%s${NC}\n" "$tz"

    # 当前时间
    printf "  当前时间: ${CYAN}%s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S  %Z %z')"

    # NTP 同步状态 + 偏差
    if [ "$running" -eq 1 ]; then
        leap=$(chronyc tracking 2>/dev/null | awk -F: '/^Leap status/{print $2}' | sed 's/^[[:space:]]*//')
        offset=$(chronyc tracking 2>/dev/null | awk -F: '/^Last offset/{print $2}' | sed 's/^[[:space:]]*//')
        if [ "$leap" = "Normal" ]; then
            if [ -n "$offset" ]; then
                printf "  NTP 状态: ${GREEN}已同步${NC}  (偏差: ${CYAN}%s${NC})\n" "$offset"
            else
                printf "  NTP 状态: ${GREEN}已同步${NC}\n"
            fi
        else
            printf "  NTP 状态: ${YELLOW}未同步${NC}\n"
        fi
    else
        printf "  NTP 状态: ${YELLOW}未运行${NC}\n"
    fi

    printf "${MAGENTA}-------------------------${NC}\n"
}

ntp_install() {
    printf "${BLUE}=== 安装 chrony ===${NC}\n"
    if command -v chronyd >/dev/null 2>&1; then
        log_warn "chrony 已经安装, 跳过"
        return 0
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
    log_info "chrony 安装完成"
}

ntp_uninstall() {
    printf "${BLUE}=== 卸载 chrony ===${NC}\n"
    if ! command -v chronyd >/dev/null 2>&1; then
        log_warn "chrony 未安装, 无需卸载"
        return 0
    fi
    read_input "确认卸载 chrony? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    systemctl stop chrony 2>/dev/null || true
    systemctl disable chrony 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y chrony
    log_info "chrony 已卸载"
}

# 把 NTP_SERVERS_FILE 写入 chrony.conf 的标记块
ntp_apply_servers() {
    if [ ! -f "$CHRONY_CONF" ]; then
        log_warn "$CHRONY_CONF 不存在, 跳过自定义服务器写入"
        return 0
    fi
    # 移除旧的标记块
    if grep -qF "$CHRONY_MARK_BEGIN" "$CHRONY_CONF"; then
        sed -i "/$CHRONY_MARK_BEGIN/,/$CHRONY_MARK_END/d" "$CHRONY_CONF"
    fi
    # 收集自定义服务器
    if [ ! -f "$NTP_SERVERS_FILE" ]; then
        return 0
    fi
    block=""
    while IFS= read -r line; do
        srv=$(printf '%s' "$line" | sed 's/#.*//' | tr -d '[:space:]')
        [ -z "$srv" ] && continue
        block="${block}server ${srv} iburst
"
    done < "$NTP_SERVERS_FILE"

    if [ -n "$block" ]; then
        {
            echo ""
            echo "$CHRONY_MARK_BEGIN"
            printf "%s" "$block"
            echo "$CHRONY_MARK_END"
        } >> "$CHRONY_CONF"
        log_info "已写入自定义 NTP 服务器到 $CHRONY_CONF"
    fi
}

ntp_enable() {
    printf "${BLUE}=== 启用 NTP ===${NC}\n"
    if ! command -v chronyd >/dev/null 2>&1; then
        log_error "chrony 未安装, 请先执行: 2 -> 1 安装"
        return 1
    fi
    ntp_apply_servers
    systemctl enable chrony >/dev/null 2>&1 || true
    systemctl restart chrony
    sleep 1
    if systemctl is-active --quiet chrony; then
        log_info "chrony 服务运行正常"
    else
        log_error "chrony 启动失败, 请检查: systemctl status chrony"
        return 1
    fi
}

ntp_disable() {
    printf "${BLUE}=== 禁用 NTP ===${NC}\n"
    if ! command -v chronyd >/dev/null 2>&1; then
        log_warn "chrony 未安装"
        return 0
    fi
    systemctl stop chrony 2>/dev/null || true
    systemctl disable chrony 2>/dev/null || true
    log_info "chrony 已停止并取消开机自启"
}

ntp_view_detail() {
    printf "${BLUE}=== chrony 详细状态 ===${NC}\n"
    if ! command -v chronyc >/dev/null 2>&1; then
        log_error "chrony 未安装"
        return 1
    fi
    if ! systemctl is-active --quiet chrony 2>/dev/null; then
        log_warn "chrony 服务未运行, 输出可能为空"
    fi
    printf "${CYAN}--- chronyc tracking ---${NC}\n"
    chronyc tracking 2>/dev/null || true
    printf "\n${CYAN}--- chronyc sources -v ---${NC}\n"
    chronyc sources -v 2>/dev/null || true
}

ntp_force_sync() {
    printf "${BLUE}=== 强制同步一次 (chronyc makestep) ===${NC}\n"
    if ! command -v chronyc >/dev/null 2>&1; then
        log_error "chrony 未安装"
        return 1
    fi
    if ! systemctl is-active --quiet chrony 2>/dev/null; then
        log_error "chrony 服务未运行, 请先启用"
        return 1
    fi
    chronyc makestep
    sleep 1
    chronyc tracking 2>/dev/null | head -n 6
}

# --- NTP 服务器 CRUD ---
ntp_servers_view() {
    printf "${BLUE}=== 自定义 NTP 服务器列表 ===${NC}\n"
    if [ ! -f "$NTP_SERVERS_FILE" ] || ! grep -qE '^[^#[:space:]].+' "$NTP_SERVERS_FILE" 2>/dev/null; then
        printf "${YELLOW}  (空, 将使用 chrony 默认 pool)${NC}\n"
        return 0
    fi
    i=0
    while IFS= read -r line; do
        srv=$(printf '%s' "$line" | sed 's/#.*//' | tr -d '[:space:]')
        [ -z "$srv" ] && continue
        i=$((i + 1))
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$srv"
    done < "$NTP_SERVERS_FILE"
}

ntp_servers_add() {
    read_input "请输入要添加的 NTP 服务器 (域名或 IP, 例: time.cloudflare.com; 空值结束)" "" NEW_SRV
    if [ -z "$NEW_SRV" ]; then
        log_warn "结束添加"
        return 1
    fi
    # 简单校验: 不含空格
    case "$NEW_SRV" in
        *' '*) log_error "服务器地址不能包含空格"; return 1 ;;
    esac

    mkdir -p "$(dirname "$NTP_SERVERS_FILE")"
    touch "$NTP_SERVERS_FILE"

    if grep -qxF "$NEW_SRV" "$NTP_SERVERS_FILE" 2>/dev/null; then
        log_warn "服务器已存在: $NEW_SRV"
        return 0
    fi
    echo "$NEW_SRV" >> "$NTP_SERVERS_FILE"
    log_info "已添加: $NEW_SRV"

    if systemctl is-active --quiet chrony 2>/dev/null; then
        log_info "检测到 chrony 正在运行, 自动重新应用配置..."
        ntp_apply_servers
        systemctl restart chrony
    fi
}

ntp_servers_delete() {
    ntp_servers_view
    if [ ! -s "$NTP_SERVERS_FILE" ] 2>/dev/null; then return 1; fi
    read_input "请输入要删除的编号 (空值结束)" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "结束删除"; return 1 ;;
    esac

    target=$(awk '
        {
            line=$0
            sub(/#.*/,"",line)
            gsub(/[[:space:]]/,"",line)
            if (line!="") { i++; if (i==n) { print line; exit } }
        }' n="$NUM" "$NTP_SERVERS_FILE")

    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    tmp="${NTP_SERVERS_FILE}.tmp.$$"
    grep -vxF "$target" "$NTP_SERVERS_FILE" > "$tmp" || true
    mv "$tmp" "$NTP_SERVERS_FILE"
    log_info "已删除: $target"

    if systemctl is-active --quiet chrony 2>/dev/null; then
        log_info "检测到 chrony 正在运行, 自动重新应用配置..."
        ntp_apply_servers
        systemctl restart chrony
    fi
}

ntp_servers_modify() {
    ntp_servers_view
    if [ ! -s "$NTP_SERVERS_FILE" ] 2>/dev/null; then return 0; fi
    read_input "请输入要修改的编号" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "已取消"; return 0 ;;
    esac

    target=$(awk '
        {
            line=$0
            sub(/#.*/,"",line)
            gsub(/[[:space:]]/,"",line)
            if (line!="") { i++; if (i==n) { print line; exit } }
        }' n="$NUM" "$NTP_SERVERS_FILE")

    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    read_input "原服务器: $target ; 输入新值" "" NEW_SRV
    if [ -z "$NEW_SRV" ]; then
        log_warn "未输入, 取消"
        return 0
    fi
    case "$NEW_SRV" in
        *' '*) log_error "服务器地址不能包含空格"; return 1 ;;
    esac

    tmp="${NTP_SERVERS_FILE}.tmp.$$"
    awk -v old="$target" -v new="$NEW_SRV" '
        BEGIN { done=0 }
        {
            line=$0
            tmp=line
            sub(/#.*/,"",tmp)
            gsub(/[[:space:]]/,"",tmp)
            if (!done && tmp==old) { print new; done=1 } else { print line }
        }' "$NTP_SERVERS_FILE" > "$tmp"
    mv "$tmp" "$NTP_SERVERS_FILE"
    log_info "已修改: $target -> $NEW_SRV"

    if systemctl is-active --quiet chrony 2>/dev/null; then
        log_info "检测到 chrony 正在运行, 自动重新应用配置..."
        ntp_apply_servers
        systemctl restart chrony
    fi
}

# ================================================================
# Fail2Ban 模块
# ================================================================
fail2ban_jail_list() {
    fail2ban-client status 2>/dev/null \
        | awk -F: '/Jail list/{print $2}' \
        | sed 's/^[[:space:]]*//' \
        | tr -d ' ' \
        | tr ',' ' '
}

fail2ban_status() {
    printf "${MAGENTA}--- Fail2Ban 状态 ---${NC}\n"
    if command -v fail2ban-server >/dev/null 2>&1; then
        ver=$(fail2ban-server --version 2>/dev/null | head -n 1)
        printf "  安装状态: ${GREEN}已安装${NC}  ${CYAN}%s${NC}\n" "$ver"

        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            printf "  服务状态: ${GREEN}active${NC}\n"

            jails=$(fail2ban_jail_list)
            if [ -n "$jails" ]; then
                printf "  启用监狱: ${CYAN}%s${NC}\n" "$(echo "$jails" | tr ' ' ',')"

                banned_total=0
                for jail in $jails; do
                    cnt=$(fail2ban-client status "$jail" 2>/dev/null | awk -F: '/Currently banned/{print $2}' | tr -d '[:space:]')
                    case "$cnt" in
                        ''|*[!0-9]*) cnt=0 ;;
                    esac
                    banned_total=$((banned_total + cnt))
                done
                printf "  当前监禁数: ${CYAN}%s${NC}\n" "$banned_total"
            fi
        else
            printf "  服务状态: ${YELLOW}inactive${NC}\n"
        fi
    else
        printf "  安装状态: ${RED}未安装${NC}\n"
    fi

    ssh_port=$(get_ssh_port)
    printf "  SSH 端口: ${CYAN}%s${NC}\n" "$ssh_port"

    jail_count=0
    if [ -f "$FAIL2BAN_JAILS_FILE" ]; then
        jail_count=$(grep -cE '^[^#[:space:]].+' "$FAIL2BAN_JAILS_FILE" 2>/dev/null || echo 0)
    fi
    printf "  已配置监狱: ${CYAN}%s${NC}  (${FAIL2BAN_JAILS_FILE})\n" "$jail_count"
    printf "${MAGENTA}---------------------${NC}\n"
}

fail2ban_install() {
    printf "${BLUE}=== 安装 Fail2Ban ===${NC}\n"
    if command -v fail2ban-server >/dev/null 2>&1; then
        log_warn "Fail2Ban 已经安装, 跳过"
        return 0
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban nftables
    if command -v fail2ban-server >/dev/null 2>&1; then
        log_info "Fail2Ban 安装完成"
    else
        log_error "Fail2Ban 安装失败"
        return 1
    fi
}

fail2ban_uninstall() {
    printf "${BLUE}=== 卸载 Fail2Ban ===${NC}\n"
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        log_warn "Fail2Ban 未安装, 无需卸载"
        return 0
    fi
    read_input "确认卸载 Fail2Ban? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y fail2ban
    log_info "Fail2Ban 已卸载"
}

fail2ban_write_config() {
    if [ ! -f "$FAIL2BAN_JAILS_FILE" ] || ! grep -qE '^[^#[:space:]].+' "$FAIL2BAN_JAILS_FILE" 2>/dev/null; then
        log_error "没有配置任何监狱 (jail), 请先 '配置监狱 -> 添加'"
        return 1
    fi

    SSH_PORT=$(get_ssh_port)
    jail_local="/etc/fail2ban/jail.local"
    log_info "生成配置文件: $jail_local (SSH 端口: $SSH_PORT)"

    if [ -f "$jail_local" ]; then
        cp "$jail_local" "${jail_local}.bak.$(date +%s)"
        log_warn "已备份现有 jail.local"
    fi

    {
        cat <<EOF
# Fail2Ban Configuration
# Generated on $(date)

[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
protocol = tcp

EOF

        while IFS= read -r line; do
            case "$line" in
                ''|\#*) continue ;;
            esac
            name=$(printf '%s' "$line"     | cut -d'|' -f1 | tr -d '[:space:]')
            port=$(printf '%s' "$line"     | cut -d'|' -f2 | tr -d '[:space:]')
            maxretry=$(printf '%s' "$line" | cut -d'|' -f3 | tr -d '[:space:]')
            bantime=$(printf '%s' "$line"  | cut -d'|' -f4 | tr -d '[:space:]')

            [ -z "$name" ] && continue
            [ "$port" = "auto" ] && port="$SSH_PORT"

            echo "[$name]"
            echo "enabled = true"

            case "$name" in
                recidive)
                    echo "backend  = auto"
                    echo "logpath  = /var/log/fail2ban.log"
                    echo "protocol = all"
                    [ -n "$maxretry" ] && echo "maxretry = $maxretry"
                    [ -n "$bantime" ]  && echo "bantime  = $bantime"
                    echo "findtime = 1d"
                    ;;
                sshd)
                    echo "port    = $port"
                    echo "mode    = normal"
                    [ -n "$maxretry" ] && echo "maxretry = $maxretry"
                    [ -n "$bantime" ]  && echo "bantime  = $bantime"
                    ;;
                sshd-ddos)
                    echo "port    = $port"
                    echo "filter  = sshd-ddos"
                    [ -n "$maxretry" ] && echo "maxretry = $maxretry"
                    [ -n "$bantime" ]  && echo "bantime  = $bantime"
                    ;;
                *)
                    echo "port    = $port"
                    echo "filter  = $name"
                    [ -n "$maxretry" ] && echo "maxretry = $maxretry"
                    [ -n "$bantime" ]  && echo "bantime  = $bantime"
                    ;;
            esac
            echo ""
        done < "$FAIL2BAN_JAILS_FILE"
    } > "$jail_local"
}

# --- Fail2Ban 监狱 CRUD ---
fail2ban_jail_view() {
    printf "${BLUE}=== 当前已配置监狱 ===${NC}\n"
    if [ ! -f "$FAIL2BAN_JAILS_FILE" ] || ! grep -qE '^[^#[:space:]].+' "$FAIL2BAN_JAILS_FILE" 2>/dev/null; then
        printf "${YELLOW}  (空, 请添加至少一个监狱再启用 Fail2Ban)${NC}\n"
        return 0
    fi
    printf "  ${MAGENTA}%-3s 名称         端口   重试   封禁${NC}\n" "#"
    i=0
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        name=$(printf '%s' "$line"     | cut -d'|' -f1)
        port=$(printf '%s' "$line"     | cut -d'|' -f2)
        mr=$(printf '%s' "$line"       | cut -d'|' -f3)
        bt=$(printf '%s' "$line"       | cut -d'|' -f4)
        i=$((i + 1))
        printf "  ${CYAN}%-3s${NC} %-12s %-6s %-6s %s\n" "$i" "$name" "$port" "$mr" "$bt"
    done < "$FAIL2BAN_JAILS_FILE"
}

fail2ban_jail_add() {
    printf "${BLUE}=== 添加监狱 ===${NC}\n"
    printf "可选监狱类型:\n"
    printf "  ${GREEN}1)${NC} sshd        (SSH 暴力破解防护)\n"
    printf "  ${GREEN}2)${NC} sshd-ddos   (SSH DDoS 防护)\n"
    printf "  ${GREEN}3)${NC} recidive    (惯犯长期封禁)\n"
    printf "  ${GREEN}4)${NC} 自定义\n"
    read_input "请选择类型 (空值/0 结束)" "" TYPE_CHOICE

    case "$TYPE_CHOICE" in
        ''|0) log_warn "结束添加"; return 1 ;;
        1) name="sshd";       def_port="auto"; def_mr="3"; def_bt="2h" ;;
        2) name="sshd-ddos";  def_port="auto"; def_mr="2"; def_bt="4h" ;;
        3) name="recidive";   def_port="all";  def_mr="3"; def_bt="1w" ;;
        4)
            read_input "监狱名 (与 fail2ban filter 同名, 例 nginx-http-auth)" "" name
            if [ -z "$name" ]; then log_warn "已取消"; return 1; fi
            def_port="auto"; def_mr="3"; def_bt="1h"
            ;;
        *) log_warn "无效选项"; return 1 ;;
    esac

    if [ -f "$FAIL2BAN_JAILS_FILE" ] && grep -qE "^${name}\|" "$FAIL2BAN_JAILS_FILE" 2>/dev/null; then
        log_warn "监狱已存在: $name (如需变更请使用 '修改')"
        return 0
    fi

    read_input "端口 (auto=SSH端口, all=全部, 或具体端口号)" "$def_port" port
    read_input "最大重试次数 maxretry" "$def_mr" maxretry
    read_input "封禁时长 bantime (如 2h/1d/1w)" "$def_bt" bantime

    mkdir -p "$(dirname "$FAIL2BAN_JAILS_FILE")"
    touch "$FAIL2BAN_JAILS_FILE"
    echo "${name}|${port}|${maxretry}|${bantime}" >> "$FAIL2BAN_JAILS_FILE"
    log_info "已添加监狱: $name"

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_info "检测到 Fail2Ban 正在运行, 自动重新应用配置..."
        if fail2ban_write_config; then
            systemctl restart fail2ban
        fi
    fi
}

fail2ban_jail_delete() {
    fail2ban_jail_view
    if [ ! -s "$FAIL2BAN_JAILS_FILE" ] 2>/dev/null; then return 1; fi
    read_input "请输入要删除的编号 (空值结束)" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "结束删除"; return 1 ;;
    esac

    target=$(awk -F'|' -v n="$NUM" '
        /^[[:space:]]*#/{next}
        /^[[:space:]]*$/{next}
        {i++; if(i==n){print $1; exit}}
    ' "$FAIL2BAN_JAILS_FILE" | tr -d '[:space:]')

    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    tmp="${FAIL2BAN_JAILS_FILE}.tmp.$$"
    grep -v "^${target}|" "$FAIL2BAN_JAILS_FILE" > "$tmp" || true
    mv "$tmp" "$FAIL2BAN_JAILS_FILE"
    log_info "已删除监狱: $target"

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_info "检测到 Fail2Ban 正在运行, 自动重新应用配置..."
        if grep -qE '^[^#[:space:]].+' "$FAIL2BAN_JAILS_FILE" 2>/dev/null; then
            fail2ban_write_config && systemctl restart fail2ban
        else
            log_warn "已无任何监狱, 停止 Fail2Ban"
            systemctl stop fail2ban
        fi
    fi
}

fail2ban_jail_modify() {
    fail2ban_jail_view
    if [ ! -s "$FAIL2BAN_JAILS_FILE" ] 2>/dev/null; then return 0; fi
    read_input "请输入要修改的编号" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "已取消"; return 0 ;;
    esac

    line=$(awk -v n="$NUM" '
        /^[[:space:]]*#/{next}
        /^[[:space:]]*$/{next}
        {i++; if(i==n){print; exit}}
    ' "$FAIL2BAN_JAILS_FILE")

    if [ -z "$line" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    name=$(printf '%s' "$line" | cut -d'|' -f1)
    port=$(printf '%s' "$line" | cut -d'|' -f2)
    mr=$(printf   '%s' "$line" | cut -d'|' -f3)
    bt=$(printf   '%s' "$line" | cut -d'|' -f4)

    printf "修改监狱: ${CYAN}%s${NC} (回车保留原值)\n" "$name"
    read_input "端口"             "$port" new_port
    read_input "最大重试次数"     "$mr"   new_mr
    read_input "封禁时长"         "$bt"   new_bt

    new_line="${name}|${new_port}|${new_mr}|${new_bt}"

    tmp="${FAIL2BAN_JAILS_FILE}.tmp.$$"
    awk -v old="$line" -v new="$new_line" '
        BEGIN { done=0 }
        {
            if (!done && $0==old) { print new; done=1 } else { print }
        }
    ' "$FAIL2BAN_JAILS_FILE" > "$tmp"
    mv "$tmp" "$FAIL2BAN_JAILS_FILE"
    log_info "已修改: $name"

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_info "检测到 Fail2Ban 正在运行, 自动重新应用配置..."
        fail2ban_write_config && systemctl restart fail2ban
    fi
}

fail2ban_enable() {
    printf "${BLUE}=== 启用 Fail2Ban ===${NC}\n"
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        log_error "Fail2Ban 未安装, 请先执行: 3 -> 1 安装"
        return 1
    fi
    fail2ban_write_config
    systemctl daemon-reload
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    sleep 2
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2Ban 服务运行正常"
    else
        log_error "Fail2Ban 启动失败, 请检查: systemctl status fail2ban"
        return 1
    fi
}

fail2ban_disable() {
    printf "${BLUE}=== 禁用 Fail2Ban ===${NC}\n"
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        log_warn "Fail2Ban 未安装"
        return 0
    fi
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    log_info "Fail2Ban 已停止并取消开机自启"
}

fail2ban_view() {
    printf "${BLUE}=== Fail2Ban 监禁状态 ===${NC}\n"
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_error "Fail2Ban 未安装"
        return 1
    fi
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_warn "Fail2Ban 服务未运行"
        return 0
    fi
    printf "${CYAN}--- fail2ban-client status ---${NC}\n"
    fail2ban-client status 2>/dev/null || true

    jails=$(fail2ban_jail_list)
    for jail in $jails; do
        printf "\n${CYAN}--- jail: %s ---${NC}\n" "$jail"
        fail2ban-client status "$jail" 2>/dev/null || true
    done
}

fail2ban_unban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_error "Fail2Ban 未安装"
        return 1
    fi
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_error "Fail2Ban 服务未运行"
        return 1
    fi
    read_input "请输入要解封的 IP" "" IP
    if [ -z "$IP" ]; then
        log_warn "未输入, 取消"
        return 0
    fi
    # 优先用全局 unban
    if fail2ban-client unban "$IP" 2>/dev/null; then
        log_info "已解封 $IP"
    else
        # 逐个 jail 尝试
        jails=$(fail2ban_jail_list)
        ok=0
        for jail in $jails; do
            if fail2ban-client set "$jail" unbanip "$IP" 2>/dev/null; then
                log_info "[$jail] 已解封 $IP"
                ok=1
            fi
        done
        [ "$ok" -eq 0 ] && log_warn "未在任何监狱中找到 $IP"
    fi
}

# ================================================================
# Sing-Box 模块
# ================================================================
singbox_status() {
    printf "${MAGENTA}--- Sing-Box 状态 ---${NC}\n"
    if command -v sing-box >/dev/null 2>&1; then
        ver=$(sing-box version 2>/dev/null | head -n 1)
        printf "  安装状态: ${GREEN}已安装${NC}  ${CYAN}%s${NC}\n" "$ver"
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            printf "  服务状态: ${GREEN}运行中${NC}\n"
        else
            printf "  服务状态: ${YELLOW}未运行${NC}\n"
        fi
        if [ -f "$SINGBOX_CONFIG" ]; then
            inbound_type=$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$SINGBOX_CONFIG" 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
            [ -n "$inbound_type" ] && printf "  当前协议: ${CYAN}%s${NC}\n" "$inbound_type"
        fi
    else
        printf "  安装状态: ${RED}未安装${NC}\n"
    fi
    printf "${MAGENTA}---------------------${NC}\n"
}

singbox_install() {
    printf "${BLUE}=== 安装 Sing-Box ===${NC}\n"
    if command -v sing-box >/dev/null 2>&1; then
        log_warn "Sing-Box 已经安装, 跳过"
        return 0
    fi
    (
        set -e
        if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
            apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl ca-certificates >/dev/null
        fi
        curl -fsSL https://sing-box.app/install.sh | sh
        if command -v sing-box >/dev/null 2>&1; then
            log_info "Sing-Box 安装成功"
        else
            log_error "Sing-Box 安装失败"
            exit 1
        fi
    )
}

singbox_uninstall() {
    printf "${BLUE}=== 卸载 Sing-Box ===${NC}\n"
    if ! command -v sing-box >/dev/null 2>&1; then
        log_warn "Sing-Box 未安装, 无需卸载"
        return 0
    fi
    read_input "确认卸载 Sing-Box? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service /lib/systemd/system/sing-box.service 2>/dev/null
    systemctl daemon-reload
    rm -f /usr/local/bin/sing-box /usr/bin/sing-box
    rm -rf "$SINGBOX_DIR"
    if command -v sing-box >/dev/null 2>&1; then
        log_error "卸载未完全, 请手动清理"
    else
        log_info "Sing-Box 已卸载"
    fi
}

singbox_restart() {
    log_info "验证并重启 Sing-Box..."
    if ! sing-box check -c "$SINGBOX_CONFIG"; then
        log_error "配置文件格式错误！"
        return 1
    fi
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        log_info "服务启动成功"
    else
        log_error "服务启动失败, 请检查: journalctl -u sing-box"
        return 1
    fi
}

# JSON 字符串字段转义 (反斜杠和双引号)
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 从 X25519 私钥 (base64url) 派生公钥 (base64url)
# 完全使用 openssl, 不依赖任何缓存
derive_x25519_pub_from_priv_b64url() {
    priv_b64url="$1"
    [ -z "$priv_b64url" ] && return 1

    # base64url -> base64 (+padding)
    priv_b64=$(printf '%s' "$priv_b64url" | tr '_-' '/+')
    case $((${#priv_b64} % 4)) in
        2) priv_b64="${priv_b64}==" ;;
        3) priv_b64="${priv_b64}=" ;;
    esac

    # 拼出 PKCS#8 DER (X25519): 16 字节固定前缀 + 32 字节原始私钥
    {
        printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'
        printf '%s' "$priv_b64" | base64 -d
    } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null \
      | tail -c 32 \
      | base64 -w 0 2>/dev/null \
      | tr '/+' '_-' \
      | tr -d '='
}

# 调用 python3 把 config.json 关键字段解析为 shell-safe 的 KEY='value' 行
_singbox_parse_config() {
    if ! command -v python3 >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1
    fi

    python3 - "$SINGBOX_CONFIG" <<'PYEOF'
import json, sys, shlex
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
    ib = (c.get('inbounds') or [{}])[0]
    t = ib.get('type', '')

    def emit(k, v):
        if v is None: v = ''
        print(f'{k}={shlex.quote(str(v))}')

    emit('TYPE', t)
    emit('TAG', ib.get('tag', ''))
    emit('PORT', ib.get('listen_port', ''))

    if t == 'shadowsocks':
        emit('METHOD', ib.get('method', ''))
        emit('PASSWORD', ib.get('password', ''))
    elif t == 'vless':
        u = (ib.get('users') or [{}])[0]
        emit('UUID', u.get('uuid', ''))
        emit('FLOW', u.get('flow', ''))
        tls = ib.get('tls', {})
        emit('SNI', tls.get('server_name', ''))
        r = tls.get('reality', {})
        emit('PRIV_KEY', r.get('private_key', ''))
        sid = r.get('short_id', [])
        emit('SHORT_ID', sid[0] if sid else '')
except Exception as e:
    sys.stderr.write(f'parse error: {e}\n')
    sys.exit(1)
PYEOF
}

singbox_view_link() {
    printf "${BLUE}=== 当前代理链接 ===${NC}\n"
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        log_warn "未配置代理 (config.json 不存在)"
        return 0
    fi

    parsed=$(_singbox_parse_config 2>&1)
    if [ -z "$parsed" ]; then
        log_error "解析 $SINGBOX_CONFIG 失败"
        return 1
    fi

    (
        # parsed 是 shlex.quote 输出, 可安全 eval
        eval "$parsed"

        SERVER_IP=$(get_server_ip)
        [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_IP"
        TAG_ENCODED=$(printf '%s' "$TAG" | sed 's/ /%20/g')

        case "$TYPE" in
            shadowsocks)
                RAW="${METHOD}:${PASSWORD}"
                B64=$(printf '%s' "$RAW" | base64 -w 0)
                LINK="ss://${B64}@${SERVER_IP}:${PORT}#${TAG_ENCODED}"

                printf "${BLUE}========================================================${NC}\n"
                printf "📋 节点信息 (Tag: ${CYAN}%s${NC})  类型: ${CYAN}Shadowsocks-2022${NC}\n" "$TAG"
                printf "${BLUE}========================================================${NC}\n"
                printf "${CYAN}🚀 Shadowsocks 链接 (SIP002):${NC}\n%s\n\n" "$LINK"
                printf "${CYAN}📄 JSON 客户端配置:${NC}\n"
                cat <<EOF
{
    "tag": "${TAG}",
    "type": "shadowsocks",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "method": "${METHOD}",
    "password": "${PASSWORD}"
}
EOF
                printf "${BLUE}========================================================${NC}\n"
                ;;
            vless)
                PUB_KEY=$(derive_x25519_pub_from_priv_b64url "$PRIV_KEY")
                if [ -z "$PUB_KEY" ]; then
                    log_error "无法从 private_key 派生 public_key, 请检查 openssl 是否支持 X25519"
                    return 1
                fi
                LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&fp=chrome&type=tcp&flow=${FLOW}&sni=${SNI}&sid=${SHORT_ID}&spx=%2F#${TAG_ENCODED}"

                printf "${BLUE}========================================================${NC}\n"
                printf "📋 节点信息 (Tag: ${CYAN}%s${NC})  类型: ${CYAN}VLESS + Reality${NC}\n" "$TAG"
                printf "${BLUE}========================================================${NC}\n"
                printf "${CYAN}🚀 VLESS 链接:${NC}\n%s\n\n" "$LINK"
                printf "${CYAN}📄 JSON 配置片段:${NC}\n"
                cat <<EOF
{
    "tag": "${TAG}",
    "type": "vless",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "uuid": "${UUID}",
    "flow": "${FLOW}",
    "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        },
        "reality": {
            "enabled": true,
            "public_key": "${PUB_KEY}",
            "short_id": "${SHORT_ID}"
        }
    }
}
EOF
                printf "${BLUE}========================================================${NC}\n"
                ;;
            *)
                log_warn "未识别协议: ${TYPE:-(空)}"
                printf "${CYAN}--- ${SINGBOX_CONFIG} ---${NC}\n"
                cat "$SINGBOX_CONFIG"
                ;;
        esac
    )
}

singbox_delete_proxy() {
    printf "${BLUE}=== 删除代理 ===${NC}\n"
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        log_warn "当前没有代理配置, 无需删除"
        return 0
    fi
    read_input "确认删除当前代理配置并停止服务? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak.$(date +%s)" 2>/dev/null || true
    rm -f "$SINGBOX_CONFIG"
    log_info "代理已删除 (服务已停止), 原 config.json 已备份"
}

singbox_restart_proxy() {
    printf "${BLUE}=== 重启代理 ===${NC}\n"
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "Sing-Box 未安装"
        return 1
    fi
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        log_error "未配置代理 (config.json 不存在), 请先 '配置代理'"
        return 1
    fi
    singbox_restart
}

singbox_configure_ss2022() {
    printf "${BLUE}=== Sing-Box 配置: Shadowsocks-2022 ===${NC}\n"
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "Sing-Box 未安装, 请先执行: 4 -> 1 安装"
        return 1
    fi

    read_input "节点 TAG" "MySSNode" NODE_TAG

    RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo 20000)
    read_input "监听端口" "$RANDOM_PORT" LISTEN_PORT
    case "$LISTEN_PORT" in
        ''|*[!0-9]*) log_error "端口必须是数字"; return 1 ;;
    esac

    (
        set -e
        PASSWORD=$(openssl rand -base64 32)
        METHOD="2022-blake3-aes-256-gcm"
        TAG_JSON=$(json_escape "$NODE_TAG")

        mkdir -p "$SINGBOX_DIR"
        [ -f "$SINGBOX_CONFIG" ] && cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak.$(date +%s)"

        cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "${TAG_JSON}",
      "listen": "::",
      "listen_port": ${LISTEN_PORT},
      "method": "${METHOD}",
      "password": "${PASSWORD}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

        singbox_restart

        SERVER_IP=$(get_server_ip)
        [ -z "$SERVER_IP" ] && SERVER_IP="YOUR_IP"
        TAG_ENCODED=$(echo "$NODE_TAG" | sed 's/ /%20/g')
        RAW_USER_INFO="${METHOD}:${PASSWORD}"
        BASE64_USER_INFO=$(echo -n "${RAW_USER_INFO}" | base64 -w 0)
        SS_LINK="ss://${BASE64_USER_INFO}@${SERVER_IP}:${LISTEN_PORT}#${TAG_ENCODED}"

        printf "\n${BLUE}========================================================${NC}\n"
        printf "📋 节点信息 (Tag: ${NODE_TAG})\n"
        printf "${BLUE}========================================================${NC}\n"
        printf "${CYAN}🚀 Shadowsocks 链接 (SIP002):${NC}\n%s\n\n" "$SS_LINK"
        printf "${CYAN}📄 JSON 客户端配置:${NC}\n"
        cat <<EOF
{
    "tag": "${NODE_TAG}",
    "type": "shadowsocks",
    "server": "${SERVER_IP}",
    "server_port": ${LISTEN_PORT},
    "method": "${METHOD}",
    "password": "${PASSWORD}"
}
EOF
        printf "${BLUE}========================================================${NC}\n"
    )
}

singbox_configure_vless_reality() {
    printf "${BLUE}=== Sing-Box 配置: VLESS + Reality ===${NC}\n"
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "Sing-Box 未安装, 请先执行: 4 -> 1 安装"
        return 1
    fi

    read_input "节点 TAG" "MyNode" NODE_TAG
    read_input "监听端口" "50443" PORT
    case "$PORT" in
        ''|*[!0-9]*) log_error "端口必须是数字"; return 1 ;;
    esac

    (
        set -e
        get_best_domain

        UUID=$(sing-box generate uuid)
        pair_out=$(sing-box generate reality-keypair)
        PRIV_KEY=$(echo "$pair_out" | grep "PrivateKey" | awk '{print $2}')
        PUB_KEY=$(echo "$pair_out" | grep "PublicKey" | awk '{print $2}')
        SHORT_ID=$(openssl rand -hex 8)
        TAG_JSON=$(json_escape "$NODE_TAG")

        mkdir -p "$SINGBOX_DIR"
        [ -f "$SINGBOX_CONFIG" ] && cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak.$(date +%s)"

        cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "${TAG_JSON}",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${BEST_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${BEST_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${PRIV_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

        singbox_restart

        SERVER_IP=$(get_server_ip)
        [ -z "$SERVER_IP" ] && SERVER_IP="[无法获取IP]"
        TAG_ENCODED=$(echo "$NODE_TAG" | sed 's/ /%20/g')
        VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${BEST_DOMAIN}&sid=${SHORT_ID}&spx=%2F#${TAG_ENCODED}"

        printf "\n${BLUE}========================================================${NC}\n"
        printf "📋 节点信息 (Tag: ${NODE_TAG})\n"
        printf "${BLUE}========================================================${NC}\n"
        printf "${CYAN}🚀 VLESS 链接:${NC}\n%s\n\n" "$VLESS_LINK"
        printf "${CYAN}📄 JSON 配置片段:${NC}\n"
        cat <<EOF
{
    "tag": "${NODE_TAG}",
    "type": "vless",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "uuid": "${UUID}",
    "flow": "xtls-rprx-vision",
    "tls": {
        "enabled": true,
        "server_name": "${BEST_DOMAIN}",
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        },
        "reality": {
            "enabled": true,
            "public_key": "${PUB_KEY}",
            "short_id": "${SHORT_ID}"
        }
    }
}
EOF
        printf "${BLUE}========================================================${NC}\n"
    )
}

# ================================================================
# 防火墙模块
# ================================================================
# --- nft 数据源工具 ---
nft_table_exists() {
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1
}

# 检查我们的 set 是否存在 (table 或 set 缺失都视为 false)
nft_set_exists() {
    nft list set inet "$NFT_TABLE" admin_ip4 >/dev/null 2>&1
}

# 从 live nft 读取我们的白名单 set 元素, 每行一个 IP
nft_get_whitelist() {
    if ! nft_set_exists; then
        return 0
    fi
    nft list set inet "$NFT_TABLE" admin_ip4 2>/dev/null \
        | tr '\n' ' ' \
        | sed -nE 's/.*elements[[:space:]]*=[[:space:]]*\{([^}]*)\}.*/\1/p' \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -E '^[0-9].*'
}

# 创建空的 landing_whitelist 框架 (set+input/forward/output)
nft_init_table() {
    log_info "初始化 table inet $NFT_TABLE..."
    nft -f - <<EOF
table inet $NFT_TABLE {
    set admin_ip4 {
        type ipv4_addr
        flags interval
    }

    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        ip saddr @admin_ip4 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
}

# 把 live ruleset 持久化到 /etc/nftables.conf (包括用户其他 table)
nft_persist() {
    {
        echo "#!/usr/sbin/nft -f"
        echo ""
        echo "flush ruleset"
        echo ""
        nft list ruleset 2>/dev/null
    } > "$NFT_CONF"
    log_info "ruleset 已持久化到 $NFT_CONF"
}

nft_status() {
    printf "${MAGENTA}--- 防火墙 (nft) 状态 ---${NC}\n"

    if command -v nft >/dev/null 2>&1; then
        printf "  安装状态: ${GREEN}已安装${NC}\n"

        if systemctl is-active --quiet nftables 2>/dev/null; then
            printf "  运行状态: ${GREEN}运行中${NC}\n"
        else
            printf "  运行状态: ${YELLOW}未运行${NC}\n"
        fi

        if systemctl is-enabled --quiet nftables 2>/dev/null; then
            printf "  自启状态: ${GREEN}已启用${NC}\n"
        else
            printf "  自启状态: ${YELLOW}未启用${NC}\n"
        fi

        # 总 table 数 (包括用户自己的)
        total_tables=$(nft list ruleset 2>/dev/null | grep -c '^table ')
        [ -z "$total_tables" ] && total_tables=0
        printf "  当前 table 总数: ${CYAN}%s${NC}\n" "$total_tables"

        if nft_table_exists; then
            cnt=$(nft_get_whitelist | grep -c .)
            printf "  本脚本 table: ${GREEN}存在 (inet %s)${NC}\n" "$NFT_TABLE"
            printf "  白名单 IP 数: ${CYAN}%s${NC}\n" "$cnt"
        else
            printf "  本脚本 table: ${YELLOW}不存在 (inet %s)${NC}\n" "$NFT_TABLE"
        fi
    else
        printf "  安装状态: ${RED}未安装${NC}\n"
    fi
    printf "${MAGENTA}-------------------------${NC}\n"
}

nft_install() {
    printf "${BLUE}=== 安装 nftables ===${NC}\n"
    if command -v nft >/dev/null 2>&1; then
        log_warn "nftables 已经安装, 跳过"
        return 0
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
    systemctl enable nftables >/dev/null 2>&1 || true
    log_info "nftables 安装完成"
}

nft_uninstall() {
    printf "${BLUE}=== 卸载 nftables ===${NC}\n"
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "nftables 未安装, 无需卸载"
        return 0
    fi
    read_input "确认卸载 nftables? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    systemctl stop nftables 2>/dev/null || true
    systemctl disable nftables 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y nftables
    log_info "nftables 已卸载"
}

firewall_enable() {
    printf "${BLUE}=== 启用防火墙 ===${NC}\n"
    if ! command -v nft >/dev/null 2>&1; then
        log_error "nftables 未安装, 请先执行: 5 -> 1 安装"
        return 1
    fi

    if ! nft_table_exists; then
        log_warn "table inet $NFT_TABLE 不存在, 即将创建"
        log_warn "⚠️ 创建后 input 默认策略为 drop, 必须在 set 中至少有一个 IP 才能远程访问"
        read_input "确认创建空表? (yes/no)" "no" CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            log_warn "已取消"
            return 0
        fi
        nft_init_table || { log_error "创建失败"; return 1; }
    fi

    # 检查白名单是否为空
    cnt=$(nft_get_whitelist | grep -c .)
    if [ "$cnt" -eq 0 ]; then
        log_warn "⚠️ 白名单 set 为空, 你将无法远程访问! 请立即添加你的 IP"
    fi

    nft_persist
    if ! systemctl enable --now nftables >/dev/null 2>&1; then
        log_error "nftables 服务启动失败, 请检查: systemctl status nftables"
        return 1
    fi
    printf "${GREEN}✅ 防火墙已启用 (白名单 IP 数: %s)${NC}\n" "$cnt"
}

firewall_disable() {
    printf "${BLUE}=== 禁用防火墙 ===${NC}\n"
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "nftables 未安装"
        return 0
    fi
    if nft_table_exists; then
        nft delete table inet "$NFT_TABLE"
        log_info "已移除 table inet ${NFT_TABLE}"
        nft_persist
    else
        log_warn "table inet ${NFT_TABLE} 不存在, 无需禁用"
    fi
}

nft_clear() {
    printf "${BLUE}=== 清空 nft 规则 ===${NC}\n"
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "nftables 未安装"
        return 0
    fi
    log_warn "⚠️ 此操作会清空所有 nft 规则, 包括你手动添加的其他 table"
    read_input "确认清空所有 nftables 规则? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    nft flush ruleset
    : > "$NFT_CONF"
    log_info "已清空 nftables 全部规则"
}

whitelist_view() {
    printf "${BLUE}=== 当前白名单 IP 列表 (从 nft 读取) ===${NC}\n"
    if ! command -v nft >/dev/null 2>&1; then
        log_error "nftables 未安装"
        return 1
    fi
    if ! nft_table_exists; then
        printf "${YELLOW}  (table inet %s 不存在, 添加 IP 时会自动创建)${NC}\n" "$NFT_TABLE"
        return 0
    fi
    ips=$(nft_get_whitelist)
    if [ -z "$ips" ]; then
        printf "${YELLOW}  (空)${NC}\n"
        return 0
    fi
    i=0
    echo "$ips" | while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        i=$((i + 1))
        printf "  ${CYAN}%2d${NC}  %s\n" "$i" "$ip"
    done
}

whitelist_add() {
    if ! command -v nft >/dev/null 2>&1; then
        log_error "nftables 未安装, 请先 '安装 nftables'"
        return 1
    fi
    read_input "请输入要添加的 IPv4 (支持 CIDR, 如 1.2.3.4 或 1.2.3.0/24; 空值结束)" "" NEW_IP
    if [ -z "$NEW_IP" ]; then
        log_warn "结束添加"
        return 1
    fi
    if ! validate_ipv4 "$NEW_IP"; then
        log_error "格式不合法: $NEW_IP"
        return 1
    fi

    if ! nft_table_exists; then
        log_warn "table inet $NFT_TABLE 不存在, 正在创建..."
        nft_init_table || { log_error "创建失败"; return 1; }
    fi

    if nft_get_whitelist | grep -qxF "$NEW_IP"; then
        log_warn "IP 已存在: $NEW_IP"
        return 0
    fi

    if nft add element inet "$NFT_TABLE" admin_ip4 "{ $NEW_IP }" 2>&1; then
        log_info "已添加: $NEW_IP"
        nft_persist
    else
        log_error "添加失败"
        return 1
    fi
}

whitelist_delete() {
    if ! nft_table_exists; then
        log_warn "table inet $NFT_TABLE 不存在"
        return 1
    fi
    whitelist_view
    ips=$(nft_get_whitelist)
    [ -z "$ips" ] && return 1

    read_input "请输入要删除的编号 (空值结束)" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "结束删除"; return 1 ;;
    esac

    target=$(echo "$ips" | sed -n "${NUM}p")
    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    if nft delete element inet "$NFT_TABLE" admin_ip4 "{ $target }" 2>&1; then
        log_info "已删除: $target"
        nft_persist
    else
        log_error "删除失败"
        return 1
    fi

    # 删完后若 set 为空, 给出警告
    new_cnt=$(nft_get_whitelist | grep -c .)
    if [ "$new_cnt" -eq 0 ]; then
        log_warn "⚠️ 白名单已清空, 当前你只能通过 lo 访问. 建议立即添加 IP 或禁用防火墙"
    fi
}

whitelist_modify() {
    if ! nft_table_exists; then
        log_warn "table inet $NFT_TABLE 不存在"
        return 0
    fi
    whitelist_view
    ips=$(nft_get_whitelist)
    [ -z "$ips" ] && return 0

    read_input "请输入要修改的编号" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "已取消"; return 0 ;;
    esac

    target=$(echo "$ips" | sed -n "${NUM}p")
    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    read_input "原 IP: $target ; 输入新 IP" "" NEW_IP
    if [ -z "$NEW_IP" ]; then
        log_warn "未输入, 取消"
        return 0
    fi
    if ! validate_ipv4 "$NEW_IP"; then
        log_error "格式不合法: $NEW_IP"
        return 1
    fi

    if ! nft delete element inet "$NFT_TABLE" admin_ip4 "{ $target }" 2>&1; then
        log_error "删除旧 IP 失败"
        return 1
    fi
    if ! nft add element inet "$NFT_TABLE" admin_ip4 "{ $NEW_IP }" 2>&1; then
        log_error "添加新 IP 失败, 回滚..."
        nft add element inet "$NFT_TABLE" admin_ip4 "{ $target }" 2>/dev/null
        return 1
    fi
    log_info "已修改: $target -> $NEW_IP"
    nft_persist
}

# ================================================================
# TCP 调优模块 (BBR + 系统参数)
# ================================================================
TCP_TUNE_CONF="/etc/sysctl.d/99-bbr-direct-manual.conf"
BBR_PERSIST_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
BBR_PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"
BBR_BUFFER_MAX_MB=128
BBR_BUFFER_MULTIPLIER="2.5"

tcp_status() {
    printf "${MAGENTA}--- TCP 调优状态 ---${NC}\n"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
    wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)

    if [ "$cc" = "bbr" ]; then
        printf "  拥塞控制: ${GREEN}%s${NC}\n" "$cc"
    else
        printf "  拥塞控制: ${YELLOW}%s${NC}\n" "$cc"
    fi
    if [ "$qd" = "fq" ]; then
        printf "  队列算法: ${GREEN}%s${NC}\n" "$qd"
    else
        printf "  队列算法: ${YELLOW}%s${NC}\n" "$qd"
    fi
    [ -n "$rmax" ] && printf "  接收缓冲上限: ${CYAN}%s${NC} bytes\n" "$rmax"
    [ -n "$wmax" ] && printf "  发送缓冲上限: ${CYAN}%s${NC} bytes\n" "$wmax"

    if [ -f "$TCP_TUNE_CONF" ]; then
        printf "  优化配置: ${GREEN}已应用${NC}\n"
        meta=$(grep -E "^# Bandwidth:" "$TCP_TUNE_CONF" 2>/dev/null | head -n 1 | sed 's/^# //')
        [ -n "$meta" ] && printf "  参数: ${CYAN}%s${NC}\n" "$meta"
    else
        printf "  优化配置: ${YELLOW}未应用${NC}\n"
    fi

    if [ -f "$BBR_PERSIST_SERVICE" ] && systemctl is-enabled --quiet bbr-optimize-persist.service 2>/dev/null; then
        printf "  开机持久化: ${GREEN}已启用${NC}\n"
    fi
    printf "${MAGENTA}--------------------${NC}\n"
}

_bbr_choose_bandwidth() {
    printf "${CYAN}请选择服务器带宽:${NC}\n"
    printf "  1.  100  Mbps\n"
    printf "  2.  200  Mbps\n"
    printf "  3.  300  Mbps\n"
    printf "  4.  500  Mbps\n"
    printf "  5.  700  Mbps\n"
    printf "  6.  1000 Mbps / 1 Gbps\n"
    printf "  7.  1500 Mbps / 1.5 Gbps\n"
    printf "  8.  2000 Mbps / 2 Gbps\n"
    printf "  9.  2500 Mbps / 2.5 Gbps\n"
    printf "  10. 自定义\n"
    read_input "请输入选择" "6" CHOICE
    case "$CHOICE" in
        1)  BBR_BANDWIDTH=100 ;;
        2)  BBR_BANDWIDTH=200 ;;
        3)  BBR_BANDWIDTH=300 ;;
        4)  BBR_BANDWIDTH=500 ;;
        5)  BBR_BANDWIDTH=700 ;;
        6)  BBR_BANDWIDTH=1000 ;;
        7)  BBR_BANDWIDTH=1500 ;;
        8)  BBR_BANDWIDTH=2000 ;;
        9)  BBR_BANDWIDTH=2500 ;;
        10) read_input "请输入带宽 (Mbps)" "1000" BBR_BANDWIDTH ;;
        *)  BBR_BANDWIDTH=1000 ;;
    esac
    case "$BBR_BANDWIDTH" in
        ''|*[!0-9]*) log_warn "无效输入, 回退到 1000"; BBR_BANDWIDTH=1000 ;;
    esac
}

_bbr_choose_latency() {
    printf "${CYAN}请选择主要使用延迟/RTT:${NC}\n"
    printf "  1.  30 ms  近距离/同区域\n"
    printf "  2.  50 ms  港/日/新/韩常见\n"
    printf "  3.  80 ms  亚太稍远\n"
    printf "  4. 120 ms  中距离\n"
    printf "  5. 180 ms  跨洋常见\n"
    printf "  6. 250 ms  高延迟线路\n"
    printf "  7. 自定义\n"
    read_input "请输入选择" "2" CHOICE
    case "$CHOICE" in
        1) BBR_LATENCY=30 ;;
        2) BBR_LATENCY=50 ;;
        3) BBR_LATENCY=80 ;;
        4) BBR_LATENCY=120 ;;
        5) BBR_LATENCY=180 ;;
        6) BBR_LATENCY=250 ;;
        7) read_input "请输入延迟 (ms)" "50" BBR_LATENCY ;;
        *) BBR_LATENCY=50 ;;
    esac
    case "$BBR_LATENCY" in
        ''|*[!0-9]*) log_warn "无效输入, 回退到 50"; BBR_LATENCY=50 ;;
    esac
}

_bbr_calc_buffer_mb() {
    awk -v bw="$1" -v rtt="$2" -v mul="$BBR_BUFFER_MULTIPLIER" -v max="$BBR_BUFFER_MAX_MB" '
        BEGIN {
            mb = (bw * rtt * 125 * mul) / 1048576
            if (mb < 4) mb = 4
            if (mb > max) mb = max
            printf "%d\n", int(mb + 0.999)
        }
    '
}

_bbr_clean_sysctl_conf() {
    if [ -f /etc/sysctl.conf ] && [ ! -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi
    if [ -f /etc/sysctl.conf ]; then
        for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.default_qdisc net.ipv4.tcp_congestion_control; do
            sed -i "/^${key}/s/^/# /" /etc/sysctl.conf 2>/dev/null || true
        done
    fi
}

_bbr_check_conflicts() {
    log_info "检查 sysctl 配置冲突..."
    conflicts=""
    for conf in /etc/sysctl.d/[0-9]*-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$TCP_TUNE_CONF" ] && continue
        if grep -qE "(^|[[:space:]])net\.(core\.(rmem_max|wmem_max)|ipv4\.tcp_(rmem|wmem|congestion_control))" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\{1,\}\).*/\1/p')
            if [ -n "$num" ] && [ "$num" -ge 99 ]; then
                if [ -z "$conflicts" ]; then
                    conflicts="$conf"
                else
                    conflicts="${conflicts}
${conf}"
                fi
            fi
        fi
    done

    if [ -z "$conflicts" ]; then
        log_info "未发现可能覆盖本脚本的高优先级配置"
        return 0
    fi

    log_warn "发现可能覆盖本脚本的配置:"
    echo "$conflicts" | sed 's/^/  - /'
    read_input "是否自动禁用这些冲突文件? (yes/no)" "yes" ANS
    case "$ANS" in
        yes|y|Y|YES)
            ts=$(date +%Y%m%d_%H%M%S)
            echo "$conflicts" | while IFS= read -r conf; do
                [ -z "$conf" ] && continue
                mv "$conf" "${conf}.disabled.${ts}" 2>/dev/null || true
            done
            log_info "已禁用冲突文件"
            ;;
        *) log_warn "已跳过, 若配置未生效请手动检查 /etc/sysctl.d/" ;;
    esac
}

_bbr_eligible_ifaces() {
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        echo "$dev"
    done
}

_bbr_apply_tc_fq() {
    if ! command -v tc >/dev/null 2>&1; then
        log_warn "未检测到 tc, 跳过 fq 应用"
        return 0
    fi
    applied=0
    for dev in $(_bbr_eligible_ifaces); do
        if tc qdisc replace dev "$dev" root fq 2>/dev/null; then
            applied=$((applied + 1))
        fi
    done
    log_info "已对 $applied 个网卡应用 fq"
}

_bbr_apply_mss_clamp() {
    if ! command -v iptables >/dev/null 2>&1; then
        log_warn "未检测到 iptables, 跳过 MSS clamp"
        return 0
    fi
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

_bbr_install_persist() {
    cat > "$BBR_PERSIST_SERVICE" <<'EOF'
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
EOF

    cat > "$BBR_PERSIST_SCRIPT" <<'EOF'
#!/bin/sh
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null
done

if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
fi

def_route=$(ip route show default 2>/dev/null | head -1)
if [ -n "$def_route" ]; then
    clean_route=$(echo "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null || true
fi

cpu_count=$(nproc 2>/dev/null || echo 1)
if [ "$cpu_count" -gt 1 ]; then
    rps_mask=$(printf '%x' $((2**cpu_count - 1)))
    flow_entries=$((4096 * cpu_count))
    echo "$flow_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        [ -d "/sys/class/net/$dev/queues" ] || continue
        for rxq in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
            [ -f "$rxq" ] && echo "$rps_mask" > "$rxq" 2>/dev/null || true
        done
        for rxq_dir in /sys/class/net/$dev/queues/rx-*/; do
            [ -f "${rxq_dir}rps_flow_cnt" ] && echo "$((flow_entries / cpu_count))" > "${rxq_dir}rps_flow_cnt" 2>/dev/null || true
        done
    done
fi
EOF

    chmod +x "$BBR_PERSIST_SCRIPT"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable bbr-optimize-persist.service 2>/dev/null || true
}

bbr_apply() {
    printf "${BLUE}=== 应用 BBR / TCP 调优 ===${NC}\n"

    # 内核 BBR 支持检查
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if ! printf '%s' "$available" | grep -qw bbr; then
        log_warn "当前内核未提供 bbr 模块, 尝试 modprobe..."
        modprobe tcp_bbr 2>/dev/null || true
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
        if ! printf '%s' "$available" | grep -qw bbr; then
            log_error "内核不支持 BBR (可用算法: $available)"
            return 1
        fi
    fi

    _bbr_choose_bandwidth
    _bbr_choose_latency

    buffer_mb=$(_bbr_calc_buffer_mb "$BBR_BANDWIDTH" "$BBR_LATENCY")
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    printf "\n${GREEN}将使用以下配置:${NC}\n"
    printf "  带宽:   ${CYAN}%s${NC} Mbps\n" "$BBR_BANDWIDTH"
    printf "  延迟:   ${CYAN}%s${NC} ms\n" "$BBR_LATENCY"
    printf "  缓冲区: ${CYAN}%s${NC} MB\n" "$buffer_mb"
    printf "  计算:   BDP × %s, 上限 %s MB\n" "$BBR_BUFFER_MULTIPLIER" "$BBR_BUFFER_MAX_MB"

    read_input "确认应用? (yes/no)" "yes" CONFIRM
    case "$CONFIRM" in
        yes|y|Y|YES) ;;
        *) log_warn "已取消"; return 0 ;;
    esac

    _bbr_clean_sysctl_conf
    [ -L /etc/sysctl.d/99-sysctl.conf ] && rm -f /etc/sysctl.d/99-sysctl.conf
    _bbr_check_conflicts

    mem_total=$(free -m | awk 'NR==2{print $2}')
    vm_swappiness=5
    vm_dirty_ratio=15
    vm_min_free_kbytes=65536
    if [ "$mem_total" -lt 2048 ] 2>/dev/null; then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi

    cat > "$TCP_TUNE_CONF" <<EOF
# BBR Direct/Endpoint Configuration (Manual Bandwidth/Latency)
# Generated on $(date)
# Bandwidth: ${BBR_BANDWIDTH} Mbps | Latency: ${BBR_LATENCY} ms | Buffer: ${buffer_mb} MB

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}

net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_syncookies=1

vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50

kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    sysctl_output=$(sysctl -p "$TCP_TUNE_CONF" 2>&1 || true)
    if printf '%s' "$sysctl_output" | grep -qiE 'error|invalid|unknown|cannot'; then
        log_warn "sysctl 部分参数可能未生效:"
        printf '%s\n' "$sysctl_output" | grep -iE 'error|invalid|unknown|cannot' | head -n 8
    else
        log_info "sysctl 参数已应用"
    fi

    _bbr_apply_tc_fq
    _bbr_apply_mss_clamp
    _bbr_install_persist

    if ! grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# BBR - 文件描述符优化
* soft nofile 524288
* hard nofile 524288
EOF
    fi
    ulimit -n 524288 2>/dev/null || true

    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi

    def_route=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$def_route" ]; then
        clean_route=$(printf '%s' "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null || true
    fi

    [ -x "$BBR_PERSIST_SCRIPT" ] && "$BBR_PERSIST_SCRIPT" 2>/dev/null || true

    printf "\n${CYAN}--- 验证 ---${NC}\n"
    printf "  队列算法: %s\n" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    printf "  拥塞控制: %s\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf "  发送缓冲: %s bytes\n" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')"
    printf "  接收缓冲: %s bytes\n" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')"
    log_info "BBR / TCP 调优已应用"
}

bbr_remove() {
    printf "${BLUE}=== 移除 BBR / TCP 调优 ===${NC}\n"
    if [ ! -f "$TCP_TUNE_CONF" ] && [ ! -f "$BBR_PERSIST_SERVICE" ]; then
        log_warn "未检测到本脚本的调优配置, 无需移除"
        return 0
    fi
    read_input "确认移除? (yes/no)" "no" CONFIRM
    case "$CONFIRM" in
        yes|y|Y|YES) ;;
        *) log_warn "已取消"; return 0 ;;
    esac

    if [ -f "$TCP_TUNE_CONF" ]; then
        rm -f "$TCP_TUNE_CONF"
        log_info "已删除 $TCP_TUNE_CONF"
    fi
    if [ -f "$BBR_PERSIST_SERVICE" ]; then
        systemctl disable bbr-optimize-persist.service 2>/dev/null || true
        rm -f "$BBR_PERSIST_SERVICE"
        log_info "已移除 $BBR_PERSIST_SERVICE"
    fi
    if [ -f "$BBR_PERSIST_SCRIPT" ]; then
        rm -f "$BBR_PERSIST_SCRIPT"
        log_info "已移除 $BBR_PERSIST_SCRIPT"
    fi

    systemctl daemon-reload 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    log_info "完成. 部分内核参数 (如 tcp_rmem) 可能需要重启才能完全回退"
}

tcp_view_params() {
    printf "${CYAN}--- 当前 TCP / 网络相关参数 ---${NC}\n"
    for k in \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_fastopen \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_keepalive_time \
        net.ipv4.tcp_slow_start_after_idle ; do
        v=$(sysctl -n "$k" 2>/dev/null)
        printf "  %-42s = ${CYAN}%s${NC}\n" "$k" "$v"
    done
    printf "${CYAN}--- 可用拥塞控制算法 ---${NC}\n"
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | sed 's/^/  /'
    printf "${CYAN}--- 各网卡 qdisc ---${NC}\n"
    if command -v tc >/dev/null 2>&1; then
        for dev in $(_bbr_eligible_ifaces); do
            qd=$(tc qdisc show dev "$dev" 2>/dev/null | head -n 1)
            printf "  %-15s : %s\n" "$dev" "$qd"
        done
    fi
}

# ================================================================
# Realm 模块 (TCP/UDP 转发)
# ================================================================
REALM_BIN=""
REALM_CFG=""
REALM_SERVICE=""

# 检测当前 realm 二进制 / 配置 / service, 设置上面 3 个全局变量
realm_detect() {
    REALM_BIN=""
    REALM_CFG=""
    REALM_SERVICE=""

    # 二进制候选 (含用户提到的 /opt/realm)
    for b in /usr/local/bin/realm /usr/bin/realm /opt/realm/realm /etc/realm/realm; do
        if [ -x "$b" ]; then REALM_BIN="$b"; break; fi
    done
    if [ -z "$REALM_BIN" ] && command -v realm >/dev/null 2>&1; then
        REALM_BIN=$(command -v realm)
    fi

    # 配置候选 (按优先级)
    for c in \
        /opt/realm/config.toml \
        /opt/realm/realm.toml \
        /etc/realm/config.toml \
        /etc/realm/realm.toml \
        /opt/realm/config.json \
        /opt/realm/realm.json \
        /etc/realm/config.json \
        /etc/realm/realm.json
    do
        if [ -f "$c" ]; then REALM_CFG="$c"; break; fi
    done

    # service: 先看 loaded units, 再看 unit-files
    unit=$(systemctl list-units 'realm*.service' --all --no-legend 2>/dev/null \
           | awk '/^realm.*\.service/ {print $1; exit}')
    if [ -z "$unit" ]; then
        unit=$(systemctl list-unit-files 'realm*.service' --no-legend 2>/dev/null \
               | awk '/^realm.*\.service/ && $1 != "realm@.service" {print $1; exit}')
    fi
    [ -n "$unit" ] && REALM_SERVICE="$unit"
}

# 解析 TOML 中的 [[endpoints]], 每行输出 "listen|remote"
_realm_parse_endpoints_toml() {
    cfg="$1"
    [ -f "$cfg" ] || return 0
    awk '
        function flush() {
            if (in_ep && (listen != "" || remote != "")) print listen "|" remote
            listen = ""; remote = ""
        }
        /^\[\[endpoints\]\]/ {
            flush(); in_ep = 1; next
        }
        /^\[/ {
            flush(); in_ep = 0; next
        }
        in_ep && /^[[:space:]]*listen[[:space:]]*=/ {
            v = $0
            sub(/^[^"]*"/, "", v)
            sub(/".*$/, "", v)
            listen = v
        }
        in_ep && /^[[:space:]]*remote[[:space:]]*=/ {
            v = $0
            sub(/^[^"]*"/, "", v)
            sub(/".*$/, "", v)
            remote = v
        }
        END { flush() }
    ' "$cfg"
}

realm_parse_endpoints() {
    [ -z "$REALM_CFG" ] && return 0
    case "$REALM_CFG" in
        *.toml) _realm_parse_endpoints_toml "$REALM_CFG" ;;
        *.json)
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$REALM_CFG" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    for ep in (d.get('endpoints') or []):
        print(f"{ep.get('listen','')}|{ep.get('remote','')}")
except Exception:
    sys.exit(1)
PYEOF
            fi
            ;;
    esac
}

realm_status() {
    realm_detect
    printf "${MAGENTA}--- Realm 状态 ---${NC}\n"

    if [ -n "$REALM_BIN" ]; then
        ver=$("$REALM_BIN" -v 2>/dev/null | head -n 1)
        [ -z "$ver" ] && ver=$("$REALM_BIN" --version 2>/dev/null | head -n 1)
        printf "  安装状态: ${GREEN}已安装${NC}  ${CYAN}%s${NC}\n" "$ver"
        printf "  二进制:   ${CYAN}%s${NC}\n" "$REALM_BIN"
    else
        printf "  安装状态: ${RED}未安装${NC}\n"
    fi

    if [ -n "$REALM_CFG" ]; then
        printf "  配置文件: ${CYAN}%s${NC}\n" "$REALM_CFG"
    else
        printf "  配置文件: ${YELLOW}未找到 (/opt/realm 或 /etc/realm)${NC}\n"
    fi

    if [ -n "$REALM_SERVICE" ]; then
        if systemctl is-active --quiet "$REALM_SERVICE" 2>/dev/null; then
            printf "  服务状态: ${GREEN}运行中${NC}  (%s)\n" "$REALM_SERVICE"
        else
            printf "  服务状态: ${YELLOW}未运行${NC}  (%s)\n" "$REALM_SERVICE"
        fi
    else
        printf "  服务状态: ${YELLOW}未找到 service${NC}\n"
    fi

    if [ -n "$REALM_CFG" ]; then
        cnt=$(realm_parse_endpoints | grep -c .)
        printf "  转发规则数: ${CYAN}%s${NC}\n" "$cnt"
    fi
    printf "${MAGENTA}-----------------${NC}\n"
}

realm_install() {
    printf "${BLUE}=== 安装 realm ===${NC}\n"
    realm_detect
    if [ -n "$REALM_BIN" ]; then
        log_warn "realm 已经安装在 $REALM_BIN, 跳过"
        return 0
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  asset="realm-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64|arm64) asset="realm-aarch64-unknown-linux-musl.tar.gz" ;;
        armv7l)        asset="realm-armv7-unknown-linux-musleabihf.tar.gz" ;;
        *) log_error "不支持的架构: $arch"; return 1 ;;
    esac

    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar ca-certificates >/dev/null
    fi

    log_info "获取最新版本 (zhboner/realm)..."
    url=$(curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest 2>/dev/null \
          | grep "browser_download_url" \
          | grep "$asset" \
          | head -n 1 \
          | sed -E 's/.*"(https:[^"]+)".*/\1/')

    if [ -z "$url" ]; then
        log_error "无法获取下载链接, 请检查网络或手动安装"
        return 1
    fi

    tmpdir=$(mktemp -d)
    log_info "下载: $url"
    if ! curl -fsSL -o "$tmpdir/realm.tar.gz" "$url"; then
        log_error "下载失败"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! tar -xzf "$tmpdir/realm.tar.gz" -C "$tmpdir"; then
        log_error "解压失败"
        rm -rf "$tmpdir"
        return 1
    fi

    if [ ! -x "$tmpdir/realm" ]; then
        log_error "解压后未找到 realm 二进制"
        rm -rf "$tmpdir"
        return 1
    fi

    install -m 0755 "$tmpdir/realm" /usr/local/bin/realm
    rm -rf "$tmpdir"
    log_info "已安装到 /usr/local/bin/realm"

    # 默认配置目录与初始 config (用户没有现成 config 时)
    mkdir -p /etc/realm
    if [ ! -f /etc/realm/config.toml ] && [ ! -f /opt/realm/config.toml ]; then
        cat > /etc/realm/config.toml <<'EOF'
[log]
level = "warn"

[network]
no_tcp = false
use_udp = true
EOF
        log_info "已创建初始 /etc/realm/config.toml (无 endpoints, 请添加转发规则)"
    fi

    # systemd service (使用检测到或默认的配置路径)
    realm_detect
    cfg_for_service="${REALM_CFG:-/etc/realm/config.toml}"
    cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/realm -c ${cfg_for_service}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log_info "已写入 /etc/systemd/system/realm.service (Exec: realm -c $cfg_for_service)"
    log_info "完成. 下一步: '配置转发规则 -> 添加', 再 '启用 realm'"
}

realm_uninstall() {
    printf "${BLUE}=== 卸载 realm ===${NC}\n"
    realm_detect
    if [ -z "$REALM_BIN" ] && [ -z "$REALM_SERVICE" ]; then
        log_warn "未检测到 realm 安装"
        return 0
    fi
    read_input "确认卸载 realm? (yes/no)" "no" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi

    if [ -n "$REALM_SERVICE" ]; then
        systemctl stop "$REALM_SERVICE" 2>/dev/null || true
        systemctl disable "$REALM_SERVICE" 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/realm.service /lib/systemd/system/realm.service
    systemctl daemon-reload 2>/dev/null || true

    [ -n "$REALM_BIN" ] && rm -f "$REALM_BIN"
    rm -f /usr/local/bin/realm /usr/bin/realm /opt/realm/realm /etc/realm/realm

    log_info "二进制和 service 已删除. 配置目录 (/opt/realm, /etc/realm) 保留, 如需清理请手动 rm -rf"
}

realm_enable() {
    printf "${BLUE}=== 启用 realm ===${NC}\n"
    realm_detect
    if [ -z "$REALM_BIN" ]; then
        log_error "realm 未安装"
        return 1
    fi
    if [ -z "$REALM_SERVICE" ]; then
        log_error "未找到 realm service, 请重新 '安装 realm'"
        return 1
    fi

    cnt=$(realm_parse_endpoints | grep -c .)
    if [ "$cnt" -eq 0 ]; then
        log_warn "⚠️ 配置中没有转发规则 (endpoints), 启动后没有实际效果"
    fi

    systemctl enable "$REALM_SERVICE" >/dev/null 2>&1
    systemctl restart "$REALM_SERVICE"
    sleep 1
    if systemctl is-active --quiet "$REALM_SERVICE"; then
        log_info "realm 已启用 (规则数: $cnt)"
    else
        log_error "启动失败, 请检查: journalctl -u $REALM_SERVICE"
        return 1
    fi
}

realm_disable() {
    printf "${BLUE}=== 禁用 realm ===${NC}\n"
    realm_detect
    if [ -z "$REALM_SERVICE" ]; then
        log_warn "未找到 realm service"
        return 0
    fi
    systemctl stop "$REALM_SERVICE" 2>/dev/null || true
    systemctl disable "$REALM_SERVICE" 2>/dev/null || true
    log_info "realm 已停止并取消开机自启"
}

realm_restart() {
    printf "${BLUE}=== 重启 realm ===${NC}\n"
    realm_detect
    if [ -z "$REALM_SERVICE" ]; then
        log_error "未找到 realm service"
        return 1
    fi
    systemctl restart "$REALM_SERVICE"
    sleep 1
    if systemctl is-active --quiet "$REALM_SERVICE"; then
        log_info "realm 已重启"
    else
        log_error "重启失败, 请检查: journalctl -u $REALM_SERVICE"
        return 1
    fi
}

realm_view_config() {
    realm_detect
    if [ -z "$REALM_CFG" ] || [ ! -f "$REALM_CFG" ]; then
        log_warn "配置文件不存在"
        return 0
    fi
    printf "${CYAN}--- ${REALM_CFG} ---${NC}\n"
    cat "$REALM_CFG"
    printf "${CYAN}-----------------------------${NC}\n"
}

# --- Realm endpoints CRUD ---
realm_endpoints_view() {
    realm_detect
    printf "${BLUE}=== 当前转发规则 (从 ${REALM_CFG:-?} 读取) ===${NC}\n"
    if [ -z "$REALM_CFG" ] || [ ! -f "$REALM_CFG" ]; then
        printf "${YELLOW}  (配置文件不存在, 请先 '安装 realm')${NC}\n"
        return 0
    fi
    eps=$(realm_parse_endpoints)
    if [ -z "$eps" ]; then
        printf "${YELLOW}  (无转发规则)${NC}\n"
        return 0
    fi
    printf "  ${MAGENTA}%-3s %-24s %s${NC}\n" "#" "listen" "remote"
    i=0
    while IFS='|' read -r listen remote; do
        [ -z "$listen$remote" ] && continue
        i=$((i + 1))
        printf "  ${CYAN}%-3s${NC} %-24s %s\n" "$i" "$listen" "$remote"
    done <<EOF
$eps
EOF
}

# 校验 host:port 简单格式
_validate_hostport() {
    case "$1" in
        *:[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

realm_endpoint_add() {
    realm_detect
    if [ -z "$REALM_CFG" ]; then
        log_error "未找到 realm 配置文件, 请先 '安装 realm'"
        return 1
    fi
    case "$REALM_CFG" in
        *.toml) ;;
        *) log_error "暂只支持 TOML 配置的写入 (当前: $REALM_CFG)"; return 1 ;;
    esac

    read_input "listen 地址 (例: 0.0.0.0:5000; 空值结束)" "" LISTEN
    if [ -z "$LISTEN" ]; then log_warn "结束添加"; return 1; fi
    if ! _validate_hostport "$LISTEN"; then
        log_error "listen 格式错误, 应为 host:port"
        return 1
    fi

    read_input "remote 地址 (例: 1.2.3.4:5000)" "" REMOTE
    if [ -z "$REMOTE" ]; then log_warn "已取消"; return 1; fi
    if ! _validate_hostport "$REMOTE"; then
        log_error "remote 格式错误, 应为 host:port"
        return 1
    fi

    cp "$REALM_CFG" "${REALM_CFG}.bak.$(date +%s)" 2>/dev/null || true
    {
        echo ""
        echo "[[endpoints]]"
        echo "listen = \"$LISTEN\""
        echo "remote = \"$REMOTE\""
    } >> "$REALM_CFG"
    log_info "已添加: $LISTEN -> $REMOTE"

    if [ -n "$REALM_SERVICE" ] && systemctl is-active --quiet "$REALM_SERVICE" 2>/dev/null; then
        log_info "检测到 realm 正在运行, 自动重启..."
        systemctl restart "$REALM_SERVICE"
    fi
}

realm_endpoint_delete() {
    realm_detect
    realm_endpoints_view
    [ -z "$REALM_CFG" ] && return 1
    case "$REALM_CFG" in
        *.toml) ;;
        *) log_error "暂只支持 TOML 配置的写入"; return 1 ;;
    esac

    eps=$(realm_parse_endpoints)
    [ -z "$eps" ] && return 1

    read_input "请输入要删除的编号 (空值结束)" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "结束删除"; return 1 ;;
    esac

    target=$(echo "$eps" | sed -n "${NUM}p")
    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    cp "$REALM_CFG" "${REALM_CFG}.bak.$(date +%s)" 2>/dev/null || true

    tmp="${REALM_CFG}.tmp.$$"
    awk -v target_idx="$NUM" '
        BEGIN { ep_count = 0; skip = 0 }
        /^\[\[endpoints\]\]/ {
            ep_count++
            if (ep_count == target_idx) { skip = 1; next }
            skip = 0
            print
            next
        }
        /^\[/ {
            skip = 0
            print
            next
        }
        skip { next }
        { print }
    ' "$REALM_CFG" > "$tmp" && mv "$tmp" "$REALM_CFG"

    listen=$(printf '%s' "$target" | cut -d'|' -f1)
    remote=$(printf '%s' "$target" | cut -d'|' -f2)
    log_info "已删除: $listen -> $remote"

    if [ -n "$REALM_SERVICE" ] && systemctl is-active --quiet "$REALM_SERVICE" 2>/dev/null; then
        log_info "检测到 realm 正在运行, 自动重启..."
        systemctl restart "$REALM_SERVICE"
    fi
}

realm_endpoint_modify() {
    realm_detect
    realm_endpoints_view
    [ -z "$REALM_CFG" ] && return 1
    case "$REALM_CFG" in
        *.toml) ;;
        *) log_error "暂只支持 TOML 配置的写入"; return 1 ;;
    esac

    eps=$(realm_parse_endpoints)
    [ -z "$eps" ] && return 0

    read_input "请输入要修改的编号" "" NUM
    case "$NUM" in
        ''|*[!0-9]*) log_warn "已取消"; return 0 ;;
    esac

    target=$(echo "$eps" | sed -n "${NUM}p")
    if [ -z "$target" ]; then
        log_error "编号无效: $NUM"
        return 1
    fi

    old_listen=$(printf '%s' "$target" | cut -d'|' -f1)
    old_remote=$(printf '%s' "$target" | cut -d'|' -f2)

    read_input "listen" "$old_listen" NEW_LISTEN
    read_input "remote" "$old_remote" NEW_REMOTE

    if ! _validate_hostport "$NEW_LISTEN"; then
        log_error "listen 格式错误"
        return 1
    fi
    if ! _validate_hostport "$NEW_REMOTE"; then
        log_error "remote 格式错误"
        return 1
    fi

    cp "$REALM_CFG" "${REALM_CFG}.bak.$(date +%s)" 2>/dev/null || true

    tmp="${REALM_CFG}.tmp.$$"
    awk -v target_idx="$NUM" -v nl="$NEW_LISTEN" -v nr="$NEW_REMOTE" '
        BEGIN { ep_count = 0; in_ep = 0 }
        /^\[\[endpoints\]\]/ {
            ep_count++
            in_ep = (ep_count == target_idx)
            print
            next
        }
        /^\[/ {
            in_ep = 0
            print
            next
        }
        in_ep && /^[[:space:]]*listen[[:space:]]*=/ {
            print "listen = \"" nl "\""
            next
        }
        in_ep && /^[[:space:]]*remote[[:space:]]*=/ {
            print "remote = \"" nr "\""
            next
        }
        { print }
    ' "$REALM_CFG" > "$tmp" && mv "$tmp" "$REALM_CFG"

    log_info "已修改: $old_listen -> $old_remote  ==>  $NEW_LISTEN -> $NEW_REMOTE"

    if [ -n "$REALM_SERVICE" ] && systemctl is-active --quiet "$REALM_SERVICE" 2>/dev/null; then
        log_info "检测到 realm 正在运行, 自动重启..."
        systemctl restart "$REALM_SERVICE"
    fi
}

# ================================================================
# 系统重装 (reinstall.sh) 任务
# ================================================================
task_system_reinstall() {
    printf "${RED}========================================================${NC}\n"
    printf "${RED}            系统重装 (DD)  -  ⚠️  高危操作${NC}\n"
    printf "${RED}========================================================${NC}\n"

    cur_sys=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
    printf "${YELLOW}当前系统:${NC} %s\n" "$cur_sys"
    printf "${RED}⚠️  执行后所有数据将丢失, 重启后变为新系统!${NC}\n\n"

    printf "${CYAN}可选系统:${NC}\n"
    printf "  ${GREEN}1)${NC}  debian       9 / 10 / 11 / 12 / 13\n"
    printf "  ${GREEN}2)${NC}  ubuntu       18.04 / 20.04 / 22.04 / 24.04 / 26.04  [--minimal]\n"
    printf "  ${GREEN}3)${NC}  centos       9 / 10\n"
    printf "  ${GREEN}4)${NC}  rocky        8 / 9 / 10\n"
    printf "  ${GREEN}5)${NC}  almalinux    8 / 9 / 10\n"
    printf "  ${GREEN}6)${NC}  oracle       8 / 9 / 10\n"
    printf "  ${GREEN}7)${NC}  fedora       43 / 44\n"
    printf "  ${GREEN}8)${NC}  anolis       7 / 8 / 23\n"
    printf "  ${GREEN}9)${NC}  opencloudos  8 / 9 / 23\n"
    printf "  ${GREEN}10)${NC} openeuler    20.03 / 22.03 / 24.03\n"
    printf "  ${GREEN}11)${NC} alpine       3.20 / 3.21 / 3.22 / 3.23\n"
    printf "  ${GREEN}12)${NC} opensuse     16.0 / tumbleweed\n"
    printf "  ${GREEN}13)${NC} nixos        25.11\n"
    printf "  ${GREEN}14)${NC} fnos         1\n"
    printf "  ${GREEN}15)${NC} arch         (无版本)\n"
    printf "  ${GREEN}16)${NC} kali         (无版本)\n"
    printf "  ${GREEN}17)${NC} gentoo       (无版本)\n"
    printf "  ${GREEN}18)${NC} aosc         (无版本)\n"
    printf "  ${GREEN}19)${NC} redhat       (需要 qcow2 镜像 URL)\n"

    read_input "请选择系统编号" "" SYS_CHOICE
    if [ -z "$SYS_CHOICE" ]; then log_warn "已取消"; return 0; fi

    versions=""
    default_v=""
    case "$SYS_CHOICE" in
        1)  system="debian";      versions="9 10 11 12 13";                default_v="13" ;;
        2)  system="ubuntu";      versions="18.04 20.04 22.04 24.04 26.04"; default_v="24.04" ;;
        3)  system="centos";      versions="9 10";                          default_v="10" ;;
        4)  system="rocky";       versions="8 9 10";                        default_v="10" ;;
        5)  system="almalinux";   versions="8 9 10";                        default_v="10" ;;
        6)  system="oracle";      versions="8 9 10";                        default_v="10" ;;
        7)  system="fedora";      versions="43 44";                         default_v="44" ;;
        8)  system="anolis";      versions="7 8 23";                        default_v="23" ;;
        9)  system="opencloudos"; versions="8 9 23";                        default_v="23" ;;
        10) system="openeuler";   versions="20.03 22.03 24.03";             default_v="24.03" ;;
        11) system="alpine";      versions="3.20 3.21 3.22 3.23";           default_v="3.23" ;;
        12) system="opensuse";    versions="16.0 tumbleweed";               default_v="tumbleweed" ;;
        13) system="nixos";       versions="25.11";                         default_v="25.11" ;;
        14) system="fnos";        versions="1";                             default_v="1" ;;
        15) system="arch" ;;
        16) system="kali" ;;
        17) system="gentoo" ;;
        18) system="aosc" ;;
        19) system="redhat" ;;
        *)  log_error "无效选项"; return 1 ;;
    esac

    # 处理版本 / 额外参数
    VERSION=""
    EXTRA_ARG=""
    if [ "$system" = "redhat" ]; then
        read_input "请输入 RedHat qcow2 镜像 URL" "" IMG_URL
        if [ -z "$IMG_URL" ]; then log_warn "已取消"; return 0; fi
        EXTRA_ARG="--img=$IMG_URL"
    elif [ -n "$versions" ]; then
        printf "${CYAN}可用版本: %s${NC}\n" "$versions"
        read_input "请选择版本" "$default_v" VERSION
        # 校验是否在列表内 (不强制)
        match=0
        for v in $versions; do
            [ "$v" = "$VERSION" ] && match=1 && break
        done
        if [ "$match" -eq 0 ]; then
            log_warn "版本 '$VERSION' 不在推荐列表 ($versions), 仍将继续"
        fi
    fi

    # Ubuntu 的 --minimal
    if [ "$system" = "ubuntu" ]; then
        read_input "是否使用 minimal 镜像? (yes/no)" "no" UBU_MIN
        case "$UBU_MIN" in
            yes|y|Y|YES) EXTRA_ARG="--minimal" ;;
        esac
    fi

    # SSH 端口
    cur_port=$(get_ssh_port)
    read_input "新系统 SSH 端口" "$cur_port" SSH_PORT
    case "$SSH_PORT" in
        ''|*[!0-9]*) log_error "端口必须是数字"; return 1 ;;
    esac

    # SSH 公钥
    printf "${CYAN}请输入 SSH 公钥 (一行完整 ssh-rsa / ssh-ed25519 ...), 留空使用 /root/.ssh/authorized_keys 第一行:${NC}\n"
    read_tty SSH_KEY

    if [ -z "$SSH_KEY" ]; then
        if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
            SSH_KEY=$(head -n 1 /root/.ssh/authorized_keys)
            log_info "使用 /root/.ssh/authorized_keys 第一行作为公钥"
        else
            log_error "未提供 SSH 公钥且无 /root/.ssh/authorized_keys, 重装后将无法登录"
            return 1
        fi
    fi

    # 摘要
    printf "\n${BLUE}=== 重装摘要 ===${NC}\n"
    printf "  系统:     ${CYAN}%s${NC}\n" "$system"
    [ -n "$VERSION" ]   && printf "  版本:     ${CYAN}%s${NC}\n" "$VERSION"
    [ -n "$EXTRA_ARG" ] && printf "  额外参数: ${CYAN}%s${NC}\n" "$EXTRA_ARG"
    printf "  SSH 端口: ${CYAN}%s${NC}\n" "$SSH_PORT"
    key_preview=$(printf '%s' "$SSH_KEY" | cut -c1-50)
    printf "  SSH 公钥: ${CYAN}%s...${NC} (长度: %s)\n" "$key_preview" "${#SSH_KEY}"

    printf "\n${RED}⚠️  即将执行系统重装. 本次 SSH 会话稍后会断开, 几分钟后机器以新系统启动.${NC}\n"
    read_input "确认执行重装? (y/n)" "n" CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *) log_warn "已取消"; return 0 ;;
    esac

    # 下载 reinstall.sh
    workdir=$(mktemp -d)
    cd "$workdir" || { log_error "无法切换到临时目录"; return 1; }
    log_info "下载 reinstall.sh..."
    if ! curl -fsSL -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh; then
        if ! wget -q -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh; then
            log_error "下载 reinstall.sh 失败 (curl & wget 均失败)"
            return 1
        fi
    fi

    # 构造并执行
    log_info "执行 reinstall.sh..."
    if [ -n "$VERSION" ] && [ -n "$EXTRA_ARG" ]; then
        log_info "命令: bash reinstall.sh $system $VERSION $EXTRA_ARG --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" "$VERSION" "$EXTRA_ARG" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    elif [ -n "$VERSION" ]; then
        log_info "命令: bash reinstall.sh $system $VERSION --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" "$VERSION" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    elif [ -n "$EXTRA_ARG" ]; then
        log_info "命令: bash reinstall.sh $system $EXTRA_ARG --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" "$EXTRA_ARG" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    else
        log_info "命令: bash reinstall.sh $system --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    fi

    ret=$?
    if [ "$ret" -eq 0 ]; then
        log_info "reinstall.sh 执行完成. 按提示重启系统以完成 DD"
        log_warn "重启命令: reboot"
    else
        log_error "reinstall.sh 返回非零退出码: $ret"
    fi
}

# ================================================================
# 子菜单: NTP 服务器 (增删改查)
# ================================================================
menu_ntp_servers() {
    menu_crud ntp_servers_view ntp_servers_add ntp_servers_delete ntp_servers_modify
}

# ================================================================
# 子菜单: NTP
# ================================================================
menu_ntp() {
    while true; do
        printf "\n${BLUE}========== NTP (chrony) 配置 ==========${NC}\n"
        ntp_status
        printf "  ${GREEN}1)${NC}  安装 chrony\n"
        printf "  ${GREEN}2)${NC}  卸载 chrony\n"
        printf "  ${GREEN}3)${NC}  启用 NTP\n"
        printf "  ${GREEN}4)${NC}  禁用 NTP\n"
        printf "  ${GREEN}5)${NC}  查看详细状态\n"
        printf "  ${GREEN}6)${NC}  配置 NTP 服务器 (增删改查) ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}7)${NC}  强制同步一次\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    ntp_install; press_to_continue ;;
            2)    ntp_uninstall; press_to_continue ;;
            3)    ntp_enable; press_to_continue ;;
            4)    ntp_disable; press_to_continue ;;
            5)    ntp_view_detail; press_to_continue ;;
            6)    menu_ntp_servers; _r=$?; [ "$_r" -eq 99 ] && return 99 ;;
            7)    ntp_force_sync; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 子菜单: Fail2Ban 监狱 (增删改查)
# ================================================================
menu_fail2ban_jails() {
    menu_crud fail2ban_jail_view fail2ban_jail_add fail2ban_jail_delete fail2ban_jail_modify
}

# ================================================================
# 子菜单: Fail2Ban
# ================================================================
menu_fail2ban() {
    while true; do
        printf "\n${BLUE}========== Fail2Ban 配置 ==========${NC}\n"
        fail2ban_status
        printf "  ${GREEN}1)${NC}  安装 Fail2Ban\n"
        printf "  ${GREEN}2)${NC}  卸载 Fail2Ban\n"
        printf "  ${GREEN}3)${NC}  启用 Fail2Ban (读取监狱配置并启动)\n"
        printf "  ${GREEN}4)${NC}  禁用 Fail2Ban\n"
        printf "  ${GREEN}5)${NC}  配置监狱 (增删改查) ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}6)${NC}  查看监禁状态\n"
        printf "  ${GREEN}7)${NC}  解封 IP\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    fail2ban_install; press_to_continue ;;
            2)    fail2ban_uninstall; press_to_continue ;;
            3)    fail2ban_enable; press_to_continue ;;
            4)    fail2ban_disable; press_to_continue ;;
            5)    menu_fail2ban_jails; _r=$?; [ "$_r" -eq 99 ] && return 99 ;;
            6)    fail2ban_view; press_to_continue ;;
            7)    fail2ban_unban; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 子菜单: Sing-Box 配置代理
# ================================================================
menu_singbox_proxy() {
    while true; do
        printf "\n${BLUE}====== Sing-Box 配置代理 ======${NC}\n"
        printf "  ${GREEN}1)${NC}  Shadowsocks-2022\n"
        printf "  ${GREEN}2)${NC}  VLESS + Reality\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    singbox_configure_ss2022; press_to_continue ;;
            2)    singbox_configure_vless_reality; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 子菜单: Sing-Box
# ================================================================
menu_singbox() {
    while true; do
        printf "\n${BLUE}========== Sing-Box 配置 ==========${NC}\n"
        singbox_status
        printf "  ${GREEN}1)${NC}  安装 Sing-Box\n"
        printf "  ${GREEN}2)${NC}  卸载 Sing-Box\n"
        printf "  ${GREEN}3)${NC}  配置代理 ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}4)${NC}  查看代理链接\n"
        printf "  ${GREEN}5)${NC}  删除代理\n"
        printf "  ${GREEN}6)${NC}  重启代理\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    singbox_install; press_to_continue ;;
            2)    singbox_uninstall; press_to_continue ;;
            3)    menu_singbox_proxy; _r=$?; [ "$_r" -eq 99 ] && return 99 ;;
            4)    singbox_view_link; press_to_continue ;;
            5)    singbox_delete_proxy; press_to_continue ;;
            6)    singbox_restart_proxy; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 子菜单: 入站 IP 配置 (增删改查)
# ================================================================
menu_firewall_ip() {
    menu_crud whitelist_view whitelist_add whitelist_delete whitelist_modify
}

# ================================================================
# 子菜单: 防火墙
# ================================================================
menu_firewall() {
    while true; do
        printf "\n${BLUE}========== 防火墙配置 ==========${NC}\n"
        nft_status
        printf "  ${GREEN}1)${NC}  安装 nftables\n"
        printf "  ${GREEN}2)${NC}  卸载 nftables\n"
        printf "  ${GREEN}3)${NC}  启用防火墙\n"
        printf "  ${GREEN}4)${NC}  禁用防火墙\n"
        printf "  ${GREEN}5)${NC}  配置入站 IP (增删改查) ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}6)${NC}  查看入站 IP\n"
        printf "  ${GREEN}7)${NC}  清空 nft\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    nft_install; press_to_continue ;;
            2)    nft_uninstall; press_to_continue ;;
            3)    firewall_enable; press_to_continue ;;
            4)    firewall_disable; press_to_continue ;;
            5)    menu_firewall_ip; _r=$?; [ "$_r" -eq 99 ] && return 99 ;;
            6)    whitelist_view; press_to_continue ;;
            7)    nft_clear; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 主菜单
# ================================================================
# ================================================================
# 子菜单: Realm 转发规则 (增删改查)
# ================================================================
menu_realm_endpoints() {
    menu_crud realm_endpoints_view realm_endpoint_add realm_endpoint_delete realm_endpoint_modify
}

# ================================================================
# 子菜单: Realm
# ================================================================
menu_realm() {
    while true; do
        printf "\n${BLUE}========== Realm 配置 ==========${NC}\n"
        realm_status
        printf "  ${GREEN}1)${NC}  安装 realm\n"
        printf "  ${GREEN}2)${NC}  卸载 realm\n"
        printf "  ${GREEN}3)${NC}  启用 realm\n"
        printf "  ${GREEN}4)${NC}  禁用 realm\n"
        printf "  ${GREEN}5)${NC}  重启 realm\n"
        printf "  ${GREEN}6)${NC}  配置转发规则 (增删改查) ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}7)${NC}  查看完整配置\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    realm_install; press_to_continue ;;
            2)    realm_uninstall; press_to_continue ;;
            3)    realm_enable; press_to_continue ;;
            4)    realm_disable; press_to_continue ;;
            5)    realm_restart; press_to_continue ;;
            6)    menu_realm_endpoints; _r=$?; [ "$_r" -eq 99 ] && return 99 ;;
            7)    realm_view_config; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# ================================================================
# 子菜单: TCP 调优
# ================================================================
menu_tcp_tune() {
    while true; do
        printf "\n${BLUE}========== TCP 调优 (BBR) ==========${NC}\n"
        tcp_status
        printf "  ${GREEN}1)${NC}  应用 BBR 优化 (按带宽+延迟自动计算缓冲)\n"
        printf "  ${GREEN}2)${NC}  移除 BBR 优化\n"
        printf "  ${GREEN}3)${NC}  查看当前 TCP 参数\n"
        print_submenu_footer
        prompt_choice

        case "$choice" in
            1)    bbr_apply; press_to_continue ;;
            2)    bbr_remove; press_to_continue ;;
            3)    tcp_view_params; press_to_continue ;;
            '')   return 0 ;;
            m|M)  return 99 ;;
            q|Q)  exit 0 ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

menu_main() {
    while true; do
        clear 2>/dev/null || printf "\n\n"
        printf "${BLUE}========================================================${NC}\n"
        printf "${BLUE}      Debian/Ubuntu VPS 一键配置脚本 (主菜单)${NC}\n"
        printf "${BLUE}========================================================${NC}\n"
        printf "  ${GREEN}1)${NC}  安装常用软件\n"
        printf "  ${GREEN}2)${NC}  配置 NTP ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}3)${NC}  Fail2Ban ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}4)${NC}  Sing-Box 配置 ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}5)${NC}  防火墙配置 ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}6)${NC}  TCP 调优 ${MAGENTA}>${NC}\n"
        printf "  ${GREEN}7)${NC}  Realm 配置 ${MAGENTA}>${NC}\n"
        printf "  ${RED}8)${NC}  系统重装 (DD) ${RED}⚠${NC}\n"
        printf "  ${RED}q)${NC}  退出脚本\n"
        printf "${BLUE}========================================================${NC}\n"
        prompt_choice "请输入选项: "

        case "$choice" in
            1)    task_install_common; press_to_continue ;;
            2)    menu_ntp ;;
            3)    menu_fail2ban ;;
            4)    menu_singbox ;;
            5)    menu_firewall ;;
            6)    menu_tcp_tune ;;
            7)    menu_realm ;;
            8)    task_system_reinstall; press_to_continue ;;
            q|Q)  printf "${GREEN}再见!${NC}\n"; exit 0 ;;
            ''|m|M) ;;
            *)    log_warn "无效选项: $choice"; press_to_continue ;;
        esac
    done
}

# --- 入口 ---
check_root
menu_main
