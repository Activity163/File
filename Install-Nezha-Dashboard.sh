#!/bin/bash
set -e

echo "=== 哪吒 Dashboard 一键安装脚本（含证书申请 & Docker安装）==="

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

  if ! command -v docker compose >/dev/null 2>&1; then
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
    apt-get install -y curl wget socat cron openssl netcat-openbsd dnsutils
    systemctl enable cron
    systemctl start cron
  elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget socat cronie openssl nmap-ncat bind-utils
    systemctl enable crond
    systemctl start crond
  else
    echo "未知系统，请手动安装依赖: curl wget socat cron openssl netcat dnsutils"
  fi
}

install_docker
install_acme_deps

# -------------------------------
# 2. 用户输入
# -------------------------------
read -p "请输入项目目录 (默认: Nezha-Dashboard): " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-/etc/Nezha-Dashboard}
PROJECT_DIR=$(realpath $PROJECT_DIR)


read -p "请输入绑定的域名 (必填): " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "错误: 域名不能为空！"
  exit 1
fi

# 域名解析检测
if command -v dig >/dev/null 2>&1; then
  DOMAIN_IP=$(dig +short $DOMAIN | tail -n1)
else
  DOMAIN_IP=$(getent hosts $DOMAIN | awk '{ print $1 }' | head -n1)
fi
LOCAL_IP=$(curl -s ipv4.icanhazip.com)

if [ "$DOMAIN_IP" != "$LOCAL_IP" ]; then
  echo "错误: 域名解析IP ($DOMAIN_IP) 与本机IP ($LOCAL_IP) 不匹配！"
  exit 1
else
  echo "✅ 域名解析正确: $DOMAIN -> $DOMAIN_IP"
fi

read -p "请输入邮箱 (留空则随机生成一个@gmail.com): " EMAIL
if [ -z "$EMAIL" ]; then
  RAND=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
  EMAIL="${RAND}@gmail.com"
  echo "未输入邮箱，使用随机邮箱: $EMAIL"
fi

echo "请选择证书申请方式:"
echo "1) 80端口 standalone 模式"
echo "2) Cloudflare DNS 模式"
read -p "输入选项 (1/2): " MODE

# -------------------------------
# 3. 创建目录
# -------------------------------
mkdir -p $PROJECT_DIR/cert
cd $PROJECT_DIR

# -------------------------------
# 4. 安装 acme.sh
# -------------------------------
if [ ! -d "$HOME/.acme.sh" ]; then
  echo "安装 acme.sh ..."
  curl https://get.acme.sh | sh
fi

# -------------------------------
# 5. 注册 ACME 账户
# -------------------------------
$HOME/.acme.sh/acme.sh --register-account -m $EMAIL || true

# -------------------------------
# 6. 申请证书
# -------------------------------
if [ "$MODE" == "1" ]; then
  # 检查 80 端口占用
  if lsof -i:80 >/dev/null 2>&1; then
    echo "错误: 80端口已被占用，请先停止占用服务再运行脚本！"
    exit 1
  fi

  echo "使用 80端口 standalone 模式申请证书..."
  $HOME/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --force

elif [ "$MODE" == "2" ]; then
  echo "使用 Cloudflare DNS 模式申请证书..."
  read -p "请输入 Cloudflare API Key: " CF_KEY
  read -p "请输入 Cloudflare 邮箱: " CF_EMAIL

  export CF_Key="$CF_KEY"
  export CF_Email="$CF_EMAIL"

  $HOME/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN --force
else
  echo "错误: 无效选项"
  exit 1
fi

# -------------------------------
# 7. 安装证书到项目目录 (绝对路径)
# -------------------------------
$HOME/.acme.sh/acme.sh --install-cert -d $DOMAIN \
  --cert-file $PROJECT_DIR/cert/cert.crt \
  --key-file $PROJECT_DIR/cert/private.key \
  --fullchain-file $PROJECT_DIR/cert/fullchain.crt \
  --reloadcmd "docker restart nezha-nginx || true"

echo "证书已生成到: $PROJECT_DIR/cert/"

# -------------------------------
# 8. 生成 docker-compose.yml
# -------------------------------
cat > docker-compose.yml <<EOF
services:
  nezha-dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: nezha-dashboard
    restart: always
    ports:
      - "8008:8008"
    volumes:
      - $PROJECT_DIR/data:/dashboard/data

  nginx:
    image: nginx:latest
    container_name: nezha-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf
      - $PROJECT_DIR/cert/cert.crt:/etc/nezha/cert/cert.crt:ro
      - $PROJECT_DIR/cert/private.key:/etc/nezha/cert/private.key:ro
EOF


# -------------------------------
# 9. 生成 nginx.conf
# -------------------------------
cat > nginx.conf <<EOF
upstream dashboard {
    server nezha-dashboard:8008;
    keepalive 1024;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name $DOMAIN;

    # SSL 配置
    ssl_certificate     /etc/nezha/cert/cert.crt;
    ssl_certificate_key /etc/nezha/cert/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    underscores_in_headers on;

    # Cloudflare 或其他反代的真实 IP
    real_ip_header CF-Connecting-IP;
    set_real_ip_from 0.0.0.0/0;

    # gRPC
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host $host;
        grpc_set_header nz-realip $http_cf_connecting_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 20m;
        grpc_buffer_size 8m;
        grpc_pass grpc://dashboard;
    }

    # WebSocket
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host $host;
        proxy_set_header nz-realip $http_cf_connecting_ip;
        proxy_set_header Origin https://$host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_pass http://dashboard;
    }

    # Web
    location / {
        proxy_set_header Host $host;
        proxy_set_header nz-realip $http_cf_connecting_ip;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_buffer_size 128k;
        proxy_buffers 8 256k;
        proxy_busy_buffers_size 512k;
        proxy_max_temp_file_size 0;

        proxy_pass http://dashboard;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # 自动跳转到 HTTPS
    return 301 https://$host$request_uri;
}
EOF

# -------------------------------
# 10. 启动服务
# -------------------------------
docker compose up -d

echo "✅ 部署完成！访问地址: https://$DOMAIN"
