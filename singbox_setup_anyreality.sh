#!/bin/sh

# Debian/Ubuntu Sing-Box 自动配置脚本
# 功能: 自动配置 AnyTLS + Reality，输出 JSON 配置
# 运行方式: curl -fsSL url | sh

set -e

# --- 变量与默认值 ---
NODE_TAG="${TAG:-MyNode}"
CONFIG_FILE="/etc/sing-box/config.json"
PORT=443

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
    
    if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl ca-certificates >/dev/null
    fi

    if ! command -v sing-box >/dev/null 2>&1; then
        log_warn "未检测到 Sing-Box，开始自动安装..."
        curl -fsSL https://sing-box.app/install.sh | sh
        if ! command -v sing-box >/dev/null 2>&1; then
            log_error "Sing-Box 安装失败"
            exit 1
        fi
    fi
}

# 3. 筛选低延迟域名
get_best_domain() {
    log_info "正在筛选低延迟 Reality 目标域名..."
    DOMAINS="www.microsoft.com www.apple.com www.amazon.com www.nvidia.com www.amd.com www.intel.com www.google.com www.bing.com www.icloud.com itunes.apple.com s0.awsstatic.com www.oracle.com www.cisco.com www.samsung.com www.ibm.com www.adobe.com www.dell.com www.tesla.com www.qualcomm.com azure.microsoft.com"
    
    BEST_DOMAIN=""
    MIN_TIME=10.0

    for d in $DOMAINS; do
        time_cost=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 1 "https://$d" || echo "10.0")
        is_faster=$(awk "BEGIN {print ($time_cost < $MIN_TIME)}")
        
        if [ "$is_faster" -eq 1 ]; then
            MIN_TIME=$time_cost
            BEST_DOMAIN=$d
            printf "   - %-20s : ${GREEN}%.3fs${NC}\n" "$d" "$time_cost"
        else
            printf "   - %-20s : %.3fs\n" "$d" "$time_cost"
        fi
    done

    if [ -z "$BEST_DOMAIN" ] || [ "$MIN_TIME" = "10.0" ]; then
        BEST_DOMAIN="www.microsoft.com"
        log_warn "所有域名测试超时，回退默认: $BEST_DOMAIN"
    else
        log_info "🏆 最佳域名: $BEST_DOMAIN (延迟: ${MIN_TIME}s)"
    fi
}

# 4. 获取公网 IP (轮询机制)
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

# 5. 生成配置
generate_config() {
    log_info "生成密钥对和密码..."
    
    # 生成 16 字节随机密码并 Base64 编码
    PASSWORD=$(openssl rand -base64 16)
    
    pair_out=$(sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$pair_out" | grep "PrivateKey" | awk '{print $2}')
    PUB_KEY=$(echo "$pair_out" | grep "PublicKey" | awk '{print $2}')
    
    SHORT_ID=$(openssl rand -hex 8)

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    fi

    log_info "写入配置文件..."
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${PASSWORD}"
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
}

# 6. 启动服务
restart_service() {
    log_info "验证并重启服务..."
    if ! sing-box check -c "$CONFIG_FILE"; then
        log_error "配置文件格式错误！"
        exit 1
    fi

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    
    sleep 2
    if systemctl is-active --quiet sing-box; then
        log_info "服务启动成功"
    else
        log_error "服务启动失败，请检查: journalctl -u sing-box"
        exit 1
    fi
}

# 7. 输出客户端信息
print_client_config() {
    log_info "获取服务器公网 IP..."
    SERVER_IP=$(get_server_ip)
    
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="[无法获取IP]"
        log_warn "公网 IP 获取失败"
    fi
    
    printf "\n"
    printf "${BLUE}========================================================${NC}\n"
    printf "📋 节点信息 (Tag: ${NODE_TAG})\n"
    printf "${BLUE}========================================================${NC}\n"

    printf "${CYAN}📄 JSON 配置片段 (复制到客户端 outbounds):${NC}\n"
    cat <<EOF
{
    "tag": "${NODE_TAG}",
    "type": "anytls",
    "server": "${SERVER_IP}",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "idle_session_check_interval": "30s",
    "min_idle_session": 5,
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
}

# --- 主流程 ---
main() {
    printf "${BLUE}🚀 Sing-Box AnyTLS + Reality 自动配置脚本 (Tag: ${NODE_TAG})${NC}\n"
    check_install_deps
    get_best_domain
    generate_config
    restart_service
    print_client_config
}

main
