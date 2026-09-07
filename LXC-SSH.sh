cat > /tmp/enable_root_ssh.sh << 'EOF'
#!/bin/bash
set -e
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

echo ">>> [1/4] 检查 root 用户状态..."
id root &>/dev/null || { echo "❌ root 用户不存在"; exit 1; }

echo ">>> [2/4] 备份原始 SSH 配置..."
cp "$SSHD_CONFIG" "$BACKUP_FILE" && echo "   ✅ 已备份至: $BACKUP_FILE"

echo ">>> [3/4] 修改 SSH 配置..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
grep -q "^PermitRootLogin" "$SSHD_CONFIG" || echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"

echo ">>> [4/4] 设置 root 密码并重启 SSH..."
passwd root
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null

echo -e "\n✅ SSH Root 登录已成功开启!"
echo "测试命令: ssh root@$(hostname -I | awk '{print $1}')"
EOF

chmod +x /tmp/enable_root_ssh.sh
bash /tmp/enable_root_ssh.sh
