<p align="center">
  <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20CentOS-blue?style=for-the-badge&logo=linux&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Made%20with-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Python-3.8+-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge" alt="License">
</p>

<br>

<p align="center">
  <h1 align="center">🐳 Docker 备份系统</h1>
  <p align="center"><i>一键备份 · 双网盘上传 · Telegram 远程管理</i></p>
</p>

<br>

---

## 📖 项目概述

自动备份 VPS 上所有运行中的 **Docker 容器**（含 `docker-compose` 项目），支持上传到 **OneDrive** + **Google Drive** 双网盘，并可通过 **Telegram Bot** 进行远程管理。

| 📄 文件 | 🎯 用途 |
|:---------|:---------|
| `bf.sh` | 备份脚本，支持 cron 定时或手动执行 |
| `restore.sh` | 恢复脚本，从备份文件还原容器 |
| `tg_bot.py` | Telegram 机器人，远程查看状态 / 触发备份 |
| `tg_bot.service` | Bot 的 systemd 服务文件 |
| `install_bot.sh` | 一键部署脚本 |

---

## ⚙️ 一、环境要求

| 项目 | 要求 |
|:------|:------|
| 🖥️ 操作系统 | Ubuntu 20.04+ / Debian 11+ / CentOS 7+ |
| 🐳 Docker | 已安装并正常运行 |
| 🔑 权限 | `root` |
| 🔧 Git | 已安装 |
| ☁️ 网盘 (可选) | rclone 已配置 remote |

---

## 🚀 二、部署步骤

### 📥 1. 从 GitHub 拉取项目

```bash
cd /root
git clone https://github.com/Agff45/vps_docker-bf.git bf
cd /root/bf
chmod +x *.sh
```

### 📦 2. 安装系统依赖

```bash
apt update && apt install -y jq tar gzip curl
```

### ☁️ 3. 配置 rclone 网盘 (可选)

<details>
<summary><b>📂 展开查看 rclone 配置步骤</b></summary>

```bash
# 安装 rclone
curl https://rclone.org/install.sh | bash

# 配置 OneDrive
rclone config create onedrive onedrive

# 配置 Google Drive
rclone config create gdrive drive

# 验证配置
rclone lsd onedrive:
rclone lsd gdrive:
```

</details>

> 💡 **提示：** 如果不想用网盘，跳过此步骤即可。备份会保存在本地，网盘上传步骤会显示失败，不影响本地备份。

### 🤖 4. 修改 Telegram 配置

#### 📝 编辑 `bf.sh`

```bash
vi /root/bf/bf.sh
```

修改第 22-23 行：

```bash
TG_BOT_TOKEN="你的BotToken"       # @BotFather 获取
TG_CHAT_ID="你的ChatID"           # @userinfobot 获取
TG_ENABLED=true                   # 不需要通知就改 false
```

#### 📝 编辑 `tg_bot.py`

```bash
vi /root/bf/tg_bot.py
```

修改第 16-17 行：

```python
BOT_TOKEN = "你的BotToken"
ALLOWED_CHAT_ID = 你的ChatID
```

> ⚠️ **注意：** 如果不想用 Telegram 通知和 Bot，把 `TG_ENABLED` 设为 `false`，并且不要运行 `install_bot.sh`。

### 🧪 5. 测试备份

```bash
/root/bf/bf.sh
```

> ✅ 正常输出：`依赖检查` → `容器扫描` → `打包完成` → `网盘上传结果`

### ⏰ 6. 设置定时任务

```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /root/bf/bf.sh >> /var/log/docker_backup.log 2>&1") | crontab -
```

> 📅 默认每天 **凌晨 3 点** 自动备份，可自行修改 cron 表达式。

### 🔌 7. 部署 Telegram Bot (可选)

```bash
/root/bf/install_bot.sh
```

Bot 将自动启动，在 Telegram 中发送 `/start` 测试。

```bash
# 📋 Bot 管理命令
systemctl status tg_bot      # 查看状态
systemctl restart tg_bot     # 重启 Bot
journalctl -u tg_bot -f      # 实时查看日志
```

### ✔️ 8. 验证部署

| ✅ 检查项 | 📟 命令 |
|:-----------|:---------|
| 手动备份 | `/root/bf/bf.sh` |
| 备份文件 | `ls -lh /root/bf/docker_backup_*.tar.gz` |
| Bot 状态 | `systemctl status tg_bot` |
| 定时任务 | `crontab -l` |

---

## 🔄 三、恢复备份

```bash
cd /root/bf
./restore.sh docker_backup_YYYYMMDD_HHMMSS.tar.gz
```

恢复分 **3 步** 自动执行：

```
1️⃣  还原 docker-compose 项目
2️⃣  还原普通容器（卷数据 + 参数）
3️⃣  还原 /home/docker 下的文件
```

> 🛡️ 已运行的容器会**自动跳过**，不会重复创建。

---

## 📋 四、配置文件参考

### `bf.sh` 配置项

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

### `tg_bot.py` 配置项

```python
BOT_TOKEN = "你的Token"               # @BotFather 获取
ALLOWED_CHAT_ID = 你的ID              # @userinfobot 获取
```

---

## 💬 五、Bot 命令

| 🎮 命令 | 🧩 功能 |
|:---------|:---------|
| `/start` | 欢迎消息 |
| `/status` | 查看最近备份状态（含容器统计） |
| `/run` | 手动触发备份（实时回显进度） |
| `/help` | 帮助信息 |

---

## 📁 六、VPS 目录结构 (部署后)

```
/root/bf/
├── 📜 bf.sh                   # 备份脚本
├── 📜 restore.sh              # 恢复脚本
├── 📜 tg_bot.py               # Telegram Bot 脚本
├── 📜 install_bot.sh          # 安装脚本
├── 📜 tg_bot.service          # systemd 服务文件
├── 📜 README.md               # 本文档
├── 📜 .gitignore              # Git 忽略规则
├── 📁 venv/                   # Python 虚拟环境 (install_bot.sh 创建)
├── 📄 backup_status.json      # 最近一次备份状态
└── 📦 docker_backup_*.tar.gz  # 备份文件（本地只保留最新 1 份）
```

---

## 🗑️ 七、完全卸载

<details>
<summary><b>🤖 卸载 Telegram Bot</b></summary>

```bash
systemctl stop tg_bot
systemctl disable tg_bot
rm -f /etc/systemd/system/tg_bot.service
systemctl daemon-reload
```

</details>

<details>
<summary><b>⏰ 删除定时任务</b></summary>

```bash
crontab -l | grep -v '/root/bf/bf.sh' | crontab -
```

</details>

<details>
<summary><b>📂 删除所有项目文件</b></summary>

```bash
rm -rf /root/bf
```

</details>

<details>
<summary><b>📋 删除备份日志</b></summary>

```bash
rm -f /var/log/docker_backup.log
```

</details>

<br>

> ⚡ **一键卸载（复制整段到终端执行）**

```bash
systemctl stop tg_bot 2>/dev/null
systemctl disable tg_bot 2>/dev/null
rm -f /etc/systemd/system/tg_bot.service
systemctl daemon-reload
crontab -l 2>/dev/null | grep -v '/root/bf/bf.sh' | crontab -
rm -rf /root/bf
rm -f /var/log/docker_backup.log
echo "✅ 卸载完成"
```

---

## 🔄 八、更新项目

```bash
cd /root/bf
git pull
chmod +x *.sh
```

---

## ❓ 九、常见问题

<br>

<details>
<summary><b>🌐 Q: git clone 失败（国内服务器）？</b></summary>

```bash
# 方式一：使用代理
git config --global http.proxy http://127.0.0.1:端口
git config --global https.proxy http://127.0.0.1:端口
git clone https://github.com/Agff45/vps_docker-bf.git bf

# 方式二：使用镜像站
git clone https://ghproxy.com/https://github.com/Agff45/vps_docker-bf.git bf
```

</details>

<br>

<details>
<summary><b>📝 Q: 脚本报 syntax error？</b></summary>

```bash
sed -i 's/\r$//' /root/bf/*.sh
```

> 原因：Windows 换行符 `\r\n` 与 Linux 不兼容。

</details>

<br>

<details>
<summary><b>📦 Q: 备份时提示缺少依赖？</b></summary>

```bash
apt install -y jq tar gzip curl rclone
```

</details>

<br>

<details>
<summary><b>☁️ Q: 网盘上传失败？</b></summary>

确认 rclone remote 已正确配置：

```bash
rclone lsd onedrive:
rclone lsd gdrive:
```

> 💡 如果不想用网盘，上传失败不影响本地备份。

</details>

<br>

<details>
<summary><b>🤖 Q: Bot 启动失败？</b></summary>

```bash
journalctl -u tg_bot -n 50      # 查看错误日志
systemctl restart tg_bot         # 重试启动
```

> 常见原因：`Token 错误`、`网络不通`、`Python 依赖未安装`。

</details>

<br>

<details>
<summary><b>🐳 Q: 恢复时容器启动失败？</b></summary>

一般为镜像未拉取，手动 pull 后重试：

```bash
docker pull <镜像名>
./restore.sh <备份文件>
```

</details>

---

<br>

<p align="center">
  <sub>Made with ❤️ for VPS & Docker users</sub>
</p>
