#!/bin/bash
# ================================================
# 数据库自动检测 + 安全导出模块
# 用法: source db_dump.sh 后调用相关函数
# ================================================

# ---- 检测函数 ----

detect_db_type() {
    local container="$1"
    local image
    image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    [ -z "$image" ] && return 1

    if echo "$image" | grep -qE 'mysql|mariadb'; then
        echo "mysql"
        return 0
    fi

    if echo "$image" | grep -qE 'postgres|postgis|timescaledb'; then
        echo "postgres"
        return 0
    fi

    if echo "$image" | grep -qE 'mongo'; then
        echo "mongodb"
        return 0
    fi

    return 1
}

get_db_creds() {
    local container="$1"
    local db_type="$2"

    case "$db_type" in
        mysql)
            local user
            user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -i '^MYSQL_ROOT_PASSWORD=' | head -1 | cut -d'=' -f2-)
            if [ -n "$user" ]; then
                echo "root:$user"
            else
                user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -i '^MARIADB_ROOT_PASSWORD=' | head -1 | cut -d'=' -f2-)
                if [ -n "$user" ]; then
                    echo "root:$user"
                else
                    echo "root:"
                fi
            fi
            ;;
        postgres)
            local pg_pass
            pg_pass=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -i '^POSTGRES_PASSWORD=' | head -1 | cut -d'=' -f2-)
            local pg_user
            pg_user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -i '^POSTGRES_USER=' | head -1 | cut -d'=' -f2-)
            [ -z "$pg_user" ] && pg_user="postgres"
            echo "$pg_user:$pg_pass"
            ;;
        mongodb)
            local mongo_user mongo_pass
            mongo_user=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -i '^MONGO_INITDB_ROOT_USERNAME=' | head -1 | cut -d'=' -f2-)
            mongo_pass=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | grep -i '^MONGO_INITDB_ROOT_PASSWORD=' | head -1 | cut -d'=' -f2-)
            echo "${mongo_user:-}:${mongo_pass:-}"
            ;;
    esac
}

# ---- 导出函数 ----

dump_mysql() {
    local container="$1"
    local output_dir="$2"
    local creds="$3"
    local user pass
    user=$(echo "$creds" | cut -d':' -f1)
    pass=$(echo "$creds" | cut -d':' -f2-)

    local dump_file="${output_dir}/${container}_mysqldump_all.sql"

    if [ -n "$pass" ]; then
        docker exec "$container" sh -c "mysqldump --all-databases -u $user -p'$pass' --single-transaction --quick --routines --triggers --events" > "$dump_file"
    else
        docker exec "$container" sh -c "mysqldump --all-databases -u $user --single-transaction --quick --routines --triggers --events" > "$dump_file"
    fi

    if [ -s "$dump_file" ]; then
        gzip "$dump_file" 2>/dev/null
        echo "${dump_file}.gz"
        return 0
    fi

    rm -f "$dump_file"
    return 1
}

dump_postgres() {
    local container="$1"
    local output_dir="$2"
    local creds="$3"
    local user pass
    user=$(echo "$creds" | cut -d':' -f1)
    pass=$(echo "$creds" | cut -d':' -f2-)

    local dump_file="${output_dir}/${container}_pgdumpall.sql"

    if [ -n "$pass" ]; then
        docker exec -e PGPASSWORD="$pass" "$container" pg_dumpall -U "$user" > "$dump_file"
    else
        docker exec "$container" pg_dumpall -U "$user" > "$dump_file"
    fi

    if [ -s "$dump_file" ]; then
        gzip "$dump_file" 2>/dev/null
        echo "${dump_file}.gz"
        return 0
    fi

    rm -f "$dump_file"
    return 1
}

dump_mongodb() {
    local container="$1"
    local output_dir="$2"
    local creds="$3"
    local user pass
    user=$(echo "$creds" | cut -d':' -f1)
    pass=$(echo "$creds" | cut -d':' -f2-)

    local dump_file="${output_dir}/${container}_mongodump.archive"

    local auth_args=""
    if [ -n "$user" ] && [ -n "$pass" ]; then
        auth_args="--username $user --password '$pass' --authenticationDatabase admin"
    fi

    docker exec "$container" sh -c "mongodump --archive $auth_args" > "$dump_file"

    if [ -s "$dump_file" ]; then
        gzip "$dump_file" 2>/dev/null
        echo "${dump_file}.gz"
        return 0
    fi

    rm -f "$dump_file"
    return 1
}

dump_database() {
    local container="$1"
    local db_type="$2"
    local output_dir="$3"

    echo "   🩺 对数据库容器 [$container] ($db_type) 执行专用导出..." >&2

    mkdir -p "$output_dir"

    local creds
    creds=$(get_db_creds "$container" "$db_type")

    local stderr_file="${output_dir}/.db_dump_stderr_${container}"
    local result=""
    case "$db_type" in
        mysql)
            result=$(dump_mysql "$container" "$output_dir" "$creds" 2>"$stderr_file")
            ;;
        postgres)
            result=$(dump_postgres "$container" "$output_dir" "$creds" 2>"$stderr_file")
            ;;
        mongodb)
            result=$(dump_mongodb "$container" "$output_dir" "$creds" 2>"$stderr_file")
            ;;
    esac

    if [ -n "$result" ] && [ -f "$result" ]; then
        echo "   ✅ [$container] 导出成功: $(basename "$result") ($(du -h "$result" | cut -f1))" >&2
        echo "$db_type" > "${output_dir}/db_type_${container}"
        echo "$creds" > "${output_dir}/db_creds_${container}"
        echo "$result" > "${output_dir}/db_dump_path_${container}"
        rm -f "$stderr_file"
        return 0
    fi

    echo "   ⚠️ [$container] 导出失败，将回退到卷打包方式" >&2
    if [ -s "$stderr_file" ]; then
        echo "   🔍 错误详情:" >&2
        sed 's/^/      /' "$stderr_file" >&2
    fi
    rm -f "$stderr_file"
    return 1
}

# ---- 入口函数 ----

process_all_databases() {
    local output_dir="$1"
    local db_count=0
    local containers=()
    local db_containers=()

    mkdir -p "$output_dir"

    mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null)

    if [ ${#containers[@]} -eq 0 ]; then
        echo "0"
        return
    fi

    echo "" >&2
    echo "🕵️ ==== 数据库自动检测 ====" >&2

    for c in "${containers[@]}"; do
        local db_type
        db_type=$(detect_db_type "$c" 2>/dev/null)
        if [ -n "$db_type" ]; then
            echo "   🔍 检测到数据库: [$c] 类型=$db_type" >&2
            db_containers+=("$c:$db_type")
        fi
    done

    if [ ${#db_containers[@]} -eq 0 ]; then
        echo "   ℹ️ 未检测到数据库容器" >&2
        echo "" >&2
        echo "0"
        return
    fi

    echo "   📊 共检测到 ${#db_containers[@]} 个数据库容器" >&2
    echo "" >&2

    for entry in "${db_containers[@]}"; do
        local c="${entry%%:*}"
        local db_type="${entry##*:}"
        if dump_database "$c" "$db_type" "$output_dir"; then
            db_count=$((db_count + 1))
            mkdir -p "${output_dir}/db_processed"
            echo "$db_type" > "${output_dir}/db_processed/${c}"
        fi
    done

    echo "" >&2
    echo "   ✅ 数据库专用导出完成: $db_count/${#db_containers[@]} 个成功" >&2
    echo "" >&2

    echo "$db_count"
}
