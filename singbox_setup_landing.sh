#!/bin/sh

# Debian/Ubuntu Sing-Box Shadowsocks 2022 自动配置脚本
# 功能: 自动配置 SS-2022，支持环境变量注入，无交互全自动
#
# 1. 自定义安装: PORT=8443 TAG="HK_Node" sh -c "$(curl -fsSL url)"
# 2. 随机安装:   sh -c "$(curl -fsSL url)"

set -e

# --- 变量处理逻辑 (核心修改) ---

# 1. 处理 TAG (优先读取环境变量，否则使用默认)
if [ -n "$TAG" ]; then
    NODE_TAG="$TAG"
    TAG_SOURCE="环境变量"
else
    NODE_TAG="MySSNode"
    TAG_SOURCE="默认值"
fi

# 2. 处理 PORT (优先读取环境变量，否则随机生成)
if [ -n "$PORT" ]; then
    # 简单检查是否为数字
    case $PORT in
        ''|*[!0-9]*) 
            echo "错误: 提供的 PORT 不是数字"
            exit 1 ;;
        *) ;;
    esac
    LISTEN_PORT="$PORT"
    PORT_SOURCE="环境变量"
else
    LISTEN_PORT=$(shuf -i 10000-60000 -n 1)
    PORT_SOURCE="自动随机"
fi

CONFIG_FILE="/etc/sing-box/config.json"

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
    log_info "配置参数确认:"
    printf "   - TAG  : ${CYAN}${NODE_TAG}${NC} [${TAG_SOURCE}]\n"
    printf "   - PORT : ${CYAN}${LISTEN_PORT}${NC} [${PORT_SOURCE}]\n"
    
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

# 3. 获取公网 IP
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

# 4. 生成配置
generate_config() {
    log_info "生成 SS-2022 密钥..."
    
    PASSWORD=$(openssl rand -base64 32)
    METHOD="2022-blake3-aes-256-gcm"

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    fi

    log_info "写入配置文件..."
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
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
  ],
  "route": {
    "rules": [
      {
        "inbound": ["ss-in"],
        "outbound": "direct"
      }
    ]
  }
}
EOF
}

# 5. 启动服务
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

# 6. 输出客户端信息
print_client_config() {
    SERVER_IP=$(get_server_ip)
    if [ -z "$SERVER_IP" ]; then SERVER_IP="YOUR_IP"; fi

    # URL 编码 Tag
    TAG_ENCODED=$(echo "$NODE_TAG" | sed 's/ /%20/g')
    
    RAW_USER_INFO="${METHOD}:${PASSWORD}"
    BASE64_USER_INFO=$(echo -n "${RAW_USER_INFO}" | base64 -w 0)
    
    SS_LINK="ss://${BASE64_USER_INFO}@${SERVER_IP}:${LISTEN_PORT}#${TAG_ENCODED}"
    
    printf "\n"
    printf "${BLUE}========================================================${NC}\n"
    printf "📋 节点信息 (Tag: ${NODE_TAG})\n"
    printf "${BLUE}========================================================${NC}\n"
    
    printf "${CYAN}🚀 Shadowsocks 链接 (SIP002 标准):${NC}\n"
    printf "%s\n\n" "$SS_LINK"

    printf "${CYAN}📄 JSON 客户端配置 (Sing-Box 格式):${NC}\n"
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
}

# --- 主流程 ---
main() {
    printf "${BLUE}🚀 Sing-Box SS-2022 自动配置脚本${NC}\n"
    check_install_deps
    generate_config
    restart_service
    print_client_config
}

main
