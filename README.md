<p align="center">
  <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20CentOS-blue?style=for-the-badge&logo=linux&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Made%20with-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Python-3.8+-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge" alt="License">
</p>

<br>

<p align="center">
  <h1 align="center">🐳 Docker 备份系统</h1>
  <p align="center">
    <i>一键备份 · 数据库安全导出 · 双网盘上传 · GPG 加密 · Telegram 远程管理</i>
  </p>
</p>

<br>

---

## 📖 项目概述

自动备份 VPS 上所有运行中的 **Docker 容器**（含 `docker-compose` 项目），内建数据库智能检测与安全导出，支持上传到 **OneDrive + Google Drive** 双网盘，并可通过 **Telegram Bot** 进行远程管理。

> ⚠️ **核心规则：仅备份 Running 状态的容器**  
> 脚本通过 `docker ps` 扫描当前处于 **Running** 状态的容器。已停止 (Exited) 或暂停 (Paused) 的容器**不会被备份**。如需备份某个已停止的容器，请先 `docker start <容器>` 启动它。

> 🗄️ **数据库智能导出**  
> 自动检测 **MySQL / MariaDB / PostgreSQL / MongoDB** 容器，使用 `mysqldump` / `pg_dumpall` / `mongodump` 执行一致性安全导出。导出失败时自动降级为卷打包，不中断整体备份流程。

---

### 🎯 核心能力

| 能力 | 说明 |
|:---|:---|
| 🐳 **全容器备份** | 所有 Running 容器的 inspect JSON + 卷数据 + 运行参数 |
| 🧩 **Compose 支持** | 自动识别 `docker-compose` 项目，打包完整的 `docker-compose.yml` + 目录 |
| 🗄️ **数据库安全导出** | MySQL / MariaDB / PostgreSQL / MongoDB 专用导出，保证数据一致性 |
| � **GPG 加密** | 可选 AES256 对称加密，备份文件上传前自动加密 |
| ☁️ **双网盘上传** | OneDrive + Google Drive 自动上传，远程保留策略 |
| 🤖 **Telegram Bot** | 远程查看状态、手动触发备份，实时回显执行进度 |
| 🔄 **完整还原** | 一键恢复所有容器（含 compose 项目 + 数据库 dump + 卷数据） |
| 🌐 **多网络支持** | host / bridge / 自定义 bridge / compose 网络全兼容 |
| ⚙️ **参数全保留** | 还原时完整保留 `--privileged` / `--shm-size` / `--dns` / `--security-opt` / `--cap-drop` / `--init` / HEALTHCHECK / labels / workdir 等 |

---

### 📄 项目文件

| 📄 文件 | 🎯 用途 |
|:---|:---|
| `bf.sh` | 主备份脚本，支持 cron 定时或手动执行 |
| `db_dump.sh` | 数据库自动检测 + 专用安全导出模块 |
| `restore.sh` | 一键恢复脚本（容器 + Compose + 数据库 dump） |
| `tg_bot.py` | Telegram Bot，远程查看状态 / 触发备份 |
| `tg_bot.service` | Bot 的 systemd 服务文件 |
| `install_bot.sh` | Bot 一键部署脚本 |

---

## ⚙️ 一、环境要求

| 项目 | 要求 |
|:---|:---|
| 🖥️ **操作系统** | Ubuntu 20.04+ / Debian 11+ / CentOS 7+ |
| 🐳 **Docker** | 已安装并正常运行（`docker ps` 可执行） |
| 🔑 **权限** | `root` |
| 🔧 **Git** | 已安装 |
| ☁️ **网盘 (可选)** | rclone 已配置 `onedrive` 和 `gdrive` remote |

---

## 🚀 二、部署步骤

### 📥 步骤 1 — 拉取项目

```bash
cd /root
git clone https://github.com/Agff45/vps_docker-bf.git bf
cd /root/bf
chmod +x *.sh
```

---

### 📦 步骤 2 — 安装系统依赖

```bash
apt update && apt install -y jq tar gzip curl
```

> 🔐 **可选：安装 GPG 加密支持**
> 
> ```bash
> apt install -y gnupg
> ```

---

### ☁️ 步骤 3 — 配置 rclone 网盘 (可选)

> 🚨 **重要：rclone remote 名必须固定为 `onedrive` 和 `gdrive`**，脚本通过名称识别网盘。

<details>
<summary><b>📂 点击展开 rclone 配置步骤</b></summary>

```bash
# 安装 rclone
curl https://rclone.org/install.sh | bash

# 交互式配置（remote 名必须填写 onedrive 和 gdrive）
rclone config
```

配置过程中按提示操作：
1. 输入 `n` 新建 remote
2. 名称输入 `onedrive`
3. 类型选择 `onedrive`（OneDrive）或 `drive`（Google Drive）
4. 按提示完成 OAuth 授权

```bash
# 验证配置是否成功
rclone lsd onedrive:
rclone lsd gdrive:
```

</details>

> 💡 **不想用网盘？** 跳过此步骤即可。备份会保存在本地 `VPS_Backups/` 目录，网盘上传步骤会显示失败，不影响本地备份。

---

### 🤖 步骤 4 — 配置 Telegram (可选)

> **两个配置项的区别：**
> - `TG_BOT_TOKEN` / `BOT_TOKEN` — Telegram 机器人的 Token，由 [@BotFather](https://t.me/BotFather) 发放，格式 `123456:ABC-DEF1234gh...`
> - `TG_CHAT_ID` / `ALLOWED_CHAT_ID` — 你个人账户的数字 ID，由 [@userinfobot](https://t.me/userinfobot) 查询，格式 `123456789`
>
> 两者缺一不可：Token 让脚本操控机器人，Chat ID 确保只有你能发命令。

#### 📝 编辑 `bf.sh`

```bash
nano /root/bf/bf.sh
```

找到配置区域，修改以下三行：

```bash
TG_BOT_TOKEN="你的BotToken"
TG_CHAT_ID="你的ChatID"
TG_ENABLED=true                   # 不需要通知就改为 false
```

#### 📝 编辑 `tg_bot.py`

```bash
nano /root/bf/tg_bot.py
```

修改第 16-17 行：

```python
BOT_TOKEN = "你的BotToken"
ALLOWED_CHAT_ID = 你的ChatID
```

> ⚠️ **如果不想用 Telegram 通知和 Bot**，在 `bf.sh` 中把 `TG_ENABLED` 设为 `false`，并且不要执行步骤 9。

---

### 🗄️ 步骤 5 — 数据库备份配置 (可选)

`bf.sh` 默认已启用数据库自动检测。如需关闭：

```bash
# bf.sh 配置区域
DB_DUMP_ENABLED=false   # 设为 false 关闭数据库专用导出
```

#### 支持的数据库类型

| 数据库 | 检测方式 | 导出命令 | 导出文件 |
|:---|:---|:---|:---|
| **MySQL** | 镜像名含 `mysql` | `mysqldump --all-databases --single-transaction --routines --triggers --events` | `容器名_mysqldump_all.sql.gz` |
| **MariaDB** | 镜像名含 `mariadb` | `mysqldump --all-databases --single-transaction` | `容器名_mysqldump_all.sql.gz` |
| **PostgreSQL** | 镜像名含 `postgres` / `postgis` | `pg_dumpall` | `容器名_pgdumpall.sql.gz` |
| **MongoDB** | 镜像名含 `mongo` | `mongodump --archive` | `容器名_mongodump.archive.gz` |

#### 凭证自动提取机制

| 数据库 | 读取的环境变量 |
|:---|:---|
| MySQL | `MYSQL_ROOT_PASSWORD` |
| MariaDB | `MARIADB_ROOT_PASSWORD` |
| PostgreSQL | `POSTGRES_USER` + `POSTGRES_PASSWORD` |
| MongoDB | `MONGO_INITDB_ROOT_USERNAME` + `MONGO_INITDB_ROOT_PASSWORD` |

#### 自动降级策略

如果专用导出失败（容器内缺少客户端工具 / 密码错误 / 无认证 MongoDB 等），脚本自动回退为 **卷数据 tar 打包**，不中断备份。

---

### 🔐 步骤 6 — GPG 加密备份 (可选)

启用后备份文件在上传前使用 **AES256 对称加密**，生成 `.tar.gz.gpg` 文件。

**安装 GPG：**

```bash
apt install -y gnupg
```

**配置 `bf.sh`：**

```bash
ENCRYPT_ENABLED=true              # 开启加密
ENCRYPT_PASSPHRASE="你的加密密码"   # 设置密码（⚠️ 必须设置，空密码会跳过加密）
```

**恢复加密备份：**

```bash
./restore.sh backup.tar.gz.gpg 你的加密密码
```

---

### 🧪 步骤 7 — 测试备份

```bash
/root/bf/bf.sh
```

> ✅ 正常输出流程：`依赖检查` → `容器扫描` → `数据库检测` → `数据导出` → `打包完成` → `网盘上传结果`

**预期输出示例：**

```
[Sun May  3 01:07:37 CST 2026] 🚀 开始 Docker 容器备份...
🔍 检查依赖...
   ✅ 所有依赖就绪
🐳 正在扫描 Docker 容器...
📋 发现 23 个运行中的容器

🕵️ ==== 数据库自动检测 ====
   🔍 检测到数据库: [mysql_main] 类型=mysql
   🔍 检测到数据库: [postgres_main] 类型=postgres
   📊 共检测到 2 个数据库容器

   🩺 对数据库容器 [mysql_main] (mysql) 执行专用导出...
   ✅ [mysql_main] 导出成功: mysql_main_mysqldump_all.sql.gz (876K)
   🩺 对数据库容器 [postgres_main] (postgres) 执行专用导出...
   ✅ [postgres_main] 导出成功: postgres_main_pgdumpall.sql.gz (20K)

   ✅ 数据库专用导出完成: 2/2 个成功

📦 打包备份目录...
   ✅ 打包完成: docker_backup_20260503_010737.tar.gz (2.5M)
🎉 所有任务完成.
```

---

### ⏰ 步骤 8 — 设置定时任务

```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /root/bf/bf.sh >> /var/log/docker_backup.log 2>&1") | crontab -
```

> 📅 默认每天 **凌晨 3 点** 自动执行，可自行修改 cron 表达式。

<details>
<summary><b>📂 Crontab 常用时间参考</b></summary>

| 时间 | 表达式 |
|:---|:---|
| 每天凌晨 2 点 | `0 2 * * *` |
| 每天凌晨 3 点 | `0 3 * * *` |
| 每 6 小时 | `0 */6 * * *` |
| 每周日凌晨 3 点 | `0 3 * * 0` |

</details>

---

### 🔌 步骤 9 — 部署 Telegram Bot (可选)

```bash
/root/bf/install_bot.sh
```

脚本自动完成：
1. 创建 Python 虚拟环境
2. 安装 `python-telegram-bot` 依赖
3. 配置 systemd 服务并设为开机自启

```bash
# Bot 管理命令
systemctl status tg_bot       # 查看运行状态
systemctl restart tg_bot      # 重启 Bot
systemctl stop tg_bot         # 停止 Bot
journalctl -u tg_bot -f       # 实时查看日志
```

---

### ✔️ 步骤 10 — 验证部署

| ✅ 检查项 | 📟 命令 |
|:---|:---|
| 手动备份 | `/root/bf/bf.sh` |
| 查看备份文件 | `ls -lh /root/bf/VPS_Backups/` |
| Bot 状态 | `systemctl status tg_bot` |
| 定时任务 | `crontab -l` |

---

## 🔄 三、恢复备份

### 基本用法

```bash
cd /root/bf

# 恢复未加密备份
./restore.sh VPS_Backups/docker_backup_YYYYMMDD_HHMMSS.tar.gz

# 恢复加密备份
./restore.sh VPS_Backups/docker_backup_YYYYMMDD_HHMMSS.tar.gz.gpg 你的加密密码
```

### 恢复流程 (4 步自动执行)

```
┌─────────────────────────────────────────────────┐
│ 1️⃣  还原 docker-compose 项目                      │
│     · 解压 compose 项目目录                        │
│     · docker compose up -d 启动                   │
│     · 已运行的项目自动跳过                          │
├─────────────────────────────────────────────────┤
│ 2️⃣  还原普通 Docker 容器                           │
│     · 恢复卷数据 (tar)                             │
│     · 还原 SSH 端口映射 / 环境变量 / 网络 / 重启策略   │
│     · 还原 tmpfs / read_only / cap / init / DNS    │
│     · 还原 HEALTHCHECK / labels / workdir          │
│     · 缺失的自定义网络自动创建                       │
├─────────────────────────────────────────────────┤
│ 3️⃣  还原 /home/docker 下的文件                     │
├─────────────────────────────────────────────────┤
│ 4️⃣  还原数据库 dump                                │
│     · 等待数据库就绪（健康检查轮询，最多 60s）           │
│     · zcat dump.gz → mysql / psql / mongorestore  │
└─────────────────────────────────────────────────┘
```

### 恢复时完整保留的 `docker run` 参数

| 参数 | 来源 | 备注 |
|:---|:---|:---|
| `--name` | 容器名 | 原始名称 |
| `-p` | `HostConfig.PortBindings` | TCP/UDP 协议完整保留；host 网络自动跳过 |
| `-e` | `Config.Env` | 含特殊字符（`!@#$%` / 引号 / 换行） |
| `-v` | `Mounts` | bind mount + volume 均支持 |
| `--network` | `HostConfig.NetworkMode` | 缺失网络自动 `docker network create` |
| `--restart` | `HostConfig.RestartPolicy` | 含 `on-failure:N` 重试次数 |
| `--tmpfs` | `HostConfig.Tmpfs` | 保留 size 参数 |
| `--read-only` | `HostConfig.ReadonlyRootfs` | |
| `--cap-drop` / `--cap-add` | `HostConfig.CapDrop` / `CapAdd` | |
| `--init` | `HostConfig.Init` | |
| `--privileged` | `HostConfig.Privileged` | |
| `--shm-size` | `HostConfig.ShmSize` | 字节精确还原 |
| `--dns` | `HostConfig.Dns` | 支持多个 |
| `--security-opt` | `HostConfig.SecurityOpt` | 支持多个 |
| `--health-cmd` / `--health-interval` / `--health-timeout` / `--health-retries` | `Config.Healthcheck` | 纳秒自动转秒 |
| `--label` | `Config.Labels` | 自动跳过 `com.docker.*` 内部标签 |
| `--workdir` | `Config.WorkingDir` | |
| `IMAGE [CMD...]` | `Config.Image` + `Config.Cmd` | 保留原始启动命令 |

> 🛡️ 已运行的容器及 Compose 项目会**自动跳过**，不会重复创建。

---

## 📋 四、完整配置参考

### `bf.sh` 全部配置项

```bash
# ================= 配置区域 =================
# --- 本地设置 ---
BACKUP_DIR="/root/bf/VPS_Backups"         # 本地备份存放目录
LOCAL_KEEP_COUNT=1                        # 本地保留最近 N 份

# --- 网盘 1: OneDrive ---
REMOTE1_NAME="onedrive"                   # rclone remote 名称
REMOTE1_DIR="VPS_Backups/Docker"          # 远程目标目录

# --- 网盘 2: Google Drive ---
REMOTE2_NAME="gdrive"                     # rclone remote 名称
REMOTE2_DIR="VPS_Backups/Docker"          # 远程目标目录
REMOTE_KEEP_COUNT=4                       # 网盘各保留最近 N 份

# --- Telegram ---
TG_BOT_TOKEN="你的BotToken"               # Bot Token
TG_CHAT_ID="你的ChatID"                   # 你的 Chat ID
TG_ENABLED=true                           # 是否启用通知

# --- 数据库专用导出 ---
DB_DUMP_ENABLED=true                      # 是否启用数据库自动检测

# --- GPG 加密 ---
ENCRYPT_ENABLED=false                     # 是否启用加密
ENCRYPT_PASSPHRASE=""                     # 加密密码（留空不加密）
```

### `tg_bot.py` 配置项

```python
BOT_TOKEN = "你的BotToken"
ALLOWED_CHAT_ID = 你的ChatID
```

---

## 💬 五、Telegram Bot 命令

| 🎮 命令 | 🧩 功能 | 说明 |
|:---|:---|:---|
| `/start` | 欢迎消息 | 显示可用命令列表 |
| `/status` | 查看备份状态 | 最近一次备份的完整统计（容器数 / DB 导出数 / 文件大小 / 上传状态） |
| `/run` | 手动触发备份 | 实时回显 bf.sh 执行进度 |
| `/help` | 帮助信息 | 命令说明 |

---

## 📁 六、VPS 目录结构

```
/root/bf/
├── 📜 bf.sh                        # 主备份脚本
├── 📜 db_dump.sh                  # 数据库检测 + 导出模块
├── 📜 restore.sh                  # 一键恢复脚本
├── 📜 tg_bot.py                   # Telegram Bot 脚本
├── 📜 tg_bot.service              # systemd 服务文件
├── 📜 install_bot.sh              # Bot 一键部署脚本
├── 📜 README.md                   # 本文档
├── 📜 .gitignore                  # Git 忽略规则
├── 📁 venv/                       # Python 虚拟环境 (install_bot.sh 创建)
├── 📄 backup_status.json          # 最近一次备份状态 JSON
└── 📁 VPS_Backups/                # 本地备份存放目录
    └── 📦 docker_backup_*.tar.gz  # 备份文件（本地保留最新 N 份）
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
<summary><b>📂 删除项目文件</b></summary>

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

> ⚡ **一键卸载（复制整段到终端执行）：**

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

<details>
<summary><b>🌐 Q: git clone 失败（国内服务器）？</b></summary>

```bash
# 方式一：使用镜像站
git clone https://ghproxy.com/https://github.com/Agff45/vps_docker-bf.git bf

# 方式二：使用代理
git config --global http.proxy http://127.0.0.1:端口
git config --global https.proxy http://127.0.0.1:端口
git clone https://github.com/Agff45/vps_docker-bf.git bf
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
journalctl -u tg_bot -n 50       # 查看错误日志
systemctl restart tg_bot          # 重试启动
```
> 常见原因：Token 错误、网络不通、Python 依赖未安装。
</details>

<br>

<details>
<summary><b>🐳 Q: 恢复时容器启动失败？</b></summary>

一般为镜像未拉取或网络不存在，手动处理后重试：

```bash
docker pull <镜像名>
docker network create <网络名>     # 如果 restore.sh 未能自动创建
./restore.sh <备份文件>
```
</details>

<br>

<details>
<summary><b>🗄️ Q: 数据库导出失败怎么办？</b></summary>

备份日志中会显示 `⚠️ [容器名] 导出失败，将回退到卷打包方式` 以及 `🔍 错误详情`。

常见原因和解决方案：

| 症状 | 原因 | 解决 |
|:---|:---|:---|
| `mysqldump: command not found` | 精简镜像不含客户端 | 回退卷打包，或换用完整镜像 |
| 密码为空导出失败 | 环境变量缺失 | 回退卷打包 |
| pg_dumpall 报权限错误 | 非超级用户 | 回退卷打包 |
| MongoDB 无认证导出失败 | 不支持空密码场景 | 回退卷打包 |
</details>

<br>

<details>
<summary><b>🔐 Q: GPG 加密提示 "未设置密码，跳过加密"？</b></summary>

`ENCRYPT_ENABLED=true` 但没有设置 `ENCRYPT_PASSPHRASE`。设置密码即可：

```bash
nano /root/bf/bf.sh
# 修改: ENCRYPT_PASSPHRASE="你的密码"
```
</details>

<br>

<details>
<summary><b>🌐 Q: 自定义网络容器恢复后网络不存在？</b></summary>

`restore.sh` 已自动处理此场景 — 恢复时会检测网络是否存在，不存在则自动 `docker network create`。

如果还是失败，手动创建即可：

```bash
docker network create <网络名>
```
</details>

---

<br>

<p align="center">
  Made with ❤️ for VPS & Docker users
</p>
