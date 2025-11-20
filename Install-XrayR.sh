#!/bin/bash

# 彩色日志输出
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log_info() { echo -e "${green}[INFO]${plain} $1"; }
log_warn() { echo -e "${yellow}[WARN]${plain} $1"; }
log_error() { echo -e "${red}[ERROR]${plain} $1"; }

cur_dir=$(pwd)

# 必须 root
[[ $EUID -ne 0 ]] && log_error "必须使用 root 用户运行此脚本！" && exit 1

# 检测系统
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif grep -Eqi "debian" /etc/issue /proc/version; then
    release="debian"
elif grep -Eqi "ubuntu" /etc/issue /proc/version; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat" /etc/issue /proc/version; then
    release="centos"
else
    log_error "未检测到系统版本" && exit 1
fi

# 架构检测
arch=$(arch)
case $arch in
    x86_64|x64|amd64) arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    s390x) arch="s390x" ;;
    *) arch="64"; log_warn "检测架构失败，使用默认: ${arch}" ;;
esac
log_info "架构: ${arch}"

# 系统版本检测
os_version=""
[[ -f /etc/os-release ]] && os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
[[ -z "$os_version" && -f /etc/lsb-release ]] && os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)

if [[ x"${release}" == x"centos" && ${os_version} -le 6 ]]; then
    log_error "请使用 CentOS 7 或更高版本！" && exit 1
elif [[ x"${release}" == x"ubuntu" && ${os_version} -lt 16 ]]; then
    log_error "请使用 Ubuntu 16 或更高版本！" && exit 1
elif [[ x"${release}" == x"debian" && ${os_version} -lt 8 ]]; then
    log_error "请使用 Debian 8 或更高版本！" && exit 1
fi

# 安装依赖
install_base() {
    log_info "安装依赖..."
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

# 更新 Geo 文件
update_geo_files() {
    log_info "正在更新 Geo 文件..."
    wget -O /etc/XrayR/geoip.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
    wget -O /etc/XrayR/geosite.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    log_info "Geo 文件更新完成"
}

# 设置定时任务每天凌晨六点更新
setup_cron_update() {
    log_info "设置定时任务：每天凌晨六点更新 Geo 文件"
    cat > /etc/cron.d/xrayr-geo-update <<EOF
0 6 * * * root wget -O /etc/XrayR/geoip.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && wget -O /etc/XrayR/geosite.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
EOF
    systemctl restart cron
    log_info "定时任务已添加并生效"
}

# 安装 XrayR 最新版（不自动启动）
install_XrayR() {
    log_info "开始安装 XrayR 最新版..."
    rm -rf /usr/local/XrayR/
    mkdir -p /usr/local/XrayR/
    cd /usr/local/XrayR/

    last_version=$(curl -Ls "https://proxy.shuiqiang.xyz/https://api.github.com/repos/XrayR-project/XrayR/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$last_version" ]] && log_error "检测 XrayR 版本失败" && exit 1

    log_info "检测到最新版本: ${last_version}"
    wget -q -N --no-check-certificate -O XrayR-linux.zip https://proxy.shuiqiang.xyz/https://github.com/XrayR-project/XrayR/releases/download/${last_version}/XrayR-linux-${arch}.zip || { log_error "下载失败"; exit 1; }

    unzip XrayR-linux.zip && rm -f XrayR-linux.zip
    chmod +x XrayR
    mkdir -p /etc/XrayR/
    wget -q -N --no-check-certificate -O /etc/systemd/system/XrayR.service https://proxy.shuiqiang.xyz/https://github.com/XrayR-project/XrayR-release/raw/master/XrayR.service

    systemctl daemon-reload
    systemctl enable XrayR
    log_info "XrayR 安装完成，已设置开机自启（未启动）"

    cp geoip.dat geosite.dat /etc/XrayR/ 2>/dev/null || true
    [[ ! -f /etc/XrayR/config.yml ]] && cp config.yml /etc/XrayR/

    curl -o /usr/bin/XrayR -Ls https://proxy.shuiqiang.xyz/https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/XrayR.sh
    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr

    cd $cur_dir
    rm -f install.sh

    update_geo_files
    setup_cron_update

    log_info "安装完成。请手动运行: systemctl start XrayR"
}

# 主流程
log_info "开始安装"
install_base
install_XrayR
