#!/bin/bash
# ================================================
# Docker 备份恢复脚本
# 用法: ./restore.sh <备份文件.tar.gz>
# ================================================

set -e

BACKUP_FILE="$1"
[ -z "$BACKUP_FILE" ] && { echo "用法: $0 <备份文件.tar.gz>"; echo "示例: $0 /root/bf/VPS_Backups/docker_backup_20260502_120000.tar.gz"; exit 1; }
[ ! -f "$BACKUP_FILE" ] && { echo "❌ 文件不存在: $BACKUP_FILE"; exit 1; }

echo "📦 Docker 备份恢复工具"
echo "备份文件: $BACKUP_FILE"

for cmd in docker tar jq gzip; do
    command -v "$cmd" &>/dev/null || { echo "❌ 缺少依赖: $cmd"; exit 1; }
done
echo "✅ 依赖就绪"

WORK_DIR="/tmp/docker_restore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORK_DIR"
echo "📂 解压到: $WORK_DIR"
tar -xzf "$BACKUP_FILE" -C "$WORK_DIR"

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

    RUN_ARGS=(-d --name "$container")

    while IFS= read -r port; do
        [ -n "$port" ] && RUN_ARGS+=(-p "$port")
    done < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "\(.value[0].HostPort):\(.key | split("/")[0])"' "$json" 2>/dev/null)

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

    NETWORK_MODE=$(jq -r '.[0].HostConfig.NetworkMode // ""' "$json" 2>/dev/null)
    [ -n "$NETWORK_MODE" ] && [ "$NETWORK_MODE" != "default" ] && [ "$NETWORK_MODE" != "bridge" ] && [ "$NETWORK_MODE" != "null" ] && { RUN_ARGS+=(--network "$NETWORK_MODE"); echo "   网络: $NETWORK_MODE"; }

    RESTART_POLICY=$(jq -r '.[0].HostConfig.RestartPolicy.Name // ""' "$json" 2>/dev/null)
    [ -n "$RESTART_POLICY" ] && [ "$RESTART_POLICY" != "no" ] && [ "$RESTART_POLICY" != "null" ] && RUN_ARGS+=(--restart "$RESTART_POLICY")

    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" && { docker rm -f "$container" 2>/dev/null || true; }

    RUN_ARGS+=("$IMAGE")
    echo "   🚀 docker run ${RUN_ARGS[*]}"
    docker run "${RUN_ARGS[@]}"
    [ $? -eq 0 ] && { echo "   ✅ [$container] 已启动"; NORMAL_RESTORED=$((NORMAL_RESTORED + 1)); } || echo "   ❌ 启动失败"
done

echo ""
echo "📂 步骤 3: 还原 /home/docker 文件"
if [ -f "$DATA_DIR/home_docker_files.tar.gz" ]; then
    read -e -p "   确认还原? (y/n): " confirm
    [ "$confirm" = "y" ] && { mkdir -p /home/docker; tar -xzf "$DATA_DIR/home_docker_files.tar.gz" -C /; echo "   ✅ 已还原"; }
fi

echo ""
echo "🎉 恢复完成! Compose: $COMPOSE_RESTORED | 普通: $NORMAL_RESTORED"
