#!/bin/bash
# ================================================
# Docker 备份恢复脚本
# 用法: ./restore.sh <备份文件.tar.gz>
# ================================================

set -e

BACKUP_FILE="$1"
[ -z "$BACKUP_FILE" ] && { echo "用法: $0 <备份文件.tar.gz | 备份文件.tar.gz.gpg> [GPG密码]"; echo "示例: $0 /root/bf/VPS_Backups/docker_backup_20260502_120000.tar.gz"; echo "加密文件: $0 backup.tar.gz.gpg mypassword"; exit 1; }
[ ! -f "$BACKUP_FILE" ] && { echo "❌ 文件不存在: $BACKUP_FILE"; exit 1; }

GPG_PASSPHRASE="${2:-}"

echo "📦 Docker 备份恢复工具"
echo "备份文件: $BACKUP_FILE"

for cmd in docker tar jq gzip; do
    command -v "$cmd" &>/dev/null || { echo "❌ 缺少依赖: $cmd"; exit 1; }
done
echo "✅ 依赖就绪"

# ---- GPG 解密 ----
RESTORE_TAR="$BACKUP_FILE"
IS_ENCRYPTED=false
if echo "$BACKUP_FILE" | grep -q '\.gpg$'; then
    IS_ENCRYPTED=true
    if ! command -v gpg &>/dev/null; then
        echo "❌ 缺少依赖: gpg (请 apt install -y gnupg)"
        exit 1
    fi
    RESTORE_TAR="${BACKUP_FILE%.gpg}"
    echo "🔓 正在解密备份文件..."
    if [ -n "$GPG_PASSPHRASE" ]; then
        gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --decrypt -o "$RESTORE_TAR" "$BACKUP_FILE" 2>/dev/null
    else
        gpg --batch --yes --decrypt -o "$RESTORE_TAR" "$BACKUP_FILE" 2>/dev/null
    fi
    if [ $? -ne 0 ] || [ ! -f "$RESTORE_TAR" ]; then
        echo "❌ 解密失败，请检查密码是否正确"
        exit 1
    fi
    echo "   ✅ 解密成功: $RESTORE_TAR"
fi
# -----------------

WORK_DIR="/tmp/docker_restore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORK_DIR"
echo "📂 解压到: $WORK_DIR"
tar -xzf "$RESTORE_TAR" -C "$WORK_DIR"

DATA_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d ! -name "$(basename "$WORK_DIR")" | head -1)
[ -z "$DATA_DIR" ] && DATA_DIR="$WORK_DIR"

COMPOSE_RESTORED=0
NORMAL_RESTORED=0

echo ""
echo "🐳 步骤 1: 还原 docker-compose 项目"
for type_file in "$DATA_DIR"/backup_type_*; do
    [ ! -f "$type_file" ] && continue
    grep -q "compose" "$type_file" || continue
    project_name=$(basename "$type_file" | sed 's/backup_type_//')
    path_file="$DATA_DIR/compose_path_${project_name}.txt"
    tar_file="$DATA_DIR/compose_project_${project_name}.tar.gz"
    [ ! -f "$tar_file" ] && { echo "⚠️ 未找到 $project_name 数据，跳过"; continue; }
    original_path=""
    [ -f "$path_file" ] && original_path=$(cat "$path_file")
    [ -z "$original_path" ] && read -e -p "   Compose [$project_name] 恢复目录: " original_path
    running_count=$(docker ps --filter "label=com.docker.compose.project=$project_name" --format '{{.Names}}' 2>/dev/null | wc -l)
    [ "$running_count" -gt 0 ] && { echo "⏭️  [$project_name] 已在运行"; continue; }
    read -e -p "   确认恢复 [$project_name] ? (y/n): " confirm
    [ "$confirm" != "y" ] && continue
    mkdir -p "$original_path"
    tar -xzf "$tar_file" -C "$original_path"
    cd "$original_path" || continue
    docker compose down --remove-orphans 2>/dev/null || true
    docker compose up -d
    echo "   ✅ [$project_name] 已启动"
    COMPOSE_RESTORED=$((COMPOSE_RESTORED + 1))
done

echo ""
echo "🐳 步骤 2: 还原普通 Docker 容器"
for json in "$DATA_DIR"/*_inspect.json; do
    [ ! -f "$json" ] && continue
    container=$(basename "$json" | sed 's/_inspect.json//')
    echo ""
    echo "📦 处理: $container"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" && { echo "   ⏭️ 已在运行"; continue; }
    IMAGE=$(jq -r '.[0].Config.Image' "$json" 2>/dev/null)
    [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ] && { echo "   ⚠️ 无法获取镜像"; continue; }
    echo "   镜像: $IMAGE"

    NETWORK_MODE=$(jq -r '.[0].HostConfig.NetworkMode // ""' "$json" 2>/dev/null)

    RUN_ARGS=(-d --name "$container")

    if [ "$NETWORK_MODE" != "host" ]; then
        while IFS= read -r port; do
            [ -n "$port" ] && RUN_ARGS+=(-p "$port")
        done < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "\(.value[0].HostPort):\(.key)"' "$json" 2>/dev/null)
    else
        echo "   ⚠️ host 网络，跳过端口映射"
    fi

    while IFS= read -r env; do
        [ -n "$env" ] && RUN_ARGS+=(-e "$env")
    done < <(jq -r '.[0].Config.Env[]' "$json" 2>/dev/null)

    while IFS= read -r vol; do
        VOL_SRC=$(echo "$vol" | cut -d':' -f1)
        VOL_DST=$(echo "$vol" | cut -d':' -f2)
        if [ ! -e "$VOL_SRC" ]; then
            mkdir -p "$VOL_SRC"
            VOL_FILE="$DATA_DIR/${container}_$(basename "$VOL_SRC").tar.gz"
            if [ -f "$VOL_FILE" ]; then
                echo "   恢复卷: $VOL_SRC"
                tar -xzf "$VOL_FILE" -C /
            fi
        fi
        RUN_ARGS+=(-v "$VOL_SRC:$VOL_DST")
    done < <(jq -r '.[0].Mounts[] | "\(.Source):\(.Destination)"' "$json" 2>/dev/null)

    NETWORK_ARG=""
    if [ -n "$NETWORK_MODE" ] && [ "$NETWORK_MODE" != "default" ] && [ "$NETWORK_MODE" != "bridge" ] && [ "$NETWORK_MODE" != "null" ]; then
        if [ "$NETWORK_MODE" = "host" ]; then
            NETWORK_ARG="--network host"
            echo "   网络: host"
        else
            docker network inspect "$NETWORK_MODE" &>/dev/null || {
                echo "   🔧 创建网络: $NETWORK_MODE"
                docker network create "$NETWORK_MODE" &>/dev/null
            }
            NETWORK_ARG="--network $NETWORK_MODE"
            echo "   网络: $NETWORK_MODE"
        fi
    fi
    [ -n "$NETWORK_ARG" ] && RUN_ARGS+=($NETWORK_ARG)

    RESTART_POLICY=$(jq -r '.[0].HostConfig.RestartPolicy.Name // ""' "$json" 2>/dev/null)
    if [ -n "$RESTART_POLICY" ] && [ "$RESTART_POLICY" != "no" ] && [ "$RESTART_POLICY" != "null" ]; then
        MAX_RETRY=$(jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0' "$json" 2>/dev/null)
        if [ "$MAX_RETRY" != "0" ] && [ "$MAX_RETRY" != "null" ]; then
            RUN_ARGS+=(--restart "${RESTART_POLICY}:${MAX_RETRY}")
        else
            RUN_ARGS+=(--restart "$RESTART_POLICY")
        fi
    fi

    while IFS= read -r line; do
        [ -n "$line" ] && RUN_ARGS+=(--tmpfs "$line")
    done < <(jq -r '.[0].HostConfig.Tmpfs | to_entries[]? | "\(.key):\(.value)"' "$json" 2>/dev/null)

    READONLY=$(jq -r '.[0].HostConfig.ReadonlyRootfs // false' "$json" 2>/dev/null)
    [ "$READONLY" = "true" ] && RUN_ARGS+=(--read-only)

    while IFS= read -r cap; do
        [ -n "$cap" ] && RUN_ARGS+=(--cap-drop="$cap")
    done < <(jq -r '.[0].HostConfig.CapDrop[]?' "$json" 2>/dev/null)

    while IFS= read -r cap; do
        [ -n "$cap" ] && RUN_ARGS+=(--cap-add="$cap")
    done < <(jq -r '.[0].HostConfig.CapAdd[]?' "$json" 2>/dev/null)

    INIT=$(jq -r '.[0].HostConfig.Init // false' "$json" 2>/dev/null)
    [ "$INIT" = "true" ] && RUN_ARGS+=(--init)

    PRIVILEGED=$(jq -r '.[0].HostConfig.Privileged // false' "$json" 2>/dev/null)
    [ "$PRIVILEGED" = "true" ] && RUN_ARGS+=(--privileged)

    SHM_SIZE=$(jq -r '.[0].HostConfig.ShmSize // 0' "$json" 2>/dev/null)
    [ "$SHM_SIZE" != "0" ] && [ "$SHM_SIZE" != "null" ] && RUN_ARGS+=(--shm-size "$SHM_SIZE")

    while IFS= read -r dns; do
        [ -n "$dns" ] && RUN_ARGS+=(--dns "$dns")
    done < <(jq -r '.[0].HostConfig.Dns[]?' "$json" 2>/dev/null)

    while IFS= read -r sec; do
        [ -n "$sec" ] && RUN_ARGS+=(--security-opt "$sec")
    done < <(jq -r '.[0].HostConfig.SecurityOpt[]?' "$json" 2>/dev/null)

    HC_CMD=$(jq -c '[.[0].Config.Healthcheck.Test[]? | select(. != "NONE")]' "$json" 2>/dev/null)
    if [ -n "$HC_CMD" ]; then
        RUN_ARGS+=(--health-cmd "$HC_CMD")
    fi
    HC_INTERVAL=$(jq -r '.[0].Config.Healthcheck.Interval // 0' "$json" 2>/dev/null)
    [ "$HC_INTERVAL" != "0" ] && [ "$HC_INTERVAL" != "null" ] && RUN_ARGS+=(--health-interval "$(( HC_INTERVAL / 1000000000 ))s")
    HC_TIMEOUT=$(jq -r '.[0].Config.Healthcheck.Timeout // 0' "$json" 2>/dev/null)
    [ "$HC_TIMEOUT" != "0" ] && [ "$HC_TIMEOUT" != "null" ] && RUN_ARGS+=(--health-timeout "$(( HC_TIMEOUT / 1000000000 ))s")
    HC_RETRIES=$(jq -r '.[0].Config.Healthcheck.Retries // 0' "$json" 2>/dev/null)
    [ "$HC_RETRIES" != "0" ] && [ "$HC_RETRIES" != "null" ] && RUN_ARGS+=(--health-retries "$HC_RETRIES")

    while IFS='=' read -r key val; do
        [ -n "$key" ] && ! echo "$key" | grep -q "^com\.docker\." && RUN_ARGS+=(--label "${key}=${val}")
    done < <(jq -r '.[0].Config.Labels | to_entries[]? | "\(.key)=\(.value)"' "$json" 2>/dev/null)

    WORKDIR=$(jq -r '.[0].Config.WorkingDir // ""' "$json" 2>/dev/null)
    [ -n "$WORKDIR" ] && [ "$WORKDIR" != "null" ] && RUN_ARGS+=(--workdir "$WORKDIR")

    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" && { docker rm -f "$container" 2>/dev/null || true; }

    RUN_ARGS+=("$IMAGE")

    while IFS= read -r arg; do
        [ -n "$arg" ] && RUN_ARGS+=("$arg")
    done < <(jq -r '.[0].Config.Cmd[]?' "$json" 2>/dev/null)
    echo "   🚀 docker run ${RUN_ARGS[*]}"
    docker run "${RUN_ARGS[@]}" && { echo "   ✅ [$container] 已启动"; NORMAL_RESTORED=$((NORMAL_RESTORED + 1)); } || echo "   ❌ 启动失败"
done

echo ""
echo "📂 步骤 3: 还原 /home/docker 文件"
if [ -f "$DATA_DIR/home_docker_files.tar.gz" ]; then
    read -e -p "   确认还原? (y/n): " confirm
    [ "$confirm" = "y" ] && { mkdir -p /home/docker; tar -xzf "$DATA_DIR/home_docker_files.tar.gz" -C /; echo "   ✅ 已还原"; }
fi

echo ""
echo "🗄️ 步骤 4: 还原数据库 dump"

DB_RESTORED=0
for type_file in "$DATA_DIR"/db_type_*; do
    [ ! -f "$type_file" ] && continue
    container=$(basename "$type_file" | sed 's/db_type_//')
    db_type=$(cat "$type_file")
    creds_file="$DATA_DIR/db_creds_${container}"
    dump_path_file="$DATA_DIR/db_dump_path_${container}"

    echo ""
    echo "   🗄️ 数据库容器: $container (类型: $db_type)"

    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" || {
        echo "   ⚠️ 容器 [$container] 未运行，请先启动后再恢复数据库"
        continue
    }

    dump_file=""
    if [ -f "$dump_path_file" ]; then
        dump_file=$(cat "$dump_path_file")
        dump_file="$DATA_DIR/$(basename "$dump_file")"
    fi

    if [ -z "$dump_file" ] || [ ! -f "$dump_file" ]; then
        possible_dump=$(ls "$DATA_DIR/${container}_mysqldump_all.sql.gz" "$DATA_DIR/${container}_pgdumpall.sql.gz" "$DATA_DIR/${container}_mongodump.archive.gz" 2>/dev/null | head -1)
        if [ -n "$possible_dump" ]; then
            dump_file="$possible_dump"
        else
            echo "   ⚠️ 未找到 dump 文件，跳过"
            continue
        fi
    fi

    read -e -p "   确认恢复数据库 [$container] ? (y/n): " confirm
    [ "$confirm" != "y" ] && continue

    echo "   等待数据库就绪 (最多 60s)..."

    max_wait=60
    waited=0
    case "$db_type" in
        mysql)
            mysql_user="root"
            mysql_pass=""
            if [ -f "$creds_file" ]; then
                mysql_user=$(cat "$creds_file" | cut -d':' -f1)
                mysql_pass=$(cat "$creds_file" | cut -d':' -f2-)
            fi
            while [ $waited -lt $max_wait ]; do
                if [ -n "$mysql_pass" ]; then
                    docker exec "$container" mysqladmin ping -u "$mysql_user" -p"$mysql_pass" --protocol=TCP -h 127.0.0.1 &>/dev/null && break
                else
                    docker exec "$container" mysqladmin ping -u "$mysql_user" --protocol=TCP -h 127.0.0.1 &>/dev/null && break
                fi
                sleep 2
                waited=$((waited + 2))
            done
            [ $waited -ge $max_wait ] && echo "   ⚠️ MySQL 启动超时，尝试强制导入..."
            ;;
        postgres)
            pg_user="postgres"
            pg_pass=""
            if [ -f "$creds_file" ]; then
                pg_user=$(cat "$creds_file" | cut -d':' -f1)
                pg_pass=$(cat "$creds_file" | cut -d':' -f2-)
            fi
            while [ $waited -lt $max_wait ]; do
                if [ -n "$pg_pass" ]; then
                    docker exec -e PGPASSWORD="$pg_pass" "$container" pg_isready -U "$pg_user" &>/dev/null && break
                else
                    docker exec "$container" pg_isready -U "$pg_user" &>/dev/null && break
                fi
                sleep 2
                waited=$((waited + 2))
            done
            [ $waited -ge $max_wait ] && echo "   ⚠️ PostgreSQL 启动超时，尝试强制导入..."
            ;;
        mongodb)
            mongo_user=""
            mongo_pass=""
            if [ -f "$creds_file" ]; then
                mongo_user=$(cat "$creds_file" | cut -d':' -f1)
                mongo_pass=$(cat "$creds_file" | cut -d':' -f2-)
            fi
            while [ $waited -lt $max_wait ]; do
                if [ -n "$mongo_user" ] && [ -n "$mongo_pass" ]; then
                    docker exec "$container" mongosh --quiet -u "$mongo_user" -p "$mongo_pass" --authenticationDatabase admin --eval "db.runCommand({ping:1})" &>/dev/null && break
                else
                    docker exec "$container" mongosh --quiet --eval "db.runCommand({ping:1})" &>/dev/null && break
                fi
                sleep 2
                waited=$((waited + 2))
            done
            [ $waited -ge $max_wait ] && echo "   ⚠️ MongoDB 启动超时，尝试强制导入..."
            ;;
    esac

    if [ $waited -lt $max_wait ]; then
        echo "   ✅ $db_type 已就绪 ($waited s)"
    fi

    case "$db_type" in
        mysql)
            user=""
            pass=""
            if [ -f "$creds_file" ]; then
                user=$(cat "$creds_file" | cut -d':' -f1)
                pass=$(cat "$creds_file" | cut -d':' -f2-)
            else
                user="root"
                pass=""
            fi
            if [ -n "$pass" ]; then
                zcat "$dump_file" 2>/dev/null | docker exec -i "$container" mysql -u "$user" -p"$pass" 2>/dev/null
            else
                zcat "$dump_file" 2>/dev/null | docker exec -i "$container" mysql -u "$user" 2>/dev/null
            fi
            if [ $? -eq 0 ]; then
                echo "   ✅ [$container] MySQL 恢复成功"
                DB_RESTORED=$((DB_RESTORED + 1))
            else
                echo "   ❌ [$container] MySQL 恢复失败"
            fi
            ;;
        postgres)
            pg_user=""
            pg_pass=""
            if [ -f "$creds_file" ]; then
                pg_user=$(cat "$creds_file" | cut -d':' -f1)
                pg_pass=$(cat "$creds_file" | cut -d':' -f2-)
            else
                pg_user="postgres"
                pg_pass=""
            fi
            if [ -n "$pg_pass" ]; then
                zcat "$dump_file" 2>/dev/null | docker exec -i -e PGPASSWORD="$pg_pass" "$container" psql -U "$pg_user" &>/dev/null
            else
                zcat "$dump_file" 2>/dev/null | docker exec -i "$container" psql -U "$pg_user" &>/dev/null
            fi
            if [ $? -eq 0 ]; then
                echo "   ✅ [$container] PostgreSQL 恢复成功"
                DB_RESTORED=$((DB_RESTORED + 1))
            else
                echo "   ❌ [$container] PostgreSQL 恢复失败"
            fi
            ;;
        mongodb)
            mongo_user=""
            mongo_pass=""
            if [ -f "$creds_file" ]; then
                mongo_user=$(cat "$creds_file" | cut -d':' -f1)
                mongo_pass=$(cat "$creds_file" | cut -d':' -f2-)
            fi
            auth_args=""
            if [ -n "$mongo_user" ] && [ -n "$mongo_pass" ]; then
                auth_args="--username $mongo_user --password '$mongo_pass' --authenticationDatabase admin"
            fi
            zcat "$dump_file" 2>/dev/null | docker exec -i "$container" sh -c "mongorestore --archive $auth_args" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "   ✅ [$container] MongoDB 恢复成功"
                DB_RESTORED=$((DB_RESTORED + 1))
            else
                echo "   ❌ [$container] MongoDB 恢复失败"
            fi
            ;;
        *)
            echo "   ⚠️ 未知数据库类型: $db_type"
            ;;
    esac
done

# 清理解密临时文件
if [ "$IS_ENCRYPTED" = true ] && [ -f "$RESTORE_TAR" ]; then
    rm -f "$RESTORE_TAR"
    echo ""
    echo "🧹 已清理解密临时文件"
fi

echo ""
echo "🎉 恢复完成! Compose: $COMPOSE_RESTORED | 普通: $NORMAL_RESTORED | 数据库: $DB_RESTORED"
