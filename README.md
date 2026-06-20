# VPS 一键工具箱

一键部署 Shadowsocks + Shadow-TLS 代理服务，同时完成系统安全加固。

## 功能

### 一键安装自动完成

- 系统安全加固 (更新/SSH加固/内核加固/清理无用服务)
- 安装 Docker + Docker Compose
- 部署 Shadowsocks + Shadow-TLS (Docker容器)
- 启用 BBR 拥塞控制
- 配置防火墙 (Oracle 自动配置 iptables)
- 安装 fail2ban (封禁暴力破解IP)
- 防滥用保护 (限连接/限速率/限流量)
- Oracle Cloud 保活 (自动适配CPU核心数)
- 关闭 SSH 密码登录
- 生成 ss:// 导入链接

### 平台自动适配

| 平台 | 防火墙 | 保活 | TLS伪装域名 | 流量上限 |
|------|--------|------|-------------|----------|
| Oracle Cloud | iptables 自动配置 | ✅ 自动启用 | www.apple.com | 9TB/月 |
| Azure | 跳过 (使用NSG) | ❌ 不需要 | www.microsoft.com | 3TB/月 |
| 通用 VPS | 交互式选择 | ❌ 手动 | www.apple.com | 9TB/月 |

## 使用方法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/macmini21/vps-toolkit/main/vps.sh)
```

### Azure + 中国大陆推荐用法

大陆网络环境部署 Azure VM 时，建议显式指定平台和区域，脚本会启用大陆 apt/Docker 镜像、DNS/NTP、BBR/fq/MTU probing，并跳过本机 iptables 防火墙配置，改由 Azure NSG 管理。

```bash
sudo bash <(curl -fsSL https://macmini21.github.io/vps-toolkit/vps.sh) install --azure --cn
```

也可以使用等价快捷参数 `--azure-cn`。

免交互安装可加 `--yes`，也可以用环境变量覆盖默认节点名、端口、TLS 伪装域名和 Docker 镜像站：

```bash
sudo env VPS_NODE_NAME="Azure-HK-01" \
	VPS_STLS_PORT=443 \
	VPS_TLS_HOST="www.microsoft.com" \
	bash <(curl -fsSL https://macmini21.github.io/vps-toolkit/vps.sh) install --azure --cn --yes
```

如果默认 Docker Hub 镜像站不可用，可自定义：

```bash
sudo env VPS_DOCKER_MIRRORS="https://mirror1.example.com,https://mirror2.example.com" \
	bash <(curl -fsSL https://macmini21.github.io/vps-toolkit/vps.sh) install --azure --cn --yes
```

## 命令行模式

```bash
sudo bash vps.sh install    # 直接安装
sudo bash vps.sh uninstall  # 直接删除
sudo bash vps.sh status     # 查看状态/链接
sudo bash vps.sh install --azure --cn --yes  # Azure + 大陆免交互安装
sudo bash vps.sh install --azure-cn --yes    # 同上，快捷写法
```

## 交互菜单

```
1) 安装 SSR (Shadowsocks + Shadow-TLS)
2) 删除 SSR
3) 查看 SSR 状态/链接
4) 优化网络 (BBR)
5) 安装 fail2ban
6) SSR 防滥用保护 (限连接/限流量)
7) Oracle Cloud 保活 (防停机回收)
0) 退出
```

## 安全加固详情

| 项目 | 说明 |
|------|------|
| 系统更新 | apt update/upgrade + 自动安全更新 (unattended-upgrades) |
| SSH 加固 | Root仅key登录, MaxAuthTries=3, 关闭X11, 60s超时 |
| 密码登录 | 检测到SSH公钥后自动关闭密码登录 |
| 内核参数 | 防IP欺骗/ICMP重定向, SYN cookie, 记录异常包 |
| fail2ban | 10分钟内3次失败 → 封禁24小时 |
| 连接限制 | 单IP最大20并发, 新连接30/秒 |
| 流量配额 | 超限自动停服, 次月1号自动恢复 |
| 服务清理 | 停用 rpcbind/avahi/cups/snapd |

## Oracle Cloud 保活

自动检测 CPU 核心数和内存，智能适配负载策略：

- **目标**: CPU 7天均值 ≥ 10% (防止被回收)
- **策略**: 每10分钟运行，`cores` 个并行 worker × 75 秒
- **优先级**: nice 19 (最低优先级，不影响正常业务)
- **双保险**: cron + systemd timer
- **低内存适配**: ≤1GB 内存限制 worker 数，防止 OOM

## 客户端

生成的 `ss://` 链接支持以下客户端直接导入：

- Shadowrocket (iOS)
- Clash Meta / mihomo
- sing-box

## 依赖 (自动安装)

- Docker + Docker Compose
- curl / openssl / python3
- fail2ban / vnstat / iptables-persistent
