#!/bin/bash
# 初始化 Debian 12 系统配置脚本（自动检测网卡）
# 功能：设置主机名、root 密码、SSH 登录、网络、APT 源

set -e

HOSTNAME="YEZHU"
ROOTPASS="QAZxsw412500"

echo "=== 设置主机名 ==="
hostnamectl set-hostname "$HOSTNAME"

echo "=== 设置 root 密码 ==="
echo "root:$ROOTPASS" | chpasswd

echo "=== 配置 SSH 允许 root 密码登录 ==="
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

echo "=== 自动检测网卡名称 ==="
NET_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^en|^eth' | head -n1)
if [ -z "$NET_IF" ]; then
    echo "未检测到合适的网卡，请手动修改 /etc/network/interfaces"
    exit 1
fi
echo "检测到网卡: $NET_IF"

echo "=== 配置网络为 DHCP ==="
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

allow-hotplug $NET_IF
iface $NET_IF inet dhcp
EOF
systemctl restart networking || true

echo "=== 替换 APT 源为清华大学镜像 ==="
cat > /etc/apt/sources.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

echo "=== 更新系统并安装常用工具 ==="
apt update
apt install -y curl wget sudo unzip

echo "=== 初始化完成 ==="
echo "主机名: $HOSTNAME"
echo "root 密码: $ROOTPASS"
echo "网卡: $NET_IF (DHCP 模式)"
