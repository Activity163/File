#!/bin/bash

# ==============================
# Nezha Dashboard 安装脚本
# 支持用户自定义输入或使用默认值
# ==============================

# 读取用户输入（带默认值）
read -p "请输入项目目录 (默认: Nezha-Dashboard): " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-Nezha-Dashboard}

read -p "请输入绑定的域名 (必填): " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "错误: 域名不能为空！"
  exit 1
fi

read -p "请输入证书文件路径 (cert.crt): " CERT_FILE
if [ -z "$CERT_FILE" ]; then
  echo "错误: 证书文件路径不能为空！"
  exit 1
fi

read -p "请输入私钥文件路径 (private.key): " KEY_FILE
if [ -z "$KEY_FILE" ]; then
  echo "错误: 私钥文件路径不能为空！"
  exit 1
fi

# 创建项目目录
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# 生成 docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3.3'
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
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - $CERT_FILE:/etc/nginx/certs/cert.crt:ro
      - $KEY_FILE:/etc/nginx/certs/private.key:ro
EOF

# 生成 nginx.conf
cat > nginx.conf <<EOF
upstream dashboard {
    server nezha-dashboard:8008;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/certs/cert.crt;
    ssl_certificate_key /etc/nginx/certs/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /proto.NezhaService/ {
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(.+)$ {
        proxy_pass http://dashboard;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        proxy_pass http://dashboard;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

# 启动服务
docker compose up -d
echo "✅ Nezha Dashboard 已部署完成，访问地址：https://$DOMAIN"
