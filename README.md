# VPS 一键工具箱

一键部署 Shadowsocks + Shadow-TLS 代理服务。

## 功能

- 一键安装/删除 Shadowsocks + Shadow-TLS
- 自动检测平台 (Oracle Cloud / Azure)
- Oracle Cloud 自动开放 iptables
- 随机生成高强度密码
- 自动启用 BBR 拥塞控制优化
- 自动关闭 SSH 密码登录
- 安装完成后输出 ss:// 导入链接

## 使用方法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/macmini21/vps-toolkit/main/vps.sh)
```

或者克隆后执行:

```bash
git clone https://github.com/macmini21/vps-toolkit.git
cd vps-toolkit
sudo bash vps.sh
```

## 命令行模式

```bash
sudo bash vps.sh install    # 直接安装
sudo bash vps.sh uninstall  # 直接删除
sudo bash vps.sh status     # 查看状态
```

## 兼容性

| 平台 | 支持 | 备注 |
|------|------|------|
| Oracle Cloud | ✅ | 自动开放 iptables |
| Azure | ✅ | 跳过 iptables (使用 NSG) |
| 通用 VPS | ✅ | 交互式选择 |

## 依赖

- Docker
- Docker Compose
- curl / openssl / python3 (base64编码)
