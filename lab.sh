#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

info() {
    echo -e "${BLUE}[*]${NC} $1"
}

ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

err() {
    echo -e "${RED}[-]${NC} $1"
}

NEED_SUDO=false
COMPOSE_CMD=()

detect_docker_access() {
    if docker info >/dev/null 2>&1; then
        NEED_SUDO=false
        return 0
    fi

    if sudo -n docker info >/dev/null 2>&1; then
        NEED_SUDO=true
        return 0
    fi

    if sudo docker info >/dev/null 2>&1; then
        NEED_SUDO=true
        return 0
    fi

    return 1
}

docker_cmd() {
    if [ "$NEED_SUDO" = true ]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

resolve_compose_cmd() {
    if docker_cmd compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker_cmd compose)
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
        return 0
    fi

    return 1
}

ensure_docker_ready() {
    if ! command -v docker >/dev/null 2>&1; then
        err "Docker is not installed."
        exit 1
    fi

    if ! detect_docker_access; then
        err "Cannot access the Docker daemon."
        exit 1
    fi

    if ! resolve_compose_cmd; then
        err "Docker Compose is not available."
        exit 1
    fi
}

valid_target() {
    [ "$1" = "dvwa" ] || [ "$1" = "juiceshop" ]
}

target_name() {
    case "$1" in
        dvwa) echo "DVWA" ;;
        juiceshop) echo "OWASP Juice Shop" ;;
    esac
}

target_ip() {
    case "$1" in
        dvwa) echo "10.10.10.10" ;;
        juiceshop) echo "10.10.10.11" ;;
    esac
}

target_port() {
    case "$1" in
        dvwa) echo "80" ;;
        juiceshop) echo "3000" ;;
    esac
}

target_url() {
    case "$1" in
        dvwa) echo "http://10.10.10.10" ;;
        juiceshop) echo "http://10.10.10.11:3000" ;;
    esac
}

is_running() {
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps \
        --status running --services 2>/dev/null |
        grep -qx "$1"
}

wait_for_target() {
    local target="$1"
    local ip
    local port
    local name

    ip="$(target_ip "$target")"
    port="$(target_port "$target")"
    name="$(target_name "$target")"

    info "Waiting for $name..."

    for _ in {1..30}; do
        if curl -s --connect-timeout 1 \
            "http://$ip:$port" >/dev/null 2>&1; then
            ok "$name is ready"
            return 0
        fi

        sleep 1
    done

    warn "$name started but is not reachable yet."
    return 1
}

start_target() {
    local target="$1"

    info "Starting $(target_name "$target")..."

    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d "$target"

    if wait_for_target "$target"; then
        ok "$(target_name "$target") → $(target_url "$target")"
    fi
}

stop_target() {
    local target="$1"

    if ! is_running "$target"; then
        warn "$(target_name "$target") is already stopped."
        return 0
    fi

    info "Stopping $(target_name "$target")..."
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" stop "$target"
    ok "$(target_name "$target") stopped."
}

reset_target() {
    local target="$1"

    info "Resetting $(target_name "$target")..."

    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" rm -sf "$target"
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d "$target"

    wait_for_target "$target" || true

    ok "$(target_name "$target") reset."
}

cmd_up() {
    local target="${1:-}"

    ensure_docker_ready

    if [ ! -f "$COMPOSE_FILE" ]; then
        err "docker-compose.yml not found."
        exit 1
    fi

    if [ "$target" = "all" ]; then
        start_target dvwa
        start_target juiceshop
    elif valid_target "$target"; then
        start_target "$target"
    else
        err "Invalid target."
        usage
        exit 1
    fi
}

cmd_down() {
    local target="${1:-}"

    ensure_docker_ready

    if [ "$target" = "all" ]; then
        stop_target dvwa
        stop_target juiceshop
    elif valid_target "$target"; then
        stop_target "$target"
    else
        err "Invalid target."
        usage
        exit 1
    fi
}

cmd_reset() {
    local target="${1:-}"

    ensure_docker_ready

    if [ "$target" = "all" ]; then
        warn "This will remove all lab containers and volumes."
        read -r -p "Continue? [y/N] " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "Reset cancelled."
            return 0
        fi

        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down -v

        start_target dvwa
        start_target juiceshop

    elif valid_target "$target"; then
        reset_target "$target"

    else
        err "Invalid target."
        usage
        exit 1
    fi
}

cmd_status() {
    ensure_docker_ready

    echo ""
    echo "SOM Web Security Lab"
    echo "────────────────────────────"

    for target in dvwa juiceshop; do
        local name
        local ip
        local port

        name="$(target_name "$target")"
        ip="$(target_ip "$target")"
        port="$(target_port "$target")"

        echo ""
        echo "$name"
        echo "  Target: $ip:$port"

        if is_running "$target"; then
            if curl -s --connect-timeout 2 \
                "http://$ip:$port" >/dev/null 2>&1; then
                echo "  Status: READY"
            else
                echo "  Status: STARTING"
            fi
        else
            echo "  Status: STOPPED"
        fi
    done

    echo ""
}

cmd_logs() {
    local target="${1:-}"

    ensure_docker_ready

    if [ "$target" = "all" ]; then
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" logs -f
    elif valid_target "$target"; then
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" logs -f "$target"
    else
        err "Invalid target."
        usage
        exit 1
    fi
}

cmd_doctor() {
    echo "SOM Web Security Lab"
    echo "────────────────────────────"

    if command -v docker >/dev/null 2>&1; then
        ok "Docker installed"
    else
        err "Docker not installed"
        return 1
    fi

    if detect_docker_access; then
        ok "Docker daemon accessible"
    else
        err "Docker daemon unavailable"
        return 1
    fi

    if resolve_compose_cmd; then
        ok "Docker Compose available"
    else
        err "Docker Compose unavailable"
        return 1
    fi

    if [ -f "$COMPOSE_FILE" ]; then
        ok "Compose file found"
    else
        err "docker-compose.yml not found"
        return 1
    fi

    echo ""
    echo "Targets"

    for target in dvwa juiceshop; do
        local ip
        local port

        ip="$(target_ip "$target")"
        port="$(target_port "$target")"

        if is_running "$target"; then
            if curl -s --connect-timeout 2 \
                "http://$ip:$port" >/dev/null 2>&1; then
                ok "$(target_name "$target") reachable at $ip:$port"
            else
                warn "$(target_name "$target") running but unreachable"
            fi
        else
            warn "$(target_name "$target") is stopped"
        fi
    done
}

usage() {
    echo ""
    echo "SOM Web Security Lab"
    echo ""
    echo "Usage:"
    echo "  ./lab.sh <command> [target]"
    echo ""
    echo "Commands:"
    echo "  up <target>        Start a target"
    echo "  down <target>      Stop a target"
    echo "  status             Show lab status"
    echo "  reset <target>     Reset a target"
    echo "  logs <target>      Show target logs"
    echo "  doctor             Check lab environment"
    echo "  help               Show help"
    echo ""
    echo "Targets:"
    echo "  dvwa"
    echo "  juiceshop"
    echo "  all"
    echo ""
}

cmd="${1:-help}"
shift || true

case "$cmd" in
    up)       cmd_up "${1:-}" ;;
    down)     cmd_down "${1:-}" ;;
    status)   cmd_status ;;
    reset)    cmd_reset "${1:-}" ;;
    logs)     cmd_logs "${1:-}" ;;
    doctor)   cmd_doctor ;;
    help)     usage ;;
    *)        err "Unknown command: $cmd"; usage; exit 1 ;;
esac