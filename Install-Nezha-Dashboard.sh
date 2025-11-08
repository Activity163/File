#!/bin/bash
set -e

PROJECT_DIR=/root/project
CERT_DIR=/root
DOMAIN=stats.example.com   # 修改为你的真实域名

echo ">>> 创建项目目录"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

echo ">>> 生成 docker-compose.yml"
cat > docker-compose.yml <<EOF
services:
  nezha-dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: nezha-dashboard
    restart: always
    ports:
      - "8008:8008"
    volumes:
      - ./data:/dashboard/data

  nginx:
    image: nginx:latest
    container_name: nezha-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - $CERT_DIR/cert.crt:/etc/nginx/certs/cert.crt:ro
      - $CERT_DIR/private.key:/etc/nginx/certs/private.key:ro
EOF

echo ">>> 生成 nginx.conf"
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

    ssl_certificate     /etc/nginx/certs/cert.crt;
    ssl_certificate_key /etc/nginx/certs/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    underscores_in_headers on;
    real_ip_header CF-Connecting-IP;
    set_real_ip_from 0.0.0.0/0;

    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$http_cf_connecting_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 20m;
        grpc_buffer_size 8m;
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_cf_connecting_ip;
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_pass http://dashboard;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_cf_connecting_ip;
        proxy_set_header X-Forwarded-Proto \$scheme;
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
    return 301 https://\$host\$request_uri;
}
EOF

echo ">>> 启动服务"
docker compose up -d
