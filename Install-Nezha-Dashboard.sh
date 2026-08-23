#!/bin/bash
set -e

echo "=== 哪吒 Dashboard 一键安装脚本（优化版）==="
echo "支持：自动申请证书 / 手动导入证书 | Let's Encrypt / ZeroSSL | Cloudflare CDN 可选"
echo ""

# -------------------------------
# 0. 安装 Docker & Docker Compose
# -------------------------------
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
  else
    echo "Docker 已安装"
  fi

  if ! command -v docker compose >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    echo "安装 Docker Compose 插件..."
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4)
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  else
    echo "Docker Compose 已安装"
  fi
}

# -------------------------------
# 1. 安装 acme.sh 依赖
# -------------------------------
install_acme_deps() {
  echo "安装 acme.sh 所需依赖..."
  if [ -f /etc/debian_version ]; then
    apt-get update
    apt-get install -y curl wget socat cron openssl netcat-openbsd dnsutils lsof
    systemctl enable cron
    systemctl start cron
  elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget socat cronie openssl nmap-ncat bind-utils lsof
    systemctl enable crond
    systemctl start crond
  else
    echo "未知系统，请手动安装依赖: curl wget socat cron openssl netcat dnsutils lsof"
  fi
}

install_docker
install_acme_deps

# -------------------------------
# 2. 基础用户输入
# -------------------------------
read -p "请输入项目目录 (默认: /etc/Nezha-Dashboard): " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-/etc/Nezha-Dashboard}
PROJECT_DIR=$(realpath -m "$PROJECT_DIR")

read -p "请输入绑定的域名 (必填): " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "错误: 域名不能为空！"
  exit 1
fi

# 域名解析检测
if command -v dig >/dev/null 2>&1; then
  DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -n1)
else
  DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{ print $1 }' | head -n1)
fi
LOCAL_IP=$(curl -s4 ipv4.icanhazip.com || curl -s4 ifconfig.me)

echo "本机公网 IP: $LOCAL_IP"
echo "域名解析 IP: ${DOMAIN_IP:-未解析到}"

read -p "请输入邮箱 (用于证书注册，留空则随机生成一个@gmail.com): " EMAIL
if [ -z "$EMAIL" ]; then
  RAND=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
  EMAIL="${RAND}@gmail.com"
  echo "未输入邮箱，使用随机邮箱: $EMAIL"
fi

# -------------------------------
# 3. 证书获取方式选择
# -------------------------------
echo ""
echo "请选择证书获取方式:"
echo "1) 自动申请证书 (推荐)"
echo "2) 手动指定已有证书目录"
read -p "输入选项 (1/2，默认 1): " CERT_MODE
CERT_MODE=${CERT_MODE:-1}

mkdir -p "$PROJECT_DIR/cert"
cd "$PROJECT_DIR"

USE_ACME=false

if [ "$CERT_MODE" == "1" ]; then
  USE_ACME=true

  # 选择 CA
  echo ""
  echo "请选择证书颁发机构 (CA):"
  echo "1) Let's Encrypt (默认)"
  echo "2) ZeroSSL"
  read -p "输入选项 (1/2，默认 1): " CA_CHOICE
  CA_CHOICE=${CA_CHOICE:-1}

  if [ "$CA_CHOICE" == "2" ]; then
    ACME_SERVER="zerossl"
    echo "已选择 ZeroSSL"
  else
    ACME_SERVER="letsencrypt"
    echo "已选择 Let's Encrypt"
  fi

  # 选择申请方式
  echo ""
  echo "请选择证书申请方式:"
  echo "1) 80端口 standalone 模式 (需要域名已解析到本机，且 80 端口空闲)"
  echo "2) Cloudflare DNS 模式 (推荐，支持 CDN)"
  read -p "输入选项 (1/2): " MODE

  # standalone 模式校验域名
  if [ "$MODE" == "1" ]; then
    if [ -z "$DOMAIN_IP" ] || [ "$DOMAIN_IP" != "$LOCAL_IP" ]; then
      echo "错误: 域名解析 IP ($DOMAIN_IP) 与本机 IP ($LOCAL_IP) 不匹配！"
      echo "standalone 模式必须让域名直接解析到本机。"
      exit 1
    else
      echo "✅ 域名解析正确: $DOMAIN -> $DOMAIN_IP"
    fi
  fi

  # 安装 acme.sh
  if [ ! -d "$HOME/.acme.sh" ]; then
    echo "安装 acme.sh ..."
    curl https://get.acme.sh | sh -s email="$EMAIL"
  fi

  # 注册账户
  "$HOME/.acme.sh/acme.sh" --register-account -m "$EMAIL" --server "$ACME_SERVER" || true

  # 申请证书
  if [ "$MODE" == "1" ]; then
    if lsof -i:80 >/dev/null 2>&1; then
      echo "错误: 80 端口已被占用，请先停止占用服务再运行脚本！"
      exit 1
    fi
    echo "使用 80 端口 standalone 模式申请证书..."
    "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --server "$ACME_SERVER" --force

  elif [ "$MODE" == "2" ]; then
    echo "使用 Cloudflare DNS 模式申请证书..."
    read -p "请输入 Cloudflare API Token: " CF_TOKEN
    read -p "请输入 Cloudflare 邮箱: " CF_EMAIL

    export CF_Token="$CF_TOKEN"
    export CF_Email="$CF_EMAIL"

    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --server "$ACME_SERVER" --force

    unset CF_Token CF_Email
  else
    echo "错误: 无效选项"
    exit 1
  fi

  # 安装证书到项目目录
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
    --cert-file       "$PROJECT_DIR/cert/cert.crt" \
    --key-file        "$PROJECT_DIR/cert/private.key" \
    --fullchain-file  "$PROJECT_DIR/cert/fullchain.crt" \
    --reloadcmd       "docker restart nezha-nginx || true"

  echo "✅ 证书已申请并安装到: $PROJECT_DIR/cert/"

elif [ "$CERT_MODE" == "2" ]; then
  echo ""
  echo "请输入已有证书所在目录（目录内需包含证书和私钥文件）"
  echo "支持常见文件名: fullchain.crt / fullchain.pem / cert.crt / cert.pem + private.key / privkey.pem 等"
  read -p "证书目录路径: " MANUAL_CERT_DIR

  if [ ! -d "$MANUAL_CERT_DIR" ]; then
    echo "错误: 目录不存在: $MANUAL_CERT_DIR"
    exit 1
  fi

  # 自动查找证书和私钥
  CERT_FILE=""
  KEY_FILE=""

  for f in fullchain.crt fullchain.pem cert.crt cert.pem certificate.crt; do
    if [ -f "$MANUAL_CERT_DIR/$f" ]; then
      CERT_FILE="$MANUAL_CERT_DIR/$f"
      break
    fi
  done

  for f in private.key privkey.pem key.pem private.pem; do
    if [ -f "$MANUAL_CERT_DIR/$f" ]; then
      KEY_FILE="$MANUAL_CERT_DIR/$f"
      break
    fi
  done

  if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
    echo "错误: 未能在目录中自动找到证书或私钥文件。"
    echo "请确保目录包含以下文件之一："
    echo "  证书: fullchain.crt / fullchain.pem / cert.crt / cert.pem"
    echo "  私钥: private.key / privkey.pem / key.pem"
    exit 1
  fi

  echo "找到证书: $CERT_FILE"
  echo "找到私钥: $KEY_FILE"

  cp -f "$CERT_FILE" "$PROJECT_DIR/cert/fullchain.crt"
  cp -f "$CERT_FILE" "$PROJECT_DIR/cert/cert.crt"
  cp -f "$KEY_FILE"  "$PROJECT_DIR/cert/private.key"
  chmod 600 "$PROJECT_DIR/cert/private.key"

  echo "✅ 证书已复制到: $PROJECT_DIR/cert/"

else
  echo "错误: 无效选项"
  exit 1
fi

# -------------------------------
# 4. 是否开启 Cloudflare CDN
# -------------------------------
echo ""
echo "是否开启 Cloudflare CDN 相关配置？"
echo "1) 开启 (使用 CF-Connecting-IP 获取真实 IP，推荐使用 CF CDN 时选择)"
echo "2) 关闭 (Nginx 作为最外层，使用 \$remote_addr)"
read -p "输入选项 (1/2，默认 2): " CF_CDN
CF_CDN=${CF_CDN:-2}

if [ "$CF_CDN" == "1" ]; then
  ENABLE_CF=true
  echo "已开启 Cloudflare CDN 配置"
else
  ENABLE_CF=false
  echo "已关闭 Cloudflare CDN 配置（推荐无 CDN 或使用其他 CDN 时选择）"
fi

# -------------------------------
# 5. 生成 docker-compose.yml
# -------------------------------
cat > docker-compose.yml <<EOF
services:
  nezha-dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: nezha-dashboard
    restart: always
    # 不再暴露 8008 端口到宿主机，仅通过 Nginx 访问，更安全
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

# -------------------------------
# 6. 生成 nginx.conf（根据是否开启 CF 动态生成）
# -------------------------------
if [ "$ENABLE_CF" = true ]; then
  # Cloudflare 开启时的配置
  REAL_IP_CONF=$(cat <<'REALIP'
    # Cloudflare 真实 IP
    real_ip_header CF-Connecting-IP;
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    set_real_ip_from 162.158.0.0/15;
    set_real_ip_from 104.16.0.0/13;
    set_real_ip_from 104.24.0.0/14;
    set_real_ip_from 172.64.0.0/13;
    set_real_ip_from 131.0.72.0/22;
REALIP
)
  NZ_REALIP='$http_cf_connecting_ip'
else
  # 关闭 Cloudflare 时注释相关配置，并使用 $remote_addr
  REAL_IP_CONF=$(cat <<'REALIP'
    # Cloudflare 真实 IP（已关闭）
    # real_ip_header CF-Connecting-IP;
    # set_real_ip_from 173.245.48.0/20;
    # set_real_ip_from 103.21.244.0/22;
    # set_real_ip_from 103.22.200.0/22;
    # set_real_ip_from 103.31.4.0/22;
    # set_real_ip_from 141.101.64.0/18;
    # set_real_ip_from 108.162.192.0/18;
    # set_real_ip_from 190.93.240.0/20;
    # set_real_ip_from 188.114.96.0/20;
    # set_real_ip_from 197.234.240.0/22;
    # set_real_ip_from 198.41.128.0/17;
    # set_real_ip_from 162.158.0.0/15;
    # set_real_ip_from 104.16.0.0/13;
    # set_real_ip_from 104.24.0.0/14;
    # set_real_ip_from 172.64.0.0/13;
    # set_real_ip_from 131.0.72.0/22;
REALIP
)
  NZ_REALIP='$remote_addr'
fi

cat > nginx.conf <<EOF
upstream dashboard {
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

    # SSL 配置
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

    # 静态资源缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|woff2|ttf|svg|webp|avif|wasm)$ {
        expires 1y;
        add_header Cache-Control "public, immutable, max-age=31536000";
        access_log off;
        log_not_found off;
        proxy_pass http://dashboard;
    }

    # gRPC（哪吒 Agent 通信）
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

    # WebSocket（终端、文件传输）
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
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

# HTTP → HTTPS 强制跳转
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

# -------------------------------
# 7. 启动服务
# -------------------------------
echo ""
echo "正在启动服务..."
docker compose up -d

echo ""
echo "========================================="
echo "✅ 部署完成！"
echo "   访问地址: https://${DOMAIN}"
echo "   项目目录: ${PROJECT_DIR}"
echo "   证书路径: ${PROJECT_DIR}/cert/"
if [ "$ENABLE_CF" = true ]; then
  echo "   Cloudflare CDN: 已开启"
else
  echo "   Cloudflare CDN: 已关闭（使用 \$remote_addr）"
fi
echo "========================================="
echo ""
echo "提示："
echo "1. 请确保防火墙/安全组已放行 80 和 443 端口"
echo "2. Agent 对接地址请填写: ${DOMAIN}:443 并开启 TLS"
echo "3. 如需重新生成 Nginx 配置，可再次运行本脚本（注意会覆盖现有文件）"
