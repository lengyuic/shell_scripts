#!/bin/sh

# ==========================================
# Debian 13 Nftables 自动部署脚本 (POSIX sh版)
# 兼容性: /bin/sh (Dash, Ash, Bash)
# 功能: 隐身模式 (中国 IP 无法 Ping)
# ==========================================

set -e

# --- 变量定义 ---
NFT_CONF="/etc/nftables.conf"
SB_CONF="/etc/sing-box/config.json"
ZONE_FILE="/tmp/cn.zone"

# ANSI 颜色 (使用 printf 输出)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 辅助函数: 打印日志 ---
log_info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}
log_error() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
}

# --- 1. 核心: 智能解析 IP (POSIX 兼容写法) ---
parse_ips() {
    if [ -z "$RELAY_IP" ]; then
        log_error "未检测到 RELAY_IP 环境变量！"
        exit 1
    fi

    # 预处理: 将所有逗号替换为空格，以便处理
    # 这里的逻辑是先统一格式，再根据是否有 | 来分割
    CLEAN_RELAY=$(echo "$RELAY_IP" | tr ',' ' ')

    # 检查是否包含 "|" (使用 grep)
    if echo "$RELAY_IP" | grep -q "|"; then
        # === 模式 A: 显式分隔 (|) ===
        # 使用 cut 获取分隔符前后的内容
        ADMIN_RAW=$(echo "$RELAY_IP" | cut -d'|' -f1)
        USER_RAW=$(echo "$RELAY_IP" | cut -d'|' -f2)
    else
        # === 模式 B: 默认逻辑 (首位Admin) ===
        # awk '{print $1}' 获取第一个
        ADMIN_RAW=$(echo "$CLEAN_RELAY" | awk '{print $1}')
        # awk 打印从第2个开始的所有字段
        USER_RAW=$(echo "$CLEAN_RELAY" | awk '{$1=""; print $0}')
    fi

    # 格式化为 Nftables 列表格式 (逗号分隔)
    # 1. tr ',' ' ' : 确保输入是空格分隔
    # 2. xargs : 去除首尾空格
    # 3. sed : 将中间的空格替换为 ", "
    
    # 处理 Admin IP
    ADMIN_IPS=$(echo "$ADMIN_RAW" | tr ',' ' ' | xargs | sed 's/ /, /g')
    
    # 处理 User IP
    USER_IPS=$(echo "$USER_RAW" | tr ',' ' ' | xargs | sed 's/ /, /g')

    if [ -z "$ADMIN_IPS" ]; then
        log_error "解析失败: 必须至少有一个管理员 IP"
        exit 1
    fi

    log_info "权限分配:"
    printf "   👑 管理员: ${GREEN}${ADMIN_IPS}${NC}\n"
    if [ -n "$USER_IPS" ]; then
        printf "   👥 用户:   ${GREEN}${USER_IPS}${NC}\n"
    else
        printf "   👥 用户:   ${YELLOW}无${NC}\n"
    fi
}

# --- 2. 环境检查 ---
check_env() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限运行"
        exit 1
    fi

    # POSIX 检查命令是否存在
    if ! command -v curl >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq curl
    fi
    if ! command -v nft >/dev/null 2>&1; then
        apt-get install -y -qq nftables
    fi
    if ! command -v sshd >/dev/null 2>&1; then
        apt-get install -y -qq openssh-server
    fi
}

# --- 3. 下载 IP 库 ---
download_cn() {
    log_info "正在下载中国 IP 数据库..."
    curl -s --retry 3 http://www.ipdeny.com/ipblocks/data/countries/cn.zone -o "$ZONE_FILE"
    if [ ! -s "$ZONE_FILE" ]; then
        log_error "IP 库下载失败"
        exit 1
    fi
}

# --- 4. 获取端口 ---
get_ports() {
    # 获取 SSH 端口
    SSH_PORT=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -n 1)
    if [ -z "$SSH_PORT" ]; then SSH_PORT=22; fi

    # 获取 Sing-Box 端口
    if [ -f "$SB_CONF" ]; then
        # 使用 tr 删除非数字字符
        SB_PORT=$(grep "listen_port" "$SB_CONF" | head -n 1 | tr -cd '0-9')
    else
        log_error "未找到 Sing-Box 配置文件: $SB_CONF"
        exit 1
    fi
    
    log_info "端口探测: SSH=[$SSH_PORT], SS=[$SB_PORT]"
}

# --- 5. 生成 Nftables 配置 ---
generate_nft() {
    log_info "正在生成防火墙规则 (隐身模式)..."

    # 开始写入配置文件
    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet my_firewall {
    # 👑 管理员集合
    set admin_ips {
        type ipv4_addr
        elements = { ${ADMIN_IPS} }
    }
EOF

    # 如果有用户 IP，则写入用户集合
    if [ -n "$USER_IPS" ]; then
        cat >> "$NFT_CONF" <<EOF
    # 👥 用户集合
    set user_ips {
        type ipv4_addr
        elements = { ${USER_IPS} }
    }
EOF
    fi

    cat >> "$NFT_CONF" <<EOF
    # 🇨🇳 中国 IP 集合
    set cn_ips {
        type ipv4_addr
        flags interval
        elements = {
EOF

    # 注入中国 IP 列表 (sed 是标准的)
    sed 's/$/,/' "$ZONE_FILE" >> "$NFT_CONF"

    cat >> "$NFT_CONF" <<EOF
        }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        # --- 1. 基础规则 ---
        iif "lo" accept
        ct state established,related accept

        # --- 2. 👑 管理员 VIP (全通) ---
        ip saddr @admin_ips accept

EOF

    # 如果有用户 IP，写入用户规则
    if [ -n "$USER_IPS" ]; then
        cat >> "$NFT_CONF" <<EOF
        # --- 3. 👥 用户 VIP (仅 SS) ---
        ip saddr @user_ips tcp dport ${SB_PORT} accept
        ip saddr @user_ips udp dport ${SB_PORT} accept
EOF
    fi

    cat >> "$NFT_CONF" <<EOF
        # --- 4. 🚫 封禁中国 IP (含 Ping) ---
        # 关键: 这一步在允许 Ping 之前
        ip saddr @cn_ips drop

        # --- 5. 🌍 允许全球 Ping (非 CN) ---
        ip protocol icmp accept

        # --- 6. 🌍 SSH 开放 (非 CN) ---
        tcp dport ${SSH_PORT} accept
    }

    chain forward { type filter hook forward priority 0; policy drop; }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF
}

# --- 6. 应用规则 ---
apply_nft() {
    log_info "正在应用规则..."
    if nft -f "$NFT_CONF"; then
        # 尝试设置开机自启 (兼容 systemd)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables >/dev/null 2>&1
            systemctl start nftables >/dev/null 2>&1
        fi
        printf "${GREEN}✅ 部署成功！中国 IP 已被完全隔离 (无法 Ping)。${NC}\n"
    else
        log_error "规则应用失败，请检查配置文件格式！"
        exit 1
    fi
}

# --- 主程序入口 ---
main() {
    parse_ips
    check_env
    download_cn
    get_ports
    generate_nft
    apply_nft
}

# 执行主程序
main
