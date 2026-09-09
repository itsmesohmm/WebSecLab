#!/bin/bash
# Web Sec Lab manager
# One command, per-target control, beginner-friendly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
cd "$SCRIPT_DIR" || exit 1
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# ---------- output helpers ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[-]${NC} $1"; }
head_() { echo -e "${BOLD}$1${NC}"; }

# ---------- privilege handling ----------
if [ "$(id -u)" = "0" ]; then
    SUDO=""
elif command -v sudo &> /dev/null; then
    SUDO="sudo"
else
    err "This script needs root privileges (run as root, or install sudo)."
    exit 1
fi

NEED_SUDO=0
COMPOSE_CMD=()


TARGET_KEYS=(dvwa juiceshop)
declare -A TARGET_SERVICE=( [dvwa]="dvwa"            [juiceshop]="juiceshop" )
declare -A TARGET_LABEL=(   [dvwa]="DVWA"             [juiceshop]="Juice Shop" )
declare -A TARGET_PORT=(    [dvwa]="8081"             [juiceshop]="3000" )
declare -A TARGET_URL=(     [dvwa]="http://127.0.0.1:8081" [juiceshop]="http://127.0.0.1:3000" )
declare -A TARGET_HINT=(    [dvwa]="First time: open ${TARGET_URL[dvwa]}/setup.php and click 'Create / Reset Database' before logging in."
                             [juiceshop]="Score tracker: ${TARGET_URL[juiceshop]}/#/score-board" )

is_valid_target() {
    local t="$1"
    for k in "${TARGET_KEYS[@]}"; do [ "$k" = "$t" ] && return 0; done
    return 1
}


detect_docker_access() {
    if docker info >/dev/null 2>&1; then
        NEED_SUDO=0
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 &&
       sudo docker info >/dev/null 2>&1; then
        NEED_SUDO=1
        return 0
    fi

    return 1
}

resolve_compose_cmd() {
    local sudo_prefix=()
    [ "$NEED_SUDO" = "1" ] && sudo_prefix=(sudo)
    if "${sudo_prefix[@]}" docker compose version &> /dev/null; then
        COMPOSE_CMD=("${sudo_prefix[@]}" docker compose); return 0
    fi
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD=("${sudo_prefix[@]}" docker-compose); return 0
    fi
    return 1
}

ensure_base_tools() {
    local missing=()
    command -v curl &> /dev/null || missing+=(curl)
    command -v ss   &> /dev/null || missing+=(iproute2)
    if [ "${#missing[@]}" -gt 0 ]; then
        info "Installing missing prerequisite(s): ${missing[*]}"
        $SUDO apt-get update -y
        $SUDO apt-get install -y "${missing[@]}" || warn "Could not install ${missing[*]}; some checks may not work."
    fi
}

install_docker_engine() {
    info "Docker engine not found. Installing via 'docker.io'..."
    $SUDO apt-get update -y
    if ! $SUDO apt-get install -y docker.io; then
        warn "Install failed, retrying with --fix-broken..."
        $SUDO apt-get install -y -f
        $SUDO apt-get install -y docker.io || { err "Could not install docker.io. Check network/apt sources."; exit 1; }
    fi
    if command -v systemctl &> /dev/null; then
        $SUDO systemctl enable docker --now 2>/dev/null || warn "Could not enable docker via systemctl."
    else
        $SUDO service docker start 2>/dev/null || warn "Could not start docker via service command."
    fi
    if ! groups "$USER" | grep -q '\bdocker\b'; then
        $SUDO usermod -aG docker "$USER"
        warn "Added $USER to the docker group. Using sudo for this session;"
        warn "log out/in (or run 'newgrp docker') so future runs don't need sudo."
    fi
    NEED_SUDO=1
    ok "Docker engine installed."
}

install_compose() {
    detect_docker_access
    if resolve_compose_cmd; then ok "docker compose already available."; return 0; fi
    info "No working 'docker compose' found. Trying known package names..."
    local pkg
    for pkg in docker-compose-plugin docker-compose-v2; do
        info "Trying apt package: $pkg"
        if $SUDO apt-get install -y "$pkg" &> /dev/null && resolve_compose_cmd; then
            ok "Installed compose via $pkg."; return 0
        fi
    done
    info "Trying legacy 'docker-compose' package..."
    if $SUDO apt-get install -y docker-compose &> /dev/null && resolve_compose_cmd; then
        ok "Installed legacy docker-compose."; return 0
    fi
    warn "No apt package worked. Downloading static compose binary as a last resort..."
    local arch url
    arch="$(uname -m)"
    url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
    $SUDO mkdir -p /usr/local/lib/docker/cli-plugins
    if $SUDO curl -fsSL "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose \
        && $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
        && resolve_compose_cmd; then
        ok "Installed compose via static binary download."; return 0
    fi
    err "Could not obtain a working 'docker compose' by any method."
    err "Try manually: sudo apt install docker-compose-plugin"
    return 1
}

ensure_docker_ready() {
    ensure_base_tools
    if ! command -v docker &> /dev/null; then
        install_docker_engine
    elif ! detect_docker_access; then
        err "Docker is installed but not usable, and no sudo is available."
        exit 1
    fi
    install_compose || exit 1
    [ -f "$COMPOSE_FILE" ] || { err "docker-compose.yml not found in $SCRIPT_DIR"; exit 1; }
}

dc() { "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" "$@"; }

container_state() {
    # prints: absent | running | stopped
    local svc="$1" cid
    cid=$(dc ps -q "$svc" 2>/dev/null)
    if [ -z "$cid" ]; then
        cid=$(dc ps -aq "$svc" 2>/dev/null)
        [ -z "$cid" ] && { echo "absent"; return; }
        echo "stopped"; return
    fi
    if docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true; then
        echo "running"
    else
        echo "stopped"
    fi
}

is_reachable() {
    curl -s -o /dev/null -m 2 "$1"
}

container_ip() {
    local svc="$1" cid
    cid=$(dc ps -q "$svc" 2>/dev/null)
    [ -z "$cid" ] && { echo "-"; return; }
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || echo "-"
}

port_owner_is_us() {
    # true if the process bound to $1 belongs to one of our containers
    local port="$1" t
    for t in "${TARGET_KEYS[@]}"; do
        [ "${TARGET_PORT[$t]}" = "$port" ] && [ "$(container_state "${TARGET_SERVICE[$t]}")" = "running" ] && return 0
    done
    return 1
}

check_port_conflict() {
    local target="$1" port="${TARGET_PORT[$1]}"
    [ "$(container_state "${TARGET_SERVICE[$target]}")" = "running" ] && return 0   # our own, not a conflict
    if command -v ss &> /dev/null && ss -ltn 2>/dev/null | grep -q ":${port} "; then
        err "Port $port is already in use by something else (needed for ${TARGET_LABEL[$target]})."
        err "Find what's using it: sudo ss -ltnp | grep :$port"
        return 1
    fi
    return 0
}


wait_ready() {
    local target="$1" url="${TARGET_URL[$1]}" tries=25 n=0
    echo -ne "${BLUE}[*]${NC} Waiting for ${TARGET_LABEL[$target]} to respond"
    while [ $n -lt $tries ]; do
        if is_reachable "$url"; then
            echo ""
            ok "${TARGET_LABEL[$target]} is up and reachable: $url"
            [ -n "${TARGET_HINT[$target]:-}" ] && info "${TARGET_HINT[$target]}"
            return 0
        fi
        echo -n "."
        sleep 2
        n=$((n+1))
    done
    echo ""
    warn "${TARGET_LABEL[$target]} container started but isn't answering HTTP yet."
    warn "It may still be initializing — check again with: ./lab.sh status"
    warn "If it's still not up in a minute, check logs: ./lab.sh logs $target"
    return 1
}


cmd_start_one() {
    local target="$1"
    local svc="${TARGET_SERVICE[$target]}"
    if [ "$(container_state "$svc")" = "running" ] && is_reachable "${TARGET_URL[$target]}"; then
        ok "${TARGET_LABEL[$target]} is already running: ${TARGET_URL[$target]}"
        return 0
    fi
    check_port_conflict "$target" || return 1
    info "Starting ${TARGET_LABEL[$target]}..."
    if dc up -d "$svc"; then
        wait_ready "$target"
    else
        err "Failed to start ${TARGET_LABEL[$target]}. Run './lab.sh doctor' for diagnostics."
        return 1
    fi
}

cmd_stop_one() {
    local target="$1" svc="${TARGET_SERVICE[$1]}"
    if [ "$(container_state "$svc")" = "absent" ]; then
        info "${TARGET_LABEL[$target]} isn't running."
        return 0
    fi
    info "Stopping ${TARGET_LABEL[$target]}..."
    dc stop "$svc" && ok "${TARGET_LABEL[$target]} stopped."
}

resolve_targets_arg() {
    # echoes a space-separated list of target keys for "", "all", or a specific name
    local arg="${1:-}"
    if [ -z "$arg" ] || [ "$arg" = "all" ]; then
        echo "${TARGET_KEYS[*]}"
    elif is_valid_target "$arg"; then
        echo "$arg"
    else
        return 1
    fi
}

cmd_start() {
    ensure_docker_ready
    local arg="${1:-}"
    if [ -z "$arg" ]; then
        arg="$(pick_target_menu "start")" || return 1
    fi
    local targets
    targets=$(resolve_targets_arg "$arg") || { err "Unknown target '$arg'. Try: ${TARGET_KEYS[*]} or all"; return 1; }
    local t rc=0
    for t in $targets; do cmd_start_one "$t" || rc=1; done
    echo ""
    cmd_status
    return $rc
}

cmd_stop() {
    ensure_docker_ready
    local arg="${1:-}"
    if [ -z "$arg" ]; then
        arg="$(pick_target_menu "stop")" || return 1
    fi
    local targets
    targets=$(resolve_targets_arg "$arg") || { err "Unknown target '$arg'. Try: ${TARGET_KEYS[*]} or all"; return 1; }
    local t rc=0
    for t in $targets; do cmd_stop_one "$t" || rc=1; done
    return $rc
}

cmd_status() {
    ensure_docker_ready
    head_ "Lab status"
    printf "  %-14s %-10s %-12s %s\n" "TARGET" "STATE" "REACHABLE" "URL"
    local t state reach url
    for t in "${TARGET_KEYS[@]}"; do
        state=$(container_state "${TARGET_SERVICE[$t]}")
        url="${TARGET_URL[$t]}"
        if [ "$state" = "running" ] && is_reachable "$url"; then
            reach="yes"
        elif [ "$state" = "running" ]; then
            reach="starting..."
        else
            reach="-"
        fi
        printf "  %-14s %-10s %-12s %s\n" "${TARGET_LABEL[$t]}" "$state" "$reach" "$url"
    done
}

cmd_list() {
    ensure_docker_ready
    head_ "Available targets"
    local t
    for t in "${TARGET_KEYS[@]}"; do
        echo ""
        echo -e "  ${BOLD}${TARGET_LABEL[$t]}${NC}  (key: $t)"
        echo "    Host URL:      ${TARGET_URL[$t]}"
        echo "    Container IP:  $(container_ip "${TARGET_SERVICE[$t]}")  (for nmap/recon against the lab subnet)"
        echo "    State:         $(container_state "${TARGET_SERVICE[$t]}")"
    done
    echo ""
}

cmd_logs() {
    ensure_docker_ready
    local target="${1:-}" follow="${2:-}"
    if [ -z "$target" ]; then
        target="$(pick_target_menu "view logs for")" || return 1
    fi
    is_valid_target "$target" || { err "Unknown target '$target'. Try: ${TARGET_KEYS[*]}"; return 1; }
    if [ "$(container_state "${TARGET_SERVICE[$target]}")" = "absent" ]; then
        info "${TARGET_LABEL[$target]} has never been started, so there are no logs yet."
        info "Start it first: ./lab.sh start $target"
        return 0
    fi
    if [ "$follow" = "-f" ] || [ "$follow" = "--follow" ]; then
        dc logs -f --tail=100 "${TARGET_SERVICE[$target]}"
    else
        dc logs --tail=100 "${TARGET_SERVICE[$target]}"
    fi
}

cmd_reset() {
    ensure_docker_ready
    local arg="" skip_confirm=0 a
    for a in "$@"; do
        case "$a" in
            -y|--yes) skip_confirm=1 ;;
            *) arg="$a" ;;
        esac
    done
    if [ -z "$arg" ]; then
        arg="$(pick_target_menu "reset")" || return 1
    fi
    local targets
    targets=$(resolve_targets_arg "$arg") || { err "Unknown target '$arg'. Try: ${TARGET_KEYS[*]} or all"; return 1; }

    warn "This will DELETE and recreate the container (and its data) for: $targets"
    if [ "$skip_confirm" != "1" ]; then
        read -r -p "Type 'yes' to confirm: " reply
        if [ "$reply" != "yes" ]; then
            info "Reset cancelled."
            return 0
        fi
    fi

    local t rc=0
    for t in $targets; do
        info "Resetting ${TARGET_LABEL[$t]}..."
        dc rm -sf "${TARGET_SERVICE[$t]}"
        cmd_start_one "$t" || rc=1
    done
    return $rc
}

cmd_doctor() {
    head_ "Environment check"
    if command -v docker &> /dev/null; then ok "docker binary found"; else err "docker binary missing"; fi

    if command -v systemctl &> /dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        ok "docker service running"
    else
        warn "docker service not active (or systemctl unavailable — normal in some containers)"
    fi

    if detect_docker_access; then
        ok "current user can reach docker (sudo needed: $NEED_SUDO)"
    else
        err "cannot talk to docker daemon at all — is Docker installed and running?"
    fi

    if resolve_compose_cmd; then
        ok "compose command resolved: ${COMPOSE_CMD[*]}"
    else
        err "no working compose command"
    fi

    echo ""
    head_ "Docker Hub reachability"
    if curl -s -m 4 -o /dev/null https://registry-1.docker.io/v2/; then
        ok "Docker Hub reachable (image pulls should work)"
    else
        warn "Could not reach Docker Hub — first-time image pulls may fail. Check internet/proxy/firewall."
    fi

    echo ""
    head_ "Disk / memory"
    df -h "$SCRIPT_DIR" | awk 'NR==1 || NR==2'
    local mem_avail
    mem_avail=$(free -m | awk '/^Mem:/{print $7}')
    free -h | awk 'NR==1 || NR==2'
    if [ -n "$mem_avail" ] && [ "$mem_avail" -lt 1024 ]; then
        warn "Less than 1GB RAM available — consider starting one target at a time (./lab.sh start dvwa)."
    fi

    echo ""
    head_ "Port availability"
    local t
    for t in "${TARGET_KEYS[@]}"; do
        local port="${TARGET_PORT[$t]}"
        if port_owner_is_us "$port"; then
            ok "Port $port is in use by our own ${TARGET_LABEL[$t]} container (expected)"
        elif command -v ss &> /dev/null && ss -ltn 2>/dev/null | grep -q ":${port} "; then
            err "Port $port is occupied by something else — needed for ${TARGET_LABEL[$t]}"
        else
            ok "Port $port is free"
        fi
    done

    echo ""
    head_ "Container/network sanity"
    for t in "${TARGET_KEYS[@]}"; do
        local svc="${TARGET_SERVICE[$t]}" state
        state=$(container_state "$svc")
        case "$state" in
            running) ok "${TARGET_LABEL[$t]} container: running" ;;
            stopped) warn "${TARGET_LABEL[$t]} container exists but is stopped — start with: ./lab.sh start $t" ;;
            absent)  info "${TARGET_LABEL[$t]} container not created yet — start with: ./lab.sh start $t" ;;
        esac
    done
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "lab_net"; then
        ok "lab_net docker network exists"
    fi
}

pick_target_menu() {
    local action="$1"
    echo "" >&2
    echo "Which target do you want to $action?" >&2
    local i=1
    local opts=()
    for t in "${TARGET_KEYS[@]}"; do
        echo "  $i) ${TARGET_LABEL[$t]}" >&2
        opts+=("$t")
        i=$((i+1))
    done
    echo "  $i) All targets" >&2
    opts+=("all")
    echo "  0) Cancel" >&2
    read -r -p "> " choice
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then return 1; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#opts[@]}" ]; then
        err "Invalid choice."
        return 1
    fi
    echo "${opts[$((choice-1))]}"
}

interactive_menu() {
    while true; do
        echo ""
        head_ "WebSecLab"
        echo "  1) Start a target"
        echo "  2) Stop a target"
        echo "  3) Status"
        echo "  4) List targets (URLs + container IPs)"
        echo "  5) Reset a target"
        echo "  6) View logs"
        echo "  7) Doctor (troubleshoot)"
        echo "  0) Quit"
        read -r -p "> " choice
        case "$choice" in
            1) cmd_start "" ;;
            2) cmd_stop "" ;;
            3) cmd_status ;;
            4) cmd_list ;;
            5) cmd_reset ;;
            6) cmd_logs ;;
            7) cmd_doctor ;;
            0) exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

usage() {
    cat <<EOF
$(echo -e "${BOLD}Web Sec Lab manager${NC}")

Usage: ./lab.sh <command> [target] [options]

Targets: ${TARGET_KEYS[*]}  (or "all")

Commands:
  start [target]        Start one target, all targets, or pick interactively
  stop  [target]        Stop one target, all targets, or pick interactively
  status                 Show state + reachability for every target
  list                    Show URLs and container IPs for every target
  logs  [target] [-f]    View recent logs (or follow) for a target
  reset [target] [-y]    Recreate a target from scratch (asks for confirmation)
  doctor                  Diagnose Docker/network/port/permission problems
  help                    Show this message

Examples:
  ./lab.sh start dvwa       Start only DVWA
  ./lab.sh start all        Start everything
  ./lab.sh stop juiceshop   Stop only Juice Shop
  ./lab.sh reset dvwa -y    Reset DVWA without confirmation prompt
  ./lab.sh                  Open the interactive menu
EOF
}


cmd="${1:-}"
[ -n "$cmd" ] && shift
case "$cmd" in
    start)   cmd_start "${1:-}" ;;
    stop)    cmd_stop "${1:-}" ;;
    status)  cmd_status ;;
    list)    cmd_list ;;
    logs)    cmd_logs "${1:-}" "${2:-}" ;;
    reset)   cmd_reset "$@" ;;
    doctor)  cmd_doctor ;;
    help|-h|--help) usage ;;
    "")      ensure_docker_ready; interactive_menu ;;
    *)       err "Unknown command: $cmd"; echo ""; usage; exit 1 ;;
esac