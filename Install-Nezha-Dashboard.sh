#!/bin/bash
set -e

# ============================================================
#  哪吒 Dashboard 一键管理脚本 v2.0
#  支持 Caddy / Nginx | 安装 / 卸载 / 更新 / 重启 / 日志
# ============================================================

SCRIPT_VERSION="2.0.0"
DEFAULT_PROJECT_DIR="/etc/Nezha-Dashboard"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✘]${NC} $*"; }

# ============================================================
#  工具函数
# ============================================================

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 用户运行此脚本"
    exit 1
  fi
}

detect_os() {
  if [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
  elif [ -f /etc/redhat-release ]; then
    OS_TYPE="redhat"
  else
    OS_TYPE="unknown"
  fi
}

ask_project_dir() {
  read -p "请输入项目目录 (默认: ${DEFAULT_PROJECT_DIR}): " PROJECT_DIR
  PROJECT_DIR=${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}
  PROJECT_DIR=$(realpath -m "$PROJECT_DIR")
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Docker 未安装，请先执行「全新安装」"
    exit 1
  fi
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    error "Docker Compose 未安装，请先执行「全新安装」"
    exit 1
  fi
}

ensure_project() {
  if [ ! -d "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
    error "未找到有效的项目目录或 docker-compose.yml: $PROJECT_DIR"
    exit 1
  fi
}

# 判断目录是否适合删除：拒绝根目录、系统关键目录与层级过浅的路径
is_safe_dir() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in
    "/"|"//"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/var") return 1 ;;
  esac
  # 至少两级路径，如 /etc/Nezha-Dashboard
  case "${p#/}" in
    */*) return 0 ;;
    *)   return 1 ;;
  esac
}

# 启动并开机自启服务（兼容无 systemd 环境）
svc_enable_start() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl start  "$svc" >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service "$svc" start >/dev/null 2>&1 || true
  else
    warn "未检测到 systemctl/service，请手动确保 $svc 已启动"
  fi
}

# 检查 80 / 443 是否被占用
check_ports() {
  local p busy=0
  for p in 80 443; do
    if command -v ss >/dev/null 2>&1; then
      ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && { error "端口 $p 已被占用"; busy=1; }
    elif command -v lsof >/dev/null 2>&1; then
      lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && { error "端口 $p 已被占用"; busy=1; }
    elif command -v netstat >/dev/null 2>&1; then
      netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && { error "端口 $p 已被占用"; busy=1; }
    else
      warn "无 ss/lsof/netstat，跳过端口检查"
      return 0
    fi
  done
  if [ "$busy" -eq 1 ]; then
    warn "请先释放以上端口（停止占用服务或旧容器）后重试"
    exit 1
  fi
  info "80 / 443 端口可用"
}

# 获取 Cloudflare IP 段（在线获取，失败回退内置），输出换行分隔
get_cf_ranges() {
  local list
  list="$(curl -fsSL https://www.cloudflare.com/ips-v4 2>/dev/null || true)
$(curl -fsSL https://www.cloudflare.com/ips-v6 2>/dev/null || true)"
  if ! printf '%s' "$list" | grep -qE '^[0-9a-fA-F:.]+/[0-9]{1,3}$'; then
    warn "无法在线获取 Cloudflare IP 段，使用内置列表" >&2
    list="$(cat <<'BUILTIN'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
BUILTIN
)"
  fi
  printf '%s\n' "$list" | grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' || true
}

# 让面板读取 nz-realip 头（不设置则在线用户/审计只显示代理 IP）
# 注意：面板在 nz-realip 为空或非法时会让每个请求直接报错，因此反代必须恒传合法 IP
setup_real_ip_header() {
  local cfg="$PROJECT_DIR/data/config.yaml" i=0
  while [ ! -f "$cfg" ] && [ "$i" -lt 20 ]; do
    sleep 1; i=$((i + 1))
  done
  if [ ! -f "$cfg" ]; then
    warn "未找到 $cfg"
    echo "  请稍后在面板「系统设置 → 系统配置 → 前端真实 IP 请求头」中填: nz-realip"
    return 0
  fi

  local changed=0
  grep -q '^web_real_ip_header:' "$cfg" || { printf 'web_real_ip_header: nz-realip\n' >> "$cfg"; changed=1; }
  grep -q '^agent_real_ip_header:' "$cfg" || { printf 'agent_real_ip_header: nz-realip\n' >> "$cfg"; changed=1; }

  if [ "$changed" = 1 ]; then
    info "已写入真实 IP 请求头配置，重启面板使其生效..."
    docker restart nezha-dashboard >/dev/null 2>&1 || true
    sleep 5
  else
    info "真实 IP 请求头配置已存在，跳过"
  fi
}

# ============================================================
#  Docker 安装
# ============================================================

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    svc_enable_start docker
    info "Docker 安装完成"
  else
    info "Docker 已安装: $(docker --version)"
  fi

  if docker compose version >/dev/null 2>&1; then
    info "Docker Compose (插件) 已就绪"
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    info "Docker Compose (独立) 已就绪"
    COMPOSE_CMD="docker-compose"
  else
    info "安装 Docker Compose 插件..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4)
    if [ -n "$COMPOSE_VERSION" ]; then
      curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
      ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    else
      warn "无法获取版本号，尝试通过包管理器安装..."
      if [ "$OS_TYPE" = "debian" ]; then
        apt-get install -y docker-compose-plugin 2>/dev/null || apt-get install -y docker-compose
      elif [ "$OS_TYPE" = "redhat" ]; then
        yum install -y docker-compose-plugin 2>/dev/null || yum install -y docker-compose
      fi
    fi
    COMPOSE_CMD="docker compose"
    info "Docker Compose 安装完成"
  fi
}

# ============================================================
#  acme.sh 依赖（仅 Nginx 模式）
# ============================================================

install_acme_deps() {
  info "安装 acme.sh 依赖..."
  if [ "$OS_TYPE" = "debian" ]; then
    apt-get update -qq
    apt-get install -y -qq curl wget socat cron openssl netcat-openbsd dnsutils lsof
    svc_enable_start cron
  elif [ "$OS_TYPE" = "redhat" ]; then
    yum install -y -q curl wget socat cronie openssl nmap-ncat bind-utils lsof
    svc_enable_start crond
  else
    warn "未知系统，请手动安装: curl wget socat cron openssl netcat dnsutils lsof"
  fi
}

# ============================================================
#  安装 — Caddy 模式
# ============================================================

install_caddy() {
  echo ""
  info "===== Caddy 模式 ====="
  echo ""

  ensure_docker
  ask_project_dir

  read -p "请输入绑定的域名 (必填): " DOMAIN
  if [ -z "$DOMAIN" ]; then
    error "域名不能为空！"; exit 1
  fi

  read -p "请输入邮箱 (可选，用于证书通知，留空跳过): " EMAIL

  echo ""
  echo "反向代理真实 IP 获取方式："
  echo "  1) Cloudflare CDN   (使用 client_ip，自动识别 CF-Connecting-IP)"
  echo "  2) 直连             (Caddy 直接对外，使用 remote_host)"
  echo "  3) 国内外分流       (CF + 第三方 CDN 混合回源，使用 client_ip)"
  read -p "请选择 [1/2/3] (默认 2): " CF_CHOICE
  CF_CHOICE=${CF_CHOICE:-2}

  SERVERS_BLOCK=""
  case "$CF_CHOICE" in
    1)
      NZ_REALIP='{client_ip}'
      info "已启用 Cloudflare CDN 配置"
      CF_RANGES="$(get_cf_ranges | tr '\n' ' ')"
      SERVERS_BLOCK="
	servers {
		trusted_proxies static ${CF_RANGES}
		trusted_proxies_strict
		client_ip_headers CF-Connecting-IP X-Real-IP X-Forwarded-For
	}"
      ;;
    2)
      NZ_REALIP='{remote_host}'
      info "未使用 CDN（直连）"
      ;;
    3)
      NZ_REALIP='{client_ip}'
      info "已启用国内外分流（多 CDN）配置"
      CF_RANGES="$(get_cf_ranges | tr '\n' ' ')"
      echo ""
      echo "请粘贴第三方 CDN 的回源 IP 段（空格分隔，可留空稍后手动补）"
      read -p "第三方 CDN 回源 IP 段: " TP_RANGES
      TRUSTED_RANGES=$(printf '%s %s' "$CF_RANGES" "$TP_RANGES" | tr -s ' ' | sed 's/^ *//; s/ *$//')
      if [ -z "$TP_RANGES" ]; then
        warn "未提供第三方 CDN 回源段：其回源请求将取不到真实 IP（面板访客 IP 会显示为 CDN 节点）"
      fi
      SERVERS_BLOCK="
	servers {
		trusted_proxies static ${TRUSTED_RANGES}
		trusted_proxies_strict
		client_ip_headers CF-Connecting-IP X-Real-IP X-Forwarded-For
	}"
      ;;
    *)
      error "无效选项"; exit 1 ;;
  esac

  # 覆盖检测
  if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    warn "检测到已有 docker-compose.yml"
    read -p "是否覆盖现有配置？[y/N]: " OVERWRITE
    if [ "${OVERWRITE,,}" != "y" ]; then
      info "已取消"; exit 0
    fi
  fi

  mkdir -p "$PROJECT_DIR"/{data,caddy_data,caddy_config}
  cd "$PROJECT_DIR"

  # 覆盖安装：先停旧容器释放 80/443
  if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    info "停止旧容器以释放端口..."
    $COMPOSE_CMD down --remove-orphans 2>/dev/null || true
  fi
  check_ports

  # ---- Caddyfile ----
  EMAIL_BLOCK=""
  if [ -n "$EMAIL" ]; then
    EMAIL_BLOCK="    email ${EMAIL}"
  fi

  cat > Caddyfile <<EOF
{
${EMAIL_BLOCK}${SERVERS_BLOCK}
}

${DOMAIN} {
    @grpcProto {
        path /proto.NezhaService/*
    }

    reverse_proxy @grpcProto {
        header_up Host {host}
        header_up nz-realip ${NZ_REALIP}
        transport http {
            versions h2c
            read_buffer 4096
        }
        to nezha-dashboard:8008
    }

    reverse_proxy {
        header_up Host {host}
        header_up Origin https://{host}
        header_up nz-realip ${NZ_REALIP}
        transport http {
            read_buffer 16384
        }
        to nezha-dashboard:8008
    }
}
EOF
  info "已生成 Caddyfile"

  # ---- docker-compose.yml ----
  cat > docker-compose.yml <<EOF
services:
  nezha-dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: nezha-dashboard
    restart: always
    volumes:
      - ${PROJECT_DIR}/data:/dashboard/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  caddy:
    image: caddy:latest
    container_name: nezha-caddy
    restart: always
    depends_on:
      - nezha-dashboard
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${PROJECT_DIR}/Caddyfile:/etc/caddy/Caddyfile
      - ${PROJECT_DIR}/caddy_data:/data
      - ${PROJECT_DIR}/caddy_config:/config
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
  info "已生成 docker-compose.yml"

  # ---- 启动 ----
  info "正在拉取镜像并启动..."
  $COMPOSE_CMD up -d

  setup_real_ip_header

  echo ""
  echo -e "${BOLD}=========================================${NC}"
  info "部署完成！"
  echo -e "  访问地址  : ${CYAN}https://${DOMAIN}${NC}"
  echo -e "  反向代理  : Caddy (自动证书管理)"
  echo -e "  项目目录  : ${PROJECT_DIR}"
  case "$CF_CHOICE" in
    1) echo -e "  CDN       : Cloudflare 已开启" ;;
    3) echo -e "  CDN       : 国内外分流（CF + 第三方 CDN）" ;;
  esac
  echo -e "${BOLD}=========================================${NC}"
  echo ""
  echo "提示:"
  echo "  1. 确保防火墙/安全组已放行 80 和 443 端口"
  echo "  2. Agent 对接地址: ${DOMAIN}:443 (开启 TLS)"
  echo "  3. Caddy 会自动申请和续期证书，无需手动干预"

  if [ "$CF_CHOICE" = "3" ]; then
    echo ""
    warn "分流模式额外注意："
    echo "  1. 第三方 CDN 多数不支持 gRPC 回源，哪吒 Agent 请改用"
    echo "     不分流的地址（如 agent.${DOMAIN} 直接解析到源站 IP）。"
    echo "  2. 建议证书改用 DNS-01 申请，避免 HTTP-01 被 CDN 拦截。"
    echo "  3. 两个 CDN 均需把回源 Host 设为 ${DOMAIN}、回源 HTTPS:443。"
  fi
}

# ============================================================
#  安装 — Nginx 模式
# ============================================================

install_nginx() {
  echo ""
  info "===== Nginx 模式 ====="
  echo ""

  install_acme_deps
  ensure_docker
  ask_project_dir

  # 覆盖检测（放在证书申请之前，避免白跑一次 acme 申请、浪费 LE 速率配额）
  if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    warn "检测到已有 docker-compose.yml"
    read -p "是否覆盖现有配置？[y/N]: " OVERWRITE
    if [ "${OVERWRITE,,}" != "y" ]; then
      info "已取消"; exit 0
    fi
  fi

  read -p "请输入绑定的域名 (必填): " DOMAIN
  if [ -z "$DOMAIN" ]; then
    error "域名不能为空！"; exit 1
  fi

  # 域名解析检测
  if command -v dig >/dev/null 2>&1; then
    DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
  else
    DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{ print $1 }' | head -n1)
  fi
  LOCAL_IP=$(curl -s4 ipv4.icanhazip.com || curl -s4 ifconfig.me || echo "未知")

  echo "  本机公网 IP : ${LOCAL_IP}"
  echo "  域名解析 IP : ${DOMAIN_IP:-未解析}"

  read -p "请输入邮箱 (用于证书注册，留空随机生成): " EMAIL
  if [ -z "$EMAIL" ]; then
    RAND=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
    EMAIL="${RAND}@gmail.com"
    info "使用随机邮箱: $EMAIL"
  fi

  # 证书方式
  echo ""
  echo "请选择证书获取方式:"
  echo "  1) 自动申请证书 (推荐)"
  echo "  2) 手动指定已有证书目录"
  read -p "请选择 [1/2] (默认 1): " CERT_MODE
  CERT_MODE=${CERT_MODE:-1}

  mkdir -p "$PROJECT_DIR"/{data,cert}

  if [ "$CERT_MODE" = "1" ]; then
    # --- CA 选择 ---
    echo ""
    echo "请选择证书颁发机构:"
    echo "  1) Let's Encrypt (默认)"
    echo "  2) ZeroSSL"
    read -p "请选择 [1/2] (默认 1): " CA_CHOICE
    CA_CHOICE=${CA_CHOICE:-1}
    ACME_SERVER="letsencrypt"
    [ "$CA_CHOICE" = "2" ] && ACME_SERVER="zerossl"
    info "CA: $ACME_SERVER"

    # --- 申请方式 ---
    echo ""
    echo "请选择证书申请方式:"
    echo "  1) 80 端口 standalone 模式 (域名需解析到本机)"
    echo "  2) Cloudflare DNS 模式 (支持 CDN，推荐)"
    read -p "请选择 [1/2]: " MODE

    if [ "$MODE" = "1" ]; then
      if [ -z "$DOMAIN_IP" ] || [ "$DOMAIN_IP" != "$LOCAL_IP" ]; then
        error "域名解析 IP ($DOMAIN_IP) 与本机 IP ($LOCAL_IP) 不匹配"
        exit 1
      fi
      info "域名解析正确: $DOMAIN -> $DOMAIN_IP"
    fi

    # acme.sh
    if [ ! -d "$HOME/.acme.sh" ]; then
      info "安装 acme.sh..."
      curl -s https://get.acme.sh | sh -s email="$EMAIL"
    fi
    "$HOME/.acme.sh/acme.sh" --register-account -m "$EMAIL" --server "$ACME_SERVER" || true

    if [ "$MODE" = "1" ]; then
      if lsof -i:80 >/dev/null 2>&1; then
        error "80 端口已被占用，请先停止占用服务"; exit 1
      fi
      info "standalone 模式申请中..."
      "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --server "$ACME_SERVER"

    elif [ "$MODE" = "2" ]; then
      info "Cloudflare DNS 模式申请中..."
      read -rs -p "Cloudflare API Token : " CF_TOKEN; echo ""
      read -p "Cloudflare 邮箱      : " CF_EMAIL
      export CF_Token="$CF_TOKEN" CF_Email="$CF_EMAIL"
      "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --server "$ACME_SERVER"
      unset CF_Token CF_Email
    else
      error "无效选项"; exit 1
    fi

    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
      --cert-file      "$PROJECT_DIR/cert/cert.crt" \
      --key-file       "$PROJECT_DIR/cert/private.key" \
      --fullchain-file "$PROJECT_DIR/cert/fullchain.crt" \
      --reloadcmd      "docker restart nezha-nginx || true"

    info "证书已安装到 $PROJECT_DIR/cert/"

  elif [ "$CERT_MODE" = "2" ]; then
    read -p "证书目录路径: " MANUAL_CERT_DIR
    if [ ! -d "$MANUAL_CERT_DIR" ]; then
      error "目录不存在: $MANUAL_CERT_DIR"; exit 1
    fi

    CERT_FILE="" KEY_FILE=""
    for f in fullchain.crt fullchain.pem cert.crt cert.pem certificate.crt; do
      [ -f "$MANUAL_CERT_DIR/$f" ] && { CERT_FILE="$MANUAL_CERT_DIR/$f"; break; }
    done
    for f in private.key privkey.pem key.pem private.pem; do
      [ -f "$MANUAL_CERT_DIR/$f" ] && { KEY_FILE="$MANUAL_CERT_DIR/$f"; break; }
    done

    if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
      error "未找到证书或私钥文件"; exit 1
    fi

    cp -f "$CERT_FILE" "$PROJECT_DIR/cert/fullchain.crt"
    cp -f "$CERT_FILE" "$PROJECT_DIR/cert/cert.crt"
    cp -f "$KEY_FILE"  "$PROJECT_DIR/cert/private.key"
    chmod 600 "$PROJECT_DIR/cert/private.key"
    info "证书已复制到 $PROJECT_DIR/cert/"
  else
    error "无效选项"; exit 1
  fi

  # Cloudflare CDN
  echo ""
  echo "是否开启 Cloudflare CDN 配置？"
  echo "  1) 开启 (CF-Connecting-IP)"
  echo "  2) 关闭 (\$remote_addr)"
  read -p "请选择 [1/2] (默认 2): " CF_CDN
  CF_CDN=${CF_CDN:-2}
  ENABLE_CF=false
  [ "$CF_CDN" = "1" ] && ENABLE_CF=true

  cd "$PROJECT_DIR"

  # 覆盖安装：先停旧容器释放 80/443
  if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    info "停止旧容器以释放端口..."
    $COMPOSE_CMD down --remove-orphans 2>/dev/null || true
  fi
  check_ports

  # ---- docker-compose.yml ----
  cat > docker-compose.yml <<EOF
services:
  nezha-dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: nezha-dashboard
    restart: always
    volumes:
      - ${PROJECT_DIR}/data:/dashboard/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  nginx:
    image: nginx:latest
    container_name: nezha-nginx
    restart: always
    depends_on:
      - nezha-dashboard
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${PROJECT_DIR}/nginx.conf:/etc/nginx/conf.d/default.conf
      - ${PROJECT_DIR}/cert/fullchain.crt:/etc/nezha/cert/cert.crt:ro
      - ${PROJECT_DIR}/cert/private.key:/etc/nezha/cert/private.key:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

  # ---- nginx.conf ----
  if [ "$ENABLE_CF" = true ]; then
    CF_IP_LIST="$(get_cf_ranges)"

    REAL_IP_CONF="    # Cloudflare 真实 IP
    real_ip_header CF-Connecting-IP;"
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      printf '%s' "$ip" | grep -qE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' || continue
      REAL_IP_CONF="${REAL_IP_CONF}
    set_real_ip_from ${ip};"
    done <<< "$CF_IP_LIST"
    NZ_REALIP='$nz_realip'
    MAP_BLOCK="map \$http_cf_connecting_ip \$nz_realip {
    \"\"      \$remote_addr;
    default \$http_cf_connecting_ip;
}

"
  else
    REAL_IP_CONF="    # Cloudflare 真实 IP (已关闭)"
    NZ_REALIP='$remote_addr'
    MAP_BLOCK=""
  fi

  cat > nginx.conf <<EOF
${MAP_BLOCK}upstream dashboard {
    server nezha-dashboard:8008;
    keepalive 1024;
    keepalive_requests 10000;
    keepalive_timeout 3600s;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name ${DOMAIN};

    # 跨域头
    add_header Cross-Origin-Resource-Policy cross-origin always;
    add_header Access-Control-Allow-Private-Network true always;
    add_header Cross-Origin-Embedder-Policy credentialless always;

    # SSL
    ssl_certificate     /etc/nezha/cert/cert.crt;
    ssl_certificate_key /etc/nezha/cert/private.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:100m;
    ssl_session_timeout 4h;
    ssl_session_tickets off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    underscores_in_headers on;

${REAL_IP_CONF}

    # 静态资源
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|woff2|ttf|svg|webp|avif|wasm)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable, max-age=31536000";
        access_log off;
        log_not_found off;
        proxy_pass http://dashboard;
    }

    # gRPC（Agent 通信）
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip ${NZ_REALIP};
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 20m;
        grpc_buffer_size 16m;
        proxy_buffering off;
        grpc_pass grpc://dashboard;
    }

    # WebSocket（终端、文件）
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip ${NZ_REALIP};
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_pass http://dashboard;
    }

    # 主入口
    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip ${NZ_REALIP};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 256k;
        proxy_buffers 8 512k;
        proxy_busy_buffers_size 1024k;
        proxy_max_temp_file_size 0;
        proxy_pass http://dashboard;
    }
}

# HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

  info "已生成 nginx.conf"

  # ---- 启动 ----
  info "正在拉取镜像并启动..."
  $COMPOSE_CMD up -d

  setup_real_ip_header

  echo ""
  echo -e "${BOLD}=========================================${NC}"
  info "部署完成！"
  echo -e "  访问地址  : ${CYAN}https://${DOMAIN}${NC}"
  echo -e "  反向代理  : Nginx (acme.sh 证书管理)"
  echo -e "  项目目录  : ${PROJECT_DIR}"
  echo -e "  证书路径  : ${PROJECT_DIR}/cert/"
  $ENABLE_CF && echo -e "  CDN       : Cloudflare 已开启"
  echo -e "${BOLD}=========================================${NC}"
  echo ""
  echo "提示:"
  echo "  1. 确保防火墙/安全组已放行 80 和 443 端口"
  echo "  2. Agent 对接地址: ${DOMAIN}:443 (开启 TLS)"
  echo "  3. 证书自动续期由 acme.sh + cron 管理"
}

# ============================================================
#  主安装入口
# ============================================================

do_install() {
  echo ""
  echo "请选择反向代理:"
  echo -e "  ${CYAN}1)${NC} Caddy   ${DIM}(自动证书管理，配置简洁，内存占用稍高)${NC}"
  echo -e "  ${CYAN}2)${NC} Nginx   ${DIM}(acme.sh 证书管理，高度可定制，内存极低)${NC}"
  read -p "请选择 [1/2] (默认 1): " PROXY_CHOICE
  PROXY_CHOICE=${PROXY_CHOICE:-1}

  case "$PROXY_CHOICE" in
    1) install_caddy ;;
    2) install_nginx ;;
    *) error "无效选项"; exit 1 ;;
  esac
}

# ============================================================
#  卸载
# ============================================================

do_uninstall() {
  ask_project_dir

  if [ ! -d "$PROJECT_DIR" ]; then
    error "项目目录不存在: $PROJECT_DIR"; exit 1
  fi

  echo ""
  warn "即将卸载哪吒 Dashboard"
  echo "  项目目录: $PROJECT_DIR"
  echo ""
  read -p "确认卸载？[y/N]: " CONFIRM
  if [ "${CONFIRM,,}" != "y" ]; then
    info "已取消"; exit 0
  fi

  if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    info "停止并移除容器..."
    cd "$PROJECT_DIR"
    if docker compose version >/dev/null 2>&1; then
      docker compose down --remove-orphans 2>/dev/null || true
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose down --remove-orphans 2>/dev/null || true
    fi
  fi

  echo ""
  read -p "是否删除项目目录 ($PROJECT_DIR) 和所有数据？[y/N]: " DEL_DATA
  if [ "${DEL_DATA,,}" = "y" ]; then
    if ! is_safe_dir "$PROJECT_DIR"; then
      error "路径不安全，拒绝删除: $PROJECT_DIR"
      exit 1
    fi
    rm -rf -- "$PROJECT_DIR"
    info "已删除: $PROJECT_DIR"
  else
    info "已保留项目目录: $PROJECT_DIR"
  fi

  info "卸载完成"
}

# ============================================================
#  更新
# ============================================================

do_update() {
  ask_project_dir
  ensure_docker
  ensure_project

  cd "$PROJECT_DIR"

  info "拉取最新镜像..."
  $COMPOSE_CMD pull

  info "重建容器..."
  $COMPOSE_CMD up -d

  info "清理旧镜像..."
  docker image prune -f

  echo ""
  info "更新完成！当前容器:"
  $COMPOSE_CMD ps
}

# ============================================================
#  重启
# ============================================================

do_restart() {
  ask_project_dir
  ensure_docker
  ensure_project

  cd "$PROJECT_DIR"

  info "正在重启..."
  $COMPOSE_CMD restart

  echo ""
  info "重启完成！当前容器:"
  $COMPOSE_CMD ps
}

# ============================================================
#  查看状态
# ============================================================

do_status() {
  ask_project_dir
  ensure_docker
  ensure_project

  cd "$PROJECT_DIR"

  echo ""
  info "容器状态:"
  $COMPOSE_CMD ps

  echo ""
  info "资源占用:"
  CONTAINER_IDS=$($COMPOSE_CMD ps -q 2>/dev/null)
  if [ -n "$CONTAINER_IDS" ]; then
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" $CONTAINER_IDS
  else
    warn "没有运行中的容器"
  fi
}

# ============================================================
#  查看日志
# ============================================================

do_logs() {
  ask_project_dir
  ensure_docker
  ensure_project

  cd "$PROJECT_DIR"

  echo ""
  echo "查看哪个服务的日志？"
  echo "  1) 全部"
  echo "  2) nezha-dashboard"
  echo "  3) 反向代理 (nginx / caddy)"
  read -p "请选择 [1/2/3] (默认 1): " LOG_CHOICE
  LOG_CHOICE=${LOG_CHOICE:-1}

  case "$LOG_CHOICE" in
    1) $COMPOSE_CMD logs --tail=100 -f ;;
    2) $COMPOSE_CMD logs --tail=100 -f nezha-dashboard ;;
    3)
      if $COMPOSE_CMD ps --format '{{.Name}}' 2>/dev/null | grep -q "caddy"; then
        $COMPOSE_CMD logs --tail=100 -f caddy
      else
        $COMPOSE_CMD logs --tail=100 -f nginx
      fi
      ;;
  esac
}

# ============================================================
#  主菜单
# ============================================================

show_menu() {
  echo ""
  echo -e "${BOLD}┌──────────────────────────────────────┐${NC}"
  echo -e "${BOLD}│      哪吒 Dashboard 管理脚本         │${NC}"
  echo -e "${BOLD}│          v${SCRIPT_VERSION}                       │${NC}"
  echo -e "${BOLD}├──────────────────────────────────────┤${NC}"
  echo -e "│  ${CYAN}1)${NC} 全新安装                         │"
  echo -e "│  ${CYAN}2)${NC} 卸载                             │"
  echo -e "│  ${CYAN}3)${NC} 更新 (拉取最新镜像并重建)       │"
  echo -e "│  ${CYAN}4)${NC} 重启容器                         │"
  echo -e "│  ${CYAN}5)${NC} 查看容器状态                     │"
  echo -e "│  ${CYAN}6)${NC} 查看日志                         │"
  echo -e "│  ${CYAN}0)${NC} 退出                             │"
  echo -e "${BOLD}└──────────────────────────────────────┘${NC}"
  read -p "请选择操作 [0-6]: " MAIN_CHOICE
}

# ============================================================
#  入口
# ============================================================

check_root
detect_os

while true; do
  show_menu
  case "$MAIN_CHOICE" in
    1) install_docker; do_install; break ;;
    2) do_uninstall; break ;;
    3) do_update; break ;;
    4) do_restart; break ;;
    5) do_status; break ;;
    6) do_logs; break ;;
    0) echo "再见！"; exit 0 ;;
    *) error "无效选项，请重新选择"; continue ;;
  esac
done
