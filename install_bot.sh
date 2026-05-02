#!/bin/bash
# ================================================
# Telegram 备份机器人 一键安装脚本
# ================================================

set -e

echo "🤖 Docker 备份机器人 一键安装脚本"
echo "================================"

# 配置变量
INSTALL_DIR="/root/bf"
VENV_DIR="$INSTALL_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. 创建安装目录
echo ""
echo "📁 创建安装目录..."
mkdir -p "$INSTALL_DIR"

# 2. 复制文件
echo "📋 复制文件..."
cp "$SCRIPT_DIR/bf.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/tg_bot.py" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bf.sh"
chmod +x "$INSTALL_DIR/tg_bot.py"
echo "   ✅ 已复制 bf.sh 和 tg_bot.py 到 $INSTALL_DIR"

# 3. 安装 python3-venv (如果需要)
echo ""
echo "📦 检查 Python 虚拟环境支持..."
if ! python3 -m venv --help > /dev/null 2>&1; then
    echo "   正在安装 python3-venv..."
    apt update && apt install -y python3-venv python3-full
fi

# 4. 创建虚拟环境并安装依赖
echo ""
echo "🐍 创建 Python 虚拟环境..."
python3 -m venv "$VENV_DIR"
echo "   ✅ 虚拟环境已创建: $VENV_DIR"

echo ""
echo "📦 安装 Python 依赖..."
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install python-telegram-bot --quiet
echo "   ✅ python-telegram-bot 已安装"

# 5. 配置 rclone remote (OneDrive + Google Drive)
echo ""
echo "⚙️ 配置 rclone remote..."

echo ""
echo "   ℹ️  请确保已配置以下 rclone remote:"
echo ""
echo "   1) OneDrive:"
echo "   rclone config create onedrive onedrive"
echo ""
echo "   2) Google Drive:"
echo "   rclone config create gdrive drive"
echo ""
echo "   📌 配置完成后可验证: rclone lsd onedrive: && rclone lsd gdrive:"

if ! command -v rclone &>/dev/null; then
    echo ""
    echo "   ⚠️  rclone 未安装，正在安装..."
    apt update && apt install -y rclone
    echo "   ✅ rclone 已安装"
fi
echo ""

# 6. 配置 tg_bot systemd 服务
echo ""
echo "⚙️ 配置 Telegram Bot 服务..."
cat > /etc/systemd/system/tg_bot.service << EOF
[Unit]
Description=Telegram Docker Backup Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/tg_bot.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tg_bot
echo "   ✅ 服务已配置并设置开机自启"

# 7. 启动服务
echo ""
echo "🚀 启动 Docker 备份机器人服务..."
systemctl start tg_bot
sleep 2

# 8. 检查状态
if systemctl is-active --quiet tg_bot; then
    echo "   ✅ 机器人已成功启动！"
else
    echo "   ⚠️ 启动可能有问题，请检查: systemctl status tg_bot"
fi

# 9. 显示完成信息
echo ""
echo "================================"
echo "🎉 安装完成！"
echo ""
echo "📍 安装位置: $INSTALL_DIR"
echo "🐍 虚拟环境: $VENV_DIR"
echo ""
echo "📋 常用命令:"
echo "   查看状态: systemctl status tg_bot"
echo "   查看日志: journalctl -u tg_bot -f"
echo "   重启服务: systemctl restart tg_bot"
echo "   停止服务: systemctl stop tg_bot"
echo ""
echo "🔧 配置 cron 定时备份 (可选):"
echo "   crontab -e"
echo "   # 每天凌晨 3 点执行备份"
echo "   0 3 * * * $INSTALL_DIR/bf.sh"
echo ""
echo "📱 现在可以在 Telegram 中测试机器人:"
echo "   发送 /start 查看欢迎消息"
echo "   发送 /status 查看备份状态"
echo "   发送 /run 手动触发备份"
echo ""
echo "☁️ rclone remote 上传:"
echo "   bf.sh 使用 'onedrive' 和 'gdrive' 两个 remote"
echo "   配置命令: rclone config"
echo "================================"
