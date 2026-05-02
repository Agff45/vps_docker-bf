# Docker 备份系统 — 部署与卸载文档

## 项目概述

自动备份 VPS 上所有运行中的 Docker 容器（含 docker-compose 项目），上传到 OneDrive + Google Drive 网盘，支持 Telegram Bot 远程管理。

| 文件 | 用途 |
|------|------|
| `bf.sh` | 备份脚本，cron 定时或手动执行 |
| `restore.sh` | 恢复脚本，从备份文件还原容器 |
| `tg_bot.py` | Telegram 机器人，远程查看状态 / 触发备份 |
| `tg_bot.service` | Bot 的 systemd 服务文件 |
| `install_bot.sh` | 一键部署脚本 |

---

## 一、环境要求

- Linux (Ubuntu 20.04+ / Debian 11+ / CentOS 7+)
- Docker 已安装并正常运行
- root 权限
- 如果使用网盘：需要 rclone 并配置好 remote

---

## 二、部署步骤

### 1. 上传文件

```powershell
# 在 Windows 本地执行
scp d:\桌面\1\bf.sh        root@你的IP:/root/bf/
scp d:\桌面\1\restore.sh   root@你的IP:/root/bf/
scp d:\桌面\1\tg_bot.py    root@你的IP:/root/bf/
scp d:\桌面\1\tg_bot.service root@你的IP:/root/bf/
scp d:\桌面\1\install_bot.sh root@你的IP:/root/bf/
```

### 2. 登录 VPS，修正换行符

```bash
ssh root@你的IP
mkdir -p /root/bf
cd /root/bf
sed -i 's/\r$//' *.sh
chmod +x *.sh
```

### 3. 安装系统依赖

```bash
apt update && apt install -y jq tar gzip curl
```

### 4. 配置 rclone 网盘（可选）

```bash
curl https://rclone.org/install.sh | bash

# 配置 OneDrive
rclone config create onedrive onedrive

# 配置 Google Drive
rclone config create gdrive drive

# 验证
rclone lsd onedrive:
rclone lsd gdrive:
```

### 5. 修改配置（可选）

编辑 `bf.sh` 和 `tg_bot.py` 中的 Telegram 参数：

```bash
# bf.sh 第 19-21 行
TG_BOT_TOKEN="你的BotToken"
TG_CHAT_ID="你的ChatID"
TG_ENABLED=true

# tg_bot.py 第 16-17 行
BOT_TOKEN = "你的BotToken"
ALLOWED_CHAT_ID = 你的ChatID
```

### 6. 测试备份

```bash
./bf.sh
```

正常输出应包含：依赖检查 → 容器扫描 → 打包完成 → 网盘上传结果。

### 7. 设置定时任务

```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /root/bf/bf.sh >> /var/log/docker_backup.log 2>&1") | crontab -
```

### 8. 部署 Telegram Bot（可选）

```bash
./install_bot.sh
```

安装完成后 Bot 自动启动，在 Telegram 中发送 `/start` 测试。

```bash
# Bot 管理命令
systemctl status tg_bot     # 查看状态
systemctl restart tg_bot    # 重启
journalctl -u tg_bot -f     # 查看日志
```

### 9. 验证部署

| 检查项 | 命令 |
|--------|------|
| 手动备份 | `/root/bf/bf.sh` |
| 备份文件 | `ls -lh /root/bf/docker_backup_*.tar.gz` |
| Bot 状态 | `systemctl status tg_bot` |
| 定时任务 | `crontab -l` |

---

## 三、恢复备份

```bash
cd /root/bf
./restore.sh docker_backup_YYYYMMDD_HHMMSS.tar.gz
```

恢复分 3 步自动执行：
1. 还原 docker-compose 项目
2. 还原普通容器（卷数据 + 参数）
3. 还原 /home/docker 下的文件

已运行的容器会**自动跳过**，不会重复创建。

---

## 四、配置文件参考

### bf.sh 配置项

```bash
BACKUP_DIR="/root/bf"                 # 本地备份存放目录
LOCAL_KEEP_COUNT=1                    # 本地保留份数
REMOTE1_NAME="onedrive"               # OneDrive rclone remote 名
REMOTE1_DIR="VPS_Backups/Docker"      # OneDrive 目标路径
REMOTE2_NAME="gdrive"                 # Google Drive rclone remote 名
REMOTE2_DIR="VPS_Backups/Docker"      # Google Drive 目标路径
REMOTE_KEEP_COUNT=4                   # 网盘各保留份数
TG_ENABLED=true                       # 是否启用 Telegram 通知
```

### tg_bot.py 配置项

```python
BOT_TOKEN = "你的Token"               # @BotFather 获取
ALLOWED_CHAT_ID = 你的ID              # @userinfobot 获取
```

---

## 五、Bot 命令

| 命令 | 功能 |
|------|------|
| `/start` | 欢迎消息 |
| `/status` | 查看最近备份状态（含容器统计） |
| `/run` | 手动触发备份（实时回显进度） |
| `/help` | 帮助信息 |

---

## 六、VPS 目录结构（最终）

```
/root/bf/
├── bf.sh                   # 备份脚本
├── restore.sh              # 恢复脚本
├── tg_bot.py               # Telegram Bot 脚本
├── install_bot.sh          # 安装脚本
├── venv/                   # Python 虚拟环境 (install_bot.sh 创建)
├── backup_status.json      # 最近一次备份状态
└── docker_backup_*.tar.gz  # 备份文件
```

---

## 七、完全卸载

```bash
# 1. 停止并禁用 Bot 服务
systemctl stop tg_bot 2>/dev/null
systemctl disable tg_bot 2>/dev/null

# 2. 删除 systemd 服务文件
rm -f /etc/systemd/system/tg_bot.service
systemctl daemon-reload

# 3. 删除 cron 定时任务
crontab -l | grep -v '/root/bf/bf.sh' | crontab -

# 4. 删除项目目录
rm -rf /root/bf

# 5. 删除备份日志（如果有）
rm -f /var/log/docker_backup.log
```

---

## 八、常见问题

### Q: Windows 上传后脚本报 syntax error
```bash
sed -i 's/\r$//' /root/bf/*.sh
```

### Q: 备份时提示缺少依赖
```bash
apt install -y jq tar gzip curl
```

### Q: 网盘上传失败
确认 rclone remote 已正确配置：
```bash
rclone lsd onedrive:
rclone lsd gdrive:
```
如果不想用网盘，上传失败不影响本地备份，只是远程那一步会显示失败。

### Q: Bot 启动失败
```bash
journalctl -u tg_bot -n 50      # 查看错误日志
systemctl restart tg_bot         # 重试启动
```
常见原因：Token 错误、网络不通、Python 依赖未安装。

### Q: 恢复时容器启动失败
一般是镜像未拉取，手动 pull 后重试：
```bash
docker pull <镜像名>
./restore.sh <备份文件>
```
