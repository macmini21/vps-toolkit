#!/bin/bash
# ============================================================
# VPS 一键工具箱
# 功能: SSR(Shadowsocks + Shadow-TLS) 一键部署/删除
# 兼容: Oracle Cloud / Azure / 通用VPS
# 用法: bash vps.sh
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
SS_PORT=22000
SHADOW_TLS_PORT=443
TLS_HOST_AZURE="www.microsoft.com"
TLS_HOST_ORACLE="www.apple.com"
TLS_HOST_DEFAULT="www.apple.com"
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
    ip=$(curl -s -m 5 ifconfig.me 2>/dev/null) || true
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
    tag_encoded=$(printf '%s' "$tag" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || printf '%s' "$tag" | sed 's/ /%20/g; s/#/%23/g')

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
    local port="$2"  # Shadow-TLS 端口

    if [ "$platform" = "oracle" ]; then
        echo -e "${CYAN}检测到 Oracle Cloud，配置防火墙...${NC}"

        # 获取当前SSH端口
        local ssh_port
        ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
        [ -z "$ssh_port" ] && ssh_port=22

        # 清除甲骨文默认的限制规则 (不清nat/mangle, 保护Docker)
        iptables -F
        iptables -X 2>/dev/null || true

        # 设置默认策略: 出站允许，入站丢弃
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT

        # 允许回环
        iptables -A INPUT -i lo -j ACCEPT

        # 允许已建立的连接
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        # 允许 ICMP (ping)
        iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
        iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

        # 允许 SSH
        iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT

        # 允许 Shadow-TLS 端口
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT

        # 记录并丢弃其他
        iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables-dropped: " --log-level 4

        # 持久化规则
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi

        echo -e "${GREEN}✓${NC} 防火墙已配置: SSH(${ssh_port}) + Shadow-TLS(${port}) + ICMP"
    elif [ "$platform" = "azure" ]; then
        echo -e "${GREEN}✓${NC} Azure 平台，跳过 iptables 配置 (使用 NSG 管理)"
    else
        echo -e "${YELLOW}未知平台，是否配置防火墙? (仅开放 SSH + 代理端口 + ping)${NC}"
        read -rp "[y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            local ssh_port
            ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
            [ -z "$ssh_port" ] && ssh_port=22

            iptables -F
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
            iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo -e "${GREEN}✓${NC} 防火墙已配置: SSH(${ssh_port}) + Shadow-TLS(${port}) + ICMP"
        fi
    fi
}

# ==================== 安装 fail2ban ====================
install_fail2ban() {
    echo -e "${CYAN}配置 fail2ban (自动封禁暴力扫描IP)...${NC}"

    if ! command -v fail2ban-client &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq fail2ban 2>/dev/null
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
    iptables -D INPUT -p tcp --dport "$port" -m connlimit --connlimit-above "$max_conn" -j DROP 2>/dev/null
    # 在ACCEPT规则之前插入connlimit
    iptables -I INPUT -p tcp --dport "$port" -m connlimit --connlimit-above "$max_conn" -j DROP
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
    echo -e "${DIM}  原理: 定期产生CPU负载，保持7天均值 >10%${NC}"
    echo ""

    # 检测CPU核心数和内存，计算需要的负载参数
    local cores mem_mb
    cores=$(nproc)
    mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    echo -e "  CPU核心数: ${BOLD}${cores}${NC}"
    echo -e "  内存大小:  ${BOLD}${mem_mb}MB${NC}"

    # 目标: 维持约12-15%的 总CPU 使用率
    # 公式: CPU% = (workers × duration) / (interval × cores)
    # 策略: 每10分钟运行，启动 cores 个并行 worker 各跑 duration 秒
    # 这样无论几核，CPU% = duration / interval = 75/600 ≈ 12.5%
    local duration=75
    local workers=$cores

    # 低内存机器 (<=1GB) 限制并行数，避免 OOM
    if [ "$mem_mb" -le 1024 ] && [ "$workers" -gt 2 ]; then
        workers=2
        duration=$(( 75 * cores / workers ))
        # 上限180秒，防止任务重叠
        [ "$duration" -gt 180 ] && duration=180
    fi

    echo -e "  保活策略:  ${BOLD}${workers} workers × ${duration}s${NC} (目标≈12%)"

    cat > /opt/ssr/keepalive.sh << SCRIPT
#!/bin/bash
# Oracle Cloud 实例保活 - CPU负载生成 (自动适配)
# 每10分钟运行, 目标CPU均值 12-15%
# 机器配置: ${cores}C / ${mem_mb}MB
# 策略: ${workers} 并行 worker × ${duration}s

# 随机延迟0-30秒，避免固定模式
sleep \$(( RANDOM % 30 ))

WORKERS=${workers}
DURATION=${duration}

# 启动 worker (nice 19, 不影响正常业务)
for i in \$(seq 1 \$WORKERS); do
    timeout \$DURATION nice -n 19 sh -c 'while true; do :; done' &
done

# 偶尔额外增加一点 I/O 负载 (更自然的使用模式)
if [ \$(( RANDOM % 4 )) -eq 0 ]; then
    timeout \$(( DURATION / 3 )) nice -n 19 dd if=/dev/urandom bs=64K count=256 of=/dev/null 2>/dev/null &
fi

wait
SCRIPT
    chmod +x /opt/ssr/keepalive.sh

    # 设置 cron: 每10分钟
    (crontab -l 2>/dev/null | grep -v "keepalive"; \
     echo "*/10 * * * * /opt/ssr/keepalive.sh") | crontab -

    # 创建 systemd 服务 (备份，防止cron失效)
    cat > /etc/systemd/system/oracle-keepalive.service << 'EOF'
[Unit]
Description=Oracle Cloud Instance Keepalive
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/ssr/keepalive.sh
Nice=19
CPUSchedulingPolicy=idle
EOF

    cat > /etc/systemd/system/oracle-keepalive.timer << 'EOF'
[Unit]
Description=Run Oracle Keepalive every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable oracle-keepalive.timer
    systemctl start oracle-keepalive.timer

    echo ""
    echo -e "${GREEN}✓${NC} 保活已配置:"
    echo -e "  • 频率: 每10分钟"
    echo -e "  • 策略: ${workers} workers × ${duration}s"
    echo -e "  • 优先级: nice 19 (最低，不影响正常业务)"
    echo -e "  • 预估CPU均值: 12-15%"
    echo -e "  • 双保险: cron + systemd timer"
    echo ""
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

    # 根据平台选择默认TLS域名
    local default_tls
    case "$platform" in
        azure)  default_tls="$TLS_HOST_AZURE" ;;
        oracle) default_tls="$TLS_HOST_ORACLE" ;;
        *)      default_tls="$TLS_HOST_DEFAULT" ;;
    esac

    # 获取节点名称
    read -rp "输入节点名称 (用于标识，如 东京01): " node_name
    [ -z "$node_name" ] && node_name="VPS-$(date +%s | tail -c 5)"

    # 自定义端口
    local stls_port=$SHADOW_TLS_PORT
    read -rp "Shadow-TLS 监听端口 [默认 443]: " custom_port
    [ -n "$custom_port" ] && stls_port=$custom_port

    # 自定义TLS伪装域名
    local tls_host=$default_tls
    read -rp "TLS 伪装域名 [默认 ${default_tls}]: " custom_tls
    [ -n "$custom_tls" ] && tls_host=$custom_tls

    echo ""

    # 安装依赖
    install_docker || { echo -e "${RED}Docker 安装失败${NC}"; return 1; }
    install_docker_compose || { echo -e "${RED}Docker Compose 安装失败${NC}"; return 1; }

    # 防火墙
    configure_firewall "$platform" "$stls_port"

    # BBR
    enable_bbr

    # fail2ban
    install_fail2ban

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
    ss_link=$(generate_ss_link "$public_ip" "$password" "$stls_port" "$node_name" "$tls_host")

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
    echo -e "  ${GREEN}5)${NC} 安装 fail2ban (封禁暴力扫描IP)"
    echo -e "  ${GREEN}6)${NC} SSR 防滥用保护 (限连接/限流量)"
    echo -e "  ${GREEN}7)${NC} Oracle Cloud 保活 (防停机回收)"
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
        read -rp "请选择 [0-7]: " choice
        case "$choice" in
            1) install_ssr ;;
            2) uninstall_ssr ;;
            3) status_ssr ;;
            4) enable_bbr ;;
            5) install_fail2ban ;;
            6) setup_abuse_protection ;;
            7) setup_oracle_keepalive ;;
            0) echo -e "${GREEN}Bye${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

main "$@"
