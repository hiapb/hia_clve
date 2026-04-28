#!/usr/bin/env bash

# ==========================================
# Cloudreve 运维控制台
# 部署 / 升级 / 启停 / 备份 / 恢复 / 定时备份 / 卸载
# ==========================================

set -u
set -E
set -o pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DEFAULT_INSTALL_PATH="/opt/cloudreve"
ENV_FILE="/etc/cloudreve_env"
COMPOSE_FILE="docker-compose.yml"

CRON_TAG_BEGIN="# CLOUDREVE_BACKUP_BEGIN"
CRON_TAG_END="# CLOUDREVE_BACKUP_END"
BACKUP_LOG="/var/log/cloudreve_backup.log"

CLOUDREVE_IMAGE="cloudreve/cloudreve:v4"
POSTGRES_IMAGE="postgres:17"
REDIS_IMAGE="redis:7-alpine"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "必须使用 root 权限执行脚本。"
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo ""
    fi
}

get_workdir() {
    if [[ -f "$ENV_FILE" ]]; then
        local dir
        dir="$(cat "$ENV_FILE" 2>/dev/null || true)"
        if [[ -n "$dir" && -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

random_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        tr -dc 'a-f0-9' </dev/urandom | head -c $(( "$1" * 2 ))
    fi
}

install_base_deps() {
    local need_update=0
    for c in curl ca-certificates openssl tar gzip; do
        if ! command -v "$c" >/dev/null 2>&1; then
            need_update=1
        fi
    done

    if [[ "$need_update" == "1" ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y
            apt-get install -y curl ca-certificates openssl tar gzip
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl ca-certificates openssl tar gzip
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl ca-certificates openssl tar gzip
        else
            die "无法自动安装依赖，请手动安装 curl ca-certificates openssl tar gzip"
        fi
    fi
}

install_cron_if_missing() {
    if command -v crontab >/dev/null 2>&1; then
        return
    fi

    warn "未检测到 crontab，尝试自动安装 cron。"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y cron
        systemctl enable --now cron >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y cronie
        systemctl enable --now crond >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y cronie
        systemctl enable --now crond >/dev/null 2>&1 || true
    else
        die "无法自动安装 cron，请手动安装后重试。"
    fi

    command -v crontab >/dev/null 2>&1 || die "crontab 仍不可用。"
}

install_docker_if_missing() {
    if command -v docker >/dev/null 2>&1 && [[ -n "$(docker_compose_cmd)" ]]; then
        return
    fi

    warn "未检测到 Docker 或 Docker Compose，准备自动安装。"
    install_base_deps
    curl -fsSL https://get.docker.com | sh || die "Docker 自动安装失败。"
    systemctl enable --now docker >/dev/null 2>&1 || true

    [[ -n "$(docker_compose_cmd)" ]] || die "Docker 已安装，但 docker compose 不可用。"
}

check_docker_alive() {
    install_docker_if_missing
    docker info >/dev/null 2>&1 || die "Docker 服务不可用，请执行: systemctl restart docker"
}

wait_postgres() {
    local pguser="${1:-cloudreve}"
    local pgdb="${2:-cloudreve}"
    local i

    for i in $(seq 1 90); do
        if docker exec cloudreve-postgres pg_isready -h 127.0.0.1 -p 5432 -U "$pguser" -d "$pgdb" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

write_compose_file() {
    local host_port="$1"
    local open_bt="$2"
    local bt_port="$3"

    cat > "$COMPOSE_FILE" <<EOF
services:
  cloudreve:
    image: ${CLOUDREVE_IMAGE}
    container_name: cloudreve-backend
    restart: unless-stopped
    depends_on:
      - postgresql
      - redis
    ports:
      - "${host_port}:5212"
EOF

    if [[ "$open_bt" == "1" ]]; then
        cat >> "$COMPOSE_FILE" <<EOF
      - "${bt_port}:6888"
      - "${bt_port}:6888/udp"
EOF
    fi

    cat >> "$COMPOSE_FILE" <<'EOF'
    environment:
      - CR_CONF_Database.Type=postgres
      - CR_CONF_Database.Host=postgresql
      - CR_CONF_Database.User=${POSTGRES_USER}
      - CR_CONF_Database.Password=${POSTGRES_PASSWORD}
      - CR_CONF_Database.Name=${POSTGRES_DB}
      - CR_CONF_Database.Port=5432
      - CR_CONF_Redis.Server=redis:6379
      - TZ=${TZ}
    volumes:
      - ./backend_data:/cloudreve/data

  postgresql:
    image: ${POSTGRES_IMAGE}
    container_name: cloudreve-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12

  redis:
    image: ${REDIS_IMAGE}
    container_name: cloudreve-redis
    restart: unless-stopped
    volumes:
      - ./redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 12
EOF
}

deploy_cloudreve() {
    info "== 启动 Cloudreve 自动化部署 =="
    install_base_deps
    check_docker_alive

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"
    [[ -n "$dc_cmd" ]] || die "未检测到 docker compose。"

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$install_path" && -f "$install_path/$COMPOSE_FILE" ]]; then
        err "该路径已存在 Cloudreve 实例，请先执行 [8] 完全卸载，或换一个安装路径。"
        return
    fi

    read -r -p "请输入 Web 访问端口 [默认: 5212]: " input_port
    local host_port="${input_port:-5212}"
    if [[ ! "$host_port" =~ ^[0-9]+$ ]] || (( host_port < 1 || host_port > 65535 )); then
        err "端口无效。"
        return
    fi
    if port_in_use "$host_port"; then
        err "端口 ${host_port} 已被占用，请换一个端口。"
        return
    fi

    local open_bt="0"
    local bt_port="6888"
    read -r -p "是否开放离线下载/BT 端口 6888？一般分享文件不用开 (y/N): " bt_yn
    if [[ "$bt_yn" =~ ^[Yy]$ ]]; then
        open_bt="1"
        read -r -p "请输入 BT 映射端口 [默认: 6888]: " input_bt_port
        bt_port="${input_bt_port:-6888}"
        if [[ ! "$bt_port" =~ ^[0-9]+$ ]] || (( bt_port < 1 || bt_port > 65535 )); then
            err "BT 端口无效。"
            return
        fi
        if port_in_use "$bt_port"; then
            err "BT 端口 ${bt_port} 已被占用，请换一个端口。"
            return
        fi
    fi

    read -r -p "请输入时区 [默认: Asia/Shanghai]: " input_tz
    local tz="${input_tz:-Asia/Shanghai}"

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_FILE"
    cd "$install_path" || return

    local postgres_pass
    postgres_pass="$(random_hex 24)"

    cat > .env <<EOF
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
POSTGRES_USER=cloudreve
POSTGRES_PASSWORD=${postgres_pass}
POSTGRES_DB=cloudreve
TZ=${tz}
SERVER_PORT=${host_port}
BT_PORT=${bt_port}
EOF
    chmod 600 .env

    mkdir -p backend_data postgres_data redis_data backups
    write_compose_file "$host_port" "$open_bt" "$bt_port"

    info "正在拉起 Cloudreve / PostgreSQL / Redis 容器..."
    $dc_cmd -f "$COMPOSE_FILE" up -d || {
        err "容器启动失败，请执行 [10] 查看日志。"
        return
    }

    local server_ip
    server_ip="$(get_local_ip)"

    echo -e "\n=================================================="
    echo -e "\033[32m✅ Cloudreve 部署完成/启动中\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "安装路径: \033[33m${install_path}\033[0m"
    echo -e "数据库用户: \033[33mcloudreve\033[0m"
    echo -e "数据库密码: \033[33m${postgres_pass}\033[0m"
    echo -e "请在防火墙/安全组放行 Web 端口: \033[31m${host_port}\033[0m"
    if [[ "$open_bt" == "1" ]]; then
        echo -e "BT/离线下载端口也需要放行 TCP/UDP: \033[31m${bt_port}\033[0m"
    fi
    echo -e "首次打开网页注册账号，第一个注册账号就是管理员。"
    echo -e "==================================================\n"
}

make_pg_dump() {
    local out_file="$1"
    local workdir
    workdir="$(get_workdir)"
    [[ -n "$workdir" ]] || return 1
    cd "$workdir" || return 1

    local pguser pgdb pgpass
    pguser="$(grep -oP '^POSTGRES_USER=\K.*' .env 2>/dev/null || echo "cloudreve")"
    pgdb="$(grep -oP '^POSTGRES_DB=\K.*' .env 2>/dev/null || echo "cloudreve")"
    pgpass="$(grep -oP '^POSTGRES_PASSWORD=\K.*' .env 2>/dev/null || true)"

    $(docker_compose_cmd) -f "$COMPOSE_FILE" up -d postgresql >/dev/null 2>&1 || return 1
    wait_postgres "$pguser" "$pgdb" || return 1

    docker exec -i -e PGPASSWORD="$pgpass" cloudreve-postgres \
        pg_dump -h 127.0.0.1 -p 5432 -U "$pguser" -d "$pgdb" > "$out_file"
}

upgrade_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到 Cloudreve 环境，请先执行 [1] 一键部署。"
        return
    fi

    check_docker_alive
    cd "$workdir" || return

    info "升级前先做一次数据库+配置备份..."
    do_backup "silent" "core"

    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) -f "$COMPOSE_FILE" pull
    $(docker_compose_cmd) -f "$COMPOSE_FILE" up -d
    info "升级完成。"
}

pause_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到 Cloudreve 环境。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f "$COMPOSE_FILE" stop || true
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到 Cloudreve 环境。"
        return
    fi
    cd "$workdir" || return
    $(docker_compose_cmd) -f "$COMPOSE_FILE" restart || true
    info "服务已重启。"
}

do_backup() {
    local mode="${1:-normal}"
    local backup_type="${2:-ask}"

    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法备份。"
        return
    fi

    cd "$workdir" || return
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    if [[ "$backup_type" == "ask" ]]; then
        echo -e "\033[33mCloudreve 的 backend_data 里通常包含程序数据和本地文件，可能很大。\033[0m"
        echo " 1) 完整备份：配置 + 数据库 + Redis + backend_data 文件"
        echo " 2) 核心备份：配置 + 数据库 + Redis，不包含 backend_data 文件"
        read -r -p "请选择备份类型 [默认: 1]: " bt
        case "${bt:-1}" in
            1) backup_type="full" ;;
            2) backup_type="core" ;;
            *) err "无效选择。"; return ;;
        esac
    fi

    local timestamp backup_file tmp_dir
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    tmp_dir="$(mktemp -d)"

    cp "$COMPOSE_FILE" "$tmp_dir/$COMPOSE_FILE"
    cp .env "$tmp_dir/.env"

    info "正在导出 PostgreSQL 数据库..."
    if ! make_pg_dump "$tmp_dir/postgres_dump.sql"; then
        rm -rf "$tmp_dir"
        err "数据库导出失败，请执行 [10] 查看日志。"
        return
    fi

    cp -a redis_data "$tmp_dir/redis_data" 2>/dev/null || mkdir -p "$tmp_dir/redis_data"

    if [[ "$backup_type" == "full" ]]; then
        backup_file="${backup_dir}/cloudreve_full_backup_${timestamp}.tar.gz"
        info "开始完整备份，文件多时会比较久..."
        tar -czf "$backup_file" \
            -C "$tmp_dir" "$COMPOSE_FILE" .env postgres_dump.sql redis_data \
            -C "$workdir" backend_data
    else
        backup_file="${backup_dir}/cloudreve_core_backup_${timestamp}.tar.gz"
        info "开始核心备份，不包含 backend_data 文件..."
        tar -czf "$backup_file" \
            -C "$tmp_dir" "$COMPOSE_FILE" .env postgres_dump.sql redis_data
    fi

    local tar_ec=$?
    rm -rf "$tmp_dir"

    if [[ $tar_ec -ne 0 ]]; then
        err "备份打包失败。"
        rm -f "$backup_file" 2>/dev/null || true
        return
    fi

    cd "$backup_dir" || return
    ls -t cloudreve_*_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    if [[ "$mode" != "silent" ]]; then
        info "备份完成。当前备份："
        for f in $(ls -t cloudreve_*_backup_*.tar.gz 2>/dev/null); do
            local abs_path fsize
            abs_path="${backup_dir}/${f}"
            fsize="$(du -h "$f" | cut -f1)"
            echo -e "  📦 \033[36m${abs_path}\033[0m  大小: ${fsize}"
        done
    else
        info "备份完成: ${backup_file}"
    fi
}

restore_backup() {
    info "== Cloudreve 备份恢复 =="
    check_docker_alive

    local default_backup=""
    local current_wd search_dir
    current_wd="$(get_workdir)"
    search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"

    if [[ -d "$search_dir" ]]; then
        default_backup="$(ls -t "${search_dir}"/cloudreve_*_backup_*.tar.gz 2>/dev/null | head -n 1 || true)"
    fi

    local backup_path=""
    if [[ -n "$default_backup" ]]; then
        echo -e "检测到最新备份: \033[33m${default_backup}\033[0m"
        read -r -p "请输入备份文件路径 [直接回车使用默认]: " input_backup
        backup_path="${input_backup:-$default_backup}"
    else
        read -r -p "请输入备份文件 .tar.gz 路径: " backup_path
    fi

    if [[ ! -f "$backup_path" ]]; then
        err "备份文件不存在。"
        return
    fi

    local has_backend_data="0"
    if tar -tzf "$backup_path" 2>/dev/null | grep -qE '(^|/)backend_data(/|$)'; then
        has_backend_data="1"
    fi

    if [[ "$has_backend_data" == "1" ]]; then
        info "检测到这是完整备份：包含 backend_data 文件数据。"
    else
        warn "检测到这是核心备份：不包含 backend_data 文件数据。"
        warn "核心备份只恢复配置/数据库/Redis，不恢复实际上传文件。"
    fi

    read -r -p "请输入恢复目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$target_dir" && -f "$target_dir/$COMPOSE_FILE" ]]; then
        warn "目标目录已存在实例，恢复将覆盖数据库/配置。"
        if [[ "$has_backend_data" == "0" ]]; then
            warn "当前是核心备份，脚本会保留已有 backend_data，避免误删实际文件。"
        else
            warn "当前是完整备份，脚本会用备份包里的 backend_data 覆盖现有文件数据。"
        fi

        read -r -p "是否继续？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已取消恢复。"
            return
        fi

        cd "$target_dir" && $(docker_compose_cmd) -f "$COMPOSE_FILE" down || true

        if [[ "$has_backend_data" == "1" ]]; then
            find "$target_dir" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} +
        else
            find "$target_dir" -mindepth 1 -maxdepth 1 ! -name backups ! -name backend_data -exec rm -rf {} +
        fi
    fi

    mkdir -p "$target_dir"

    info "正在解压备份包..."
    tar -xzf "$backup_path" -C "$target_dir" || {
        err "解压失败，备份包可能损坏。"
        return
    }

    echo "$target_dir" > "$ENV_FILE"
    cd "$target_dir" || return

    mkdir -p backend_data postgres_data redis_data backups

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "备份包中缺少 docker-compose.yml，无法恢复。"
        return
    fi

    if [[ ! -f ".env" ]]; then
        err "备份包中缺少 .env，无法恢复。"
        return
    fi

    local pgpass pguser pgdb
    pgpass="$(grep -oP '^POSTGRES_PASSWORD=\K.*' .env 2>/dev/null || true)"
    pguser="$(grep -oP '^POSTGRES_USER=\K.*' .env 2>/dev/null || echo "cloudreve")"
    pgdb="$(grep -oP '^POSTGRES_DB=\K.*' .env 2>/dev/null || echo "cloudreve")"

    if [[ -f postgres_dump.sql ]]; then
        info "正在启动 PostgreSQL / Redis..."
        $(docker_compose_cmd) -f "$COMPOSE_FILE" up -d postgresql redis || {
            err "数据库容器启动失败。"
            return
        }

        info "等待 PostgreSQL 就绪..."
        if ! wait_postgres "$pguser" "$pgdb"; then
            err "PostgreSQL 等待超时。"
            docker logs --tail=120 cloudreve-postgres || true
            return
        fi

        info "正在导入 PostgreSQL 数据库..."
        if ! docker exec -i -e PGPASSWORD="$pgpass" cloudreve-postgres \
            psql -h 127.0.0.1 -p 5432 -U "$pguser" -d "$pgdb" < postgres_dump.sql; then
            err "数据库导入失败。"
            docker logs --tail=120 cloudreve-postgres || true
            return
        fi
    else
        warn "备份包中没有 postgres_dump.sql，将直接启动容器。"
    fi

    info "正在启动 Cloudreve..."
    $(docker_compose_cmd) -f "$COMPOSE_FILE" up -d || {
        err "恢复启动失败。"
        return
    }

    local server_ip host_port
    server_ip="$(get_local_ip)"
    host_port="$(grep -oP '^SERVER_PORT=\K.*' .env 2>/dev/null || echo "5212")"

    echo -e "\n=================================================="
    echo -e "\033[32m✅ Cloudreve 恢复完成\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "恢复路径: \033[33m${target_dir}\033[0m"
    if [[ "$has_backend_data" == "0" ]]; then
        echo -e "\033[33m注意：本次使用的是核心备份，不包含 backend_data 文件数据。\033[0m"
    fi
    echo -e "==================================================\n"
}

setup_auto_backup() {
    install_cron_if_missing
    info "== Cloudreve 定时备份 =="

    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境。"
        return
    fi

    local cron_script="${workdir}/cron_backup.sh"
    local existing_cron reset_cron cron_type min_interval cron_time hour minute cron_spec tmp_cron backup_type
    existing_cron="$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)"

    if [[ -n "$existing_cron" ]]; then
        echo -e "\033[36m当前定时任务:\033[0m"
        echo -e "\033[33m${existing_cron}\033[0m"
        read -r -p "是否覆盖？(y/N): " reset_cron
        if [[ ! "$reset_cron" =~ ^[Yy]$ ]]; then
            info "已保留当前配置。"
            return
        fi
    else
        echo "当前未检测到定时备份任务。"
    fi

    echo " 1) 按固定分钟备份：5/10/15/20/30/60/120/360/720"
    echo " 2) 每天固定时间备份：例如 04:30"
    echo " 3) 删除当前定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数: " min_interval
        if [[ ! "$min_interval" =~ ^[0-9]+$ ]]; then
            err "必须是整数。"
            return
        fi
        case "$min_interval" in
            5|10|15|20|30) cron_spec="*/${min_interval} * * * *" ;;
            60) cron_spec="0 * * * *" ;;
            120) cron_spec="0 */2 * * *" ;;
            360) cron_spec="0 */6 * * *" ;;
            720) cron_spec="0 */12 * * *" ;;
            *) err "不支持该间隔。"; return ;;
        esac
    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 HH:MM: " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            err "时间格式不正确。"
            return
        fi
        hour="${cron_time%:*}"
        minute="${cron_time#*:}"
        hour="$(echo "$hour" | sed 's/^0*//')"
        minute="$(echo "$minute" | sed 's/^0*//')"
        [[ -z "$hour" ]] && hour="0"
        [[ -z "$minute" ]] && minute="0"
        cron_spec="${minute} ${hour} * * *"
    elif [[ "$cron_type" == "3" ]]; then
        tmp_cron="$(mktemp)" || { err "创建临时文件失败。"; return; }
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron" "$cron_script"
        info "定时备份已删除。"
        return
    else
        err "无效选择。"
        return
    fi

    echo " 1) 定时完整备份：包含 backend_data 文件，文件多会很大"
    echo " 2) 定时核心备份：不包含 backend_data，只备份数据库/配置"
    read -r -p "请选择定时备份类型 [默认: 1]: " btype
    case "${btype:-1}" in
        1) backup_type="full" ;;
        2) backup_type="core" ;;
        *) err "无效选择。"; return ;;
    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
set -u
set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
WORKDIR="${workdir}"
BACKUP_TYPE="${backup_type}"
COMPOSE_FILE="${COMPOSE_FILE}"
cd "\$WORKDIR" || exit 1

BACKUP_DIR="\${WORKDIR}/backups"
mkdir -p "\$BACKUP_DIR"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
TMP_DIR=\$(mktemp -d)

cleanup() {
    rm -rf "\$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

PGUSER=\$(grep -oP '^POSTGRES_USER=\K.*' .env 2>/dev/null || echo "cloudreve")
PGDB=\$(grep -oP '^POSTGRES_DB=\K.*' .env 2>/dev/null || echo "cloudreve")
PGPASS=\$(grep -oP '^POSTGRES_PASSWORD=\K.*' .env 2>/dev/null || true)

cp "\$COMPOSE_FILE" "\$TMP_DIR/\$COMPOSE_FILE"
cp .env "\$TMP_DIR/.env"

docker exec -i -e PGPASSWORD="\$PGPASS" cloudreve-postgres \\
    pg_dump -h 127.0.0.1 -p 5432 -U "\$PGUSER" -d "\$PGDB" > "\$TMP_DIR/postgres_dump.sql" || exit 1

cp -a redis_data "\$TMP_DIR/redis_data" 2>/dev/null || mkdir -p "\$TMP_DIR/redis_data"

if [[ "\$BACKUP_TYPE" == "full" ]]; then
    BACKUP_FILE="\${BACKUP_DIR}/cloudreve_full_backup_\${TIMESTAMP}.tar.gz"
    tar -czf "\$BACKUP_FILE" -C "\$TMP_DIR" "\$COMPOSE_FILE" .env postgres_dump.sql redis_data -C "\$WORKDIR" backend_data || exit 1
else
    BACKUP_FILE="\${BACKUP_DIR}/cloudreve_core_backup_\${TIMESTAMP}.tar.gz"
    tar -czf "\$BACKUP_FILE" -C "\$TMP_DIR" "\$COMPOSE_FILE" .env postgres_dump.sql redis_data || exit 1
fi

cd "\$BACKUP_DIR" || exit 1
ls -t cloudreve_*_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f
EOF
    chmod +x "$cron_script"

    tmp_cron="$(mktemp)" || {
        err "创建临时文件失败。"
        return
    }

    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true

    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF

    if ! crontab "$tmp_cron" 2>/dev/null; then
        rm -f "$tmp_cron"
        err "写入 crontab 失败。"
        return
    fi

    rm -f "$tmp_cron"
    info "定时任务已写入：${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1"
}

uninstall_service() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境。"
        return
    fi

    echo -e "\033[31m⚠️ 警告：这将彻底删除 Cloudreve 容器、数据库、配置、用户文件！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return
    fi

    cd "$workdir" || return
    $(docker_compose_cmd) -f "$COMPOSE_FILE" down -v || true

    cd /
    rm -rf "$workdir" || true
    rm -f "$ENV_FILE" || true

    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true

    info "Cloudreve 已完全卸载。"
}

install_ftp() {
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

show_status() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境。"
        return
    fi
    cd "$workdir" || return

    echo "================ Docker Compose 状态 ================"
    $(docker_compose_cmd) -f "$COMPOSE_FILE" ps || true

    echo "================ 最近日志 ================"
    $(docker_compose_cmd) -f "$COMPOSE_FILE" logs --tail=120 cloudreve postgresql redis || true
}

show_info() {
    local workdir
    workdir="$(get_workdir)"
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境。"
        return
    fi

    cd "$workdir" || return

    local server_ip host_port bt_port db_pass
    server_ip="$(get_local_ip)"
    host_port="$(grep -oP '^SERVER_PORT=\K.*' .env 2>/dev/null || echo "5212")"
    bt_port="$(grep -oP '^BT_PORT=\K.*' .env 2>/dev/null || echo "6888")"
    db_pass="$(grep -oP '^POSTGRES_PASSWORD=\K.*' .env 2>/dev/null || echo "")"

    echo -e "\n=================================================="
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "安装路径: \033[33m${workdir}\033[0m"
    echo -e "数据库用户: \033[33mcloudreve\033[0m"
    echo -e "数据库密码: \033[33m${db_pass}\033[0m"
    echo -e "BT 默认端口: \033[33m${bt_port}\033[0m"
    echo -e "说明: 第一个注册账号就是管理员。"
    echo -e "==================================================\n"
}

main_menu() {
    clear
    echo "==================================================="
    echo "                Cloudreve 一键管理                 "
    echo "==================================================="
    local wd
    wd="$(get_workdir)"
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo " 10) 查看状态/日志"
    echo " 11) 查看访问信息"
    echo "  0) 退出脚本"
    echo "==================================================="

    read -r -p "请输入操作序号 [0-11]: " choice
    case "$choice" in
        1) deploy_cloudreve ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        10) show_status ;;
        11) show_info ;;
        0) info "退出。"; exit 0 ;;
        *) warn "无效选择。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup "silent" "core"
else
    require_root
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
