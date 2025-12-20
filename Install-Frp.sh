#!/bin/bash

# FRP 一键安装/卸载脚本 (Debian 12, amd64 架构)
# 版本: frp 0.65.0
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

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 清理函数
cleanup() {
  cd /
  rm -rf "$TMP_DIR"
}

# 错误处理函数
error_exit() {
  echo -e "${RED}错误: $1${NC}"
  cleanup
  exit 1
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

# 检查并安装依赖环境
check_and_install_deps() {
  echo -e "${BLUE}[环境检查] 检查系统依赖...${NC}"
  
  # 检查是否为 Debian 12
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "debian" ] || [ "$VERSION_ID" != "12" ]; then
      echo -e "${YELLOW}警告: 本脚本主要针对 Debian 12 测试，当前系统为 $PRETTY_NAME${NC}"
      read -p "是否继续? (y/N): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
      fi
    fi
  else
    echo -e "${YELLOW}警告: 无法检测操作系统版本，继续执行...${NC}"
  fi
  
  # 检查并安装 wget
  if ! command -v wget &> /dev/null; then
    echo "wget 未安装，正在安装..."
    apt-get update && apt-get install -y wget || error_exit "安装 wget 失败"
  fi
  
  # 检查并安装 tar
  if ! command -v tar &> /dev/null; then
    echo "tar 未安装，正在安装..."
    apt-get install -y tar || error_exit "安装 tar 失败"
  fi
  
  # 检查 systemd
  if ! command -v systemctl &> /dev/null; then
    error_exit "systemd 未安装，请使用 systemd 的系统"
  fi
  
  echo -e "${GREEN}[环境检查] 所有依赖已满足${NC}"
}

# 生成服务端配置
generate_server_config() {
  local config_file="$1"
  local token="$2"
  local web_password="$3"
  
  cat > "$config_file" << EOF
# 服务端基础配置
bindAddr = "0.0.0.0"
bindPort = 7000

# 认证（必须）
[auth]
method = "token"
token = "$token"

[webServer]
addr = "0.0.0.0"
port = 7500
user = "admin"
password = "$web_password"
EOF
  
  echo -e "${GREEN}服务端配置文件已生成: $config_file${NC}"
}

# 生成客户端配置
generate_client_config() {
  local config_file="$1"
  local server_addr="$2"
  local token="$3"
  local proxy_name="$4"
  local proxy_type="$5"
  local local_ip="$6"
  local local_port="$7"
  local remote_port="$8"
  
  cat > "$config_file" << EOF
# 客户端基础配置
serverAddr = "$server_addr"
serverPort = 7000

# 认证配置
[auth]
token = "$token"

# 代理配置
[[proxies]]
name = "$proxy_name"
type = "$proxy_type"
localIP = "$local_ip"
localPort = $local_port
remotePort = $remote_port
EOF
  
  echo -e "${GREEN}客户端配置文件已生成: $config_file${NC}"
}

# 获取用户输入参数
get_server_input() {
  echo ""
  echo -e "${BLUE}=== 服务端配置参数 ===${NC}"
  
  # 生成随机 token 和密码
  local random_token=$(openssl rand -hex 16 2>/dev/null || date +%s | sha256sum | base64 | head -c 16)
  local random_pwd=$(openssl rand -hex 16 2>/dev/null || date +%s | sha256sum | base64 | head -c 16)
  
  echo "系统已生成随机 token 和密码，建议使用随机值增强安全性。"
  echo "随机 token: $random_token"
  echo "随机密码: $random_pwd"
  echo ""
  
  read -p "请输入认证 token [$random_token]: " token_input
  TOKEN=${token_input:-$random_token}
  
  read -p "请输入 Web 控制台密码 [$random_pwd]: " pwd_input
  WEB_PASSWORD=${pwd_input:-$random_pwd}
}

get_client_input() {
  echo ""
  echo -e "${BLUE}=== 客户端配置参数 ===${NC}"
  
  # 生成随机 token
  local random_token=$(openssl rand -hex 16 2>/dev/null || date +%s | sha256sum | base64 | head -c 16)
  
  echo "系统已生成随机 token，建议使用随机值增强安全性。"
  echo "随机 token: $random_token"
  echo ""
  
  while true; do
    read -p "请输入服务端地址 (IP 或域名): " server_addr
    if [[ -n "$server_addr" ]]; then
      break
    fi
    echo "服务端地址不能为空！"
  done
  
  read -p "请输入认证 token [$random_token]: " token_input
  TOKEN=${token_input:-$random_token}
  
  echo ""
  echo -e "${BLUE}=== 代理配置参数 ===${NC}"
  
  while true; do
    read -p "请输入代理名称 (英文/数字/短横线): " proxy_name
    if [[ -n "$proxy_name" ]] && [[ "$proxy_name" =~ ^[a-zA-Z0-9-]+$ ]]; then
      break
    fi
    echo "代理名称不能为空，且只能包含英文、数字和短横线！"
  done
  
  while true; do
    echo "请选择代理类型:"
    echo "  1) tcp (TCP隧道)"
    echo "  2) udp (UDP隧道)"
    echo "  3) http (HTTP代理)"
    echo "  4) https (HTTPS代理)"
    read -p "请选择 (1-4): " type_choice
    
    case $type_choice in
      1) PROXY_TYPE="tcp"; break ;;
      2) PROXY_TYPE="udp"; break ;;
      3) PROXY_TYPE="http"; break ;;
      4) PROXY_TYPE="https"; break ;;
      *) echo "无效选择！" ;;
    esac
  done
  
  while true; do
    read -p "请输入本地服务IP [127.0.0.1]: " local_ip
    local_ip=${local_ip:-"127.0.0.1"}
    if [[ "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$local_ip" == "localhost" ]; then
      break
    fi
    echo "请输入有效的IP地址或 'localhost'"
  done
  
  while true; do
    read -p "请输入本地服务端口: " local_port
    if [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ]; then
      break
    fi
    echo "请输入有效的端口号 (1-65535)"
  done
  
  # 远程端口默认与本地端口相同
  read -p "请输入远程端口 [$local_port]: " remote_port_input
  REMOTE_PORT=${remote_port_input:-$local_port}
  
  SERVER_ADDR="$server_addr"
  PROXY_NAME="$proxy_name"
  LOCAL_IP="$local_ip"
  LOCAL_PORT="$local_port"
}

# 卸载函数
uninstall() {
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${GREEN}    FRP 一键卸载${NC}"
  echo -e "${BLUE}========================================${NC}"

  if [ "$EUID" -ne 0 ]; then
    error_exit "请以 root 权限运行卸载"
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
      error_exit "实例 $name 不存在！"
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
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}卸载完成！${NC}"
  echo -e "${GREEN}========================================${NC}"
  exit 0
}

# 卸载模式
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
  uninstall
fi

# 显示使用说明
show_usage() {
  echo "用法: $0 [选项]"
  echo "选项:"
  echo "  -u, --uninstall  卸载 FRP"
  echo "  -h, --help       显示帮助信息"
  echo ""
  echo "如果没有选项，则进入安装向导。"
  exit 0
}

# 帮助模式
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  show_usage
fi

# 主安装函数
main() {
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${GREEN}    FRP 一键安装脚本 (v${VERSION})${NC}"
  echo -e "${GREEN}    适用于 Debian 12 (amd64)${NC}"
  echo -e "${BLUE}========================================${NC}"

  if [ "$EUID" -ne 0 ]; then
    error_exit "请以 root 权限运行"
  fi

  # 检查并安装依赖
  check_and_install_deps

  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"

  echo -e "${BLUE}[1/7] 下载 frp ${VERSION} ...${NC}"
  wget --timeout=30 --tries=3 "$URL" -O "$PACKAGE" || error_exit "下载失败，请检查网络连接"

  echo -e "${BLUE}[2/7] 解压缩 ...${NC}"
  tar -xzf "$PACKAGE" || error_exit "解压缩失败"

  EXTRACT_DIR=$(tar -tzf "$PACKAGE" | head -1 | cut -f1 -d"/")
  cd "$EXTRACT_DIR"

  while true; do
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}    FRP 一键安装脚本 (v${VERSION})${NC}"
    echo -e "${BLUE}========================================${NC}"

    echo ""
    echo -e "${BLUE}[3/7] 请选择安装类型:${NC}"
    echo "    1) 服务端 (frps, 单实例)"
    echo "    2) 客户端 (默认 frpc)"
    echo "    3) 客户端 (自定义名称，支持多实例)"
    echo "    0) 退出脚本"
    read -p "请输入选择 (0/1/2/3): " choice

    if [ "$choice" = "1" ]; then
      if has_server_installed; then
        echo ""
        echo -e "${YELLOW}服务端 (frps) 已安装！${NC}"
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
      
      # 获取服务端配置参数
      get_server_input
      break

    elif [ "$choice" = "2" ]; then
      if has_default_client_installed; then
        echo ""
        echo -e "${YELLOW}默认客户端 (frpc) 已安装！${NC}"
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
      
      # 获取客户端配置参数
      get_client_input
      break

    elif [ "$choice" = "3" ]; then
      MODE="client"
      BIN="frpc"
      CONFIG="frpc.toml"

      echo ""
      echo -e "${BLUE}当前已安装的自定义客户端实例:${NC}"
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
          echo -e "${YELLOW}错误: 实例 $custom_name 已存在！${NC}"
          continue
        fi
        INSTANCE="$custom_name"
        SERVICE="frp-${custom_name}"
        INSTALL_DIR="${INSTALL_BASE_DIR}/${custom_name}"
        break
      done
      
      # 获取客户端配置参数
      get_client_input
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

  echo -e "${BLUE}[4/7] 安装 $MODE ($INSTANCE) 到 $INSTALL_DIR ...${NC}"

  mkdir -p "$INSTALL_DIR"
  cp "$BIN" "$CONFIG" "$INSTALL_DIR/" 2>/dev/null || error_exit "复制文件失败"
  chmod +x "$INSTALL_DIR/$BIN"

  echo -e "${BLUE}[5/7] 生成配置文件 ...${NC}"
  
  if [ "$MODE" = "server" ]; then
    generate_server_config "$INSTALL_DIR/$CONFIG" "$TOKEN" "$WEB_PASSWORD"
  else
    generate_client_config "$INSTALL_DIR/$CONFIG" "$SERVER_ADDR" "$TOKEN" \
      "$PROXY_NAME" "$PROXY_TYPE" "$LOCAL_IP" "$LOCAL_PORT" "$REMOTE_PORT"
  fi

  echo -e "${BLUE}[6/7] 创建 systemd 服务 (${SERVICE}.service) ...${NC}"

  cat > "/etc/systemd/system/${SERVICE}.service" << EOF
[Unit]
Description=FRP $MODE Service ($INSTANCE)
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BIN} -c ${INSTALL_DIR}/${CONFIG}
Restart=on-failure
RestartSec=5
User=nobody
Group=nogroup
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE}.service"

  echo -e "${BLUE}[7/7] 启动服务 ...${NC}"
  systemctl start "${SERVICE}.service" || echo -e "${YELLOW}警告: 服务启动失败，请检查配置${NC}"

  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}安装完成！${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  echo -e "${BLUE}实例信息:${NC}"
  echo "  实例名称: $INSTANCE"
  echo "  安装路径: $INSTALL_DIR"
  echo "  配置文件: $INSTALL_DIR/$CONFIG"
  echo "  服务名称: ${SERVICE}.service"
  
  echo ""
  echo -e "${BLUE}关键配置参数:${NC}"
  if [ "$MODE" = "server" ]; then
    echo "  监听端口: 7000"
    echo "  Web控制台: http://<服务器IP>:7500"
    echo "  Web用户名: admin"
    echo "  Web密码: $WEB_PASSWORD"
    echo "  认证Token: $TOKEN"
  else
    echo "  服务端地址: $SERVER_ADDR:7000"
    echo "  认证Token: $TOKEN"
    echo "  代理配置:"
    echo "    - 名称: $PROXY_NAME"
    echo "    - 类型: $PROXY_TYPE"
    echo "    - 本地地址: $LOCAL_IP:$LOCAL_PORT"
    echo "    - 远程端口: $REMOTE_PORT"
  fi
  
  echo ""
  echo -e "${BLUE}管理命令:${NC}"
  echo "  启动: sudo systemctl start ${SERVICE}"
  echo "  停止: sudo systemctl stop ${SERVICE}"
  echo "  重启: sudo systemctl restart ${SERVICE}"
  echo "  状态: sudo systemctl status ${SERVICE}"
  
  echo ""
  echo -e "${BLUE}防火墙提示:${NC}"
  if [ "$MODE" = "server" ]; then
    echo "  请确保防火墙开放以下端口:"
    echo "    - TCP 7000 (FRP主端口)"
    echo "    - TCP 7500 (Web控制台)"
  else
    echo "  请确保服务端防火墙开放端口: 7000"
  fi
  
  echo ""
  echo -e "${BLUE}卸载命令:${NC}"
  echo "  sudo bash $0 --uninstall"
  
  echo ""
  echo -e "${YELLOW}重要提示:${NC}"
  echo "  1. 请妥善保管 token 和密码"
  echo "  2. 建议修改默认端口增强安全性"
  echo "  3. 可编辑配置文件添加更多代理规则"
  echo -e "${GREEN}========================================${NC}"

  cleanup
  echo "临时文件已清理。"
}

# 显示欢迎信息并启动
echo -e "${GREEN}FRP 一键安装脚本 v${VERSION}${NC}"
echo -e "${BLUE}按 Ctrl+C 可随时退出安装${NC}"
echo ""
main
