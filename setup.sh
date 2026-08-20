#!/bin/sh

# ================================================================
# Linux VPS 一键配置脚本 (多发行版自动识别 / 单键菜单版)
# 支持: Debian/Ubuntu (apt) · RHEL/CentOS/Rocky/AlmaLinux/Fedora (dnf/yum)
#       Arch (pacman) · Alpine (apk) · openSUSE (zypper)
# 交互: 单键直达 (按键立即生效, 无需回车)
#   0/ESC 返回上层 · m 直回主菜单 · q 随处退出
#   主菜单为仪表盘, 实时显示各模块状态 (● 运行中 / ○ 未安装)
# 模块:
#   1 安装常用软件      2 NTP 时间同步     3 Fail2Ban
#   4 Sing-Box (SS2022/VLESS-Reality/AnyTLS+ACME)  5 防火墙(nftables)  6 TCP 调优(BBR)
#   7 Realm 转发        8 Cloudflare DDNS  9 SSH 配置
#   c ACME 证书 (Let's Encrypt, 独立模块, 任何服务都可引用)
#   d 系统重装 (DD)
# 用法: sudo sh setup.sh
# ================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'
ESC_CH=$(printf '\033')

# --- 日志辅助函数 ---
log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# --- 全局常量 ---
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_DIR="/etc/sing-box"
ACME_CERT_DIR="/etc/ssl/acme"
NFT_CONF="/etc/nftables.conf"
NFT_TABLE="landing_whitelist"
NFT_WL_FILE="/etc/landing_whitelist.conf"
NTP_SERVERS_FILE="/etc/ntp_servers.conf"
CHRONY_CONF="/etc/chrony/chrony.conf"
CHRONY_MARK_BEGIN="# === BEGIN setup.sh CUSTOM SOURCES ==="
CHRONY_MARK_END="# === END setup.sh CUSTOM SOURCES ==="
FAIL2BAN_JAILS_FILE="/etc/fail2ban_jails.conf"
DDNS_SCRIPT="/root/ddns.sh"
DDNS_TOKEN_FILE="/root/.cf_token"
DDNS_ZONE_FILE="/root/.cf_zone"
DDNS_LOG="/var/log/ddns.log"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-setup-script.conf"
AUTH_KEYS_FILE="/root/.ssh/authorized_keys"

# ================================================================
# 发行版检测 / 包管理抽象
# ================================================================
OS_ID=""
OS_PRETTY=""
OS_FAMILY=""
PKG_MGR=""
CHRONY_SERVICE="chrony"

detect_os() {
    OS_ID=""
    OS_PRETTY=""
    os_like=""
    if [ -r /etc/os-release ]; then
        OS_ID=$(. /etc/os-release 2>/dev/null; printf '%s' "$ID")
        OS_PRETTY=$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")
        os_like=$(. /etc/os-release 2>/dev/null; printf '%s' "$ID_LIKE")
    fi

    case "$OS_ID" in
        debian|ubuntu|devuan|kali|raspbian|linuxmint|pop|deepin|zorin)
            OS_FAMILY="debian" ;;
        rhel|centos|rocky|almalinux|fedora|ol|oracle|anolis|opencloudos|openeuler|amzn|tencentos)
            OS_FAMILY="rhel" ;;
        arch|manjaro|endeavouros|cachyos)
            OS_FAMILY="arch" ;;
        alpine)
            OS_FAMILY="alpine" ;;
        opensuse*|sles|sled|suse)
            OS_FAMILY="suse" ;;
        *)
            case " $os_like " in
                *debian*|*ubuntu*)        OS_FAMILY="debian" ;;
                *rhel*|*fedora*|*centos*) OS_FAMILY="rhel" ;;
                *arch*)                   OS_FAMILY="arch" ;;
                *suse*)                   OS_FAMILY="suse" ;;
                *alpine*)                 OS_FAMILY="alpine" ;;
                *)                        OS_FAMILY="unknown" ;;
            esac ;;
    esac

    if   command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MGR="yum"
    elif command -v pacman  >/dev/null 2>&1; then PKG_MGR="pacman"
    elif command -v apk     >/dev/null 2>&1; then PKG_MGR="apk"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MGR="zypper"
    else PKG_MGR=""
    fi
}

# 刷新软件源 (dnf/yum 安装时自动刷新, 无需单独执行)
pkg_update() {
    case "$PKG_MGR" in
        apt)     apt-get update -qq ;;
        pacman)  pacman -Sy --noconfirm >/dev/null 2>&1 || true ;;
        apk)     apk update >/dev/null 2>&1 || true ;;
        zypper)  zypper --non-interactive refresh >/dev/null 2>&1 || true ;;
        dnf|yum) : ;;
        *) log_error "未检测到受支持的包管理器"; return 1 ;;
    esac
}

# 安装一个或多个软件包
pkg_install() {
    [ "$#" -gt 0 ] || return 0
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        apk)    apk add "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        *) log_error "未检测到受支持的包管理器, 无法安装: $*"; return 1 ;;
    esac
}

# 卸载一个或多个软件包
pkg_remove() {
    [ "$#" -gt 0 ] || return 0
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$@" ;;
        dnf)    dnf remove -y "$@" ;;
        yum)    yum remove -y "$@" ;;
        pacman) pacman -Rns --noconfirm "$@" ;;
        apk)    apk del "$@" ;;
        zypper) zypper --non-interactive remove "$@" ;;
        *) log_error "未检测到受支持的包管理器"; return 1 ;;
    esac
}

# RHEL 系: 确保 EPEL 仓库可用 (fail2ban 等位于 EPEL)
ensure_epel() {
    [ "$OS_FAMILY" = "rhel" ] || return 0
    [ "$OS_ID" = "fedora" ] && return 0
    if rpm -q epel-release >/dev/null 2>&1; then
        return 0
    fi
    log_info "启用 EPEL 仓库..."
    case "$OS_ID" in
        ol|oracle)
            elv=$(rpm -E %rhel 2>/dev/null)
            pkg_install "oracle-epel-release-el${elv}" || pkg_install epel-release || true
            ;;
        *)
            pkg_install epel-release || true
            ;;
    esac
}

# 解析 chrony 的配置文件路径与 systemd 服务名 (各发行版不同)
resolve_chrony() {
    if [ -f /etc/chrony/chrony.conf ]; then
        CHRONY_CONF="/etc/chrony/chrony.conf"
    elif [ -f /etc/chrony.conf ]; then
        CHRONY_CONF="/etc/chrony.conf"
    else
        case "$OS_FAMILY" in
            debian|alpine) CHRONY_CONF="/etc/chrony/chrony.conf" ;;
            *)             CHRONY_CONF="/etc/chrony.conf" ;;
        esac
    fi

    unit_files=$(systemctl list-unit-files 2>/dev/null)
    if printf '%s\n' "$unit_files" | grep -q '^chronyd\.service'; then
        CHRONY_SERVICE="chronyd"
    elif printf '%s\n' "$unit_files" | grep -q '^chrony\.service'; then
        CHRONY_SERVICE="chrony"
    else
        case "$OS_FAMILY" in
            debian) CHRONY_SERVICE="chrony" ;;
            *)      CHRONY_SERVICE="chronyd" ;;
        esac
    fi
}

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

# --- 通用: 读取单个按键到全局变量 KEY (无需回车) ---
# ESC 及方向键等转义序列统一映射为 KEY="ESC"; 回车映射为 KEY=""
key_read() {
    KEY=""
    if [ -r /dev/tty ] && _stty_old=$(stty -g < /dev/tty 2>/dev/null) && [ -n "$_stty_old" ]; then
        stty -icanon -echo min 1 time 0 < /dev/tty 2>/dev/null
        KEY=$(dd if=/dev/tty bs=1 count=1 2>/dev/null)
        if [ "$KEY" = "$ESC_CH" ]; then
            # 吞掉方向键等 CSI 后续字节 (0.2s 内到达的)
            stty -icanon -echo min 0 time 2 < /dev/tty 2>/dev/null
            dd if=/dev/tty bs=16 count=1 >/dev/null 2>&1
            KEY="ESC"
        fi
        stty "$_stty_old" < /dev/tty 2>/dev/null
    else
        # 无 tty: 回退为行输入, 取首字符; 读取失败 (EOF) 时退出避免死循环
        read_tty KEY || { log_error "无法读取输入, 退出"; exit 1; }
        [ -n "$KEY" ] && KEY=${KEY%"${KEY#?}"}
    fi
}

# --- 通用: 读取交互输入 (行输入, 用于表单) ---
read_input() {
    prompt="$1"
    default="$2"
    varname="$3"

    if [ -n "$default" ]; then
        printf "  ${CYAN}%s ${GRAY}[默认: %s]${NC}${CYAN} > ${NC}" "$prompt" "$default"
    else
        printf "  ${CYAN}%s > ${NC}" "$prompt"
    fi

    read_tty input

    if [ -z "$input" ]; then
        input="$default"
    fi
    eval "$varname=\"\$input\""
}

# --- 等待任意按键 ---
press_to_continue() {
    printf "\n${GRAY}── 按任意键返回 ──${NC}"
    key_read
    printf "\n"
}

# --- 单键确认: confirm "提示" [默认 y|n] ; 返回 0=是 ---
# 按 y=是, 回车=默认值, 其余任意键=否
confirm() {
    _def="${2:-n}"
    if [ "$_def" = "y" ]; then _hint="Y/n"; else _hint="y/N"; fi
    printf "  ${CYAN}%s [%s] ${NC}" "$1" "$_hint"
    key_read
    case "$KEY" in
        y|Y) printf "y\n"; return 0 ;;
        '')  printf "%s\n" "$_def"; [ "$_def" = "y" ] ;;
        *)   printf "n\n"; return 1 ;;
    esac
}

do_quit() {
    printf "\n${GREEN}再见!${NC}\n"
    exit 0
}

# --- 菜单: 清屏 + 面包屑标题 + 系统信息行 ---
menu_header() {
    clear 2>/dev/null || printf '\n\n'
    printf "${BLUE}━━ VPS Setup"
    [ -n "$1" ] && printf " › %s" "$1"
    printf " ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  ${GRAY}%s · %s%s${NC}\n\n" \
        "${OS_PRETTY:-未知系统}" "${PKG_MGR:-无包管理器}" "${IP_CACHE:+ · $IP_CACHE}"
}

# ================================================================
# 菜单框架: 单键直达
#   run_menu <面包屑> <状态函数|-> <条目函数> [top]
#   条目函数每行输出:  按键|标签|处理函数|类型
#     类型: act = 执行后等待按键返回 (默认)   sub = 进入子菜单
#   导航: 0/ESC 返回上层, m 直回主菜单 (经 NAV 标志逐层退出), q 退出
#   第 4 参数 top 表示主菜单: 0/ESC/m 不生效, NAV 到此复位
# ================================================================
NAV=""

run_menu() {
    while true; do
        if [ "$NAV" = "main" ]; then
            if [ -n "$4" ]; then NAV=""; else return 0; fi
        fi
        menu_header "$1"
        if [ "$2" != "-" ]; then "$2"; printf "\n"; fi
        "$3" | while IFS='|' read -r _mk _mlbl _mfn _mtp; do
            [ -n "$_mk" ] || continue
            printf "  ${GREEN}[%s]${NC} %b\n" "$_mk" "$_mlbl"
        done
        if [ -n "$4" ]; then
            printf "\n  ${GRAY}按键直达 · [q] 退出${NC}\n"
        else
            printf "\n  ${GRAY}按键直达 · [0/ESC] 返回 · [m] 主菜单 · [q] 退出${NC}\n"
        fi
        key_read
        case "$KEY" in
            q|Q)   do_quit ;;
            0|ESC) [ -n "$4" ] && continue; return 0 ;;
            m|M)   [ -n "$4" ] && continue; NAV="main"; return 0 ;;
            '')    continue ;;
        esac
        _mline=$("$3" | awk -F'|' -v k="$KEY" '$1==k {print; exit}')
        [ -n "$_mline" ] || continue
        _mfn=$(printf '%s\n' "$_mline" | cut -d'|' -f3)
        _mtp=$(printf '%s\n' "$_mline" | cut -d'|' -f4)
        printf '\n'
        if [ "$_mtp" = "sub" ]; then
            "$_mfn"
        else
            "$_mfn"
            press_to_continue
        fi
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
        pkg_update

        # vim 在 RHEL 系的完整包名为 vim-enhanced
        case "$OS_FAMILY" in
            rhel) vim_pkg="vim-enhanced" ;;
            *)    vim_pkg="vim" ;;
        esac

        # 只安装缺失的命令, 避免 RHEL 上 curl 与 curl-minimal 冲突
        pkgs="$vim_pkg"
        command -v git  >/dev/null 2>&1 || pkgs="$pkgs git"
        command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
        command -v tar  >/dev/null 2>&1 || pkgs="$pkgs tar"
        command -v wget >/dev/null 2>&1 || pkgs="$pkgs wget"
        command -v zsh  >/dev/null 2>&1 || pkgs="$pkgs zsh"

        pkg_install $pkgs

        if [ ! -d "$HOME/.oh-my-zsh" ]; then
            log_info "安装 oh-my-zsh..."
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            log_info "oh-my-zsh 已存在, 跳过安装"
        fi

        if [ -f "$HOME/.zshrc" ]; then
            sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="ys"/' "$HOME/.zshrc"
        fi

        zsh_path=$(command -v zsh)
        [ -n "$zsh_path" ] && usermod -s "$zsh_path" root

        log_info "vim 鼠标禁用: 写入 $HOME/.vimrc"
        echo "set mouse=" > "$HOME/.vimrc"

        log_info "安装完成. 重新登录后 zsh 生效"
    )
}

# ================================================================
# NTP (chrony) 模块
# ================================================================
ntp_status() {
    resolve_chrony
    printf "${MAGENTA}--- NTP (chrony) 状态 ---${NC}\n"

    if command -v chronyd >/dev/null 2>&1; then
        printf "  安装状态: ${GREEN}已安装${NC}\n"
        installed=1
    else
        printf "  安装状态: ${RED}未安装${NC}\n"
        installed=0
    fi

    if [ "$installed" -eq 1 ] && systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
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
    pkg_update
    pkg_install chrony
    resolve_chrony
    log_info "chrony 安装完成"
}

ntp_uninstall() {
    printf "${BLUE}=== 卸载 chrony ===${NC}\n"
    if ! command -v chronyd >/dev/null 2>&1; then
        log_warn "chrony 未安装, 无需卸载"
        return 0
    fi
    confirm "确认卸载 chrony?" || { log_warn "已取消"; return 0; }
    systemctl stop "$CHRONY_SERVICE" 2>/dev/null || true
    systemctl disable "$CHRONY_SERVICE" 2>/dev/null || true
    pkg_remove chrony
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
    systemctl enable "$CHRONY_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$CHRONY_SERVICE"
    sleep 1
    if systemctl is-active --quiet "$CHRONY_SERVICE"; then
        log_info "chrony 服务运行正常"
    else
        log_error "chrony 启动失败, 请检查: systemctl status $CHRONY_SERVICE"
        return 1
    fi
}

ntp_disable() {
    printf "${BLUE}=== 禁用 NTP ===${NC}\n"
    if ! command -v chronyd >/dev/null 2>&1; then
        log_warn "chrony 未安装"
        return 0
    fi
    systemctl stop "$CHRONY_SERVICE" 2>/dev/null || true
    systemctl disable "$CHRONY_SERVICE" 2>/dev/null || true
    log_info "chrony 已停止并取消开机自启"
}

ntp_view_detail() {
    printf "${BLUE}=== chrony 详细状态 ===${NC}\n"
    if ! command -v chronyc >/dev/null 2>&1; then
        log_error "chrony 未安装"
        return 1
    fi
    if ! systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
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
    if ! systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
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

    if systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
        log_info "检测到 chrony 正在运行, 自动重新应用配置..."
        ntp_apply_servers
        systemctl restart "$CHRONY_SERVICE"
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

    if systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
        log_info "检测到 chrony 正在运行, 自动重新应用配置..."
        ntp_apply_servers
        systemctl restart "$CHRONY_SERVICE"
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

    if systemctl is-active --quiet "$CHRONY_SERVICE" 2>/dev/null; then
        log_info "检测到 chrony 正在运行, 自动重新应用配置..."
        ntp_apply_servers
        systemctl restart "$CHRONY_SERVICE"
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
    pkg_update
    if [ "$OS_FAMILY" = "rhel" ]; then
        # RHEL 系: fail2ban 位于 EPEL; systemd 后端需要 python3-systemd
        ensure_epel
        pkg_install fail2ban-server nftables python3-systemd || pkg_install fail2ban nftables
    else
        pkg_install fail2ban nftables
    fi
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
    confirm "确认卸载 Fail2Ban?" || { log_warn "已取消"; return 0; }
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    if [ "$OS_FAMILY" = "rhel" ]; then
        pkg_remove fail2ban-server fail2ban
    else
        pkg_remove fail2ban
    fi
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
# ACME (Let's Encrypt) 证书模块  —— 独立于 Sing-Box
#   证书统一放在 $ACME_CERT_DIR/<domain>.{crt,key}
#   任何服务 (sing-box / nginx / 自建程序) 都可以直接引用这两个文件
#   续期由 acme.sh 自带 cron 完成, --reloadcmd 负责重载使用方
# ================================================================
ACME_HOME="/root/.acme.sh"
ACME_BIN="/root/.acme.sh/acme.sh"

acme_installed() { [ -x "$ACME_BIN" ]; }

# 一域名一目录, 文件名沿用 certbot 惯例, 方便直接套用现成的 nginx 配置:
#   $ACME_CERT_DIR/<domain>/{fullchain.pem,privkey.pem,cert.pem,chain.pem}
acme_dir_for() { printf '%s/%s' "$ACME_CERT_DIR" "$1"; }
acme_crt_for() { printf '%s/%s/fullchain.pem' "$ACME_CERT_DIR" "$1"; }
acme_key_for() { printf '%s/%s/privkey.pem' "$ACME_CERT_DIR" "$1"; }

# 已签发并安装的域名, 每行一个
acme_list_domains() {
    [ -d "$ACME_CERT_DIR" ] || return 0
    for _dir in "$ACME_CERT_DIR"/*/; do
        [ -d "$_dir" ] || continue
        _d=${_dir%/}; _d=${_d##*/}
        [ -f "${_dir}fullchain.pem" ] && [ -f "${_dir}privkey.pem" ] || continue
        printf '%s\n' "$_d"
    done
}

# 证书表格: 域名 / 到期时间 / 状态
acme_list_certs() {
    _n=0
    acme_list_domains | while IFS= read -r _d; do
        _n=$((_n + 1))
        _crt=$(acme_crt_for "$_d")
        _end=$(openssl x509 -in "$_crt" -noout -enddate 2>/dev/null | cut -d= -f2)
        # -checkend 比解析日期可移植: 各发行版的 date -d 行为不一致
        if ! openssl x509 -in "$_crt" -noout -checkend 0 >/dev/null 2>&1; then
            _st="${RED}已过期${NC}"
        elif ! openssl x509 -in "$_crt" -noout -checkend 604800 >/dev/null 2>&1; then
            _st="${YELLOW}7天内到期${NC}"
        else
            _st="${GREEN}有效${NC}"
        fi
        printf "  ${CYAN}%-2s${NC} %-32s %-26s ${_st}\n" "$_n)" "$_d" "${_end:-未知}"
    done
}

acme_status() {
    printf "${MAGENTA}--- ACME 证书 ---${NC}\n"
    if acme_installed; then
        _ver=$("$ACME_BIN" --version 2>/dev/null | grep -i 'v[0-9]' | head -n 1)
        printf "  acme.sh:  ${GREEN}已安装${NC}  ${CYAN}%s${NC}\n" "${_ver:-}"
        _ca=$(grep '^DEFAULT_ACME_SERVER=' "${ACME_HOME}/account.conf" 2>/dev/null | cut -d"'" -f2)
        [ -n "$_ca" ] && printf "  默认 CA:  ${CYAN}%s${NC}\n" "$_ca"
        if acme_cron_enabled; then
            printf "  自动续期: ${GREEN}● 已启用${NC}\n"
        else
            printf "  自动续期: ${YELLOW}○ 未启用${NC}\n"
        fi
    else
        printf "  acme.sh:  ${RED}未安装${NC}\n"
    fi
    _cnt=$(acme_list_domains | grep -c .)
    printf "  已装证书: ${CYAN}%s${NC} 个  ${GRAY}(%s)${NC}\n" "$_cnt" "$ACME_CERT_DIR"
    if [ "$_cnt" -gt 0 ]; then
        acme_list_certs
    fi
    printf "${MAGENTA}-----------------${NC}\n"
}

acme_cron_enabled() {
    crontab -l 2>/dev/null | grep -q "acme.sh --cron"
}

acme_install() {
    printf "${BLUE}=== 安装 acme.sh ===${NC}\n"
    if acme_installed; then
        log_warn "acme.sh 已安装于 $ACME_BIN, 跳过"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        pkg_update >/dev/null 2>&1 || true
        pkg_install curl >/dev/null 2>&1
    fi
    # acme.sh 需要 cron 才能自动续期
    if ! command -v crontab >/dev/null 2>&1; then
        pkg_install cronie >/dev/null 2>&1 || pkg_install cron >/dev/null 2>&1 || \
            log_warn "未能安装 cron, 自动续期可能不可用"
    fi
    read_input "注册邮箱 (用于 CA 到期提醒)" "admin@example.com" ACME_EMAIL
    log_info "安装中..."
    curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}" >/dev/null 2>&1
    if ! acme_installed; then
        log_error "acme.sh 安装失败"
        return 1
    fi
    # 新版 acme.sh 默认 CA 是 ZeroSSL, 需要注册账号; 统一切到 Let's Encrypt
    "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1
    mkdir -p "$ACME_CERT_DIR"
    log_info "acme.sh 安装完成, 默认 CA 已设为 Let's Encrypt"
}

acme_uninstall() {
    printf "${BLUE}=== 卸载 acme.sh ===${NC}\n"
    if ! acme_installed; then
        log_warn "acme.sh 未安装, 无需卸载"
        return 0
    fi
    confirm "确认卸载 acme.sh? (已签发的证书文件会保留)" || { log_warn "已取消"; return 0; }
    "$ACME_BIN" --uninstall >/dev/null 2>&1 || true
    rm -rf "$ACME_HOME"
    log_info "acme.sh 已卸载"
    log_warn "证书文件仍在 $ACME_CERT_DIR, 如需清理请手动删除"
}

# 白名单防火墙开启时, LE 验证机的 IP 不在 set 里, 80 端口对它不可达
acme_warn_firewall() {
    nft_table_exists || return 0
    log_warn "⚠️ 检测到白名单防火墙已启用 (input policy drop)"
    log_warn "   Let's Encrypt 验证机的 IP 不在白名单中, HTTP-01 将无法通过"
    log_warn "   建议改用 DNS-01, 或先临时关闭防火墙 (5 -> 关闭防火墙)"
}

# Token 打码显示: 头4位 + **** + 尾4位
acme_mask_token() {
    _t="$1"
    if [ "${#_t}" -le 8 ]; then
        printf '********'
    else
        printf '%s****%s' \
            "$(printf '%s' "$_t" | cut -c1-4)" \
            "$(printf '%s' "$_t" | sed 's/.*\(....\)$/\1/')"
    fi
}

# 按优先级查找已保存的 Cloudflare Token, 设置 CF_TOKEN_VALUE / CF_TOKEN_SRC
#   1) DDNS 模块保存的 /root/.cf_token
#   2) acme.sh 上次签发时自己存进 account.conf 的 SAVED_CF_Token
acme_load_cf_token() {
    CF_TOKEN_VALUE=""
    CF_TOKEN_SRC=""
    if [ -s "$DDNS_TOKEN_FILE" ]; then
        CF_TOKEN_VALUE=$(cat "$DDNS_TOKEN_FILE")
        CF_TOKEN_SRC="DDNS 模块 ($DDNS_TOKEN_FILE)"
        [ -n "$CF_TOKEN_VALUE" ] && return 0
    fi
    if [ -f "${ACME_HOME}/account.conf" ]; then
        CF_TOKEN_VALUE=$(grep "^SAVED_CF_Token=" "${ACME_HOME}/account.conf" 2>/dev/null \
            | tail -n 1 | cut -d"'" -f2)
        if [ -n "$CF_TOKEN_VALUE" ]; then
            CF_TOKEN_SRC="acme.sh 上次保存"
            return 0
        fi
    fi
    return 1
}

# 续期后要重载哪个服务 (装了 sing-box 就重启它, 否则留空)
acme_default_reloadcmd() {
    if command -v sing-box >/dev/null 2>&1; then
        printf '%s' "systemctl restart sing-box"
    else
        printf '%s' "true"
    fi
}

# acme_issue_cert <domain> [reloadcmd]
# 成功后设置: ACME_CERT_PATH / ACME_KEY_PATH
acme_issue_cert() {
    _domain="$1"
    _reload="${2:-$(acme_default_reloadcmd)}"
    [ -z "$_domain" ] && { log_error "域名为空"; return 1; }

    _certdir=$(acme_dir_for "$_domain")
    mkdir -p "$_certdir"
    chmod 700 "$_certdir"
    ACME_CERT_PATH=$(acme_crt_for "$_domain")
    ACME_KEY_PATH=$(acme_key_for "$_domain")

    if [ -s "$ACME_CERT_PATH" ] && [ -s "$ACME_KEY_PATH" ]; then
        log_info "检测到已有证书: $ACME_CERT_PATH"
        if confirm "直接复用该证书?" y; then
            return 0
        fi
    fi

    acme_installed || { acme_install || return 1; }

    printf "  ${CYAN}域名验证方式:${NC}\n"
    if acme_load_cf_token; then
        printf "    ${CYAN}1)${NC} DNS-01 (Cloudflare, 已有 Token: %s)  ${GREEN}[推荐]${NC}\n" \
            "$(acme_mask_token "$CF_TOKEN_VALUE")"
    else
        printf "    ${CYAN}1)${NC} DNS-01 (Cloudflare, 需输入 API Token)  ${GREEN}[推荐]${NC}\n"
    fi
    printf "    ${CYAN}2)${NC} HTTP-01 standalone (需 80 端口对外可达)\n"
    printf "  ${CYAN}选择 [1/2] ${GRAY}[默认: 1]${NC}${CYAN} > ${NC}"
    key_read
    case "$KEY" in
        2)      printf "2\n"; _method="http" ;;
        1|'')   printf "1\n"; _method="dns" ;;
        *)      printf "\n"; log_error "无效选择"; return 1 ;;
    esac

    if [ "$_method" = "dns" ]; then
        CF_Token=""
        if acme_load_cf_token; then
            log_info "找到已保存的 Cloudflare Token (来源: ${CF_TOKEN_SRC})"
            printf "  ${GRAY}Token: %s${NC}\n" "$(acme_mask_token "$CF_TOKEN_VALUE")"
            if confirm "使用该 Token?" y; then
                CF_Token="$CF_TOKEN_VALUE"
            fi
        fi
        if [ -z "$CF_Token" ]; then
            read_input "Cloudflare API Token (Zone:DNS:Edit 权限)" "" CF_Token
        fi
        if [ -z "$CF_Token" ]; then
            log_error "Token 为空"
            return 1
        fi
        # acme.sh 会把它存进 account.conf 的 SAVED_CF_Token, 下次自动复用
        export CF_Token
        log_info "通过 DNS-01 申请证书 (域名: $_domain)..."
        "$ACME_BIN" --issue -d "$_domain" --dns dns_cf -k ec-256 || \
            log_warn "签发未成功, 尝试安装 acme.sh 中已有的证书..."
    else
        acme_warn_firewall
        if ! command -v socat >/dev/null 2>&1; then
            log_info "安装 socat (standalone 模式依赖)..."
            pkg_update >/dev/null 2>&1 || true
            pkg_install socat >/dev/null 2>&1 || log_warn "socat 安装失败, standalone 可能不可用"
        fi
        if ss -lnt 2>/dev/null | grep -q ':80[[:space:]]'; then
            log_warn "80 端口已被占用, 请先停掉占用进程"
            return 1
        fi
        log_info "通过 HTTP-01 standalone 申请证书 (域名: $_domain)..."
        "$ACME_BIN" --issue -d "$_domain" --standalone --httpport 80 -k ec-256 || \
            log_warn "签发未成功, 尝试安装 acme.sh 中已有的证书..."
    fi

    # --ecc 对应 -k ec-256; reloadcmd 保证续期后使用方重新加载证书
    # 四个文件都装上: 有的软件要 leaf 和 chain 分开, 装了不占地方
    if ! "$ACME_BIN" --install-cert -d "$_domain" --ecc \
            --fullchain-file "$ACME_CERT_PATH" \
            --key-file "$ACME_KEY_PATH" \
            --cert-file "${_certdir}/cert.pem" \
            --ca-file "${_certdir}/chain.pem" \
            --reloadcmd "$_reload"; then
        log_error "证书安装失败, 请确认: ① 域名已解析到本机 ② 验证方式可用 ③ acme.sh 中已有该域名证书"
        return 1
    fi
    if [ ! -s "$ACME_CERT_PATH" ] || [ ! -s "$ACME_KEY_PATH" ]; then
        log_error "证书文件不完整: $ACME_CERT_PATH / $ACME_KEY_PATH"
        return 1
    fi
    chmod 600 "$ACME_KEY_PATH"
    log_info "证书已安装 (fullchain): $ACME_CERT_PATH"
    log_info "私钥: $ACME_KEY_PATH   续期后执行: $_reload"
}

# --- 菜单动作 ---
acme_issue_interactive() {
    printf "${BLUE}=== 申请证书 ===${NC}\n"
    read_input "域名 (如 proxy.example.com)" "" _d
    case "$_d" in
        ''|*[!A-Za-z0-9.-]*) log_error "域名格式无效"; return 1 ;;
        *.*) : ;;
        *) log_error "请填写完整域名"; return 1 ;;
    esac
    acme_issue_cert "$_d"
}

acme_renew() {
    printf "${BLUE}=== 强制续期 ===${NC}\n"
    acme_installed || { log_error "acme.sh 未安装"; return 1; }
    _cnt=$(acme_list_domains | grep -c .)
    if [ "$_cnt" -eq 0 ]; then
        log_warn "还没有已安装的证书"
        return 0
    fi
    acme_list_certs
    read_input "选择编号 (回车全部续期)" "" _sel
    if [ -z "$_sel" ]; then
        log_info "续期全部证书..."
        "$ACME_BIN" --cron --force
    else
        _d=$(acme_list_domains | sed -n "${_sel}p")
        [ -z "$_d" ] && { log_error "编号无效"; return 1; }
        log_info "续期 $_d ..."
        "$ACME_BIN" --renew -d "$_d" --ecc --force
    fi
    log_info "续期完成 (证书文件已由 --install-cert 的 reloadcmd 自动更新)"
}

acme_delete() {
    printf "${BLUE}=== 删除证书 ===${NC}\n"
    _cnt=$(acme_list_domains | grep -c .)
    if [ "$_cnt" -eq 0 ]; then
        log_warn "没有可删除的证书"
        return 0
    fi
    acme_list_certs
    read_input "选择要删除的编号" "" _sel
    _d=$(acme_list_domains | sed -n "${_sel}p")
    [ -z "$_d" ] && { log_error "编号无效"; return 1; }
    confirm "确认删除 ${_d} 的证书?" || { log_warn "已取消"; return 0; }
    acme_installed && "$ACME_BIN" --remove -d "$_d" --ecc >/dev/null 2>&1
    rm -rf "$(acme_dir_for "$_d")"
    log_info "已删除 $_d 的证书"
    log_warn "注意: 引用了该证书的服务需要另行调整配置"
}

# 让用户从已有证书里选一个 (供 sing-box 等复用)
# 成功后设置: SELECTED_CERT_DOMAIN / SELECTED_CERT_CRT / SELECTED_CERT_KEY
# 选 n 表示申请新证书; 没有任何证书时直接进申请流程
acme_select_cert() {
    SELECTED_CERT_DOMAIN=""; SELECTED_CERT_CRT=""; SELECTED_CERT_KEY=""
    _cnt=$(acme_list_domains | grep -c .)

    if [ "$_cnt" -eq 0 ]; then
        log_info "还没有已签发的证书, 进入申请流程"
        acme_issue_interactive || return 1
        SELECTED_CERT_DOMAIN=$(dirname "$ACME_CERT_PATH"); SELECTED_CERT_DOMAIN=${SELECTED_CERT_DOMAIN##*/}
        SELECTED_CERT_CRT="$ACME_CERT_PATH"
        SELECTED_CERT_KEY="$ACME_KEY_PATH"
        return 0
    fi

    printf "  ${CYAN}选择证书:${NC}\n"
    acme_list_certs
    printf "    ${CYAN}n)${NC} 申请新证书\n"
    read_input "选择编号或 n" "1" _sel
    if [ "$_sel" = "n" ] || [ "$_sel" = "N" ]; then
        acme_issue_interactive || return 1
        SELECTED_CERT_DOMAIN=$(dirname "$ACME_CERT_PATH"); SELECTED_CERT_DOMAIN=${SELECTED_CERT_DOMAIN##*/}
        SELECTED_CERT_CRT="$ACME_CERT_PATH"
        SELECTED_CERT_KEY="$ACME_KEY_PATH"
        return 0
    fi
    _d=$(acme_list_domains | sed -n "${_sel}p")
    if [ -z "$_d" ]; then
        log_error "编号无效"
        return 1
    fi
    SELECTED_CERT_DOMAIN="$_d"
    SELECTED_CERT_CRT=$(acme_crt_for "$_d")
    SELECTED_CERT_KEY=$(acme_key_for "$_d")
    log_info "已选择证书: $_d"
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
            pkg_update >/dev/null 2>&1 || true
            pkg_install curl openssl ca-certificates >/dev/null 2>&1
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
    confirm "确认卸载 Sing-Box?" || { log_warn "已取消"; return 0; }
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
        pkg_update >/dev/null 2>&1 || true
        pkg_install python3 >/dev/null 2>&1
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
    elif t == 'anytls':
        u = (ib.get('users') or [{}])[0]
        emit('PASSWORD', u.get('password', ''))
        tls = ib.get('tls', {})
        emit('SNI', tls.get('server_name', ''))
        r = tls.get('reality', {})
        if r.get('enabled'):
            emit('TLS_MODE', 'reality')
            emit('PRIV_KEY', r.get('private_key', ''))
            sid = r.get('short_id', [])
            emit('SHORT_ID', sid[0] if sid else '')
        else:
            emit('TLS_MODE', 'cert')
            emit('CERT_PATH', tls.get('certificate_path', ''))
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
            anytls)
                if [ "$TLS_MODE" = "reality" ]; then
                    PUB_KEY=$(derive_x25519_pub_from_priv_b64url "$PRIV_KEY")
                    if [ -z "$PUB_KEY" ]; then
                        log_error "无法从 private_key 派生 public_key, 请检查 openssl 是否支持 X25519"
                        return 1
                    fi
                    LINK="anytls://${PASSWORD}@${SERVER_IP}:${PORT}?sni=${SNI}&security=reality&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#${TAG_ENCODED}"
                    TLS_DESC="AnyTLS + Reality"
                else
                    # 自签证书的 issuer == subject; 正式证书由 CA 签发, 两者不同
                    IS_SELF_SIGNED=1
                    if [ -n "$CERT_PATH" ] && [ -f "$CERT_PATH" ]; then
                        _sub=$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null | sed 's/^subject=//')
                        _iss=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
                        if [ -n "$_sub" ] && [ "$_sub" != "$_iss" ]; then
                            IS_SELF_SIGNED=0
                        fi
                    fi
                    if [ "$IS_SELF_SIGNED" -eq 0 ]; then
                        # 证书拿 SNI 校验, 所以连接地址用域名; 走中转时手动改成中转 IP 即可
                        LINK="anytls://${PASSWORD}@${SNI}:${PORT}?sni=${SNI}&security=tls&type=tcp#${TAG_ENCODED}"
                        TLS_DESC="AnyTLS + 正式证书"
                    else
                        LINK="anytls://${PASSWORD}@${SERVER_IP}:${PORT}?sni=${SNI}&security=tls&type=tcp&insecure=1#${TAG_ENCODED}"
                        TLS_DESC="AnyTLS + 自签证书"
                    fi
                fi

                printf "${BLUE}========================================================${NC}\n"
                printf "📋 节点信息 (Tag: ${CYAN}%s${NC})  类型: ${CYAN}%s${NC}\n" "$TAG" "$TLS_DESC"
                printf "${BLUE}========================================================${NC}\n"
                printf "${CYAN}🚀 AnyTLS 链接:${NC}\n%s\n\n" "$LINK"
                printf "${CYAN}📄 JSON 客户端配置:${NC}\n"
                if [ "$TLS_MODE" = "reality" ]; then
                    cat <<EOF
{
    "tag": "${TAG}",
    "type": "anytls",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
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
                elif [ "$IS_SELF_SIGNED" -eq 0 ]; then
                    cat <<EOF
{
    "tag": "${TAG}",
    "type": "anytls",
    "server": "${SNI}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        }
    }
}
EOF
                else
                    cat <<EOF
{
    "tag": "${TAG}",
    "type": "anytls",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "insecure": true,
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        }
    }
}
EOF
                fi
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
    confirm "确认删除当前代理配置并停止服务?" || { log_warn "已取消"; return 0; }
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

_anytls_write_cert_config() {
    cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "${TAG_JSON}",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "user1",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "certificate_path": "${ANYTLS_CERT}",
        "key_path": "${ANYTLS_KEY}"
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
}

singbox_configure_anytls() {
    printf "${BLUE}=== Sing-Box 配置: AnyTLS ===${NC}\n"
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "Sing-Box 未安装, 请先执行: 4 -> 1 安装"
        return 1
    fi

    read_input "节点 TAG" "MyAnyTLS" NODE_TAG
    read_input "监听端口" "8443" PORT
    case "$PORT" in
        ''|*[!0-9]*) log_error "端口必须是数字"; return 1 ;;
    esac

    printf "  ${CYAN}TLS 模式:${NC}\n"
    printf "    ${CYAN}1)${NC} Reality          (无需证书/域名, 客户端需支持 AnyTLS + Reality)\n"
    printf "    ${CYAN}2)${NC} 自签证书         (无需域名, 客户端需开启 insecure)\n"
    printf "    ${CYAN}3)${NC} Let's Encrypt    (需自有域名, 客户端无需 insecure)\n"
    printf "  ${CYAN}选择 [1/2/3] ${GRAY}[默认: 1]${NC}${CYAN} > ${NC}"
    key_read
    case "$KEY" in
        3)      printf "3\n"; TLS_MODE="acme" ;;
        2)      printf "2\n"; TLS_MODE="cert" ;;
        1|'')   printf "1\n"; TLS_MODE="reality" ;;
        *)      printf "\n"; log_error "无效选择"; return 1 ;;
    esac

    if [ "$TLS_MODE" = "cert" ]; then
        CERT_CN_DEFAULT="$IP_CACHE"
        [ -z "$CERT_CN_DEFAULT" ] && CERT_CN_DEFAULT=$(get_server_ip)
        [ -z "$CERT_CN_DEFAULT" ] && CERT_CN_DEFAULT="127.0.0.1"
        read_input "证书 CN / 客户端 SNI (默认服务器 IP, 也可填域名)" "$CERT_CN_DEFAULT" MASQ_DOMAIN
        case "$MASQ_DOMAIN" in
            ''|*[!A-Za-z0-9.:-]*) log_error "CN 格式无效 (仅允许字母/数字/. : -)"; return 1 ;;
        esac
    elif [ "$TLS_MODE" = "acme" ]; then
        # 复用证书模块: 有已签发的就直接选, 没有就走申请流程
        # 必须放在下面的子 shell 之外, 因为要交互输入
        acme_select_cert || return 1
        MASQ_DOMAIN="$SELECTED_CERT_DOMAIN"
        ACME_CERT_PATH="$SELECTED_CERT_CRT"
        ACME_KEY_PATH="$SELECTED_CERT_KEY"
    fi

    (
        set -e
        PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24)
        TAG_JSON=$(json_escape "$NODE_TAG")

        mkdir -p "$SINGBOX_DIR"
        [ -f "$SINGBOX_CONFIG" ] && cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak.$(date +%s)"

        if [ "$TLS_MODE" = "reality" ]; then
            get_best_domain
            MASQ_DOMAIN="$BEST_DOMAIN"
            pair_out=$(sing-box generate reality-keypair)
            PRIV_KEY=$(echo "$pair_out" | grep "PrivateKey" | awk '{print $2}')
            PUB_KEY=$(echo "$pair_out" | grep "PublicKey" | awk '{print $2}')
            SHORT_ID=$(openssl rand -hex 8)

            cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "${TAG_JSON}",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "user1",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${MASQ_DOMAIN}",
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
        elif [ "$TLS_MODE" = "acme" ]; then
            ANYTLS_CERT="$ACME_CERT_PATH"
            ANYTLS_KEY="$ACME_KEY_PATH"
            log_info "使用 Let's Encrypt 证书: $ANYTLS_CERT"
            _anytls_write_cert_config
        else
            ANYTLS_CERT="${SINGBOX_DIR}/anytls.crt"
            ANYTLS_KEY="${SINGBOX_DIR}/anytls.key"
            # CN 是 IP 时 SAN 必须用 IP: 类型, 否则客户端按域名校验会找不到匹配项
            SAN_TYPE="DNS"
            case "$MASQ_DOMAIN" in
                *:*) SAN_TYPE="IP" ;;
                *)   if validate_ipv4 "$MASQ_DOMAIN"; then SAN_TYPE="IP"; fi ;;
            esac
            log_info "生成自签证书 (CN=${MASQ_DOMAIN}, SAN=${SAN_TYPE}:${MASQ_DOMAIN}, 有效期 100 年)..."
            openssl ecparam -genkey -name prime256v1 -out "$ANYTLS_KEY" 2>/dev/null
            # -addext 需要 openssl >= 1.1.1, 老版本回退到 -extfile
            if ! openssl req -new -x509 -days 36500 -key "$ANYTLS_KEY" -out "$ANYTLS_CERT" \
                    -subj "/CN=${MASQ_DOMAIN}" \
                    -addext "subjectAltName = ${SAN_TYPE}:${MASQ_DOMAIN}" 2>/dev/null; then
                EXT_FILE=$(mktemp)
                printf 'subjectAltName = %s:%s\n' "$SAN_TYPE" "$MASQ_DOMAIN" > "$EXT_FILE"
                openssl req -new -x509 -days 36500 -key "$ANYTLS_KEY" -out "$ANYTLS_CERT" \
                    -subj "/CN=${MASQ_DOMAIN}" -extfile "$EXT_FILE" 2>/dev/null || true
                rm -f "$EXT_FILE"
            fi
            if [ ! -s "$ANYTLS_CERT" ] || [ ! -s "$ANYTLS_KEY" ]; then
                log_error "自签证书生成失败, 请检查 openssl"
                exit 1
            fi
            chmod 600 "$ANYTLS_KEY"

            _anytls_write_cert_config
        fi

        singbox_restart

        SERVER_IP=$(get_server_ip)
        [ -z "$SERVER_IP" ] && SERVER_IP="[无法获取IP]"
        TAG_ENCODED=$(echo "$NODE_TAG" | sed 's/ /%20/g')

        printf "\n${BLUE}========================================================${NC}\n"
        printf "📋 节点信息 (Tag: ${NODE_TAG})  类型: ${CYAN}AnyTLS${NC}\n"
        printf "${BLUE}========================================================${NC}\n"
        if [ "$TLS_MODE" = "reality" ]; then
            ANYTLS_LINK="anytls://${PASSWORD}@${SERVER_IP}:${PORT}?sni=${MASQ_DOMAIN}&security=reality&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#${TAG_ENCODED}"
            printf "${CYAN}🚀 AnyTLS 链接 (Reality):${NC}\n%s\n\n" "$ANYTLS_LINK"
            printf "${CYAN}📄 JSON 客户端配置:${NC}\n"
            cat <<EOF
{
    "tag": "${NODE_TAG}",
    "type": "anytls",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
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
        elif [ "$TLS_MODE" = "acme" ]; then
            # 正式证书: 客户端按域名连 (证书是拿 SNI 校验的), 不需要 insecure
            ANYTLS_LINK="anytls://${PASSWORD}@${MASQ_DOMAIN}:${PORT}?sni=${MASQ_DOMAIN}&security=tls&type=tcp#${TAG_ENCODED}"
            printf "${CYAN}🚀 AnyTLS 链接 (Let's Encrypt):${NC}\n%s\n\n" "$ANYTLS_LINK"
            printf "${GRAY}提示: 若走 realm 中转, 把 server 改成中转机 IP, server_name 保持域名不变${NC}\n\n"
            printf "${CYAN}📄 JSON 客户端配置:${NC}\n"
            cat <<EOF
{
    "tag": "${NODE_TAG}",
    "type": "anytls",
    "server": "${MASQ_DOMAIN}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        }
    }
}
EOF
        else
            ANYTLS_LINK="anytls://${PASSWORD}@${SERVER_IP}:${PORT}?sni=${MASQ_DOMAIN}&security=tls&type=tcp&insecure=1#${TAG_ENCODED}"
            printf "${CYAN}🚀 AnyTLS 链接 (自签证书):${NC}\n%s\n\n" "$ANYTLS_LINK"
            printf "${YELLOW}⚠ 自签证书: 客户端必须开启 '跳过证书验证 / insecure'${NC}\n\n"
            printf "${CYAN}📄 JSON 客户端配置:${NC}\n"
            cat <<EOF
{
    "tag": "${NODE_TAG}",
    "type": "anytls",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "insecure": true,
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        }
    }
}
EOF
        fi
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

# 把当前白名单备份到独立文件 (set 不存在时保持原备份不动)
nft_save_whitelist_file() {
    nft_set_exists || return 0
    nft_get_whitelist > "$NFT_WL_FILE"
}

# 从备份文件恢复白名单到 set
nft_restore_whitelist_file() {
    [ -s "$NFT_WL_FILE" ] || return 0
    restored=0
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        if nft add element inet "$NFT_TABLE" admin_ip4 "{ $ip }" 2>/dev/null; then
            restored=$((restored + 1))
        fi
    done < "$NFT_WL_FILE"
    if [ "$restored" -gt 0 ]; then
        log_info "已从 $NFT_WL_FILE 恢复 $restored 个白名单 IP"
    fi
}

# 创建空的 landing_whitelist 框架 (set+input/forward/output), 并恢复已备份的白名单
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
    _ret=$?
    [ "$_ret" -eq 0 ] && nft_restore_whitelist_file
    return "$_ret"
}

# 把 live ruleset 持久化到 /etc/nftables.conf (包括用户其他 table), 同时备份白名单
nft_persist() {
    {
        echo "#!/usr/sbin/nft -f"
        echo ""
        echo "flush ruleset"
        echo ""
        nft list ruleset 2>/dev/null
    } > "$NFT_CONF"
    nft_save_whitelist_file
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
    pkg_update
    pkg_install nftables
    systemctl enable nftables >/dev/null 2>&1 || true
    log_info "nftables 安装完成"
}

nft_uninstall() {
    printf "${BLUE}=== 卸载 nftables ===${NC}\n"
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "nftables 未安装, 无需卸载"
        return 0
    fi
    confirm "确认卸载 nftables?" || { log_warn "已取消"; return 0; }
    systemctl stop nftables 2>/dev/null || true
    systemctl disable nftables 2>/dev/null || true
    pkg_remove nftables
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
        if [ -s "$NFT_WL_FILE" ]; then
            log_info "检测到已保存的白名单 ($(grep -c . "$NFT_WL_FILE") 个 IP), 创建后将自动恢复"
        else
            log_warn "⚠️ 创建后 input 默认策略为 drop, 必须在 set 中至少有一个 IP 才能远程访问"
        fi
        confirm "确认创建?" || { log_warn "已取消"; return 0; }
        nft_init_table || { log_error "创建失败"; return 1; }
    fi

    # set 为空时尝试从备份恢复, 再检查是否仍为空
    cnt=$(nft_get_whitelist | grep -c .)
    if [ "$cnt" -eq 0 ]; then
        nft_restore_whitelist_file
        cnt=$(nft_get_whitelist | grep -c .)
    fi
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
        nft_save_whitelist_file
        nft delete table inet "$NFT_TABLE"
        log_info "已移除 table inet ${NFT_TABLE}"
        nft_persist
        if [ -s "$NFT_WL_FILE" ]; then
            log_info "白名单已保存到 $NFT_WL_FILE (共 $(grep -c . "$NFT_WL_FILE") 个 IP), 重新启用时自动恢复"
        fi
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
    confirm "确认清空所有 nftables 规则?" || { log_warn "已取消"; return 0; }
    nft_save_whitelist_file
    nft flush ruleset
    : > "$NFT_CONF"
    log_info "已清空 nftables 全部规则"
    if [ -s "$NFT_WL_FILE" ]; then
        log_info "白名单已保存到 $NFT_WL_FILE, 重新启用防火墙时自动恢复"
    fi
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
    if confirm "是否自动禁用这些冲突文件?" y; then
        ts=$(date +%Y%m%d_%H%M%S)
        echo "$conflicts" | while IFS= read -r conf; do
            [ -z "$conf" ] && continue
            mv "$conf" "${conf}.disabled.${ts}" 2>/dev/null || true
        done
        log_info "已禁用冲突文件"
    else
        log_warn "已跳过, 若配置未生效请手动检查 /etc/sysctl.d/"
    fi
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

    confirm "确认应用?" y || { log_warn "已取消"; return 0; }

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
    confirm "确认移除?" || { log_warn "已取消"; return 0; }

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
        pkg_update >/dev/null 2>&1 || true
        pkg_install curl tar ca-certificates >/dev/null 2>&1
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
    confirm "确认卸载 realm?" || { log_warn "已取消"; return 0; }

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
# Cloudflare DDNS 模块
# ================================================================

# 安装并启用 cron (多发行版: 包名/服务名各异)
ddns_ensure_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        log_info "安装 cron..."
        case "$PKG_MGR" in
            dnf|yum|pacman) cron_pkg="cronie" ;;
            apk)            cron_pkg="dcron"  ;;
            *)              cron_pkg="cron"   ;;
        esac
        pkg_update
        pkg_install "$cron_pkg" || return 1
    fi
    for _svc in cron crond cronie dcron; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${_svc}\.service"; then
            systemctl enable "$_svc" >/dev/null 2>&1 || true
            systemctl start "$_svc" 2>/dev/null || true
            break
        fi
    done
}
ddns_cfg_get() {
    key="$1"
    [ -f "$DDNS_ZONE_FILE" ] || return 1
    grep "^${key}=" "$DDNS_ZONE_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-
}

ddns_log_path() {
    p=$(ddns_cfg_get LOG 2>/dev/null)
    if [ -n "$p" ]; then
        echo "$p"
    else
        echo "$DDNS_LOG"
    fi
}

ddns_cron_enabled() {
    command -v crontab >/dev/null 2>&1 || return 1
    crontab -l 2>/dev/null | grep -q "ddns.sh"
}

ddns_status() {
    printf "${MAGENTA}--- Cloudflare DDNS 状态 ---${NC}\n"
    if [ ! -f "$DDNS_SCRIPT" ]; then
        printf "  安装状态: ${RED}未安装${NC}\n"
        printf "${MAGENTA}---------------------------${NC}\n"
        return 0
    fi
    printf "  安装状态: ${GREEN}已安装${NC}\n"

    if [ -f "$DDNS_ZONE_FILE" ]; then
        d_domain=$(ddns_cfg_get DOMAIN)
        d_zone=$(ddns_cfg_get ZONE)
        d_mode=$(ddns_cfg_get MODE)
        d_proxied=$(ddns_cfg_get PROXIED)
        d_ttl=$(ddns_cfg_get TTL)
        [ "$d_mode" = "dual" ] && mode_label="IPv4 + IPv6" || mode_label="仅 IPv4"
        [ "$d_proxied" = "true" ] && proxy_label="开启" || proxy_label="关闭"
        printf "  域名:     ${CYAN}%s${NC}\n" "$d_domain"
        printf "  Zone:     ${CYAN}%s${NC}\n" "$d_zone"
        printf "  记录模式: ${CYAN}%s${NC}\n" "$mode_label"
        printf "  CF 代理:  ${CYAN}%s${NC}\n" "$proxy_label"
        printf "  TTL:      ${CYAN}%s${NC}\n" "${d_ttl:-60}"
    fi

    if ddns_cron_enabled; then
        printf "  自动更新: ${GREEN}已启用 (每5分钟)${NC}\n"
    else
        printf "  自动更新: ${YELLOW}未启用${NC}\n"
    fi

    log=$(ddns_log_path)
    if [ -f "$log" ]; then
        last=$(tail -n 1 "$log" 2>/dev/null)
        [ -n "$last" ] && printf "  最近日志: ${CYAN}%s${NC}\n" "$last"
    fi
    printf "${MAGENTA}---------------------------${NC}\n"
}

# 由完整域名向上递归查找 Cloudflare zone, 输出 ZONE_NAME|ZONE_ID, 失败返回 1
ddns_resolve_zone() {
    domain="$1"
    token="$2"
    candidate="$domain"
    while [ -n "$candidate" ]; do
        case "$candidate" in
            *.*) ;;
            *) return 1 ;;
        esac
        resp=$(curl -s --max-time 10 \
            "https://api.cloudflare.com/client/v4/zones?name=${candidate}" \
            -H "Authorization: Bearer ${token}")
        ok=$(printf '%s' "$resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('success', ''))" 2>/dev/null)
        if [ "$ok" != "True" ]; then
            return 2
        fi
        count=$(printf '%s' "$resp" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
        if [ -n "$count" ] && [ "$count" != "0" ]; then
            zid=$(printf '%s' "$resp" | python3 -c \
                "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
            echo "${candidate}|${zid}"
            return 0
        fi
        new_candidate=$(printf '%s' "$candidate" | cut -d. -f2-)
        [ "$new_candidate" = "$candidate" ] && return 1
        candidate="$new_candidate"
    done
    return 1
}

ddns_install() {
    printf "${BLUE}=== 配置 Cloudflare DDNS ===${NC}\n"

    # 依赖安装
    need_pkgs=""
    command -v curl    >/dev/null 2>&1 || need_pkgs="$need_pkgs curl"
    command -v python3 >/dev/null 2>&1 || need_pkgs="$need_pkgs python3"
    if [ -n "$need_pkgs" ]; then
        log_info "安装依赖:$need_pkgs"
        pkg_update
        pkg_install $need_pkgs
    fi
    ddns_ensure_cron

    read_input "请输入完整域名 (如 home.example.com)" "" DDNS_DOMAIN
    if [ -z "$DDNS_DOMAIN" ]; then log_warn "已取消"; return 0; fi
    case "$DDNS_DOMAIN" in
        *.*) ;;
        *) log_error "域名格式不合法: $DDNS_DOMAIN"; return 1 ;;
    esac

    read_input "请输入 Cloudflare API Token (Zone:DNS:Edit 权限)" "" DDNS_TOKEN
    if [ -z "$DDNS_TOKEN" ]; then log_warn "已取消"; return 0; fi

    read_input "记录模式 (1=仅IPv4, 2=IPv4+IPv6)" "1" DDNS_MODE_CH
    case "$DDNS_MODE_CH" in
        2) DDNS_MODE="dual" ;;
        *) DDNS_MODE="ipv4" ;;
    esac

    if confirm "是否启用 Cloudflare 代理(橙云)?"; then
        DDNS_PROXIED="true"
    else
        DDNS_PROXIED="false"
    fi

    read_input "TTL 秒数" "60" DDNS_TTL
    case "$DDNS_TTL" in
        ''|*[!0-9]*) DDNS_TTL="60" ;;
    esac

    log_info "向上递归查找 Cloudflare zone..."
    zone_line=$(ddns_resolve_zone "$DDNS_DOMAIN" "$DDNS_TOKEN")
    rc=$?
    if [ "$rc" -eq 2 ]; then
        log_error "Token 验证失败, 请检查 Token 权限"
        return 1
    fi
    if [ "$rc" -ne 0 ] || [ -z "$zone_line" ]; then
        log_error "找不到 ${DDNS_DOMAIN} 对应的 Cloudflare Zone, 请确认域名已托管"
        return 1
    fi
    DDNS_ZONE_NAME=$(printf '%s' "$zone_line" | cut -d'|' -f1)
    ZONE_ID=$(printf '%s' "$zone_line" | cut -d'|' -f2)
    log_info "Zone: ${DDNS_ZONE_NAME}  (ID: ${ZONE_ID})"

    printf "\n${CYAN}--- 配置确认 ---${NC}\n"
    printf "  域名:    ${CYAN}%s${NC}\n" "$DDNS_DOMAIN"
    printf "  Zone:    ${CYAN}%s${NC}\n" "$DDNS_ZONE_NAME"
    [ "$DDNS_MODE" = "dual" ]    && pm="IPv4 + IPv6" || pm="仅 IPv4"
    [ "$DDNS_PROXIED" = "true" ] && pp="开启"       || pp="关闭"
    printf "  模式:    ${CYAN}%s${NC}\n" "$pm"
    printf "  CF 代理: ${CYAN}%s${NC}\n" "$pp"
    printf "  TTL:     ${CYAN}%s${NC}\n" "$DDNS_TTL"
    confirm "确认安装?" y || { log_warn "已取消"; return 0; }

    # A 记录: 不存在则创建占位
    rec=$(curl -s --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DDNS_DOMAIN}&type=A" \
        -H "Authorization: Bearer ${DDNS_TOKEN}")
    rec_count=$(printf '%s' "$rec" | python3 -c \
        "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
    if [ "$rec_count" = "0" ]; then
        log_warn "未找到 A 记录, 自动创建占位..."
        body=$(printf '{"type":"A","name":"%s","content":"1.1.1.1","ttl":%s,"proxied":%s}' \
            "$DDNS_DOMAIN" "$DDNS_TTL" "$DDNS_PROXIED")
        cr=$(curl -s -X POST --max-time 10 \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${DDNS_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$body")
        ok=$(printf '%s' "$cr" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
        if [ "$ok" = "True" ]; then
            log_info "A 记录已创建"
        else
            log_error "创建 A 记录失败"
            return 1
        fi
    else
        log_info "A 记录已存在"
    fi

    # AAAA 记录
    if [ "$DDNS_MODE" = "dual" ]; then
        rec=$(curl -s --max-time 10 \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DDNS_DOMAIN}&type=AAAA" \
            -H "Authorization: Bearer ${DDNS_TOKEN}")
        rec_count=$(printf '%s' "$rec" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
        if [ "$rec_count" = "0" ]; then
            log_warn "未找到 AAAA 记录, 自动创建占位..."
            body=$(printf '{"type":"AAAA","name":"%s","content":"::1","ttl":%s,"proxied":%s}' \
                "$DDNS_DOMAIN" "$DDNS_TTL" "$DDNS_PROXIED")
            cr=$(curl -s -X POST --max-time 10 \
                "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${DDNS_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "$body")
            ok=$(printf '%s' "$cr" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
            if [ "$ok" = "True" ]; then
                log_info "AAAA 记录已创建"
            else
                log_warn "AAAA 记录创建失败, 降级为仅 IPv4"
                DDNS_MODE="ipv4"
            fi
        else
            log_info "AAAA 记录已存在"
        fi
    fi

    # 持久化配置
    echo "$DDNS_TOKEN" > "$DDNS_TOKEN_FILE"
    chmod 600 "$DDNS_TOKEN_FILE"
    touch "$DDNS_LOG" 2>/dev/null || true
    chmod 644 "$DDNS_LOG" 2>/dev/null || true

    {
        echo "DOMAIN=${DDNS_DOMAIN}"
        echo "ZONE=${DDNS_ZONE_NAME}"
        echo "MODE=${DDNS_MODE}"
        echo "PROXIED=${DDNS_PROXIED}"
        echo "TTL=${DDNS_TTL}"
        echo "LOG=${DDNS_LOG}"
    } > "$DDNS_ZONE_FILE"

    # 写入执行脚本
    cat > "$DDNS_SCRIPT" <<'DDNS_INNER'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN="__DOMAIN__"
ZONE="__ZONE__"
MODE="__MODE__"
PROXIED="__PROXIED__"
TTL="__TTL__"
TOKEN_FILE="/root/.cf_token"
LOG_FILE="/var/log/ddns.log"

API_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
[ -z "$API_TOKEN" ] && exit 1

# 日志轮转 (>500 行截尾)
if [ -f "$LOG_FILE" ]; then
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_LINES" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

CURRENT_IP4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4 -s --max-time 5 https://ifconfig.me/ip 2>/dev/null \
    || curl -4 -s --max-time 5 https://ip.sb 2>/dev/null)
CURRENT_IP4=$(printf '%s' "$CURRENT_IP4" | tr -d '\r\n ')

CURRENT_IP6=""
if [ "$MODE" = "dual" ]; then
    CURRENT_IP6=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null \
        || curl -6 -s --max-time 5 https://ipv6.icanhazip.com 2>/dev/null)
    CURRENT_IP6=$(printf '%s' "$CURRENT_IP6" | tr -d '\r\n ')
fi

if [ -z "$CURRENT_IP4" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 无法获取公网 IPv4" >> "$LOG_FILE"
    exit 1
fi
if ! echo "$CURRENT_IP4" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取到的 IP 非法 ${CURRENT_IP4}" >> "$LOG_FILE"
    exit 1
fi

ZONE_ID=$(curl -s --max-time 8 "https://api.cloudflare.com/client/v4/zones?name=${ZONE}" \
    -H "Authorization: Bearer ${API_TOKEN}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
if [ -z "$ZONE_ID" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取 Zone ID 失败" >> "$LOG_FILE"
    exit 1
fi

update_record() {
    TYPE="$1"
    NEW_IP="$2"
    [ -z "$NEW_IP" ] && return 0
    RECORD_ID=$(curl -s --max-time 8 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN}&type=${TYPE}" \
        -H "Authorization: Bearer ${API_TOKEN}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
    if [ -z "$RECORD_ID" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 记录不存在" >> "$LOG_FILE"
        return 1
    fi
    OLD_IP=$(curl -s --max-time 8 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)
    if [ -z "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${TYPE} 无法获取当前记录值, 跳过" >> "$LOG_FILE"
        return 0
    fi
    if [ "$NEW_IP" = "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} 未变化 ${NEW_IP}" >> "$LOG_FILE"
        return 0
    fi
    JSON_BODY=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
        "$TYPE" "$DOMAIN" "$NEW_IP" "$TTL" "$PROXIED")
    RESULT=$(curl -s -X PUT --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$JSON_BODY")
    SUCCESS=$(echo "$RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('success'))" 2>/dev/null)
    if [ "$SUCCESS" = "True" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} 更新成功 ${OLD_IP} -> ${NEW_IP}" >> "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 更新失败 $RESULT" >> "$LOG_FILE"
        return 1
    fi
}

update_record A "$CURRENT_IP4"
if [ "$MODE" = "dual" ] && [ -n "$CURRENT_IP6" ]; then
    update_record AAAA "$CURRENT_IP6"
fi
DDNS_INNER

    sed -i "s|__DOMAIN__|${DDNS_DOMAIN}|g"      "$DDNS_SCRIPT"
    sed -i "s|__ZONE__|${DDNS_ZONE_NAME}|g"     "$DDNS_SCRIPT"
    sed -i "s|__MODE__|${DDNS_MODE}|g"          "$DDNS_SCRIPT"
    sed -i "s|__PROXIED__|${DDNS_PROXIED}|g"    "$DDNS_SCRIPT"
    sed -i "s|__TTL__|${DDNS_TTL}|g"            "$DDNS_SCRIPT"
    chmod 700 "$DDNS_SCRIPT"

    cron_job="*/5 * * * * ${DDNS_SCRIPT} >> ${DDNS_LOG} 2>&1"
    ( crontab -l 2>/dev/null | grep -v "ddns.sh"; echo "$cron_job" ) | crontab -
    log_info "crontab 已设置 (每5分钟自动更新)"

    log_info "立即执行一次测试..."
    if sh "$DDNS_SCRIPT"; then
        tail -n 1 "$DDNS_LOG" 2>/dev/null | while IFS= read -r l; do
            printf "  ${GREEN}%s${NC}\n" "$l"
        done
    else
        log_error "测试执行失败, 请查看日志: $DDNS_LOG"
    fi
    log_info "DDNS 配置完成: $DDNS_DOMAIN"
}

ddns_run_now() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        log_error "DDNS 未安装"
        return 1
    fi
    log_info "正在手动更新..."
    if sh "$DDNS_SCRIPT"; then
        log=$(ddns_log_path)
        tail -n 1 "$log" 2>/dev/null | while IFS= read -r l; do
            printf "  ${GREEN}%s${NC}\n" "$l"
        done
    else
        log_error "更新失败, 请查看日志"
    fi
}

ddns_view_logs() {
    log=$(ddns_log_path)
    if [ ! -f "$log" ]; then
        log_warn "日志文件不存在: $log"
        return 0
    fi
    printf "${CYAN}--- %s (尾部 30 行) ---${NC}\n" "$log"
    tail -n 30 "$log" | while IFS= read -r line; do
        case "$line" in
            *ERROR*)    printf "  ${RED}%s${NC}\n" "$line" ;;
            *"更新成功"*) printf "  ${GREEN}%s${NC}\n" "$line" ;;
            *)          printf "  %s\n" "$line" ;;
        esac
    done
}

ddns_pause() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        log_error "DDNS 未安装"
        return 1
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        log_warn "未安装 cron"
        return 0
    fi
    ( crontab -l 2>/dev/null | grep -v "ddns.sh" ) | crontab - 2>/dev/null
    log_info "DDNS 自动更新已暂停"
}

ddns_resume() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        log_error "DDNS 未安装"
        return 1
    fi
    ddns_ensure_cron
    log=$(ddns_log_path)
    cron_job="*/5 * * * * ${DDNS_SCRIPT} >> ${log} 2>&1"
    ( crontab -l 2>/dev/null | grep -v "ddns.sh"; echo "$cron_job" ) | crontab -
    log_info "DDNS 自动更新已恢复 (每5分钟)"
}

ddns_uninstall() {
    printf "${BLUE}=== 卸载 DDNS ===${NC}\n"
    if [ ! -f "$DDNS_SCRIPT" ] && [ ! -f "$DDNS_TOKEN_FILE" ] && [ ! -f "$DDNS_ZONE_FILE" ]; then
        log_warn "DDNS 未安装, 无需卸载"
        return 0
    fi
    confirm "确认卸载 DDNS? 将移除 cron / 脚本 / Token" || { log_warn "已取消"; return 0; }
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "ddns.sh" ) | crontab - 2>/dev/null
    fi
    rm -f "$DDNS_SCRIPT" "$DDNS_TOKEN_FILE" "$DDNS_ZONE_FILE"
    log_info "DDNS 已卸载 (日志文件保留: $DDNS_LOG)"
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
        if confirm "是否使用 minimal 镜像?"; then
            EXTRA_ARG="--minimal"
        fi
    fi

    # 登录用户名
    # 上游新版未指定 --username 时会从 stdin 交互询问, 在 curl|sh 场景下
    # stdin 非终端, read 遇 EOF 且上游 set -eE 会直接崩溃, 因此必须显式传参
    read_input "新系统登录用户名" "root" NEW_USER
    if printf '%s' "$NEW_USER" | grep -q '[][/\:|<>+=;,?*%@ ]'; then
        log_error "用户名包含非法字符: / \\ [ ] : | < > + = ; , ? * % @ 或空格"
        return 1
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
    printf "  用户名:   ${CYAN}%s${NC}\n" "$NEW_USER"
    printf "  SSH 端口: ${CYAN}%s${NC}\n" "$SSH_PORT"
    key_preview=$(printf '%s' "$SSH_KEY" | cut -c1-50)
    printf "  SSH 公钥: ${CYAN}%s...${NC} (长度: %s)\n" "$key_preview" "${#SSH_KEY}"

    printf "\n${RED}⚠️  即将执行系统重装. 本次 SSH 会话稍后会断开, 几分钟后机器以新系统启动.${NC}\n"
    # 高危操作: 保留行输入强确认, 必须完整输入 yes
    read_input "确认执行重装? 输入 yes 继续" "" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi

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
        log_info "命令: bash reinstall.sh $system $VERSION $EXTRA_ARG --username $NEW_USER --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" "$VERSION" "$EXTRA_ARG" --username "$NEW_USER" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    elif [ -n "$VERSION" ]; then
        log_info "命令: bash reinstall.sh $system $VERSION --username $NEW_USER --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" "$VERSION" --username "$NEW_USER" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    elif [ -n "$EXTRA_ARG" ]; then
        log_info "命令: bash reinstall.sh $system $EXTRA_ARG --username $NEW_USER --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" "$EXTRA_ARG" --username "$NEW_USER" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
    else
        log_info "命令: bash reinstall.sh $system --username $NEW_USER --ssh-key '...' --ssh-port $SSH_PORT"
        bash reinstall.sh "$system" --username "$NEW_USER" --ssh-key "$SSH_KEY" --ssh-port "$SSH_PORT"
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
# 主菜单任务 9: SSH 配置 (密钥 / 端口 / 密码登录)
# ================================================================

# 是否采用 drop-in 目录方式管理配置 (Ubuntu/Debian 新版)
ssh_use_dropin() {
    [ -d "$SSHD_DROPIN_DIR" ] || return 1
    grep -iq '^[[:space:]]*include[[:space:]].*sshd_config\.d' "$SSHD_CONFIG" 2>/dev/null
}

# 在指定文件中设置配置项: 替换首个同名指令 (含大小写不同), 删除重复项, 无则追加
_ssh_set_in_file() {
    _f="$1"; _k="$2"; _v="$3"
    _tmp="${_f}.tmp.$$"
    awk -v key="$_k" -v val="$_v" '
        BEGIN { lk = tolower(key); done = 0 }
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            n = split(line, a, /[ \t]+/)
            if (n > 0 && tolower(a[1]) == lk) {
                if (!done) { print key " " val; done = 1 }
                next
            }
            print
        }
        END { if (!done) print key " " val }
    ' "$_f" > "$_tmp" && cat "$_tmp" > "$_f" && rm -f "$_tmp"
}

# 在指定文件中注释掉某个配置项的所有生效行
_ssh_comment_in_file() {
    _f="$1"; _k="$2"
    [ -f "$_f" ] || return 0
    _tmp="${_f}.tmp.$$"
    awk -v key="$_k" '
        BEGIN { lk = tolower(key) }
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            n = split(line, a, /[ \t]+/)
            if (n > 0 && tolower(a[1]) == lk) { print "#" $0; next }
            print
        }
    ' "$_f" > "$_tmp" && cat "$_tmp" > "$_f" && rm -f "$_tmp"
}

# 设置 sshd 配置项 (优先写入 drop-in, 保证优先级最高)
ssh_config_set() {
    _key="$1"; _val="$2"
    if ssh_use_dropin; then
        [ -f "$SSHD_DROPIN" ] || printf '# 由 setup.sh 生成, 优先级最高 (00- 前缀)\n' > "$SSHD_DROPIN"
        _ssh_set_in_file "$SSHD_DROPIN" "$_key" "$_val"
        # Port 为累加型指令 (多条 = 监听多个端口), 需注释掉主配置中的旧值
        if [ "$_key" = "Port" ]; then
            _ssh_comment_in_file "$SSHD_CONFIG" "Port"
        fi
    else
        _ssh_set_in_file "$SSHD_CONFIG" "$_key" "$_val"
    fi
}

# 备份 / 恢复 sshd 配置 (校验失败时回滚)
ssh_backup_config() {
    cp -p "$SSHD_CONFIG" "${SSHD_CONFIG}.setup-bak" 2>/dev/null
    [ -f "$SSHD_DROPIN" ] && cp -p "$SSHD_DROPIN" "${SSHD_DROPIN}.setup-bak"
    return 0
}

ssh_restore_config() {
    [ -f "${SSHD_CONFIG}.setup-bak" ] && cat "${SSHD_CONFIG}.setup-bak" > "$SSHD_CONFIG"
    if [ -f "${SSHD_DROPIN}.setup-bak" ]; then
        cat "${SSHD_DROPIN}.setup-bak" > "$SSHD_DROPIN"
    elif [ -f "$SSHD_DROPIN" ]; then
        rm -f "$SSHD_DROPIN"
    fi
    return 0
}

# 重启 sshd (兼容 systemd socket 激活 / OpenRC / SysV)
ssh_restart_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        if systemctl is-active ssh.socket >/dev/null 2>&1; then
            systemctl restart ssh.socket 2>/dev/null || true
        fi
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sshd restart >/dev/null 2>&1
    else
        service sshd restart >/dev/null 2>&1 || service ssh restart >/dev/null 2>&1
    fi
}

# 校验配置并重启, 失败自动回滚 (返回 1)
ssh_validate_and_restart() {
    err=$(sshd -t 2>&1)
    if [ -n "$err" ]; then
        log_error "sshd 配置校验失败, 已回滚:"
        printf '%s\n' "$err"
        ssh_restore_config
        return 1
    fi
    ssh_restart_service
    log_info "sshd 已重启生效"
    return 0
}

# 读取 sshd 生效配置值 (sshd -T 输出为全小写键名)
ssh_effective() {
    sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { print $2; exit }'
}

# 密码登录当前是否开启
ssh_password_enabled() {
    v=$(ssh_effective passwordauthentication)
    [ "$v" != "no" ]
}

# 统计 authorized_keys 中的有效密钥数
ssh_key_count() {
    [ -f "$AUTH_KEYS_FILE" ] || { echo 0; return; }
    _cnt=$(grep -c -E '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$AUTH_KEYS_FILE" 2>/dev/null)
    echo "${_cnt:-0}"
}

# 确保 /root/.ssh 与 authorized_keys 存在且权限正确
ssh_ensure_authkeys() {
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"
}

ssh_status() {
    printf "${MAGENTA}--- SSH 状态 ---${NC}\n"
    if [ ! -f "$SSHD_CONFIG" ]; then
        printf "  ${RED}未找到 %s (openssh-server 未安装?)${NC}\n" "$SSHD_CONFIG"
        printf "${MAGENTA}----------------${NC}\n"
        return 0
    fi
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | tr '\n' ' ')
    [ -z "$ports" ] && ports="$(get_ssh_port) "
    pw=$(ssh_effective passwordauthentication)
    pk=$(ssh_effective pubkeyauthentication)
    rl=$(ssh_effective permitrootlogin)
    printf "  端口:       ${CYAN}%s${NC}\n" "$ports"
    if [ "$pw" = "no" ]; then
        printf "  密码登录:   ${GREEN}已关闭${NC}\n"
    else
        printf "  密码登录:   ${YELLOW}开启${NC}\n"
    fi
    if [ "$pk" = "no" ]; then
        printf "  密钥登录:   ${RED}已关闭${NC}\n"
    else
        printf "  密钥登录:   ${GREEN}开启${NC}\n"
    fi
    printf "  Root 登录:  ${CYAN}%s${NC}\n" "${rl:-未知}"
    printf "  已授权密钥: ${CYAN}%s 个${NC}\n" "$(ssh_key_count)"
    if ssh_use_dropin; then
        printf "  配置方式:   ${CYAN}drop-in (%s)${NC}\n" "$SSHD_DROPIN"
    else
        printf "  配置方式:   ${CYAN}%s${NC}\n" "$SSHD_CONFIG"
    fi
    printf "${MAGENTA}----------------${NC}\n"
}

# --- 密钥配置 ---
ssh_keys_view() {
    printf "${MAGENTA}--- 已授权密钥 (%s) ---${NC}\n" "$AUTH_KEYS_FILE"
    if [ ! -s "$AUTH_KEYS_FILE" ]; then
        printf "  ${YELLOW}(暂无密钥)${NC}\n"
        return 0
    fi
    i=0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        i=$((i + 1))
        ktype=$(printf '%s' "$line" | awk '{print $1}')
        kcomment=$(printf '%s' "$line" | awk '{ if (NF >= 3) { s = $3; for (j = 4; j <= NF; j++) s = s " " $j; print s } else print "-" }')
        fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        if [ -z "$fp" ]; then
            body=$(printf '%s' "$line" | awk '{print $2}')
            fp=$(printf '%s' "$body" | cut -c1-16)"..."
        fi
        printf "  ${GREEN}%d)${NC} %-12s %s  ${CYAN}%s${NC}\n" "$i" "$ktype" "$fp" "$kcomment"
    done < "$AUTH_KEYS_FILE"
    [ "$i" -eq 0 ] && printf "  ${YELLOW}(暂无密钥)${NC}\n"
    return 0
}

ssh_key_add() {
    printf "${CYAN}请粘贴公钥 (一整行, 以 ssh-ed25519 / ssh-rsa / ecdsa- 等开头, 回车取消):${NC}\n"
    read_tty pubkey
    [ -z "$pubkey" ] && return 1
    case "$pubkey" in
        ssh-ed25519\ *|ssh-rsa\ *|ssh-dss\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *|sk-ecdsa-*\ *) ;;
        *) log_error "格式不正确: 应为 \"<类型> <base64密钥> [注释]\""; return 1 ;;
    esac
    if command -v ssh-keygen >/dev/null 2>&1; then
        if ! printf '%s\n' "$pubkey" | ssh-keygen -lf - >/dev/null 2>&1; then
            log_error "公钥内容无效 (ssh-keygen 校验失败)"
            return 1
        fi
    fi
    ssh_ensure_authkeys
    keybody=$(printf '%s' "$pubkey" | awk '{print $2}')
    if grep -qF -- "$keybody" "$AUTH_KEYS_FILE"; then
        log_warn "该公钥已存在, 跳过"
        return 1
    fi
    printf '%s\n' "$pubkey" >> "$AUTH_KEYS_FILE"
    log_info "公钥已添加"
    return 1
}

ssh_key_generate() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log_error "未找到 ssh-keygen, 请先安装 openssh"
        return 0
    fi
    ssh_ensure_authkeys
    ts=$(date +%Y%m%d%H%M%S)
    keyfile="/root/.ssh/setup_ed25519_$ts"
    comment="setup-$(hostname 2>/dev/null || echo vps)-$(date +%Y%m%d)"
    if ! ssh-keygen -t ed25519 -f "$keyfile" -N "" -C "$comment" >/dev/null 2>&1; then
        log_error "密钥生成失败"
        return 0
    fi
    cat "${keyfile}.pub" >> "$AUTH_KEYS_FILE"
    log_info "已生成 ed25519 密钥对, 公钥已加入 authorized_keys"
    printf "\n${YELLOW}===== 请立即复制并妥善保存以下私钥 (仅显示这一次机会) =====${NC}\n"
    cat "$keyfile"
    printf "${YELLOW}============================================================${NC}\n"
    printf "本地保存为 ~/.ssh/id_ed25519_vps 并执行: ${CYAN}chmod 600 ~/.ssh/id_ed25519_vps${NC}\n"
    printf "登录命令: ${CYAN}ssh -i ~/.ssh/id_ed25519_vps -p %s root@服务器IP${NC}\n" "$(get_ssh_port)"
    if confirm "是否从服务器删除私钥文件 (保存好后建议删除)?"; then
        rm -f "$keyfile"
        log_info "服务器上的私钥文件已删除"
    else
        log_warn "私钥保留在: $keyfile"
    fi
}

ssh_key_delete() {
    n=$(ssh_key_count)
    if [ "$n" -eq 0 ]; then
        log_warn "没有可删除的密钥"
        return 1
    fi
    read_input "请输入要删除的密钥序号 (回车取消)" "" idx
    [ -z "$idx" ] && return 1
    case "$idx" in
        *[!0-9]*) log_error "无效序号: $idx"; return 1 ;;
    esac
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$n" ]; then
        log_error "序号超出范围 (1-$n)"
        return 1
    fi
    if [ "$n" -eq 1 ] && ! ssh_password_enabled; then
        log_error "密码登录已关闭, 禁止删除最后一把密钥 (会导致无法登录)"
        log_warn  "请先开启密码登录或添加新密钥"
        return 1
    fi
    _tmp="${AUTH_KEYS_FILE}.tmp.$$"
    awk -v n="$idx" '
        /^[ \t]*(#|$)/ { print; next }
        { i++; if (i != n) print }
    ' "$AUTH_KEYS_FILE" > "$_tmp" && cat "$_tmp" > "$AUTH_KEYS_FILE" && rm -f "$_tmp"
    log_info "密钥 #$idx 已删除"
    return 1
}

# --- 端口配置 ---
ssh_port_config() {
    cur_port=$(get_ssh_port)
    printf "${BLUE}=== SSH 端口配置 ===${NC}\n"
    printf "当前端口: ${CYAN}%s${NC}\n" "$cur_port"
    read_input "请输入新的 SSH 端口 (1-65535)" "$cur_port" new_port
    case "$new_port" in
        *[!0-9]*|'') log_error "无效端口: $new_port"; return 0 ;;
    esac
    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        log_error "端口超出范围: $new_port"
        return 0
    fi
    if [ "$new_port" = "$cur_port" ]; then
        log_warn "端口未变化, 无需修改"
        return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${new_port}$"; then
            log_error "端口 $new_port 已被其他进程占用"
            return 0
        fi
    fi
    confirm "确认将 SSH 端口改为 $new_port?" || { log_warn "已取消"; return 0; }

    ssh_backup_config
    ssh_config_set Port "$new_port"
    ssh_validate_and_restart || return 0

    printf "\n"
    log_info "SSH 端口已修改为: $new_port"
    log_warn "请保持当前会话不要断开, 另开终端验证: ssh -p $new_port root@服务器IP"
    log_warn "如使用云服务器, 请在安全组中放行 TCP $new_port"
    if [ -f "$FAIL2BAN_JAILS_FILE" ] && command -v fail2ban-client >/dev/null 2>&1; then
        log_warn "检测到 Fail2Ban, 建议进入 [Fail2Ban 菜单] 重新应用配置以跟随新端口"
    fi
}

# --- 密码登录开关 ---
ssh_password_disable() {
    n=$(ssh_key_count)
    if [ "$n" -eq 0 ]; then
        log_error "authorized_keys 中没有任何密钥, 禁止关闭密码登录 (会导致无法登录)"
        log_warn  "请先在 [密钥配置] 中添加公钥并验证密钥可登录"
        return 0
    fi
    printf "${YELLOW}关闭后仅能通过密钥登录, 请确认已用密钥成功登录过本机!${NC}\n"
    read_input "确认关闭密码登录? 输入 yes 继续" "" confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "已取消"
        return 0
    fi
    ssh_backup_config
    ssh_config_set PubkeyAuthentication yes
    ssh_config_set PasswordAuthentication no
    # 新版 OpenSSH 用 KbdInteractiveAuthentication, 旧版 (如 CentOS 7) 只认 ChallengeResponseAuthentication
    if sshd -T 2>/dev/null | grep -q '^kbdinteractiveauthentication'; then
        ssh_config_set KbdInteractiveAuthentication no
    else
        ssh_config_set ChallengeResponseAuthentication no
    fi
    ssh_validate_and_restart || return 0
    log_info "密码登录已关闭, 仅允许密钥登录"
    log_warn "请保持当前会话不要断开, 另开终端验证密钥登录正常"
}

ssh_password_enable() {
    confirm "确认重新开启密码登录?" || { log_warn "已取消"; return 0; }
    ssh_backup_config
    ssh_config_set PasswordAuthentication yes
    if sshd -T 2>/dev/null | grep -q '^kbdinteractiveauthentication'; then
        ssh_config_set KbdInteractiveAuthentication yes
    else
        ssh_config_set ChallengeResponseAuthentication yes
    fi
    ssh_validate_and_restart || return 0
    log_info "密码登录已开启"
}

# ================================================================
# 子菜单: NTP 服务器 (增删改查)
# ================================================================
# ================================================================
# 模块状态速览 (主菜单仪表盘)
# ================================================================
svc_active() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$1" 2>/dev/null && return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$1" status >/dev/null 2>&1 && return 0
    fi
    pidof "$1" >/dev/null 2>&1
}

# brief_svc <二进制> <服务名>: 输出 未安装/运行中/已停止 状态点
brief_svc() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%s' "${GRAY}○ 未安装${NC}"
    elif svc_active "$2"; then
        printf '%s' "${GREEN}● 运行中${NC}"
    else
        printf '%s' "${YELLOW}○ 已停止${NC}"
    fi
}

brief_firewall() {
    if ! command -v nft >/dev/null 2>&1; then
        printf '%s' "${GRAY}○ 未安装${NC}"
    elif nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        printf '%s' "${GREEN}● 已启用${NC}"
    else
        printf '%s' "${YELLOW}○ 未启用${NC}"
    fi
}

brief_tcp() {
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        printf '%s' "${GREEN}● BBR${NC}"
    else
        printf '%s' "${GRAY}○ 未启用${NC}"
    fi
}

brief_acme() {
    if ! acme_installed; then
        printf '%s' "${GRAY}○ 未安装${NC}"
        return
    fi
    _n=$(acme_list_domains | grep -c .)
    if [ "$_n" -eq 0 ]; then
        printf '%s' "${YELLOW}○ 无证书${NC}"
    else
        printf '%s' "${GREEN}● ${_n} 张证书${NC}"
    fi
}
brief_ddns() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        printf '%s' "${GRAY}○ 未配置${NC}"
    elif ddns_cron_enabled; then
        printf '%s' "${GREEN}● 自动更新${NC}"
    else
        printf '%s' "${YELLOW}● 已暂停${NC}"
    fi
}

brief_ssh() {
    if [ ! -f "$SSHD_CONFIG" ]; then
        printf '%s' "${GRAY}○ 未检测到${NC}"
        return
    fi
    _p=$(get_ssh_port)
    if ssh_password_enabled; then
        printf '%s' "端口 ${_p} · ${YELLOW}密码开${NC}"
    else
        printf '%s' "端口 ${_p} · ${GREEN}仅密钥${NC}"
    fi
}

# ================================================================
# 子菜单: NTP
# ================================================================
ntp_servers_items() {
    printf '%s\n' "1|添加服务器|ntp_servers_add|act"
    printf '%s\n' "2|删除服务器|ntp_servers_delete|act"
    printf '%s\n' "3|修改服务器|ntp_servers_modify|act"
}
menu_ntp_servers() { run_menu "NTP › 服务器列表" ntp_servers_view ntp_servers_items; }

# 状态自适应: 未安装只给安装; 运行中给同步/停止; 已停止给启动
ntp_items() {
    if ! command -v chronyd >/dev/null 2>&1; then
        printf '%s\n' "1|安装 chrony|ntp_install|act"
        return 0
    fi
    if svc_active "$CHRONY_SERVICE"; then
        printf '%s\n' "1|强制同步一次|ntp_force_sync|act"
        printf '%s\n' "2|配置 NTP 服务器 ›|menu_ntp_servers|sub"
        printf '%s\n' "3|查看详细状态|ntp_view_detail|act"
        printf '%s\n' "4|停止 NTP 同步|ntp_disable|act"
    else
        printf '%s\n' "1|启动 NTP 同步|ntp_enable|act"
        printf '%s\n' "2|配置 NTP 服务器 ›|menu_ntp_servers|sub"
        printf '%s\n' "3|查看详细状态|ntp_view_detail|act"
    fi
    printf '%s\n' "x|卸载 chrony|ntp_uninstall|act"
}
menu_ntp() { run_menu "NTP 时间同步" ntp_status ntp_items; }

# ================================================================
# 子菜单: Fail2Ban
# ================================================================
fail2ban_jails_items() {
    printf '%s\n' "1|添加监狱|fail2ban_jail_add|act"
    printf '%s\n' "2|删除监狱|fail2ban_jail_delete|act"
    printf '%s\n' "3|修改监狱|fail2ban_jail_modify|act"
}
menu_fail2ban_jails() { run_menu "Fail2Ban › 监狱列表" fail2ban_jail_view fail2ban_jails_items; }

# 状态自适应: 运行中给查看/解封; 已停止给启用
fail2ban_items() {
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        printf '%s\n' "1|安装 Fail2Ban|fail2ban_install|act"
        return 0
    fi
    if svc_active fail2ban; then
        printf '%s\n' "1|查看监禁状态|fail2ban_view|act"
        printf '%s\n' "2|解封 IP|fail2ban_unban|act"
        printf '%s\n' "3|配置监狱 ›|menu_fail2ban_jails|sub"
        printf '%s\n' "4|停止 Fail2Ban|fail2ban_disable|act"
    else
        printf '%s\n' "1|启用 Fail2Ban (读取监狱配置并启动)|fail2ban_enable|act"
        printf '%s\n' "2|配置监狱 ›|menu_fail2ban_jails|sub"
    fi
    printf '%s\n' "x|卸载 Fail2Ban|fail2ban_uninstall|act"
}
menu_fail2ban() { run_menu "Fail2Ban" fail2ban_status fail2ban_items; }

# ================================================================
# 子菜单: Sing-Box
# ================================================================
# 状态自适应: 未安装→安装; 未配置→选协议 (原"配置代理"子层已拍平); 已配置→日常操作
singbox_items() {
    if ! command -v sing-box >/dev/null 2>&1; then
        printf '%s\n' "1|安装 Sing-Box|singbox_install|act"
        return 0
    fi
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        printf '%s\n' "1|配置 Shadowsocks-2022|singbox_configure_ss2022|act"
        printf '%s\n' "2|配置 VLESS + Reality|singbox_configure_vless_reality|act"
        printf '%s\n' "3|配置 AnyTLS|singbox_configure_anytls|act"
    else
        printf '%s\n' "1|查看代理链接|singbox_view_link|act"
        printf '%s\n' "2|重启代理|singbox_restart_proxy|act"
        printf '%s\n' "3|重新配置 Shadowsocks-2022|singbox_configure_ss2022|act"
        printf '%s\n' "4|重新配置 VLESS + Reality|singbox_configure_vless_reality|act"
        printf '%s\n' "5|重新配置 AnyTLS|singbox_configure_anytls|act"
        printf '%s\n' "6|删除代理配置|singbox_delete_proxy|act"
    fi
    printf '%s\n' "x|卸载 Sing-Box|singbox_uninstall|act"
}
menu_singbox() { run_menu "Sing-Box" singbox_status singbox_items; }

# ================================================================
# 子菜单: ACME 证书
# ================================================================
# 状态自适应: 未安装→只给安装; 已安装→申请/续期/删除
acme_items() {
    if ! acme_installed; then
        printf '%s\n' "1|安装 acme.sh|acme_install|act"
        return 0
    fi
    printf '%s\n' "1|申请证书|acme_issue_interactive|act"
    if [ "$(acme_list_domains | grep -c .)" -gt 0 ]; then
        printf '%s\n' "2|强制续期|acme_renew|act"
        printf '%s\n' "3|删除证书|acme_delete|act"
    fi
    printf '%s\n' "x|卸载 acme.sh|acme_uninstall|act"
}
menu_acme() { run_menu "ACME 证书" acme_status acme_items; }

# ================================================================
# 子菜单: 防火墙
# ================================================================
firewall_ip_items() {
    printf '%s\n' "1|添加 IP|whitelist_add|act"
    printf '%s\n' "2|删除 IP|whitelist_delete|act"
    printf '%s\n' "3|修改 IP|whitelist_modify|act"
}
menu_firewall_ip() { run_menu "防火墙 › 入站 IP" whitelist_view firewall_ip_items; }

# 状态自适应: 未安装→安装; 未启用→启用优先; 已启用→配置优先
firewall_items() {
    if ! command -v nft >/dev/null 2>&1; then
        printf '%s\n' "1|安装 nftables|nft_install|act"
        return 0
    fi
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        printf '%s\n' "1|配置入站 IP ›|menu_firewall_ip|sub"
        printf '%s\n' "2|禁用防火墙|firewall_disable|act"
        printf '%s\n' "3|清空 nft 规则|nft_clear|act"
    else
        printf '%s\n' "1|启用防火墙|firewall_enable|act"
        printf '%s\n' "2|配置入站 IP ›|menu_firewall_ip|sub"
    fi
    printf '%s\n' "x|卸载 nftables|nft_uninstall|act"
}
menu_firewall() { run_menu "防火墙 (nftables)" nft_status firewall_items; }

# ================================================================
# 子菜单: Realm
# ================================================================
realm_endpoints_items() {
    printf '%s\n' "1|添加转发规则|realm_endpoint_add|act"
    printf '%s\n' "2|删除转发规则|realm_endpoint_delete|act"
    printf '%s\n' "3|修改转发规则|realm_endpoint_modify|act"
}
menu_realm_endpoints() { run_menu "Realm › 转发规则" realm_endpoints_view realm_endpoints_items; }

# 状态自适应: 未安装→安装; 运行中→规则/重启/停止; 已停止→启动
realm_items() {
    if ! command -v realm >/dev/null 2>&1; then
        printf '%s\n' "1|安装 realm|realm_install|act"
        return 0
    fi
    printf '%s\n' "1|配置转发规则 ›|menu_realm_endpoints|sub"
    if svc_active realm; then
        printf '%s\n' "2|重启 realm|realm_restart|act"
        printf '%s\n' "3|停止 realm|realm_disable|act"
        printf '%s\n' "4|查看完整配置|realm_view_config|act"
    else
        printf '%s\n' "2|启动 realm|realm_enable|act"
        printf '%s\n' "3|查看完整配置|realm_view_config|act"
    fi
    printf '%s\n' "x|卸载 realm|realm_uninstall|act"
}
menu_realm() { run_menu "Realm 转发" realm_status realm_items; }

# ================================================================
# 子菜单: Cloudflare DDNS
# ================================================================
# 状态自适应: 常用操作优先, 重新配置靠后, 卸载用 x
ddns_items() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        printf '%s\n' "1|安装并配置 DDNS|ddns_install|act"
        return 0
    fi
    printf '%s\n' "1|立即手动更新一次|ddns_run_now|act"
    printf '%s\n' "2|查看日志|ddns_view_logs|act"
    if ddns_cron_enabled; then
        printf '%s\n' "3|暂停自动更新|ddns_pause|act"
    else
        printf '%s\n' "3|恢复自动更新|ddns_resume|act"
    fi
    printf '%s\n' "4|重新配置 DDNS|ddns_install|act"
    printf '%s\n' "x|卸载 DDNS|ddns_uninstall|act"
}
menu_ddns() { run_menu "Cloudflare DDNS" ddns_status ddns_items; }

# ================================================================
# 子菜单: TCP 调优
# ================================================================
# 状态自适应: 未启用→应用; 已启用→重新调参/移除
tcp_items() {
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        printf '%s\n' "1|重新应用 BBR 优化 (调整带宽/延迟参数)|bbr_apply|act"
        printf '%s\n' "2|查看当前 TCP 参数|tcp_view_params|act"
        printf '%s\n' "3|移除 BBR 优化|bbr_remove|act"
    else
        printf '%s\n' "1|应用 BBR 优化 (按带宽+延迟自动计算缓冲)|bbr_apply|act"
        printf '%s\n' "2|查看当前 TCP 参数|tcp_view_params|act"
    fi
}
menu_tcp_tune() { run_menu "TCP 调优 (BBR)" tcp_status tcp_items; }

# ================================================================
# 子菜单: SSH 配置
# ================================================================
ssh_keys_items() {
    printf '%s\n' "1|粘贴添加公钥|ssh_key_add|act"
    printf '%s\n' "2|生成新密钥对|ssh_key_generate|act"
    printf '%s\n' "3|删除公钥|ssh_key_delete|act"
}
menu_ssh_keys() { run_menu "SSH › 密钥" ssh_keys_view ssh_keys_items; }

ssh_items() {
    printf '%s\n' "1|密钥配置 ›|menu_ssh_keys|sub"
    printf '%s\n' "2|端口配置|ssh_port_config|act"
    if ssh_password_enabled; then
        printf '%s\n' "3|关闭密码登录 (仅密钥)|ssh_password_disable|act"
    else
        printf '%s\n' "3|开启密码登录|ssh_password_enable|act"
    fi
}
menu_ssh() {
    if [ ! -f "$SSHD_CONFIG" ]; then
        log_error "未找到 $SSHD_CONFIG, 请先安装 openssh-server"
        press_to_continue
        return 0
    fi
    run_menu "SSH 配置" ssh_status ssh_items
}

# ================================================================
# 主菜单 (仪表盘)
# ================================================================
main_items() {
    printf '%s\n' "1|安装常用软件|task_install_common|act"
    printf '%s\n' "2|NTP 时间同步            $(brief_svc chronyd "$CHRONY_SERVICE")|menu_ntp|sub"
    printf '%s\n' "3|Fail2Ban                $(brief_svc fail2ban-server fail2ban)|menu_fail2ban|sub"
    printf '%s\n' "4|Sing-Box                $(brief_svc sing-box sing-box)|menu_singbox|sub"
    printf '%s\n' "5|防火墙 (nftables)       $(brief_firewall)|menu_firewall|sub"
    printf '%s\n' "6|TCP 调优 (BBR)          $(brief_tcp)|menu_tcp_tune|sub"
    printf '%s\n' "7|Realm 转发              $(brief_svc realm realm)|menu_realm|sub"
    printf '%s\n' "8|Cloudflare DDNS         $(brief_ddns)|menu_ddns|sub"
    printf '%s\n' "9|SSH 配置                $(brief_ssh)|menu_ssh|sub"
    printf '%s\n' "c|ACME 证书               $(brief_acme)|menu_acme|sub"
    printf '%s\n' "d|${RED}系统重装 (DD) ⚠${NC}|task_system_reinstall|act"
}
menu_main() { run_menu "主菜单" - main_items top; }

# --- 入口 ---
check_root
detect_os
if [ -z "$PKG_MGR" ]; then
    log_error "未能识别系统的包管理器, 软件安装相关功能将不可用"
    log_warn  "已识别系统: ${OS_PRETTY:-未知} (family=${OS_FAMILY:-unknown})"
elif [ "$OS_FAMILY" = "unknown" ]; then
    log_warn "未能识别发行版系族 (${OS_PRETTY:-未知}), 将基于包管理器 ($PKG_MGR) 尽力运行"
fi
resolve_chrony
IP_CACHE=$(get_server_ip)
menu_main
