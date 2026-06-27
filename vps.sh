#!/bin/bash
# ============================================================
# VPS 一键工具箱
# 功能: SSR(Shadowsocks + Shadow-TLS) 一键部署/删除
# 兼容: Azure / Oracle Cloud / 通用VPS
# 用法: bash vps.sh install --azure --cn --yes
# ============================================================

# 不使用 set -e, 部分命令预期失败 (iptables -D 等)

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ==================== 配置 ====================
INSTALL_DIR="/opt/ssr"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/.env"
HY2_INSTALL_DIR="/opt/hy2"
HY2_COMPOSE_FILE="$HY2_INSTALL_DIR/docker-compose.yml"
HY2_CONFIG_FILE="$HY2_INSTALL_DIR/.env"
HY2_IMAGE="${VPS_HY2_IMAGE:-tobyxdd/hysteria:latest}"
SS_PORT=22000
SHADOW_TLS_PORT=443
HY2_PORT=443
TLS_HOST_AZURE="www.microsoft.com"
TLS_HOST_ORACLE="www.apple.com"
TLS_HOST_DEFAULT="www.apple.com"
METHOD="aes-256-gcm"
REGION_MODE="auto"  # auto|cn|global
PLATFORM_MODE="auto"  # auto|azure|oracle|unknown
AUTO_YES="${VPS_YES:-0}"

# 大陆常用网络参数
CN_DNS_PRIMARY="223.5.5.5"
CN_DNS_SECONDARY="119.29.29.29"
CN_APT_MIRROR_UBUNTU="mirrors.aliyun.com"
CN_APT_MIRROR_DEBIAN="mirrors.aliyun.com"
CN_DOCKER_MIRROR="mirrors.aliyun.com/docker-ce"

# ==================== 命令重试 ====================
retry_cmd() {
    local retries="${1:-3}"
    shift
    local count=1
    while [ "$count" -le "$retries" ]; do
        if "$@"; then
            return 0
        fi
        count=$((count + 1))
        sleep 2
    done
    return 1
}

# ==================== 区域检测 (大陆/国际) ====================
detect_region() {
    # 允许外部指定: VPS_REGION=cn 或 VPS_REGION=global
    case "${VPS_REGION:-}" in
        cn|CN|china|mainland)
            echo "cn"
            return
            ;;
        global|intl|overseas)
            echo "global"
            return
            ;;
    esac

    # 简单网络特征判断: 百度可达 + Google 204 不可达 -> 大陆网络
    if curl -sI --max-time 3 http://www.baidu.com >/dev/null 2>&1 && \
       ! curl -sI --max-time 3 https://www.gstatic.com/generate_204 >/dev/null 2>&1; then
        echo "cn"
    else
        echo "global"
    fi
}

# ==================== 配置 APT 网络重试 ====================
configure_apt_network() {
    cat > /etc/apt/apt.conf.d/99vps-toolkit-network << 'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "15";
Acquire::https::Timeout "20";
Acquire::ForceIPv4 "true";
Dpkg::Use-Pty "0";
EOF
}

# ==================== 大陆模式优化 ====================
optimize_for_mainland() {
    echo -e "${CYAN}应用中国大陆网络优化...${NC}"

    configure_apt_network

    # Ubuntu/Debian 软件源切换到大陆镜像 (保留备份)
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.vpsbak ]; then
            cp /etc/apt/sources.list /etc/apt/sources.list.vpsbak
        fi

        if [ "${ID:-}" = "ubuntu" ] && [ -f /etc/apt/sources.list ]; then
            sed -i -E "s|https?://(archive|security)\\.ubuntu\\.com/ubuntu/?|https://${CN_APT_MIRROR_UBUNTU}/ubuntu/|g" /etc/apt/sources.list
        elif [ "${ID:-}" = "debian" ] && [ -f /etc/apt/sources.list ]; then
            sed -i -E "s|https?://deb\\.debian\\.org/debian|https://${CN_APT_MIRROR_DEBIAN}/debian|g" /etc/apt/sources.list
            sed -i -E "s|https?://security\\.debian\\.org/debian-security|https://${CN_APT_MIRROR_DEBIAN}/debian-security|g" /etc/apt/sources.list
        fi

        # Ubuntu 22.04+/24.04 和新版 Debian 常使用 deb822 (*.sources) 格式
        local source_file
        for source_file in /etc/apt/sources.list.d/*.sources; do
            [ -f "$source_file" ] || continue
            [ -f "${source_file}.vpsbak" ] || cp "$source_file" "${source_file}.vpsbak"
            if [ "${ID:-}" = "ubuntu" ]; then
                sed -i -E "s|https?://([a-zA-Z0-9.-]+\\.)?(archive|security|ports)\\.ubuntu\\.com/ubuntu/?|https://${CN_APT_MIRROR_UBUNTU}/ubuntu/|g" "$source_file"
                sed -i -E "s|https?://azure\\.archive\\.ubuntu\\.com/ubuntu/?|https://${CN_APT_MIRROR_UBUNTU}/ubuntu/|g" "$source_file"
            elif [ "${ID:-}" = "debian" ]; then
                sed -i -E "s|https?://deb\\.debian\\.org/debian/?|https://${CN_APT_MIRROR_DEBIAN}/debian/|g" "$source_file"
                sed -i -E "s|https?://security\\.debian\\.org/debian-security/?|https://${CN_APT_MIRROR_DEBIAN}/debian-security/|g" "$source_file"
            fi
        done
    fi

    # systemd-resolved DNS 优化
    if [ -f /etc/systemd/resolved.conf ]; then
        sed -i -E 's/^#?DNS=.*/DNS=223.5.5.5 119.29.29.29/' /etc/systemd/resolved.conf
        sed -i -E 's/^#?FallbackDNS=.*/FallbackDNS=8.8.8.8 1.1.1.1/' /etc/systemd/resolved.conf
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    # 启用 NTP 防止时间漂移导致 TLS 问题
    timedatectl set-ntp true 2>/dev/null || true

    echo -e "${GREEN}✓${NC} 大陆网络优化已应用 (镜像源/DNS/重试/NTP)"
}

# ==================== Docker 镜像加速 ====================
configure_docker_mirror() {
    local region="$1"
    [ "$region" != "cn" ] && return 0

    mkdir -p /etc/docker

    if [ -f /etc/docker/daemon.json ] && [ ! -f /etc/docker/daemon.json.vpsbak ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.vpsbak
    fi

    local mirrors="${VPS_DOCKER_MIRRORS:-https://docker.1ms.run,https://docker.m.daocloud.io,https://dockerproxy.com,https://hub-mirror.c.163.com}"
    local json_mirrors=""
    local mirror
    IFS=',' read -r -a mirror_list <<< "$mirrors"
    for mirror in "${mirror_list[@]}"; do
        mirror=$(echo "$mirror" | xargs)
        [ -z "$mirror" ] && continue
        if [ -n "$json_mirrors" ]; then
            json_mirrors="${json_mirrors},"
        fi
        json_mirrors="${json_mirrors}
    \"${mirror}\""
    done

    cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": [${json_mirrors}
  ],
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 3
}
EOF

    systemctl daemon-reload
    systemctl restart docker 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Docker 镜像加速已配置"
}

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
    # 允许外部指定: VPS_PLATFORM=azure/oracle/unknown 或命令行 --azure/--oracle
    case "${VPS_PLATFORM:-$PLATFORM_MODE}" in
        azure|AZURE|Azure)
            echo "azure"
            return
            ;;
        oracle|oci|ORACLE|OCI)
            echo "oracle"
            return
            ;;
        unknown|generic)
            echo "unknown"
            return
            ;;
    esac

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
get_azure_public_ip() {
    local metadata
    metadata=$(curl -s -m 3 -H "Metadata:true" "http://169.254.169.254/metadata/instance/network/interface?api-version=2021-02-01" 2>/dev/null) || true
    [ -z "$metadata" ] && return 1

    printf '%s' "$metadata" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for iface in data.get("interface", []):
        for ip in iface.get("ipv4", {}).get("ipAddress", []):
            public_ip = ip.get("publicIpAddress", "")
            if public_ip:
                print(public_ip)
                raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
' 2>/dev/null
}

get_public_ip() {
    local platform="${1:-unknown}"
    local ip=""
    if [ "$platform" = "azure" ]; then
        ip=$(get_azure_public_ip) || true
    fi
    [ -z "$ip" ] && ip=$(curl -s -m 5 ip.sb 2>/dev/null) || true
    [ -z "$ip" ] && ip=$(curl -s -m 5 myip.ipip.net 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1) || true
    [ -z "$ip" ] && ip=$(curl -s -m 5 ifconfig.me 2>/dev/null) || true
    [ -z "$ip" ] && ip=$(curl -s -m 5 ipinfo.io/ip 2>/dev/null) || true
    [ -z "$ip" ] && ip=$(curl -s -m 5 icanhazip.com 2>/dev/null) || true
    [ -z "$ip" ] && ip=$(curl -s -m 5 api.ipify.org 2>/dev/null) || true

    if [ -z "$ip" ]; then
        echo -e "${RED}无法获取公网IP${NC}" >&2
        read -rp "请手动输入服务器公网IP: " ip
    fi
    echo "$ip"
}

# ==================== 生成随机密码 ====================
generate_password() {
    local pw=""
    # 循环确保至少20字符 (去除特殊字符后可能变短)
    while [ ${#pw} -lt 20 ]; do
        pw=$(openssl rand -base64 30 | tr -d '/+=\n' | head -c 20)
    done
    echo "$pw"
}

# ==================== 生成 ss:// 链接 ====================
url_encode() {
    printf '%s' "$1" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))" 2>/dev/null || printf '%s' "$1" | sed 's/ /%20/g; s/#/%23/g; s/@/%40/g; s/:/%3A/g; s/?/%3F/g; s/&/%26/g'
}

generate_ss_link() {
    local ip="$1"
    local password="$2"
    local port="$3"
    local tag="$4"
    local tls_host="$5"

    # ss:// legacy格式: BASE64(method:password@host:port), 去掉=填充
    local userinfo="${METHOD}:${password}@${ip}:${port}"
    local encoded
    encoded=$(echo -n "$userinfo" | base64 -w 0 | tr -d '=')

    # shadow-tls JSON, 去掉=填充
    local stls_json="{\"address\":\"${ip}\",\"password\":\"${password}\",\"port\":\"${port}\",\"host\":\"${tls_host}\",\"version\":\"2\"}"
    local stls_encoded
    stls_encoded=$(echo -n "$stls_json" | base64 -w 0 | tr -d '=')

    # URL encode tag (安全: 用 stdin 传递避免命令注入)
    local tag_encoded
    tag_encoded=$(url_encode "$tag")

    echo "ss://${encoded}?tfo=1&shadow-tls=${stls_encoded}#${tag_encoded}"
}

# ==================== 生成 hysteria2:// 链接 ====================
generate_hy2_link() {
    local ip="$1"
    local password="$2"
    local port="$3"
    local tag="$4"
    local sni="$5"

    local password_encoded tag_encoded
    password_encoded=$(url_encode "$password")
    tag_encoded=$(url_encode "$tag")

    local sni_encoded
    sni_encoded=$(url_encode "$sni")

    echo "hysteria2://${password_encoded}@${ip}:${port}/?sni=${sni_encoded}&insecure=1#${tag_encoded}"
}

hy2_udp_listening() {
    local port="$1"
    ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"
}

print_hy2_diagnostics() {
    local port="${1:-443}"
    local platform="${2:-unknown}"
    local compose_cmd

    echo ""
    echo -e "${BOLD}  HY2 诊断:${NC}"
    if hy2_udp_listening "$port"; then
        echo -e "  UDP监听: ${GREEN}正常${NC} (:${port})"
    else
        echo -e "  UDP监听: ${RED}未检测到${NC} (:${port})"
    fi

    if [ "$platform" = "azure" ]; then
        echo -e "  Azure NSG: 请确认入站规则已放行 ${BOLD}UDP ${port}${NC}"
    fi

    if [ -d "$HY2_INSTALL_DIR" ]; then
        compose_cmd=$(get_compose_cmd)
        [ -z "$compose_cmd" ] && compose_cmd="docker compose"
        echo -e "  日志查看: ${BOLD}cd ${HY2_INSTALL_DIR} && ${compose_cmd} logs --tail=50${NC}"
    fi
    echo ""
}

# ==================== 输出 SS 链接 ====================
print_ss_link() {
    echo ""
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}未找到配置，SSR 可能尚未安装${NC}"
        return 1
    fi

    source "$CONFIG_FILE"
    if [ -z "${SS_LINK:-}" ]; then
        echo -e "${RED}配置中未找到 SS_LINK${NC}"
        return 1
    fi

    echo -e "${CYAN}SS 链接:${NC}"
    echo -e "${GREEN}${SS_LINK}${NC}"
    echo ""
    # 纯文本行，便于脚本调用方稳定提取
    echo "SS_LINK=${SS_LINK}"
    echo ""
    return 0
}

# ==================== 输出 HY2 链接 ====================
print_hy2_link() {
    echo ""
    if [ ! -f "$HY2_CONFIG_FILE" ]; then
        echo -e "${YELLOW}未找到配置，HY2 可能尚未安装${NC}"
        return 1
    fi

    source "$HY2_CONFIG_FILE"
    if [ -z "${HY2_LINK:-}" ]; then
        echo -e "${RED}配置中未找到 HY2_LINK${NC}"
        return 1
    fi

    echo -e "${CYAN}HY2 链接:${NC}"
    echo -e "${GREEN}${HY2_LINK}${NC}"
    echo ""
    echo "HY2_LINK=${HY2_LINK}"
    echo ""
    return 0
}

# ==================== 系统安全加固 ====================
harden_system() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ 系统安全加固 ━━━${NC}"
    echo ""

    # 先停止系统自带的自动更新，防止和我们的apt操作抢锁
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl stop apt-daily.timer 2>/dev/null || true
    systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
    systemctl kill unattended-upgrades 2>/dev/null || true

    # 等30秒看锁能否自然释放，否则强杀
    local lock_waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
        if [ "$lock_waited" -eq 0 ]; then
            echo -e "${YELLOW}等待 apt 锁释放...${NC}"
        fi
        sleep 5
        lock_waited=$((lock_waited + 5))
        if [ "$lock_waited" -ge 30 ]; then
            echo -e "${YELLOW}锁等待超时，强制终止占用进程...${NC}"
            killall -9 apt apt-get dpkg unattended-upgr 2>/dev/null || true
            sleep 2
            rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock 2>/dev/null || true
            dpkg --configure -a 2>/dev/null || true
            break
        fi
    done

    # 1. 系统更新
    echo -e "${CYAN}[1/5] 更新系统软件包 (可能需要几分钟)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    if apt-get update && apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
        echo -e "${GREEN}✓${NC} 系统已更新"
    else
        echo -e "${YELLOW}⚠ 部分包更新失败，继续执行${NC}"
    fi

    # 2. 启用自动安全更新
    echo -e "${CYAN}[2/5] 配置自动安全更新...${NC}"
    apt-get install -y unattended-upgrades apt-listchanges >/dev/null 2>&1
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    # 注意: 不在这里启动 unattended-upgrades, 等所有 apt 操作完成后再启动
    echo -e "${GREEN}✓${NC} 自动安全更新已配置 (将在部署完成后启用)"

    # 3. SSH 加固
    echo -e "${CYAN}[3/5] SSH 安全加固...${NC}"
    local sshd_config="/etc/ssh/sshd_config"
    # 禁止root密码登录 (保留key登录)
    sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
    # 禁止空密码
    sed -i -E 's/^#?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_config"
    # 限制认证尝试次数
    sed -i -E 's/^#?MaxAuthTries.*/MaxAuthTries 3/' "$sshd_config"
    # 关闭X11转发
    sed -i -E 's/^#?X11Forwarding.*/X11Forwarding no/' "$sshd_config"
    # 登录超时60秒
    sed -i -E 's/^#?LoginGraceTime.*/LoginGraceTime 60/' "$sshd_config"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo -e "${GREEN}✓${NC} SSH 已加固 (Root仅key登录, MaxAuthTries=3)"

    # 4. 内核安全参数
    echo -e "${CYAN}[4/5] 内核安全加固...${NC}"
    cat > /etc/sysctl.d/98-security.conf << 'EOF'
# 防止IP欺骗
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# 忽略ICMP重定向 (防MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# 忽略源路由
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
# SYN洪水防护
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
# 禁止IP转发 (非路由器, 注意: Docker会覆盖此设置)
# net.ipv4.ip_forward = 0
# net.ipv6.conf.all.forwarding = 0
# 记录异常包
net.ipv4.conf.all.log_martians = 1
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}✓${NC} 内核安全参数已应用"

    # 5. 清理不必要的服务
    echo -e "${CYAN}[5/5] 清理不必要的服务...${NC}"
    local disabled=0
    for svc in rpcbind avahi-daemon cups snapd; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            disabled=$((disabled + 1))
        fi
    done
    echo -e "${GREEN}✓${NC} 已停用 ${disabled} 个不必要的服务"

    echo ""
    echo -e "${BOLD}${GREEN}系统加固完成${NC}"
    echo ""
}

# ==================== 等待 apt 锁释放 ====================
wait_for_apt_lock() {
    local max_wait=300
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
        if [ "$waited" -eq 0 ]; then
            echo -e "${YELLOW}等待 apt 锁释放 (其他进程正在使用包管理器)...${NC}"
        fi
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge "$max_wait" ]; then
            echo -e "${YELLOW}⚠ 等待超时，尝试继续${NC}"
            break
        fi
    done
}

# ==================== 基础依赖 ====================
install_base_dependencies() {
    echo -e "${CYAN}安装基础依赖...${NC}"
    wait_for_apt_lock
    retry_cmd 3 apt-get update -qq || true
    apt-get install -y -qq curl ca-certificates openssl python3 bc iproute2 iptables gnupg lsb-release >/dev/null 2>&1 || true
    echo -e "${GREEN}✓${NC} 基础依赖已就绪"
}

# ==================== 安装 Docker ====================
configure_docker_apt_repo() {
    local region="${1:-global}"

    if [ ! -f /etc/os-release ]; then
        return 1
    fi
    . /etc/os-release

    local os_id="${ID:-}"
    local codename="${VERSION_CODENAME:-}"
    [ -z "$codename" ] && codename=$(lsb_release -cs 2>/dev/null || true)
    if [ -z "$os_id" ] || [ -z "$codename" ]; then
        return 1
    fi
    if [ "$os_id" != "ubuntu" ] && [ "$os_id" != "debian" ]; then
        return 1
    fi

    local repo_base="https://download.docker.com/linux/${os_id}"
    if [ "$region" = "cn" ]; then
        repo_base="https://${CN_DOCKER_MIRROR}/linux/${os_id}"
    fi

    install -m 0755 -d /etc/apt/keyrings
    if ! retry_cmd 3 curl -fsSL "${repo_base}/gpg" -o /etc/apt/keyrings/docker.asc; then
        return 1
    fi
    chmod a+r /etc/apt/keyrings/docker.asc

    local arch
    arch=$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] ${repo_base} ${codename} stable
EOF
}

install_docker() {
    local region="${1:-global}"

    if command -v docker &>/dev/null; then
        echo -e "${GREEN}✓${NC} Docker 已安装"
        return
    fi

    echo -e "${CYAN}正在安装 Docker...${NC}"
    wait_for_apt_lock

    # 修复可能损坏的 dpkg 状态
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    retry_cmd 3 apt-get update -qq || true
    apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null 2>&1 || true

    if configure_docker_apt_repo "$region" && retry_cmd 3 apt-get update -qq && \
       apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        systemctl enable docker
        systemctl start docker
        echo -e "${GREEN}✓${NC} Docker 安装完成 (APT源: ${region})"
        return 0
    fi

    if retry_cmd 3 bash -c "curl -fsSL https://get.docker.com | sh"; then
        systemctl enable docker
        systemctl start docker
        echo -e "${GREEN}✓${NC} Docker 安装完成"
    else
        # 重试一次
        echo -e "${YELLOW}首次安装失败，修复后重试...${NC}"
        wait_for_apt_lock
        dpkg --configure -a 2>/dev/null || true
        retry_cmd 3 apt-get update
        if retry_cmd 3 bash -c "curl -fsSL https://get.docker.com | sh"; then
            systemctl enable docker
            systemctl start docker
            echo -e "${GREEN}✓${NC} Docker 安装完成 (重试成功)"
        else
            echo -e "${RED}✗ Docker 安装失败，请手动检查: apt-get install -y docker-ce${NC}"
            return 1
        fi
    fi
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
    wait_for_apt_lock
    retry_cmd 3 apt-get update -qq && apt-get install -y docker-compose-plugin 2>/dev/null || {
        # fallback: 安装独立版本
        local version
        version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -n "$version" ]; then
            retry_cmd 3 curl -L "https://github.com/docker/compose/releases/download/${version}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || \
            retry_cmd 3 curl -L "https://ghfast.top/https://github.com/docker/compose/releases/download/${version}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        fi
    }
    if docker compose version &>/dev/null 2>&1 || command -v docker-compose &>/dev/null; then
        echo -e "${GREEN}✓${NC} Docker Compose 安装完成"
    else
        echo -e "${RED}✗ Docker Compose 安装失败${NC}"
        return 1
    fi
}

# ==================== 配置 iptables (仅 Oracle) ====================
add_iptables_accept_rule() {
    local protocol="$1"
    local port="$2"
    [ -z "$port" ] && return 0
    iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
}

add_installed_proxy_firewall_rules() {
    local current_protocol="$1"
    local current_port="$2"

    add_iptables_accept_rule "$current_protocol" "$current_port"

    if [ -f "$CONFIG_FILE" ]; then
        local ssr_port
        ssr_port=$(grep -E '^STLS_PORT=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"')
        add_iptables_accept_rule "tcp" "$ssr_port"
    fi

    if [ -f "$HY2_CONFIG_FILE" ]; then
        local hy2_port
        hy2_port=$(grep -E '^HY2_PORT=' "$HY2_CONFIG_FILE" | cut -d= -f2- | tr -d '"')
        add_iptables_accept_rule "udp" "$hy2_port"
    fi
}

configure_firewall() {
    local platform="$1"
    local port="$2"  # 代理端口
    local protocol="${3:-tcp}"
    local service_name="${4:-Proxy}"

    if [ "$platform" = "oracle" ]; then
        echo -e "${CYAN}检测到 Oracle Cloud，配置防火墙...${NC}"

        # 获取当前SSH端口
        local ssh_port
        ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
        [ -z "$ssh_port" ] && ssh_port=22

        # 清除甲骨文默认的限制规则 (不清nat/mangle, 保护Docker)
        iptables -F
        iptables -X 2>/dev/null || true

        # 先添加关键规则，再设置DROP策略 (防止SSH瞬断)
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
        iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
        iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        add_installed_proxy_firewall_rules "$protocol" "$port"
        iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables-dropped: " --log-level 4

        # 规则就绪后再设置默认策略
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT

        # 持久化规则
        apt-get install -y -qq iptables-persistent netfilter-persistent 2>/dev/null || true
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi

        echo -e "${GREEN}✓${NC} 防火墙已配置: SSH(${ssh_port}) + ${service_name}(${protocol}/${port}) + ICMP"
    elif [ "$platform" = "azure" ]; then
        echo -e "${GREEN}✓${NC} Azure 平台，跳过 iptables 配置 (使用 NSG 管理)"
        echo -e "${YELLOW}提示: 请确认 Azure NSG 已放行 ${protocol^^} ${port} 与 SSH 端口${NC}"
    else
        echo -e "${YELLOW}未知平台，是否配置防火墙? (仅开放 SSH + 代理端口 + ping)${NC}"
        read -rp "[y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            local ssh_port
            ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
            [ -z "$ssh_port" ] && ssh_port=22

            iptables -F
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
            iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
            add_installed_proxy_firewall_rules "$protocol" "$port"
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT

            # 持久化
            apt-get install -y -qq iptables-persistent netfilter-persistent 2>/dev/null || true
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            else
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            echo -e "${GREEN}✓${NC} 防火墙已配置: SSH(${ssh_port}) + ${service_name}(${protocol}/${port}) + ICMP"
        fi
    fi
}

# ==================== 安装 fail2ban ====================
install_fail2ban() {
    echo -e "${CYAN}配置 fail2ban (自动封禁暴力扫描IP)...${NC}"

    if ! command -v fail2ban-client &>/dev/null; then
        wait_for_apt_lock
        apt-get update -qq && apt-get install -y fail2ban
    fi

    # 获取SSH端口
    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    [ -z "$ssh_port" ] && ssh_port=22

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 3
banaction = iptables-multiport

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}✓${NC} fail2ban 已启用: 10分钟内3次失败 → 封禁24小时"
}

# ==================== SSR 防滥用保护 ====================
# 参数: $1=port (可选), $2="auto" 则使用默认值不交互
setup_abuse_protection() {
    local port="${1:-443}"
    local mode="${2:-interactive}"

    echo ""
    echo -e "${BOLD}${CYAN}━━━ SSR 防滥用保护 ━━━${NC}"
    echo ""

    if [ "$mode" != "auto" ] && [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        port="${STLS_PORT:-443}"
    fi

    # 1. 单IP并发连接限制
    echo -e "${CYAN}[1/3] 配置单IP并发连接限制...${NC}"
    local max_conn=20
    if [ "$mode" != "auto" ]; then
        read -rp "单IP最大并发连接数 [默认 20]: " max_conn
        [ -z "$max_conn" ] && max_conn=20
    fi

    # 检查是否已有connlimit规则，先清除
    iptables -D INPUT -p tcp --dport "$port" -m state --state NEW -m connlimit --connlimit-above "$max_conn" -j DROP 2>/dev/null
    # 在ACCEPT规则之前插入connlimit (仅对新连接生效,不影响已建立连接)
    iptables -I INPUT -p tcp --dport "$port" -m state --state NEW -m connlimit --connlimit-above "$max_conn" -j DROP
    echo -e "${GREEN}✓${NC} 单IP超过 ${max_conn} 连接将被拒绝"

    # 2. 每秒新连接速率限制 (防短时间大量连接)
    echo -e "${CYAN}[2/3] 配置新连接速率限制...${NC}"
    iptables -D INPUT -p tcp --dport "$port" --syn -m limit --limit 30/s --limit-burst 50 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport "$port" --syn -j DROP 2>/dev/null
    iptables -I INPUT -p tcp --dport "$port" --syn -j DROP
    iptables -I INPUT -p tcp --dport "$port" --syn -m limit --limit 30/s --limit-burst 50 -j ACCEPT
    echo -e "${GREEN}✓${NC} 新连接限速: 30/秒 (突发50)"

    # 3. 月度流量配额
    echo -e "${CYAN}[3/3] 配置月度流量配额...${NC}"
    local monthly_tb
    local default_tb=9
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        [ "$PLATFORM" = "azure" ] && default_tb=3
        [ "$PLATFORM" = "oracle" ] && default_tb=9
    elif [ "$mode" = "auto" ]; then
        # auto模式下通过传入的platform判断
        [ "${_auto_platform:-}" = "azure" ] && default_tb=3
    fi
    if [ "$mode" != "auto" ]; then
        read -rp "每月流量上限 (TB, 0=不限) [默认 ${default_tb}]: " monthly_tb
    fi
    [ -z "$monthly_tb" ] && monthly_tb=$default_tb

    if [ "$monthly_tb" -gt 0 ] 2>/dev/null; then
        # 安装 vnstat (流量统计)
        if ! command -v vnstat &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq vnstat 2>/dev/null
            systemctl enable vnstat
            systemctl start vnstat
        fi

        local monthly_gb=$(( monthly_tb * 1024 ))

        # 创建流量检查脚本
        cat > /opt/ssr/check_traffic.sh << 'SCRIPT'
#!/bin/bash
# 月度流量配额检查
MONTHLY_LIMIT_GB=PLACEHOLDER_GB
COMPOSE_DIR="/opt/ssr"

# 获取本月已用流量
MONTH_DATA=$(vnstat -m 1 --oneline 2>/dev/null | awk -F';' '{print $11}')
MONTH_VAL=$(echo "$MONTH_DATA" | grep -oP '[\d.]+')
MONTH_UNIT=$(echo "$MONTH_DATA" | grep -oP '[A-Z][a-zA-Z]+')

# 转换为GB
MONTH_GB=0
case "$MONTH_UNIT" in
    TiB|TB)  MONTH_GB=$(echo "$MONTH_VAL" | awk '{printf "%.0f", $1*1024}') ;;
    GiB|GB)  MONTH_GB=$(echo "$MONTH_VAL" | awk '{printf "%.0f", $1}') ;;
    MiB|MB)  MONTH_GB=$(echo "$MONTH_VAL" | awk '{printf "%.0f", $1/1024}') ;;
    *)       MONTH_GB=0 ;;
esac

if [ "$MONTH_GB" -ge "$MONTHLY_LIMIT_GB" ] 2>/dev/null; then
    cd "$COMPOSE_DIR"
    if docker compose ps 2>/dev/null | grep -q "running"; then
        docker compose stop
        echo "[$(date)] 月流量超限 (${MONTH_GB}GB >= ${MONTHLY_LIMIT_GB}GB), 服务已停止" >> /opt/ssr/traffic.log
    elif docker-compose ps 2>/dev/null | grep -q "Up"; then
        docker-compose stop
        echo "[$(date)] 月流量超限 (${MONTH_GB}GB >= ${MONTHLY_LIMIT_GB}GB), 服务已停止" >> /opt/ssr/traffic.log
    fi
fi
SCRIPT
        sed -i "s/PLACEHOLDER_GB/$monthly_gb/" /opt/ssr/check_traffic.sh
        chmod +x /opt/ssr/check_traffic.sh

        # 每月1号自动恢复脚本
        cat > /opt/ssr/monthly_reset.sh << 'SCRIPT'
#!/bin/bash
# 每月1号自动恢复服务
cd /opt/ssr
if docker compose version &>/dev/null; then
    docker compose start
else
    docker-compose start
fi
echo "[$(date)] 月度重置, 服务已恢复" >> /opt/ssr/traffic.log
SCRIPT
        chmod +x /opt/ssr/monthly_reset.sh

        # 设置 cron: 每30分钟检查流量 + 每月1号恢复
        (crontab -l 2>/dev/null | grep -v "check_traffic\|monthly_reset\|daily_reset"; \
         echo "*/30 * * * * /opt/ssr/check_traffic.sh"; \
         echo "0 0 1 * * /opt/ssr/monthly_reset.sh") | crontab -

        echo -e "${GREEN}✓${NC} 月度流量配额: ${monthly_tb}TB (超限停服, 次月1号恢复)"
    else
        echo -e "${GREEN}✓${NC} 跳过流量配额"
    fi

    # 持久化iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    echo ""
    echo -e "${BOLD}${GREEN}防滥用保护已配置:${NC}"
    echo -e "  • 单IP最大并发: ${BOLD}${max_conn}${NC} 连接"
    echo -e "  • 新连接速率:   ${BOLD}30/秒${NC} (突发50)"
    [ "$monthly_tb" -gt 0 ] 2>/dev/null && echo -e "  • 月度流量上限: ${BOLD}${monthly_tb}TB${NC} (超限停服, 次月恢复)"
    echo ""
}

# ==================== Oracle Cloud 保活 ====================
setup_oracle_keepalive() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Oracle Cloud 实例保活 ━━━${NC}"
    echo -e "${DIM}  防止免费实例因CPU使用率过低被回收${NC}"
    echo -e "${DIM}  原理: 使用 stress-ng 精确控制CPU负载${NC}"
    echo ""

    # ====== 清理所有旧版本残留 ======
    echo -e "${CYAN}清理旧版本...${NC}"
    systemctl stop oracle-keepalive.service 2>/dev/null || true
    systemctl stop oracle-keepalive.timer 2>/dev/null || true
    systemctl disable oracle-keepalive.timer 2>/dev/null || true
    systemctl kill --signal=SIGKILL oracle-keepalive.service 2>/dev/null || true
    rm -f /etc/systemd/system/oracle-keepalive.timer
    pkill -9 -f "while true; do :; done" 2>/dev/null || true
    pkill -9 -f "while :; do :; done" 2>/dev/null || true
    pkill -9 -f "keepalive_worker" 2>/dev/null || true
    pkill -9 -f "keepalive.sh" 2>/dev/null || true
    pkill -9 -f "stress-ng" 2>/dev/null || true
    killall -9 yes 2>/dev/null || true
    ps -eo pid,ni,comm --no-headers 2>/dev/null | awk '$2 == "19" && ($3 == "sh" || $3 == "bash" || $3 == "yes" || $3 == "stress-ng") {print $1}' | xargs -r kill -9 2>/dev/null || true
    (crontab -l 2>/dev/null | grep -v "keepalive") | crontab - 2>/dev/null || true
    echo -e "${GREEN}✓${NC} 旧版本已清理"

    # 安装 stress-ng
    if ! command -v stress-ng &>/dev/null; then
        echo -e "${CYAN}安装 stress-ng...${NC}"
        apt-get install -y stress-ng >/dev/null 2>&1
    fi

    # 检测CPU核心数
    local cores
    cores=$(nproc)
    echo -e "  CPU核心数: ${BOLD}${cores}${NC}"
    echo -e "  保活策略: 每天 8 小时, 每核 10% 负载 (日均≈3%)"

    # systemd 服务: 跑8小时后自动退出
    cat > /etc/systemd/system/oracle-keepalive.service << EOF
[Unit]
Description=Oracle Cloud Instance Keepalive (stress-ng)
After=network.target

[Service]
Type=simple
ExecStart=$(which stress-ng) --cpu ${cores} --cpu-load 10 --timeout 8h
Nice=19
KillSignal=SIGTERM
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

    # systemd timer: 每天凌晨2点启动, 随机延迟1小时
    cat > /etc/systemd/system/oracle-keepalive.timer << 'EOF'
[Unit]
Description=Oracle Keepalive Daily Timer

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable oracle-keepalive.timer
    systemctl start oracle-keepalive.timer
    # 立即启动一次 (不等到明天凌晨)
    systemctl start oracle-keepalive.service

    # 验证
    sleep 2
    if systemctl is-active oracle-keepalive.service &>/dev/null; then
        echo -e "${GREEN}✓${NC} 保活已启动"
    else
        echo -e "${RED}✗ 保活启动失败，请检查: systemctl status oracle-keepalive${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}✓${NC} 保活已配置:"
    echo -e "  • 工具: stress-ng (精确CPU负载控制)"
    echo -e "  • 时段: 每天 8 小时 (凌晨2点开始)"
    echo -e "  • 负载: 每核 10%"
    echo -e "  • 优先级: nice 19 (有其他任务时自动让出)"
    echo -e "  • 管理: systemctl stop/start oracle-keepalive"
    echo ""
}

# ==================== 网络性能优化 ====================
optimize_network_performance() {
    local platform="${1:-unknown}"
    local region="${2:-global}"

    echo ""
    echo -e "${BOLD}${CYAN}━━━ 网络性能优化 (稳速优先) ━━━${NC}"

    # 确保 BBR 模块可用
    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    # 针对跨境链路和抖动优化: 增大缓冲、启用 MTU 自适应、减少短连接抖动
    cat > /etc/sysctl.d/99-net-performance.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

net.core.somaxconn = 4096
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 8192

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

    # 大陆访问国际链路时，部分中间设备对 ECN 兼容性较差，关闭可提升稳定性
    if [ "$region" = "cn" ]; then
        echo "net.ipv4.tcp_ecn = 0" >> /etc/sysctl.d/99-net-performance.conf
    fi

    sysctl --system >/dev/null 2>&1

    # 识别默认出口网卡并优化队列
    local default_if
    default_if=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$default_if" ]; then
        ip link set dev "$default_if" txqueuelen 10000 2>/dev/null || true
        tc qdisc replace dev "$default_if" root fq 2>/dev/null || true
    fi

    # Azure 网络栈上开启 fq 后通常更稳，这里保留提示信息
    if [ "$platform" = "azure" ]; then
        echo -e "${GREEN}✓${NC} Azure 网络优化已应用 (BBR + fq + MTU probing)"
    else
        echo -e "${GREEN}✓${NC} 网络优化已应用 (BBR + fq + MTU probing)"
    fi

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local ecn
    ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)
    echo -e "  拥塞控制: ${BOLD}${cc:-unknown}${NC}"
    echo -e "  默认网卡: ${BOLD}${default_if:-unknown}${NC}"
    echo -e "  TCP ECN:  ${BOLD}${ecn:-unknown}${NC}"
    echo ""
}

# 兼容旧菜单/调用
enable_bbr() {
    optimize_network_performance "unknown" "global"
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

    local region
    if [ "$REGION_MODE" = "auto" ]; then
        region=$(detect_region)
    else
        region="$REGION_MODE"
    fi
    echo -e "${GREEN}✓${NC} 网络区域: ${BOLD}${region}${NC}"
    echo ""

    if [ "$region" = "cn" ]; then
        optimize_for_mainland
    else
        configure_apt_network
    fi

    # 根据平台选择默认TLS域名
    local default_tls
    case "$platform" in
        azure)  default_tls="$TLS_HOST_AZURE" ;;
        oracle) default_tls="$TLS_HOST_ORACLE" ;;
        *)      default_tls="$TLS_HOST_DEFAULT" ;;
    esac

    # 获取节点名称
    local node_name="${VPS_NODE_NAME:-}"
    if [ -z "$node_name" ] && [ "$AUTO_YES" != "1" ]; then
        read -rp "输入节点名称 (用于标识，如 Azure-HK-01): " node_name
    fi
    if [ -z "$node_name" ]; then
        if [ "$platform" = "azure" ]; then
            node_name="Azure-$(date +%m%d%H%M)"
        else
            node_name="VPS-$(date +%s | tail -c 5)"
        fi
    fi

    # 自定义端口
    local stls_port="${VPS_STLS_PORT:-$SHADOW_TLS_PORT}"
    local custom_port=""
    if [ "$AUTO_YES" != "1" ] && [ -z "${VPS_STLS_PORT:-}" ]; then
        read -rp "Shadow-TLS 监听端口 [默认 443]: " custom_port
        [ -n "$custom_port" ] && stls_port=$custom_port
    fi

    # 自定义TLS伪装域名
    local tls_host="${VPS_TLS_HOST:-$default_tls}"
    local custom_tls=""
    if [ "$AUTO_YES" != "1" ] && [ -z "${VPS_TLS_HOST:-}" ]; then
        read -rp "TLS 伪装域名 [默认 ${default_tls}]: " custom_tls
        [ -n "$custom_tls" ] && tls_host=$custom_tls
    fi

    echo ""

    # 系统安全加固 (更新+SSH+内核+清理)
    harden_system

    install_base_dependencies

    # 安装依赖
    install_docker "$region" || { echo -e "${RED}Docker 安装失败${NC}"; return 1; }
    configure_docker_mirror "$region"
    install_docker_compose || { echo -e "${RED}Docker Compose 安装失败${NC}"; return 1; }

    # 防火墙
    configure_firewall "$platform" "$stls_port" "tcp" "Shadow-TLS"

    # 网络优化 (稳速优先)
    optimize_network_performance "$platform" "$region"

    # fail2ban
    install_fail2ban

    # 创建安装目录 (防滥用和保活脚本需要写入此目录)
    mkdir -p "$INSTALL_DIR"

    # 防滥用保护 (默认值自动配置)
    _auto_platform="$platform"
    setup_abuse_protection "$stls_port" "auto"
    unset _auto_platform

    # Oracle 保活
    if [ "$platform" = "oracle" ]; then
        setup_oracle_keepalive
    fi

    # 生成密码
    local password
    password=$(generate_password)

    # 获取公网IP
    local public_ip
    public_ip=$(get_public_ip "$platform")

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
    ss_link=$(generate_ss_link "$public_ip" "$password" "$stls_port" "$node_name" "$tls_host")

    # 保存配置
    cat > "$CONFIG_FILE" << EOF
PLATFORM="${platform}"
REGION="${region}"
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
    echo -e "  区域模式: ${BOLD}${region}${NC}"
    echo ""

    # 测速
    echo -e "${CYAN}正在测速...${NC}"
    local dl_speed="" dl_mbps="0"
    # 依次尝试多个测速源
    for url in \
        "https://speed.cloudflare.com/__down?bytes=52428800" \
        "http://speedtest.cn-hangzhou.aliyuncs.com/10MB.zip" \
        "http://speedtest1.online.telia.com/10MB.zip" \
        "http://cachefly.cachefly.net/100mb.test" \
        "http://speedtest.tele2.net/10MB.zip" \
        "http://proof.ovh.net/files/10Mb.dat"; do
        dl_speed=$(curl -sL -o /dev/null -w '%{speed_download}' --max-time 12 "$url" 2>/dev/null)
        if [ -n "$dl_speed" ] && (( $(echo "$dl_speed > 1000" | bc -l 2>/dev/null || echo 0) )); then
            dl_mbps=$(echo "$dl_speed" | awk '{printf "%.0f", $1 * 8 / 1048576}')
            break
        fi
    done
    if [ "$dl_mbps" -gt 0 ] 2>/dev/null; then
        echo -e "  带宽:     ${BOLD}${dl_mbps} Mbps${NC}"
    else
        echo -e "  带宽:     ${YELLOW}测试失败 (可手动选菜单8重测)${NC}"
    fi

    echo ""
    echo -e "${CYAN}SS 链接 (复制到客户端导入):${NC}"
    echo ""
    echo -e "${GREEN}${ss_link}${NC}"
    echo ""
    echo "SS_LINK=${ss_link}"
    echo ""
}

# ==================== 安装 HY2 ====================
install_hy2() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  Hysteria2 部署${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ -f "$HY2_COMPOSE_FILE" ]; then
        if [ -f "$HY2_CONFIG_FILE" ]; then
            echo -e "${YELLOW}HY2 已安装，如需重新安装请先删除${NC}"
            print_hy2_link
            return
        fi
        echo -e "${YELLOW}检测到未完成的 HY2 安装，自动清理后重装...${NC}"
        rm -rf "$HY2_INSTALL_DIR"
    fi

    echo -e "${CYAN}正在检测平台...${NC}"
    local platform
    platform=$(detect_platform)
    echo -e "${GREEN}✓${NC} 平台: ${BOLD}${platform}${NC}"

    local region
    if [ "$REGION_MODE" = "auto" ]; then
        region=$(detect_region)
    else
        region="$REGION_MODE"
    fi
    echo -e "${GREEN}✓${NC} 网络区域: ${BOLD}${region}${NC}"
    echo ""

    if [ "$region" = "cn" ]; then
        optimize_for_mainland
    else
        configure_apt_network
    fi

    local default_sni
    case "$platform" in
        azure)  default_sni="$TLS_HOST_AZURE" ;;
        oracle) default_sni="$TLS_HOST_ORACLE" ;;
        *)      default_sni="$TLS_HOST_DEFAULT" ;;
    esac

    local node_name="${VPS_NODE_NAME:-}"
    if [ -z "$node_name" ] && [ "$AUTO_YES" != "1" ]; then
        read -rp "输入 HY2 节点名称 (如 Azure-HY2-01): " node_name
    fi
    if [ -z "$node_name" ]; then
        if [ "$platform" = "azure" ]; then
            node_name="Azure-HY2-$(date +%m%d%H%M)"
        else
            node_name="HY2-$(date +%s | tail -c 5)"
        fi
    fi

    local hy2_port="${VPS_HY2_PORT:-$HY2_PORT}"
    local custom_port=""
    if [ "$AUTO_YES" != "1" ] && [ -z "${VPS_HY2_PORT:-}" ]; then
        read -rp "HY2 UDP 监听端口 [默认 443]: " custom_port
        [ -n "$custom_port" ] && hy2_port=$custom_port
    fi

    local sni="${VPS_HY2_SNI:-${VPS_TLS_HOST:-$default_sni}}"
    local custom_sni=""
    if [ "$AUTO_YES" != "1" ] && [ -z "${VPS_HY2_SNI:-}${VPS_TLS_HOST:-}" ]; then
        read -rp "HY2 SNI/伪装域名 [默认 ${default_sni}]: " custom_sni
        [ -n "$custom_sni" ] && sni=$custom_sni
    fi

    echo ""

    harden_system
    install_base_dependencies
    install_docker "$region" || { echo -e "${RED}Docker 安装失败${NC}"; return 1; }
    configure_docker_mirror "$region"
    install_docker_compose || { echo -e "${RED}Docker Compose 安装失败${NC}"; return 1; }

    configure_firewall "$platform" "$hy2_port" "udp" "HY2"
    optimize_network_performance "$platform" "$region"
    install_fail2ban

    if [ "$platform" = "oracle" ]; then
        setup_oracle_keepalive
    fi

    mkdir -p "$HY2_INSTALL_DIR"

    local password
    password=$(generate_password)

    local public_ip
    public_ip=$(get_public_ip "$platform")

    if ! openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$HY2_INSTALL_DIR/server.key" \
        -out "$HY2_INSTALL_DIR/server.crt" \
        -days 3650 -subj "/CN=${sni}" >/dev/null 2>&1; then
        echo -e "${RED}✗ HY2 自签证书生成失败${NC}"
        return 1
    fi
    chmod 600 "$HY2_INSTALL_DIR/server.key"

    cat > "$HY2_INSTALL_DIR/config.yaml" << EOF
listen: ":${hy2_port}"

tls:
    cert: "/etc/hysteria/server.crt"
    key: "/etc/hysteria/server.key"

auth:
    type: password
    password: "${password}"

masquerade:
    type: proxy
    proxy:
        url: "https://${sni}/"
        rewriteHost: true

quic:
    initStreamReceiveWindow: 8388608
    maxStreamReceiveWindow: 8388608
    initConnReceiveWindow: 20971520
    maxConnReceiveWindow: 20971520
EOF

    cat > "$HY2_COMPOSE_FILE" << EOF
services:
  hysteria2:
    image: "${HY2_IMAGE}"
    restart: always
    network_mode: "host"
    volumes:
      - ./config.yaml:/etc/hysteria/config.yaml:ro
      - ./server.crt:/etc/hysteria/server.crt:ro
      - ./server.key:/etc/hysteria/server.key:ro
    command: ["server", "-c", "/etc/hysteria/config.yaml"]
EOF

    echo ""
    echo -e "${CYAN}正在拉取 HY2 镜像并启动...${NC}"
    cd "$HY2_INSTALL_DIR"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [ -z "$compose_cmd" ]; then
        echo -e "${RED}Docker Compose 未找到${NC}"
        return 1
    fi
    $compose_cmd up -d

    sleep 3
    if $compose_cmd ps | grep -q "Up\|running"; then
        echo -e "${GREEN}✓${NC} HY2 服务启动成功"
    else
        echo -e "${RED}✗ HY2 服务启动失败，请检查日志: $compose_cmd -f $HY2_COMPOSE_FILE logs${NC}"
        $compose_cmd logs --tail=50 2>/dev/null || true
        return 1
    fi

    if ! hy2_udp_listening "$hy2_port"; then
        echo -e "${YELLOW}⚠ 未检测到 HY2 UDP ${hy2_port} 监听，最近日志如下:${NC}"
        $compose_cmd logs --tail=50 2>/dev/null || true
    fi

    disable_password_auth

    local hy2_link
    hy2_link=$(generate_hy2_link "$public_ip" "$password" "$hy2_port" "$node_name" "$sni")

    cat > "$HY2_CONFIG_FILE" << EOF
PLATFORM="${platform}"
REGION="${region}"
PUBLIC_IP="${public_ip}"
PASSWORD="${password}"
HY2_PORT="${hy2_port}"
HY2_SNI="${sni}"
NODE_NAME="${node_name}"
HY2_LINK="${hy2_link}"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$HY2_CONFIG_FILE"

    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}  HY2 部署完成!${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  节点名称: ${BOLD}${node_name}${NC}"
    echo -e "  服务器IP: ${BOLD}${public_ip}${NC}"
    echo -e "  端口:     ${BOLD}${hy2_port}/UDP${NC}"
    echo -e "  密码:     ${BOLD}${password}${NC}"
    echo -e "  SNI:      ${BOLD}${sni}${NC}"
    echo -e "  证书:     ${BOLD}自签证书，客户端需允许 insecure${NC}"
    echo -e "  平台:     ${BOLD}${platform}${NC}"
    echo -e "  区域模式: ${BOLD}${region}${NC}"
    print_hy2_diagnostics "$hy2_port" "$platform"
    echo ""
    echo -e "${CYAN}HY2 链接 (复制到客户端导入):${NC}"
    echo ""
    echo -e "${GREEN}${hy2_link}${NC}"
    echo ""
    echo "HY2_LINK=${hy2_link}"
    echo ""
}

# ==================== 删除 HY2 ====================
uninstall_hy2() {
    echo ""
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${RED}  删除 Hysteria2${NC}"
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ ! -f "$HY2_COMPOSE_FILE" ]; then
        echo -e "${YELLOW}HY2 未安装${NC}"
        return
    fi

    read -rp "确认删除 HY2? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${DIM}已取消${NC}"
        return
    fi

    echo -e "${CYAN}正在停止并删除 HY2 容器...${NC}"
    cd "$HY2_INSTALL_DIR"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    [ -z "$compose_cmd" ] && compose_cmd="docker compose"
    $compose_cmd down --rmi all 2>/dev/null || $compose_cmd down 2>/dev/null

    echo -e "${CYAN}清理 HY2 文件...${NC}"
    rm -rf "$HY2_INSTALL_DIR"

    echo ""
    echo -e "${GREEN}✓${NC} HY2 已删除"
    echo ""
}

# ==================== 查看 HY2 状态 ====================
status_hy2() {
    echo ""
    if [ ! -f "$HY2_COMPOSE_FILE" ]; then
        echo -e "${YELLOW}HY2 未安装${NC}"
        return
    fi

    echo -e "${BOLD}${CYAN}━━━ HY2 状态 ━━━${NC}"
    echo ""

    if [ -f "$HY2_CONFIG_FILE" ]; then
        source "$HY2_CONFIG_FILE"
        echo -e "  节点名称: ${BOLD}${NODE_NAME}${NC}"
        echo -e "  服务器IP: ${BOLD}${PUBLIC_IP}${NC}"
        echo -e "  端口:     ${BOLD}${HY2_PORT}/UDP${NC}"
        echo -e "  SNI:      ${BOLD}${HY2_SNI}${NC}"
        [ -n "${PLATFORM:-}" ] && echo -e "  平台:     ${BOLD}${PLATFORM}${NC}"
        [ -n "${REGION:-}" ] && echo -e "  区域模式: ${BOLD}${REGION}${NC}"
        echo -e "  安装时间: ${BOLD}${INSTALL_DATE}${NC}"
        echo ""
    else
        echo -e "${YELLOW}未找到 HY2 配置文件，可能是上次安装未完成${NC}"
        echo -e "${YELLOW}建议直接重新执行 install-hy2，脚本会自动清理未完成安装${NC}"
        echo ""
    fi

    cd "$HY2_INSTALL_DIR"
    echo -e "${BOLD}  容器状态:${NC}"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    [ -z "$compose_cmd" ] && compose_cmd="docker compose"
    $compose_cmd ps
    echo ""

    print_hy2_diagnostics "${HY2_PORT:-443}" "${PLATFORM:-unknown}"
    echo -e "${BOLD}  最近日志:${NC}"
    $compose_cmd logs --tail=30 2>/dev/null || true
    echo ""

    print_hy2_link
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

    # 清理 cron 任务
    (crontab -l 2>/dev/null | grep -v "check_traffic\|monthly_reset\|keepalive") | crontab - 2>/dev/null

    # 清理 systemd timer
    systemctl stop oracle-keepalive.timer 2>/dev/null
    systemctl disable oracle-keepalive.timer 2>/dev/null
    rm -f /etc/systemd/system/oracle-keepalive.service /etc/systemd/system/oracle-keepalive.timer
    systemctl daemon-reload 2>/dev/null

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
        [ -n "${PLATFORM:-}" ] && echo -e "  平台:     ${BOLD}${PLATFORM}${NC}"
        [ -n "${REGION:-}" ] && echo -e "  区域模式: ${BOLD}${REGION}${NC}"
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
        print_ss_link
    fi
    echo ""
}

# ==================== 网络测速 ====================
speed_test() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ 网络带宽测速 ━━━${NC}"
    echo ""

    # 下载测试 (多源)
    echo -e "${CYAN}测试下载速度...${NC}"
    local dl_result="" dl_mbps="0"
    for url in \
        "http://speedtest.cn-hangzhou.aliyuncs.com/100MB.zip" \
        "http://speedtest1.online.telia.com/100MB.zip" \
        "https://speed.cloudflare.com/__down?bytes=104857600" \
        "http://cachefly.cachefly.net/100mb.test" \
        "http://speedtest.tele2.net/10MB.zip" \
        "http://proof.ovh.net/files/100Mb.dat"; do
        dl_result=$(curl -sL -o /dev/null -w '%{speed_download}' --max-time 15 "$url" 2>/dev/null)
        if [ -n "$dl_result" ] && (( $(echo "$dl_result > 1000" | bc -l 2>/dev/null || echo 0) )); then
            dl_mbps=$(echo "$dl_result" | awk '{printf "%.1f", $1 * 8 / 1048576}')
            break
        fi
    done

    if [ "$(echo "$dl_mbps > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        echo -e "  下载速度: ${BOLD}${dl_mbps} Mbps${NC}"
    else
        echo -e "  下载速度: ${YELLOW}测试失败 (所有测试源不可达)${NC}"
        dl_mbps="0"
    fi

    # 上传测试
    echo -e "${CYAN}测试上传速度...${NC}"
    local ul_result ul_mbps="0"
    ul_result=$(dd if=/dev/urandom bs=1M count=10 2>/dev/null | \
        curl -sL -o /dev/null -w '%{speed_upload}' --max-time 15 \
        -X POST --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)
    if [ -n "$ul_result" ] && (( $(echo "$ul_result > 1000" | bc -l 2>/dev/null || echo 0) )); then
        ul_mbps=$(echo "$ul_result" | awk '{printf "%.1f", $1 * 8 / 1048576}')
        echo -e "  上传速度: ${BOLD}${ul_mbps} Mbps${NC}"
    else
        echo -e "  上传速度: ${YELLOW}测试失败${NC}"
    fi

    # 判断带宽等级
    echo ""
    local dl_int
    dl_int=$(echo "$dl_mbps" | awk '{printf "%d", $1}')
    if [ "$dl_int" -ge 800 ] 2>/dev/null; then
        echo -e "  带宽等级: ${GREEN}${BOLD}≥1Gbps${NC} (无明显限速)"
    elif [ "$dl_int" -ge 400 ] 2>/dev/null; then
        echo -e "  带宽等级: ${GREEN}${BOLD}~500Mbps${NC}"
    elif [ "$dl_int" -ge 150 ] 2>/dev/null; then
        echo -e "  带宽等级: ${YELLOW}${BOLD}~200Mbps${NC}"
    elif [ "$dl_int" -ge 40 ] 2>/dev/null; then
        echo -e "  带宽等级: ${YELLOW}${BOLD}~50Mbps${NC} (Oracle免费AMD常见限速)"
    elif [ "$dl_int" -gt 0 ] 2>/dev/null; then
        echo -e "  带宽等级: ${RED}${BOLD}<50Mbps${NC} (网络较慢)"
    else
        echo -e "  带宽等级: ${RED}无法判断${NC}"
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
    echo -e "  ${GREEN}4)${NC} 优化网络 (稳速优先)"
    echo -e "  ${GREEN}5)${NC} 安装 fail2ban (封禁暴力扫描IP)"
    echo -e "  ${GREEN}6)${NC} SSR 防滥用保护 (限连接/限流量)"
    echo -e "  ${GREEN}7)${NC} Oracle Cloud 保活 (防停机回收)"
    echo -e "  ${GREEN}8)${NC} 网络测速 (检测带宽限速)"
    echo -e "  ${GREEN}9)${NC} 仅输出 SS 链接 (便于复制)"
    echo -e "  ${GREEN}10)${NC} 安装 HY2 (Hysteria2, UDP)"
    echo -e "  ${GREEN}11)${NC} 删除 HY2"
    echo -e "  ${GREEN}12)${NC} 查看 HY2 状态/链接"
    echo -e "  ${GREEN}0)${NC} 退出"
    echo ""
}

# ==================== 入口 ====================
main() {
    check_root
    local cmd=""

    case "$AUTO_YES" in
        1|yes|YES|true|TRUE|y|Y) AUTO_YES="1" ;;
        *) AUTO_YES="0" ;;
    esac

    # 快捷参数: 支持 --azure / --cn / --yes
    for arg in "$@"; do
        case "$arg" in
            --azure-cn|--cn-azure)
                PLATFORM_MODE="azure"
                REGION_MODE="cn"
                ;;
            --azure)
                PLATFORM_MODE="azure"
                ;;
            --oracle|--oci)
                PLATFORM_MODE="oracle"
                ;;
            --cn|--china)
                REGION_MODE="cn"
                ;;
            --global|--intl)
                REGION_MODE="global"
                ;;
            --yes|-y)
                AUTO_YES="1"
                ;;
            install|uninstall|remove|status|link|install-hy2|hy2|uninstall-hy2|remove-hy2|status-hy2|hy2-link)
                [ -z "$cmd" ] && cmd="$arg"
                ;;
        esac
    done

    # 支持直接命令
    case "${cmd:-${1:-}}" in
        install) install_ssr; exit 0 ;;
        install-hy2|hy2) install_hy2; exit 0 ;;
        uninstall|remove) uninstall_ssr; exit 0 ;;
        uninstall-hy2|remove-hy2) uninstall_hy2; exit 0 ;;
        status) status_ssr; exit 0 ;;
        status-hy2) status_hy2; exit 0 ;;
        link) print_ss_link; exit $? ;;
        hy2-link) print_hy2_link; exit $? ;;
        *) ;;
    esac

    # 交互式菜单
    while true; do
        show_menu
        read -rp "请选择 [0-9]: " choice
        case "$choice" in
            1) install_ssr ;;
            2) uninstall_ssr ;;
            3) status_ssr ;;
            4)
                local platform region
                platform=$(detect_platform)
                if [ "$REGION_MODE" = "auto" ]; then
                    region=$(detect_region)
                else
                    region="$REGION_MODE"
                fi
                optimize_network_performance "$platform" "$region"
                ;;
            5) install_fail2ban ;;
            6) setup_abuse_protection ;;
            7) setup_oracle_keepalive ;;
            8) speed_test ;;
            9) print_ss_link ;;
            10) install_hy2 ;;
            11) uninstall_hy2 ;;
            12) status_hy2 ;;
            0) echo -e "${GREEN}Bye${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

main "$@"
