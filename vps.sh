#!/bin/bash
# ============================================================
# VPS 一键工具箱
# 功能: SSR(Shadowsocks + Shadow-TLS) 一键部署/删除
# 兼容: Oracle Cloud / Azure / 通用VPS
# 用法: bash vps.sh
# ============================================================

set -e

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==================== 配置 ====================
INSTALL_DIR="/opt/ssr"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/.env"
SS_PORT=22000
SHADOW_TLS_PORT=443
TLS_HOST="www.microsoft.com"
METHOD="aes-256-gcm"

# ==================== Docker Compose 命令检测 ====================
get_compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# ==================== 权限检查 ====================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 需要root权限，请使用 sudo bash $0${NC}"
        exit 1
    fi
}

# ==================== 平台检测 ====================
detect_platform() {
    # 尝试通过 metadata 检测
    if curl -s -m 3 -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null | grep -qi "azure"; then
        echo "azure"
        return
    fi

    if curl -s -m 3 -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/" 2>/dev/null | grep -qi "oci"; then
        echo "oracle"
        return
    fi

    # 通过 DMI 检测
    local product_name
    product_name=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "")
    if echo "$product_name" | grep -qi "microsoft"; then
        echo "azure"
        return
    fi
    if echo "$product_name" | grep -qi "oracle"; then
        echo "oracle"
        return
    fi

    # 通过 chassis_asset_tag 检测 Azure
    local asset_tag
    asset_tag=$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || echo "")
    if echo "$asset_tag" | grep -qi "azure"; then
        echo "azure"
        return
    fi

    echo "unknown"
}

# ==================== 获取公网IP ====================
get_public_ip() {
    local ip=""
    ip=$(curl -s -m 5 ifconfig.me 2>/dev/null) ||
    ip=$(curl -s -m 5 ipinfo.io/ip 2>/dev/null) ||
    ip=$(curl -s -m 5 icanhazip.com 2>/dev/null) ||
    ip=$(curl -s -m 5 api.ipify.org 2>/dev/null)

    if [ -z "$ip" ]; then
        echo -e "${RED}无法获取公网IP${NC}" >&2
        read -rp "请手动输入服务器公网IP: " ip
    fi
    echo "$ip"
}

# ==================== 生成随机密码 ====================
generate_password() {
    openssl rand -base64 20 | tr -d '/+=' | head -c 20
}

# ==================== 生成 ss:// 链接 ====================
generate_ss_link() {
    local ip="$1"
    local password="$2"
    local port="$3"
    local tag="$4"

    # ss:// legacy格式: BASE64(method:password@host:port)
    local userinfo="${METHOD}:${password}@${ip}:${port}"
    local encoded
    encoded=$(echo -n "$userinfo" | base64 -w 0)

    # shadow-tls JSON
    local stls_json="{\"address\":\"${ip}\",\"password\":\"${password}\",\"port\":\"${port}\",\"host\":\"${TLS_HOST}\",\"version\":\"2\"}"
    local stls_encoded
    stls_encoded=$(echo -n "$stls_json" | base64 -w 0)

    # URL encode tag
    local tag_encoded
    tag_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$tag'))" 2>/dev/null || echo "$tag")

    echo "ss://${encoded}?tfo=1&shadow-tls=${stls_encoded}#${tag_encoded}"
}

# ==================== 安装 Docker ====================
install_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}✓${NC} Docker 已安装"
        return
    fi

    echo -e "${CYAN}正在安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}✓${NC} Docker 安装完成"
}

# ==================== 安装 Docker Compose ====================
install_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Docker Compose 已安装 (plugin)"
        return
    fi
    if command -v docker-compose &>/dev/null; then
        echo -e "${GREEN}✓${NC} Docker Compose 已安装 (standalone)"
        return
    fi

    echo -e "${CYAN}正在安装 Docker Compose 插件...${NC}"
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin 2>/dev/null || {
        # fallback: 安装独立版本
        local version
        version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        curl -L "https://github.com/docker/compose/releases/download/${version}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    }
    echo -e "${GREEN}✓${NC} Docker Compose 安装完成"
}

# ==================== 配置 iptables (仅 Oracle) ====================
configure_firewall() {
    local platform="$1"

    if [ "$platform" = "oracle" ]; then
        echo -e "${CYAN}检测到 Oracle Cloud，开放所有端口...${NC}"
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F

        # 持久化规则
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        elif command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
        echo -e "${GREEN}✓${NC} iptables 已开放所有端口"
    elif [ "$platform" = "azure" ]; then
        echo -e "${GREEN}✓${NC} Azure 平台，跳过 iptables 配置 (使用 NSG 管理)"
    else
        echo -e "${YELLOW}未知平台，是否开放 iptables?${NC}"
        read -rp "[y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables -F
            echo -e "${GREEN}✓${NC} iptables 已开放"
        fi
    fi
}

# ==================== 优化 BBR ====================
enable_bbr() {
    echo -e "${CYAN}启用 BBR 拥塞控制...${NC}"

    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
EOF

    sysctl --system >/dev/null 2>&1
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "${GREEN}✓${NC} BBR 已启用 (当前: $cc)"
}

# ==================== 关闭密码登录 ====================
disable_password_auth() {
    echo -e "${CYAN}关闭 SSH 密码登录...${NC}"

    # 检查是否有 SSH key 已配置
    if [ ! -f ~/.ssh/authorized_keys ] || [ ! -s ~/.ssh/authorized_keys ]; then
        echo -e "${YELLOW}警告: 未检测到 SSH 公钥，跳过关闭密码登录 (避免锁死)${NC}"
        return
    fi

    sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    # 处理 sshd_config.d 目录中的覆盖
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] && sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$f"
        done
    fi

    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null
    echo -e "${GREEN}✓${NC} SSH 密码登录已关闭"
}

# ==================== 安装 SSR ====================
install_ssr() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  Shadowsocks + Shadow-TLS 部署${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 检查是否已安装
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}SSR 已安装，如需重新安装请先删除${NC}"
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            echo -e "${CYAN}当前链接:${NC}"
            echo -e "${GREEN}$SS_LINK${NC}"
        fi
        return
    fi

    # 平台检测
    echo -e "${CYAN}正在检测平台...${NC}"
    local platform
    platform=$(detect_platform)
    echo -e "${GREEN}✓${NC} 平台: ${BOLD}${platform}${NC}"
    echo ""

    # 获取节点名称
    read -rp "输入节点名称 (用于标识，如 东京01): " node_name
    [ -z "$node_name" ] && node_name="VPS-$(date +%s | tail -c 5)"

    # 自定义端口
    local stls_port=$SHADOW_TLS_PORT
    read -rp "Shadow-TLS 监听端口 [默认 443]: " custom_port
    [ -n "$custom_port" ] && stls_port=$custom_port

    # 自定义TLS伪装域名
    local tls_host=$TLS_HOST
    read -rp "TLS 伪装域名 [默认 www.microsoft.com]: " custom_tls
    [ -n "$custom_tls" ] && tls_host=$custom_tls

    echo ""

    # 安装依赖
    install_docker
    install_docker_compose

    # 防火墙
    configure_firewall "$platform"

    # BBR
    enable_bbr

    # 生成密码
    local password
    password=$(generate_password)

    # 获取公网IP
    local public_ip
    public_ip=$(get_public_ip)

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" << EOF
services:
  shadowsocks:
    image: shadowsocks/shadowsocks-libev
    restart: always
    network_mode: "host"
    environment:
      - SERVER_PORT=${SS_PORT}
      - SERVER_ADDR=127.0.0.1
      - METHOD=${METHOD}
      - PASSWORD=${password}

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    restart: always
    network_mode: "host"
    environment:
      - MODE=server
      - LISTEN=0.0.0.0:${stls_port}
      - SERVER=127.0.0.1:${SS_PORT}
      - TLS=${tls_host}:443
      - PASSWORD=${password}
EOF

    # 启动服务
    echo ""
    echo -e "${CYAN}正在拉取镜像并启动...${NC}"
    cd "$INSTALL_DIR"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [ -z "$compose_cmd" ]; then
        echo -e "${RED}Docker Compose 未找到${NC}"
        return 1
    fi
    $compose_cmd up -d

    # 等待服务启动
    sleep 3

    # 检查服务状态
    if $compose_cmd ps | grep -q "Up\|running"; then
        echo -e "${GREEN}✓${NC} 服务启动成功"
    else
        echo -e "${RED}✗ 服务启动失败，请检查日志: $compose_cmd -f $COMPOSE_FILE logs${NC}"
        return 1
    fi

    # 关闭SSH密码登录
    disable_password_auth

    # 生成链接
    local ss_link
    ss_link=$(generate_ss_link "$public_ip" "$password" "$stls_port" "$node_name")

    # 保存配置
    cat > "$CONFIG_FILE" << EOF
PLATFORM="${platform}"
PUBLIC_IP="${public_ip}"
PASSWORD="${password}"
SS_PORT="${SS_PORT}"
STLS_PORT="${stls_port}"
TLS_HOST="${tls_host}"
NODE_NAME="${node_name}"
METHOD="${METHOD}"
SS_LINK="${ss_link}"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$CONFIG_FILE"

    # 输出结果
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}  部署完成!${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  节点名称: ${BOLD}${node_name}${NC}"
    echo -e "  服务器IP: ${BOLD}${public_ip}${NC}"
    echo -e "  端口:     ${BOLD}${stls_port}${NC}"
    echo -e "  密码:     ${BOLD}${password}${NC}"
    echo -e "  加密方式: ${BOLD}${METHOD}${NC}"
    echo -e "  TLS伪装:  ${BOLD}${tls_host}${NC}"
    echo -e "  平台:     ${BOLD}${platform}${NC}"
    echo ""
    echo -e "${CYAN}SS 链接 (复制到客户端导入):${NC}"
    echo ""
    echo -e "${GREEN}${ss_link}${NC}"
    echo ""
}

# ==================== 删除 SSR ====================
uninstall_ssr() {
    echo ""
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${RED}  删除 Shadowsocks + Shadow-TLS${NC}"
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}SSR 未安装${NC}"
        return
    fi

    read -rp "确认删除 SSR? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${DIM}已取消${NC}"
        return
    fi

    echo -e "${CYAN}正在停止并删除容器...${NC}"
    cd "$INSTALL_DIR"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    [ -z "$compose_cmd" ] && compose_cmd="docker compose"
    $compose_cmd down --rmi all 2>/dev/null || $compose_cmd down 2>/dev/null

    echo -e "${CYAN}清理文件...${NC}"
    rm -rf "$INSTALL_DIR"

    echo ""
    echo -e "${GREEN}✓${NC} SSR 已完全删除"
    echo ""
}

# ==================== 查看 SSR 状态 ====================
status_ssr() {
    echo ""
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}SSR 未安装${NC}"
        return
    fi

    echo -e "${BOLD}${CYAN}━━━ SSR 状态 ━━━${NC}"
    echo ""

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "  节点名称: ${BOLD}${NODE_NAME}${NC}"
        echo -e "  服务器IP: ${BOLD}${PUBLIC_IP}${NC}"
        echo -e "  端口:     ${BOLD}${STLS_PORT}${NC}"
        echo -e "  安装时间: ${BOLD}${INSTALL_DATE}${NC}"
        echo ""
    fi

    cd "$INSTALL_DIR"
    echo -e "${BOLD}  容器状态:${NC}"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    [ -z "$compose_cmd" ] && compose_cmd="docker compose"
    $compose_cmd ps
    echo ""

    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}SS 链接:${NC}"
        echo -e "${GREEN}${SS_LINK}${NC}"
    fi
    echo ""
}

# ==================== 主菜单 ====================
show_menu() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}        VPS 一键工具箱${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} 安装 SSR (Shadowsocks + Shadow-TLS)"
    echo -e "  ${GREEN}2)${NC} 删除 SSR"
    echo -e "  ${GREEN}3)${NC} 查看 SSR 状态/链接"
    echo -e "  ${GREEN}4)${NC} 优化网络 (BBR)"
    echo -e "  ${GREEN}0)${NC} 退出"
    echo ""
}

# ==================== 入口 ====================
main() {
    check_root

    # 支持直接命令
    case "${1:-}" in
        install) install_ssr; exit 0 ;;
        uninstall|remove) uninstall_ssr; exit 0 ;;
        status) status_ssr; exit 0 ;;
        *) ;;
    esac

    # 交互式菜单
    while true; do
        show_menu
        read -rp "请选择 [0-4]: " choice
        case "$choice" in
            1) install_ssr ;;
            2) uninstall_ssr ;;
            3) status_ssr ;;
            4) enable_bbr ;;
            0) echo -e "${GREEN}Bye${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

main "$@"
