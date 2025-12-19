#!/bin/bash

# FRP 一键安装/卸载脚本 (Debian 12, amd64 架构)
# 版本: frp 0.65.0
# 作者: Grok (根据用户最新需求优化)
# 最新调整:
# - 服务端: 只支持默认单实例 (frps)
# - 客户端: 支持默认单实例 (frpc) + 多个自定义名称实例 (frp-<自定义名称>)
# - 支持一台服务器运行一个服务端 + 多个不同配置的客户端

set -e

VERSION="0.65.0"
ARCH="amd64"
PACKAGE="frp_${VERSION}_linux_${ARCH}.tar.gz"
URL="https://github.com/fatedier/frp/releases/download/v${VERSION}/${PACKAGE}"
INSTALL_BASE_DIR="/etc/frp"
TMP_DIR="/tmp/frp_install"

# 清理函数
cleanup() {
  cd /
  rm -rf "$TMP_DIR"
}

# 检查是否已安装服务端
has_server_installed() {
  [ -d "$INSTALL_BASE_DIR/frps" ]
}

# 检查是否已安装默认客户端
has_default_client_installed() {
  [ -d "$INSTALL_BASE_DIR/client" ]
}

# 获取已安装的自定义客户端实例列表
get_custom_client_instances() {
  instances=()
  if [ -d "$INSTALL_BASE_DIR" ]; then
    for dir in "$INSTALL_BASE_DIR"/frp-*; do
      [ -d "$dir" ] && instances+=("$(basename "$dir")")
    done
  fi
  echo "${instances[@]}"
}

# 卸载函数
uninstall() {
  clear
  echo "========================================"
  echo "    FRP 一键卸载"
  echo "========================================"

  if [ "$EUID" -ne 0 ]; then
    echo "错误: 请以 root 权限运行卸载"
    exit 1
  fi

  echo "检测到以下 FRP 实例:"
  instances=()
  if [ -d "$INSTALL_BASE_DIR" ]; then
    [ -d "$INSTALL_BASE_DIR/frps" ] && echo "  - frps (服务端)" && instances+=("frps")
    [ -d "$INSTALL_BASE_DIR/client" ] && echo "  - client (默认客户端)" && instances+=("client")
    for dir in "$INSTALL_BASE_DIR"/frp-*; do
      [ -d "$dir" ] && echo "  - $(basename "$dir") (自定义客户端)" && instances+=("$(basename "$dir")")
    done
  fi

  if [ ${#instances[@]} -eq 0 ]; then
    echo "未检测到任何实例。"
    exit 0
  fi

  echo ""
  read -p "请输入要卸载的实例名称 (frps/client/customname)，或 all 卸载全部: " name

  if [ "$name" = "all" ]; then
    targets=("${instances[@]}")
  else
    if [[ ! " ${instances[@]} " =~ " $name " ]]; then
      echo "错误: 实例 $name 不存在！"
      exit 1
    fi
    targets=("$name")
  fi

  for target in "${targets[@]}"; do
    if [ "$target" = "frps" ]; then
      SERVICE="frps"
    elif [ "$target" = "client" ]; then
      SERVICE="frpc"
    else
      SERVICE="frp-${target#frp-}"
    fi

    INSTALL_DIR="${INSTALL_BASE_DIR}/${target}"

    echo "正在卸载 $target ($SERVICE) ..."
    systemctl stop ${SERVICE}.service 2>/dev/null || true
    systemctl disable ${SERVICE}.service 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service"
    rm -rf "$INSTALL_DIR"
    echo "已删除 $target"
  done

  systemctl daemon-reload
  echo ""
  echo "========================================"
  echo "卸载完成！"
  echo "========================================"
  exit 0
}

# 卸载模式
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
  uninstall
fi

# 主安装函数
main() {
  clear
  echo "========================================"
  echo "    FRP 一键安装脚本 (v${VERSION})"
  echo "    适用于 Debian 12 (amd64)"
  echo "    服务端: 单实例 (frps)"
  echo "    客户端: 默认 + 多自定义实例"
  echo "========================================"

  if [ "$EUID" -ne 0 ]; then
    echo "错误: 请以 root 权限运行"
    exit 1
  fi

  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"

  echo "[1/6] 下载 frp ${VERSION} ..."
  wget "$URL" -O "$PACKAGE"

  echo "[2/6] 解压缩 ..."
  tar -xzf "$PACKAGE"

  EXTRACT_DIR=$(tar -tzf "$PACKAGE" | head -1 | cut -f1 -d"/")
  cd "$EXTRACT_DIR"

  while true; do
    clear
    echo "========================================"
    echo "    FRP 一键安装脚本 (v${VERSION})"
    echo "========================================"

    echo ""
    echo "[3/6] 请选择安装类型:"
    echo "    1) 服务端 (frps, 单实例)"
    echo "    2) 客户端 (默认 frpc)"
    echo "    3) 客户端 (自定义名称，支持多实例)"
    echo "    0) 退出脚本"
    read -p "请输入选择 (0/1/2/3): " choice

    if [ "$choice" = "1" ]; then
      if has_server_installed; then
        echo ""
        echo "服务端 (frps) 已安装！"
        echo "本脚本只支持单个服务端实例。"
        echo "路径: $INSTALL_BASE_DIR/frps"
        read -p "按回车返回主页..."
        continue
      fi

      MODE="server"
      INSTANCE="frps"
      BIN="frps"
      CONFIG="frps.toml"
      SERVICE="frps"
      INSTALL_DIR="${INSTALL_BASE_DIR}/frps"
      break

    elif [ "$choice" = "2" ]; then
      if has_default_client_installed; then
        echo ""
        echo "默认客户端 (frpc) 已安装！"
        echo "路径: $INSTALL_BASE_DIR/client"
        echo "如需重新安装，请先卸载。"
        read -p "按回车返回主页..."
        continue
      fi

      MODE="client"
      INSTANCE="client"
      BIN="frpc"
      CONFIG="frpc.toml"
      SERVICE="frpc"
      INSTALL_DIR="${INSTALL_BASE_DIR}/client"
      break

    elif [ "$choice" = "3" ]; then
      MODE="client"
      BIN="frpc"
      CONFIG="frpc.toml"

      echo ""
      echo "当前已安装的自定义客户端实例:"
      existing=($(get_custom_client_instances))
      if [ ${#existing[@]} -eq 0 ]; then
        echo "  无"
      else
        for inst in "${existing[@]}"; do
          echo "  - $inst"
        done
      fi

      while true; do
        echo ""
        read -p "请输入自定义客户端名称 (英文/数字/短横线): " custom_name
        if [[ -z "$custom_name" ]]; then
          echo "名称不能为空！"
          continue
        fi
        if [[ ! "$custom_name" =~ ^[a-zA-Z0-9-]+$ ]]; then
          echo "只能包含英文、数字和短横线！"
          continue
        fi
        if [[ " ${existing[@]} " =~ " $custom_name " ]]; then
          echo "错误: 实例 $custom_name 已存在！"
          continue
        fi
        INSTANCE="$custom_name"
        SERVICE="frp-${custom_name}"
        INSTALL_DIR="${INSTALL_BASE_DIR}/${custom_name}"
        break
      done
      break

    elif [ "$choice" = "0" ]; then
      echo "已退出。"
      cleanup
      exit 0

    else
      echo "无效选择！"
      sleep 1
    fi
  done

  echo "[4/6] 安装 $MODE ($INSTANCE) 到 $INSTALL_DIR ..."

  mkdir -p "$INSTALL_DIR"
  cp "$BIN" "$CONFIG" "$INSTALL_DIR/"
  chmod +x "$INSTALL_DIR/$BIN"

  echo "[5/6] 创建 systemd 服务 (${SERVICE}.service) ..."

  cat > "/etc/systemd/system/${SERVICE}.service" << EOF
[Unit]
Description=FRP $MODE Service ($INSTANCE)
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BIN} -c ${INSTALL_DIR}/${CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE}.service"

  echo "[6/6] 安装完成！"

  echo ""
  echo "========================================"
  echo "实例: $INSTANCE"
  echo "路径: $INSTALL_DIR"
  echo "配置: $INSTALL_DIR/$CONFIG (请编辑)"
  echo ""
  echo "启动: sudo systemctl start ${SERVICE}"
  echo "停止/重启/状态: sudo systemctl stop/restart/status ${SERVICE}"
  echo "日志: sudo journalctl -u ${SERVICE} -f"
  echo ""
  echo "卸载: sudo bash $0 --uninstall"
  echo ""
  if [ "$MODE" = "server" ]; then
    echo "提示: 请配置 bindPort、token 等参数。"
  else
    echo "提示: 请配置 serverAddr、serverPort、token 和 proxies。"
    echo "      多客户端实例可连接不同服务端或使用不同配置。"
  fi
  echo "========================================"

  cleanup
  echo "临时文件已清理。"
}

main
