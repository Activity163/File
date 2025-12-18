#!/bin/bash

# FRP 一键安装/卸载脚本 (Debian 12, amd64 架构)
# 版本: frp 0.65.0
# 作者: Grok (基于用户需求手搓)
# 使用前请确保系统为 Debian 12 或兼容系统，且有 root 权限

set -e  # 遇到错误立即退出

VERSION="0.65.0"
ARCH="amd64"
PACKAGE="frp_${VERSION}_linux_${ARCH}.tar.gz"
URL="https://github.com/fatedier/frp/releases/download/v${VERSION}/${PACKAGE}"
INSTALL_DIR="/etc/frp"
TMP_DIR="/tmp/frp_install"

# 清理函数
cleanup() {
  cd /
  rm -rf "$TMP_DIR"
}

# 卸载函数
uninstall() {
  clear
  echo "========================================"
  echo "    FRP 一键卸载"
  echo "========================================"

  if [ "$EUID" -ne 0 ]; then
    echo "错误: 请以 root 权限运行卸载 (sudo bash $0 --uninstall)"
    exit 1
  fi

  echo "正在停止并禁用可能的 FRP 服务..."
  for service in frps frpc; do
    if systemctl is-active --quiet ${service}.service; then
      systemctl stop ${service}.service
      echo "已停止 ${service}.service"
    fi
    if systemctl is-enabled --quiet ${service}.service; then
      systemctl disable ${service}.service
      echo "已禁用 ${service}.service"
    fi
    if [ -f "/etc/systemd/system/${service}.service" ]; then
      rm -f "/etc/systemd/system/${service}.service"
      echo "已删除 /etc/systemd/system/${service}.service"
    fi
  done

  systemctl daemon-reload

  if [ -d "$INSTALL_DIR" ]; then
    echo "正在删除安装目录 $INSTALL_DIR ..."
    rm -rf "$INSTALL_DIR"
    echo "已删除 $INSTALL_DIR"
  else
    echo "$INSTALL_DIR 不存在，无需删除。"
  fi

  echo ""
  echo "========================================"
  echo "FRP 卸载完成！"
  echo "所有服务、配置文件和二进制文件已移除。"
  echo "========================================"
  exit 0
}

# 检查是否为卸载模式
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
  uninstall
fi

# 主安装函数
main() {
  clear
  echo "========================================"
  echo "    FRP 一键安装脚本 (v${VERSION})"
  echo "    适用于 Debian 12 (amd64)"
  echo "========================================"

  # 检查是否为 root
  if [ "$EUID" -ne 0 ]; then
    echo "错误: 请以 root 权限运行此脚本 (sudo bash $0)"
    exit 1
  fi

  # 清理可能存在的临时目录
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"

  echo "[1/5] 正在下载 frp ${VERSION} ..."
  wget "$URL" -O "$PACKAGE"

  echo "[2/5] 正在解压缩 ..."
  tar -xzf "$PACKAGE"

  # 解压后目录名为 frp_${VERSION}_linux_${ARCH}
  EXTRACT_DIR=$(tar -tzf "$PACKAGE" | head -1 | cut -f1 -d"/")
  cd "$EXTRACT_DIR"

  # 选择安装类型（带循环）
  while true; do
    echo ""
    echo "[3/5] 请选择安装类型:"
    echo "    1) 服务端 (frps)"
    echo "    2) 客户端 (frpc)"
    echo "    0) 退出脚本"
    read -p "请输入选择 (0/1/2): " choice

    if [ "$choice" = "1" ]; then
      MODE="server"
      BIN="frps"
      CONFIG="frps.toml"
      SERVICE="frps"
      break
    elif [ "$choice" = "2" ]; then
      MODE="client"
      BIN="frpc"
      CONFIG="frpc.toml"
      SERVICE="frpc"
      break
    elif [ "$choice" = "0" ]; then
      echo "用户取消安装，脚本退出。"
      cleanup
      exit 0
    else
      echo "无效选择，请重新输入！"
      sleep 1
    fi
  done

  echo "[4/5] 正在安装 $MODE 到 $INSTALL_DIR ..."

  mkdir -p "$INSTALL_DIR"
  cp "$BIN" "$CONFIG" "$INSTALL_DIR/"

  # 设置执行权限
  chmod +x "$INSTALL_DIR/$BIN"

  # 生成 systemd 服务文件
  echo "[4/5] 正在创建 systemd 服务 (${SERVICE}.service) ..."

  cat > "/etc/systemd/system/${SERVICE}.service" << EOF
[Unit]
Description=FRP $MODE Service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BIN} -c ${INSTALL_DIR}/${CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # 重新加载 systemd
  systemctl daemon-reload

  # 开机自启
  systemctl enable "${SERVICE}.service"

  echo "[5/5] 安装完成！"

  echo ""
  echo "========================================"
  echo "安装路径: $INSTALL_DIR"
  echo "二进制文件: $INSTALL_DIR/$BIN"
  echo "配置文件: $INSTALL_DIR/$CONFIG (请自行编辑配置)"
  echo ""
  echo "启动命令（编辑好配置文件后再执行）:"
  echo "    sudo systemctl start ${SERVICE}"
  echo ""
  echo "其他常用命令:"
  echo "    sudo systemctl stop ${SERVICE}     # 停止"
  echo "    sudo systemctl restart ${SERVICE}  # 重启"
  echo "    sudo systemctl status ${SERVICE}   # 查看状态"
  echo "    sudo journalctl -u ${SERVICE} -f   # 查看日志"
  echo ""
  echo "卸载命令:"
  echo "    sudo bash $0 --uninstall   # 或 sudo bash $0 -u"
  echo ""
  if [ "$MODE" = "server" ]; then
    echo "提示: 服务端默认 frps.toml 配置较简单，请至少设置 bindPort、token 等参数。"
  else
    echo "提示: 客户端默认 frpc.toml 配置较简单，请至少设置 serverAddr、serverPort、token 和 proxies。"
  fi
  echo "========================================"

  cleanup
  echo "临时文件已清理，脚本执行完毕。"
}

# 执行主安装函数
main
