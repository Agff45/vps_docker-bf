#!/bin/bash

# ================= 配置区域 =================
# --- 本地设置 ---
BACKUP_DIR="/root/bf/VPS_Backups"

# --- 网盘 1: OneDrive (rclone remote) ---
REMOTE1_NAME="onedrive"
REMOTE1_DIR="VPS_Backups/Docker"

# --- 网盘 2: Google Drive (rclone remote) ---
REMOTE2_NAME="gdrive"
REMOTE2_DIR="VPS_Backups/Docker"

# --- 本地保留数量 ---
LOCAL_KEEP_COUNT=1

# --- 网盘保留数量 ---
REMOTE_KEEP_COUNT=4

# --- Telegram 配置 ---
TG_BOT_TOKEN="你的BotToken"
TG_CHAT_ID="你的ChatID"
TG_ENABLED=true

# --- 状态文件路径 ---
STATUS_FILE="/root/bf/backup_status.json"

# --- 数据库专用导出 ---
DB_DUMP_ENABLED=true

# --- 备份加密 (GPG 对称加密) ---
ENCRYPT_ENABLED=false
ENCRYPT_PASSPHRASE=""   # 留空则从 ENCRYPT_PASSPHRASE_FILE 读取

# --- rclone 配置 (解决 cron 环境问题) ---
export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
# ===========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/db_dump.sh"

DATE_STR=$(date "+%Y%m%d_%H%M%S")
BACKUP_FILE="docker_backup_$DATE_STR.tar.gz"
FULL_PATH="$BACKUP_DIR/$BACKUP_FILE"
DOCKER_BACKUP_WORK="/tmp/docker_backup_work_$DATE_STR"

START_TIME=$(date +%s)

TOTAL_CONTAINERS=0
COMPOSE_COUNT=0
NORMAL_COUNT=0
SKIPPED_COUNT=0
DB_COUNT=0
declare -A DB_PROCESSED

send_telegram() {
    local message="$1"
    if [ "$TG_ENABLED" = true ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=HTML" > /dev/null 2>&1
    fi
}

save_status() {
    local status="$1"
    local message="$2"
    local file_size="$3"
    local duration="$4"
    local remote1_status="$5"
    local remote2_status="$6"
    local total="$7"
    local compose="$8"
    local normal="$9"
    local skipped="${10}"
    local db_count="${11}"
    
    cat > "$STATUS_FILE" << EOF
{
    "last_run": "$(date '+%Y-%m-%d %H:%M:%S')",
    "status": "$status",
    "message": "$message",
    "file_name": "$BACKUP_FILE",
    "file_size": "$file_size",
    "duration_seconds": $duration,
    "containers_total": "$total",
    "containers_compose": "$compose",
    "containers_normal": "$normal",
    "containers_skipped": "$skipped",
    "db_count": "$db_count",
    "remote1_name": "onedrive",
    "remote1_status": "$remote1_status",
    "remote2_name": "$REMOTE2_NAME",
    "remote2_status": "$remote2_status"
}
EOF
}

process_remote() {
    local REMOTE_NAME=$1
    local REMOTE_DIR=$2
    local FILE_PATH=$3
    
    echo "---------------------------------"
    echo "☁️ 正在处理: $REMOTE_NAME ..."
    
    rclone copy "$FILE_PATH" "$REMOTE_NAME:$REMOTE_DIR"
    
    if [ $? -eq 0 ]; then
        echo "   ✅ 上传成功"
        echo "   🧹 检查旧备份，只保留最新的 $REMOTE_KEEP_COUNT 个..."
        
        OLD_FILES=$(rclone lsf "$REMOTE_NAME:$REMOTE_DIR" --files-only -F tp | sort -r | cut -d';' -f2 | tail -n +$(($REMOTE_KEEP_COUNT + 1)))
        
        if [ -z "$OLD_FILES" ]; then
             echo "      (没有需要删除的旧文件)"
        else
             SAVEIFS=$IFS
             IFS=$'\n'
             for old_file in $OLD_FILES; do
                 echo "      🗑️ 删除旧文件: $old_file"
                 rclone deletefile "$REMOTE_NAME:$REMOTE_DIR/$old_file"
             done
             IFS=$SAVEIFS
        fi
        return 0
    else
        echo "   ❌ 上传失败"
        return 1
    fi
}

check_dependency() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺少依赖: $cmd (请安装 $pkg)"
        return 1
    fi
    return 0
}

is_compose_container() {
    local container=$1
    docker inspect "$container" 2>/dev/null | jq -e '.[0].Config.Labels["com.docker.compose.project"]' >/dev/null 2>&1
}

backup_docker() {
    echo "🐳 正在扫描 Docker 容器..."

    local TARGET_CONTAINERS=()
    mapfile -t TARGET_CONTAINERS < <(docker ps --format '{{.Names}}')

    if [ ${#TARGET_CONTAINERS[@]} -eq 0 ]; then
        echo "⚠️ 没有运行中的 Docker 容器，跳过备份"
        return 2
    fi

    TOTAL_CONTAINERS=${#TARGET_CONTAINERS[@]}
    echo "📋 发现 $TOTAL_CONTAINERS 个运行中的容器: ${TARGET_CONTAINERS[*]}"

    mkdir -p "$DOCKER_BACKUP_WORK"

    # ---- 数据库自动检测与专用导出 ----
    if [ "$DB_DUMP_ENABLED" = true ]; then
        local db_result
        db_result=$(process_all_databases "$DOCKER_BACKUP_WORK")
        DB_COUNT=$(echo "$db_result" | tail -1)
        # 读取已处理的数据库容器列表
        if [ -d "${DOCKER_BACKUP_WORK}/db_processed" ]; then
            for db_file in "${DOCKER_BACKUP_WORK}/db_processed"/*; do
                [ -f "$db_file" ] || continue
                local c_name
                c_name=$(basename "$db_file")
                DB_PROCESSED["$c_name"]=1
            done
        fi
    fi
    # ------------------------------------

    local RESTORE_SCRIPT="${DOCKER_BACKUP_WORK}/docker_restore.sh"
    echo "#!/bin/bash" > "$RESTORE_SCRIPT"
    echo "set -e" >> "$RESTORE_SCRIPT"
    echo "# 自动生成的 Docker 还原脚本 - $(date)" >> "$RESTORE_SCRIPT"

    declare -A PACKED_COMPOSE_PATHS=()

    for c in "${TARGET_CONTAINERS[@]}"; do
        echo "----------------------------------------"
        echo "📦 备份容器: $c"

        local inspect_file="${DOCKER_BACKUP_WORK}/${c}_inspect.json"
        docker inspect "$c" > "$inspect_file" 2>/dev/null

        if is_compose_container "$c"; then
            echo "   🔍 检测到 $c 是 docker-compose 容器"

            local project_dir=$(docker inspect "$c" 2>/dev/null | jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty')
            local project_name=$(docker inspect "$c" 2>/dev/null | jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty')

            if [ -z "$project_dir" ]; then
                echo "   ⚠️ 未检测到 compose 目录，跳过容器 [$c]"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                rm -f "$inspect_file"
                continue
            fi

            if [[ -n "${PACKED_COMPOSE_PATHS[$project_dir]}" ]]; then
                echo "   ⏭️ Compose 项目 [$project_name] 已备份过，跳过重复打包"
                rm -f "$inspect_file"
                continue
            fi

            if [ -f "$project_dir/docker-compose.yml" ]; then
                echo "compose" > "${DOCKER_BACKUP_WORK}/backup_type_${project_name}"
                echo "$project_dir" > "${DOCKER_BACKUP_WORK}/compose_path_${project_name}.txt"
                tar -czf "${DOCKER_BACKUP_WORK}/compose_project_${project_name}.tar.gz" -C "$project_dir" . 2>/dev/null

                echo "# docker-compose 恢复: $project_name" >> "$RESTORE_SCRIPT"
                echo "cd \"$project_dir\" && docker compose up -d" >> "$RESTORE_SCRIPT"

                PACKED_COMPOSE_PATHS["$project_dir"]=1
                COMPOSE_COUNT=$((COMPOSE_COUNT + 1))
                echo "   ✅ Compose 项目 [$project_name] 已打包: $project_dir"
            else
                echo "   ⚠️ 未找到 docker-compose.yml，跳过容器 [$c]"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                rm -f "$inspect_file"
                continue
            fi

            rm -f "$inspect_file"
        else
            # 检查是否已被数据库模块处理
            if [ -n "${DB_PROCESSED[$c]}" ]; then
                echo "   🗄️ 数据库容器 [$c] 已通过专用导出处理，跳过卷打包"

                local IMAGE
                IMAGE=$(jq -r '.[0].Config.Image' "$inspect_file" 2>/dev/null)

                local PORT_ARGS=""
                mapfile -t PORTS < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "\(.value[0].HostPort):\(.key)"' "$inspect_file" 2>/dev/null)
                for p in "${PORTS[@]}"; do PORT_ARGS+="-p $p "; done

                local ENV_VARS=""
                mapfile -t ENVS < <(jq -r '.[0].Config.Env[] | @sh' "$inspect_file" 2>/dev/null)
                for e in "${ENVS[@]}"; do ENV_VARS+="-e $e "; done

                local VOL_ARGS=""
                mapfile -t VOL_MOUNTS < <(jq -r '.[0].Mounts[]? | "\(.Source):\(.Destination)"' "$inspect_file" 2>/dev/null)
                for vm in "${VOL_MOUNTS[@]}"; do VOL_ARGS+="-v $vm "; done

                local NETWORK_MODE
                NETWORK_MODE=$(jq -r '.[0].HostConfig.NetworkMode // "default"' "$inspect_file" 2>/dev/null)
                local NETWORK_ARG=""
                if [ "$NETWORK_MODE" != "default" ] && [ "$NETWORK_MODE" != "bridge" ] && [ -n "$NETWORK_MODE" ] && [ "$NETWORK_MODE" != "null" ]; then
                    NETWORK_ARG="--network $NETWORK_MODE"
                fi

                local RESTART_POLICY
                RESTART_POLICY=$(jq -r '.[0].HostConfig.RestartPolicy.Name // "no"' "$inspect_file" 2>/dev/null)
                local RESTART_ARG=""
                if [ "$RESTART_POLICY" != "no" ] && [ "$RESTART_POLICY" != "null" ] && [ -n "$RESTART_POLICY" ]; then
                    RESTART_ARG="--restart $RESTART_POLICY"
                fi

                echo "" >> "$RESTORE_SCRIPT"
                echo "# 还原数据库容器: $c" >> "$RESTORE_SCRIPT"
                echo "docker run -d --name $c $RESTART_ARG $NETWORK_ARG $PORT_ARGS $VOL_ARGS $ENV_VARS $IMAGE" >> "$RESTORE_SCRIPT"
                echo "# ⚠️ 数据库 [$c] 启动后，请使用 restore.sh 或手动导入 dump 文件" >> "$RESTORE_SCRIPT"

                NORMAL_COUNT=$((NORMAL_COUNT + 1))
                echo "   ✅ 数据库容器 [$c] 已记录，镜像: $IMAGE"
                continue
            fi

            echo "   📦 普通容器，导出卷数据与运行参数..."

            local VOL_PATHS
            VOL_PATHS=$(docker inspect "$c" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null)

            for path in $VOL_PATHS; do
                if [ -d "$path" ] || [ -f "$path" ]; then
                    echo "      打包卷: $path"
                    tar -czpf "${DOCKER_BACKUP_WORK}/${c}_$(basename "$path").tar.gz" -C / "$(echo "$path" | sed 's/^\///')" 2>/dev/null
                fi
            done

            local PORT_ARGS=""
            mapfile -t PORTS < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "\(.value[0].HostPort):\(.key)"' "$inspect_file" 2>/dev/null)
            for p in "${PORTS[@]}"; do PORT_ARGS+="-p $p "; done

            local ENV_VARS=""
            mapfile -t ENVS < <(jq -r '.[0].Config.Env[] | @sh' "$inspect_file" 2>/dev/null)
            for e in "${ENVS[@]}"; do ENV_VARS+="-e $e "; done

            local VOL_ARGS=""
            mapfile -t VOL_MOUNTS < <(jq -r '.[0].Mounts[]? | "\(.Source):\(.Destination)"' "$inspect_file" 2>/dev/null)
            for vm in "${VOL_MOUNTS[@]}"; do VOL_ARGS+="-v $vm "; done

            local NETWORK_MODE
            NETWORK_MODE=$(jq -r '.[0].HostConfig.NetworkMode // "default"' "$inspect_file" 2>/dev/null)
            local NETWORK_ARG=""
            if [ "$NETWORK_MODE" != "default" ] && [ "$NETWORK_MODE" != "bridge" ] && [ -n "$NETWORK_MODE" ] && [ "$NETWORK_MODE" != "null" ]; then
                NETWORK_ARG="--network $NETWORK_MODE"
            fi

            local RESTART_POLICY
            RESTART_POLICY=$(jq -r '.[0].HostConfig.RestartPolicy.Name // "no"' "$inspect_file" 2>/dev/null)
            local RESTART_ARG=""
            if [ "$RESTART_POLICY" != "no" ] && [ "$RESTART_POLICY" != "null" ] && [ -n "$RESTART_POLICY" ]; then
                RESTART_ARG="--restart $RESTART_POLICY"
            fi

            local IMAGE
            IMAGE=$(jq -r '.[0].Config.Image' "$inspect_file" 2>/dev/null)

            echo "" >> "$RESTORE_SCRIPT"
            echo "# 还原容器: $c" >> "$RESTORE_SCRIPT"
            echo "docker run -d --name $c $RESTART_ARG $NETWORK_ARG $PORT_ARGS $VOL_ARGS $ENV_VARS $IMAGE" >> "$RESTORE_SCRIPT"

            NORMAL_COUNT=$((NORMAL_COUNT + 1))
            echo "   ✅ 普通容器 [$c] 备份完成，镜像: $IMAGE"
        fi
    done

    if [ -d "/home/docker" ]; then
        echo "----------------------------------------"
        echo "📂 备份 /home/docker 下的文件..."
        find /home/docker -maxdepth 1 -type f | tar -czf "${DOCKER_BACKUP_WORK}/home_docker_files.tar.gz" -T - 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "   ✅ /home/docker 下的文件已打包"
        else
            echo "   ⚠️ /home/docker 下无文件或打包失败"
        fi
    fi

    chmod +x "$RESTORE_SCRIPT"
    echo "   ✅ 还原脚本已生成: $RESTORE_SCRIPT"

    echo ""
    echo "📊 备份统计: 总计 $TOTAL_CONTAINERS 个容器 | Compose: $COMPOSE_COUNT | 普通: $NORMAL_COUNT | 跳过: $SKIPPED_COUNT | DB导出: $DB_COUNT"

    return 0
}

mkdir -p "$BACKUP_DIR"
echo "[$(date)] 🚀 开始 Docker 容器备份..."

REMOTE1_STATUS="pending"
REMOTE2_STATUS="pending"

echo "🔍 检查依赖..."
MISSING_DEPS=""
check_dependency "docker" "docker" || MISSING_DEPS="$MISSING_DEPS docker"
check_dependency "tar" "tar" || MISSING_DEPS="$MISSING_DEPS tar"
check_dependency "jq" "jq" || MISSING_DEPS="$MISSING_DEPS jq"
check_dependency "gzip" "gzip" || MISSING_DEPS="$MISSING_DEPS gzip"
check_dependency "rclone" "rclone" || MISSING_DEPS="$MISSING_DEPS rclone"

if [ -n "$MISSING_DEPS" ]; then
    echo "❌ 缺少必要依赖:$MISSING_DEPS"
    TG_MSG="❌ <b>Docker 备份失败</b>

📅 时间: $(date '+%Y-%m-%d %H:%M:%S')
🚫 原因: 缺少依赖:$MISSING_DEPS"
    send_telegram "$TG_MSG"
    exit 1
fi
echo "   ✅ 所有依赖就绪"

backup_docker
BACKUP_RESULT=$?

if [ $BACKUP_RESULT -eq 2 ]; then
    echo "⚪ 没有运行中的容器，跳过备份"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    save_status "skipped" "无运行中的容器" "0" "$DURATION" "skipped" "skipped" "0" "0" "0" "0" "$DB_COUNT"

    TG_MSG="⚪ <b>Docker 备份跳过</b>

📅 时间: $(date '+%Y-%m-%d %H:%M:%S')
📝 原因: 没有运行中的容器"

    send_telegram "$TG_MSG"
    rm -rf "$DOCKER_BACKUP_WORK"
    exit 0
fi

echo "========================================"
echo "📦 正在打包备份目录..."

tar -czf "$FULL_PATH" -C /tmp "$(basename "$DOCKER_BACKUP_WORK")" 2>/dev/null

if [ $? -ne 0 ] || [ ! -s "$FULL_PATH" ]; then
    echo "❌ 打包失败!"
    rm -rf "$DOCKER_BACKUP_WORK"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    save_status "failed" "打包失败" "0" "$DURATION" "skipped" "skipped" "$TOTAL_CONTAINERS" "$COMPOSE_COUNT" "$NORMAL_COUNT" "$SKIPPED_COUNT" "$DB_COUNT"

    TG_MSG="❌ <b>Docker 备份失败</b>

📅 时间: $(date '+%Y-%m-%d %H:%M:%S')
🚫 原因: 打包成 tar.gz 失败
📊 统计: 总计 $TOTAL_CONTAINERS | Compose: $COMPOSE_COUNT | 普通: $NORMAL_COUNT | 跳过: $SKIPPED_COUNT | DB导出: $DB_COUNT"

    send_telegram "$TG_MSG"
    exit 1
fi

FILE_SIZE=$(du -h "$FULL_PATH" | cut -f1)
echo "   ✅ 打包完成: $FULL_PATH ($FILE_SIZE)"

# ---- GPG 加密 (可选) ----
UPLOAD_PATH="$FULL_PATH"
if [ "$ENCRYPT_ENABLED" = true ]; then
    passphrase="$ENCRYPT_PASSPHRASE"
    echo "🔐 正在加密备份文件..."

    if command -v gpg &>/dev/null; then
        if [ -z "$passphrase" ]; then
            echo "   ⚠️ 未设置 ENCRYPT_PASSPHRASE，跳过加密"

        elif [ -n "$passphrase" ]; then
            gpg --batch --yes --passphrase "$passphrase" --symmetric --cipher-algo AES256 "$FULL_PATH" 2>/dev/null
        fi

        if [ $? -eq 0 ] && [ -f "${FULL_PATH}.gpg" ]; then
            rm -f "$FULL_PATH"
            UPLOAD_PATH="${FULL_PATH}.gpg"
            BACKUP_FILE="${BACKUP_FILE}.gpg"
            FILE_SIZE=$(du -h "$UPLOAD_PATH" | cut -f1)
            echo "   ✅ 加密完成: $UPLOAD_PATH ($FILE_SIZE)"
        else
            echo "   ⚠️ GPG 加密失败，使用未加密文件"
        fi
    else
        echo "   ⚠️ 未安装 gpg，请执行: apt install -y gnupg"
    fi
fi
# -----------------------

rm -rf "$DOCKER_BACKUP_WORK"

if process_remote "$REMOTE1_NAME" "$REMOTE1_DIR" "$UPLOAD_PATH"; then
    REMOTE1_STATUS="success"
else
    REMOTE1_STATUS="failed"
fi

if process_remote "$REMOTE2_NAME" "$REMOTE2_DIR" "$UPLOAD_PATH"; then
    REMOTE2_STATUS="success"
else
    REMOTE2_STATUS="failed"
fi

echo "---------------------------------"
echo "🧹 清理本地旧备份..."
OLD_LOCAL=$(ls -1t "$BACKUP_DIR"/docker_backup_*.tar.gz "$BACKUP_DIR"/docker_backup_*.tar.gz.gpg 2>/dev/null | tail -n +$(($LOCAL_KEEP_COUNT + 1)))
if [ -n "$OLD_LOCAL" ]; then
    echo "$OLD_LOCAL" | while read old_file; do
        echo "   🗑️ 删除旧备份: $(basename "$old_file")"
        rm -f "$old_file"
    done
else
    echo "   (没有需要删除的本地旧备份)"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

save_status "success" "备份完成" "$FILE_SIZE" "$DURATION" "$REMOTE1_STATUS" "$REMOTE2_STATUS" "$TOTAL_CONTAINERS" "$COMPOSE_COUNT" "$NORMAL_COUNT" "$SKIPPED_COUNT" "$DB_COUNT"

TG_MSG="🎉 <b>Docker 备份完成</b>

📅 时间: $(date '+%Y-%m-%d %H:%M:%S')
📦 文件: <code>$BACKUP_FILE</code>
📊 大小: $FILE_SIZE
⏱️ 耗时: ${DURATION_MIN}分${DURATION_SEC}秒

🐳 <b>容器统计:</b>
• 总计: $TOTAL_CONTAINERS 个
• Compose: $COMPOSE_COUNT 个
• 普通: $NORMAL_COUNT 个
• 跳过: $SKIPPED_COUNT 个
🗄️ <b>数据库导出:</b> $DB_COUNT 个

☁️ <b>上传状态:</b>
• onedrive (rclone): $([ "$REMOTE1_STATUS" = "success" ] && echo "✅ 成功" || echo "❌ 失败")
• $REMOTE2_NAME: $([ "$REMOTE2_STATUS" = "success" ] && echo "✅ 成功" || echo "❌ 失败")"

send_telegram "$TG_MSG"

echo "[$(date)] 🎉 所有任务完成."
