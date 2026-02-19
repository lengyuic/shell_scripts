#!/bin/sh

# Debian 13 Fail2Ban 1.1.0 自动配置脚本 (POSIX sh 版)
# 适用环境: Debian 13 (Trixie/Sid)
# 功能: 自动检测 SSH 端口、配置 nftables、适配 Systemd Journal
# 运行方式: sh ./script.sh

set -e  # 遇到错误立即退出

# --- 颜色定义 (使用 printf 输出) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 辅助函数 ---
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# 1. 检查 Root 权限 (使用 id -u 替代 EUID)
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 权限运行: sudo sh $0"
    exit 1
fi

# 2. 获取真实的 SSH 端口
get_ssh_port() {
    ssh_port=""
    # 尝试从 sshd 运行配置中获取
    if command -v sshd >/dev/null 2>&1; then
        ssh_port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -n 1)
    fi

    # 如果获取失败，回退到默认 22
    if [ -z "$ssh_port" ]; then
        # 输出到 stderr 以避免污染函数返回值
        printf "${YELLOW}[WARN]无法检测到 SSH 运行端口，默认使用 22${NC}\n" >&2
        ssh_port=22
    fi
    echo "$ssh_port"
}

# 3. 安装 Fail2Ban
install_fail2ban() {
    log_info "更新软件源并安装 Fail2Ban..."
    
    apt-get update -qq >/dev/null
    
    # 2. 安装：
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban nftables >/dev/null
    
    # 验证安装
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        log_error "Fail2Ban 安装失败"
        exit 1
    fi
    
    # 获取版本号
    ver=$(fail2ban-server --version | head -n 1)
    log_info "Fail2Ban 安装成功 ($ver)"
}


# 4. 配置 Fail2Ban (针对 1.1.0 + Systemd 优化)
configure_fail2ban() {
    port_to_ban=$1
    jail_local="/etc/fail2ban/jail.local"
    
    log_info "生成配置文件: $jail_local"
    log_info "检测到的 SSH 端口: $port_to_ban"
    log_info "后端模式: systemd (无需 auth.log)"

    # 备份旧配置
    if [ -f "$jail_local" ]; then
        cp "$jail_local" "${jail_local}.bak.$(date +%s)"
        log_warn "已备份现有 jail.local"
    fi

    cat > "$jail_local" << EOF
# Fail2Ban Configuration for Debian 13 (POSIX sh generated)
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

[sshd]
enabled = true
port    = $port_to_ban
mode    = normal
maxretry = 3
bantime  = 2h

[sshd-ddos]
enabled = true
port    = $port_to_ban
filter  = sshd-ddos
maxretry = 2
bantime  = 4h

[recidive]
enabled  = true
backend  = auto 
logpath  = /var/log/fail2ban.log
protocol = all
bantime  = 1w
findtime = 1d
maxretry = 3
EOF
}

# 5. 启动服务
start_services() {
    log_info "重启 Fail2Ban 服务..."
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    sleep 2
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2Ban 服务运行正常"
    else
        log_error "Fail2Ban 启动失败，请检查: systemctl status fail2ban"
        exit 1
    fi
}

# --- 主流程 ---
main() {
    printf "${BLUE}=== Debian 13 Fail2Ban 配置脚本 (sh版) ===${NC}\n"
    
    SSH_PORT=$(get_ssh_port)
    install_fail2ban
    configure_fail2ban "$SSH_PORT"
    start_services
    
    printf "\n"
    printf "${GREEN}配置完成!${NC}\n"
    printf "当前 SSH 端口: ${YELLOW}%s${NC}\n" "$SSH_PORT"
    printf "查看状态命令: ${YELLOW}fail2ban-client status sshd${NC}\n"
    printf "测试封禁命令: ${YELLOW}fail2ban-client set sshd banip 1.2.3.4${NC}\n"
}

main
