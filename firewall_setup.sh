#!/bin/sh

# Debian 13 Nftables 白名单自动配置脚本 (调试模式)
# 功能: 自动识别端口，配置 SSH 全放行 (配合 Fail2Ban)，SS 仅白名单
# 注意: 此版本不会开机自启，重启服务器后规则失效 (安全兜底)

set -e

# --- 变量与默认值 ---
NFT_CONF="/etc/nftables.conf"
SB_CONF="/etc/sing-box/config.json"
RELAY_IP="${RELAY_IP:-}" 

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 辅助函数 ---
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# 1. 检查 Root
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 权限运行"
    exit 1
fi

# 2. 环境检查与安装
check_install_deps() {
    log_info "检查依赖环境..."
    
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "未检测到 nftables，开始安装..."
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null
    fi

    if ! command -v sshd >/dev/null 2>&1; then
        log_warn "未找到 sshd 命令，尝试安装 openssh-server..."
        apt-get install -y -qq openssh-server >/dev/null
    fi
}

# 3. 获取端口信息
get_ports() {
    log_info "正在探测端口信息..."

    # 获取 SSH 端口
    SSH_PORT=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -n 1)
    if [ -z "$SSH_PORT" ]; then
        SSH_PORT=22
        log_warn "无法检测 SSH 端口，回退默认值: 22"
    else
        log_info "检测到 SSH 端口: ${SSH_PORT}"
    fi

    # 获取 Sing-Box 端口
    if [ -f "$SB_CONF" ]; then
        SB_PORT=$(grep "listen_port" "$SB_CONF" | head -n 1 | tr -cd '0-9')
        if [ -n "$SB_PORT" ]; then
            log_info "检测到 Sing-Box 端口: ${SB_PORT}"
        else
            log_error "无法从配置文件解析 Sing-Box 端口"
            exit 1
        fi
    else
        log_error "未找到 Sing-Box 配置文件: $SB_CONF"
        exit 1
    fi
}

# 4. 获取白名单 IP
get_relay_ip() {
    if [ -z "$RELAY_IP" ]; then
        printf "${YELLOW}请输入中转机 IP (白名单): ${NC}"
        if [ -t 0 ]; then
            read -r RELAY_IP
        else
            if [ -c /dev/tty ]; then
                read -r RELAY_IP < /dev/tty
            else
                log_error "无法读取输入。请使用: export RELAY_IP='x.x.x.x'; curl ... | sh"
                exit 1
            fi
        fi
    fi

    if [ -z "$RELAY_IP" ]; then
        log_error "IP 地址不能为空！"
        exit 1
    fi
    
    log_info "将允许 IP [${RELAY_IP}] 访问 Sing-Box 服务"
}

# 5. 生成 Nftables 配置
generate_nft_config() {
    log_info "生成 Nftables 配置文件..."

    if [ -f "$NFT_CONF" ]; then
        cp "$NFT_CONF" "${NFT_CONF}.bak.$(date +%s)"
    fi

    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet my_firewall {
    set whitelist_ips {
        type ipv4_addr
        elements = { ${RELAY_IP} }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        # 允许本地回环
        iif "lo" accept

        # 允许已建立连接
        ct state established,related accept

        # 允许 Ping
        ip protocol icmp accept

        # SSH: 全网开放 (Fail2Ban 保护)
        tcp dport ${SSH_PORT} accept

        # Sing-Box: 仅白名单
        ip saddr @whitelist_ips tcp dport ${SB_PORT} accept
        ip saddr @whitelist_ips udp dport ${SB_PORT} accept
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

# 6. 应用并验证 (调试模式核心修改)
apply_firewall() {
    log_info "正在应用防火墙规则 (当前会话)..."
    
    if ! nft -c -f "$NFT_CONF"; then
        log_error "配置文件语法错误！"
        exit 1
    fi

    # 仅加载文件，不启用 systemd 服务
    if nft -f "$NFT_CONF"; then
        log_info "✅ 规则已立即生效！"
        
        # --- 关键修改：注释掉开机自启 ---
        # systemctl enable nftables >/dev/null 2>&1
        # systemctl restart nftables
        # ------------------------------
        
        log_warn "⚠️  注意：开机自启已禁用 (调试模式)"
        log_warn "如果测试出现问题，重启服务器即可恢复原状。"
    else
        log_error "规则应用失败！"
        exit 1
    fi
}

# 7. 最终状态输出
print_status() {
    printf "\n"
    printf "${BLUE}========================================================${NC}\n"
    printf "🛡️  防火墙配置完成 (调试模式)\n"
    printf "${BLUE}========================================================${NC}\n"
    printf "${CYAN}SSH 端口 (${SSH_PORT}):${NC}  全网开放\n"
    printf "${CYAN}SS  端口 (${SB_PORT}):${NC}  仅限白名单 IP [${RELAY_IP}]\n"
    printf "${BLUE}========================================================${NC}\n"
    printf "👉 测试流程:\n"
    printf "1. 尝试连接 SSH (应该成功)\n"
    printf "2. 尝试连接 SS 节点 (应该成功)\n"
    printf "3. 如果一切正常，请执行命令永久生效:\n"
    printf "${GREEN}   systemctl enable nftables && systemctl start nftables${NC}\n"
    printf "${BLUE}========================================================${NC}\n"
}

# --- 主流程 ---
main() {
    printf "${BLUE}🚀 Debian 13 Nftables 自动配置脚本 (调试版)${NC}\n"
    check_install_deps
    get_ports
    get_relay_ip
    generate_nft_config
    apply_firewall
    print_status
}

main
