#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif grep -Eqi "debian" /etc/issue /proc/version; then
    release="debian"
elif grep -Eqi "ubuntu" /etc/issue /proc/version; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat" /etc/issue /proc/version; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(arch)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi
echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)"
    exit 2
fi

os_version=""
[[ -f /etc/os-release ]] && os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
[[ -z "$os_version" && -f /etc/lsb-release ]] && os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)

if [[ x"${release}" == x"centos" && ${os_version} -le 6 ]]; then
    echo -e "${red}请使用 CentOS 7 或更高版本！${plain}" && exit 1
elif [[ x"${release}" == x"ubuntu" && ${os_version} -lt 16 ]]; then
    echo -e "${red}请使用 Ubuntu 16 或更高版本！${plain}" && exit 1
elif [[ x"${release}" == x"debian" && ${os_version} -lt 8 ]]; then
    echo -e "${red}请使用 Debian 8 或更高版本！${plain}" && exit 1
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

update_geo_files() {
    echo -e "${yellow}正在更新 Geo 文件...${plain}"
    wget -O /etc/XrayR/geoip.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
    wget -O /etc/XrayR/geosite.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    echo -e "${green}Geo 文件更新完成${plain}"
}

setup_cron_update() {
    echo -e "${yellow}设置定时任务：每天凌晨六点更新 Geo 文件${plain}"
    cat > /etc/cron.d/xrayr-geo-update <<EOF
0 6 * * * root wget -O /etc/XrayR/geoip.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && wget -O /etc/XrayR/geosite.dat https://proxy.shuiqiang.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
EOF
    systemctl restart cron
    echo -e "${green}定时任务已添加并生效${plain}"
}

install_XrayR() {
    rm -rf /usr/local/XrayR/
    mkdir -p /usr/local/XrayR/
    cd /usr/local/XrayR/

    last_version=$(curl -Ls "https://proxy.shuiqiang.xyz/https://api.github.com/repos/XrayR-project/XrayR/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$last_version" ]] && echo -e "${red}检测 XrayR 版本失败${plain}" && exit 1

    echo -e "检测到最新版本：${last_version}，开始安装"
    wget -q -N --no-check-certificate -O XrayR-linux.zip https://proxy.shuiqiang.xyz/https://github.com/XrayR-project/XrayR/releases/download/${last_version}/XrayR-linux-${arch}.zip || { echo -e "${red}下载失败${plain}"; exit 1; }

    unzip XrayR-linux.zip
    rm -f XrayR-linux.zip
    chmod +x XrayR
    mkdir -p /etc/XrayR/
    wget -q -N --no-check-certificate -O /etc/systemd/system/XrayR.service https://proxy.shuiqiang.xyz/https://github.com/XrayR-project/XrayR-release/raw/master/XrayR.service

    systemctl daemon-reload
    systemctl enable XrayR
    echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启（未启动）"

    # 修复缺失的配置文件
    cp -n geoip.dat /etc/XrayR/
    cp -n geosite.dat /etc/XrayR/
    cp -n config.yml /etc/XrayR/
    cp -n dns.json /etc/XrayR/
    cp -n route.json /etc/XrayR/
    cp -n custom_outbound.json /etc/XrayR/
    cp -n custom_inbound.json /etc/XrayR/
    cp -n rulelist /etc/XrayR/

    curl -o /usr/bin/XrayR -Ls https://proxy.shuiqiang.xyz/https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/XrayR.sh
    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr

    cd $cur_dir
    rm -f install.sh

    update_geo_files
    setup_cron_update

    echo -e "${yellow}安装完成。请手动运行: systemctl start XrayR${plain}"
}

echo -e "${green}开始安装${plain}"
install_base
install_XrayR
