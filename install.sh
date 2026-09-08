#!/bin/bash
# ============================================================
# SOM Web Hacking Lab — student lab manager
# Works on any Kali (or Debian-based) install. Idempotent.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
cd "$SCRIPT_DIR" || exit 1

# ---------- colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[-]${NC} $1"; }

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
NEED_SUDO=0
COMPOSE_CMD=()   # array, e.g. (docker compose) or (sudo docker-compose) — avoids all quoting bugs

# Privilege escalation for install/admin commands (apt, systemctl, usermod).
# Distinct from NEED_SUDO, which is only about running `docker` itself.
if [ "$(id -u)" = "0" ]; then
    SUDO=""
elif command -v sudo &> /dev/null; then
    SUDO="sudo"
else
    err "This script needs root privileges (run as root, or install sudo) to install packages."
    exit 1
fi

# ------------------------------------------------------------
# Can the current user talk to the docker daemon directly?
# Never shells out to a bare `sudo <cmd>` here — that can hang
# forever waiting on a password prompt in non-interactive runs.
# ------------------------------------------------------------
detect_docker_access() {
    if docker info &> /dev/null; then
        NEED_SUDO=0
        return 0
    fi
    if command -v sudo &> /dev/null; then
        NEED_SUDO=1
        return 0   # sudo will prompt interactively when actually used — that's fine for a student at a terminal
    fi
    return 1  # no direct access and no sudo binary at all — unrecoverable
}

# ------------------------------------------------------------
# Resolve a working compose invocation into the COMPOSE_CMD array.
# ------------------------------------------------------------
resolve_compose_cmd() {
    local sudo_prefix=()
    [ "$NEED_SUDO" = "1" ] && sudo_prefix=(sudo)

    if "${sudo_prefix[@]}" docker compose version &> /dev/null; then
        COMPOSE_CMD=("${sudo_prefix[@]}" docker compose)
        return 0
    fi
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD=("${sudo_prefix[@]}" docker-compose)
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# Make sure basic tools the script relies on are present.
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Install the Docker engine itself (not compose).
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Install a working compose command, trying multiple package
# names (they differ across Debian/Kali releases) before
# falling back to a static binary download.
# ------------------------------------------------------------
install_compose() {
    detect_docker_access
    if resolve_compose_cmd; then
        ok "docker compose already available."
        return 0
    fi

    info "No working 'docker compose' found. Trying known package names..."
    local pkg
    for pkg in docker-compose-plugin docker-compose-v2; do
        info "Trying apt package: $pkg"
        if $SUDO apt-get install -y "$pkg" &> /dev/null; then
            if resolve_compose_cmd; then
                ok "Installed compose via $pkg."
                return 0
            fi
        fi
    done

    info "Trying legacy 'docker-compose' package..."
    if $SUDO apt-get install -y docker-compose &> /dev/null && resolve_compose_cmd; then
        ok "Installed legacy docker-compose."
        return 0
    fi

    warn "No apt package worked. Downloading static compose binary as a last resort..."
    local arch url
    arch="$(uname -m)"
    url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
    $SUDO mkdir -p /usr/local/lib/docker/cli-plugins
    if $SUDO curl -fsSL "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose \
        && $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
        && resolve_compose_cmd; then
        ok "Installed compose via static binary download."
        return 0
    fi

    err "Could not obtain a working 'docker compose' by any method."
    err "Try manually: sudo apt install docker-compose-plugin"
    return 1
}

# ------------------------------------------------------------
# Top-level readiness check used by every command that touches docker.
# ------------------------------------------------------------
ensure_docker_ready() {
    ensure_base_tools

    if ! command -v docker &> /dev/null; then
        install_docker_engine
    elif ! detect_docker_access; then
        err "Docker is installed but not usable, and no sudo is available."
        exit 1
    else
        ok "Docker engine already installed and usable."
    fi

    install_compose || exit 1
    ok "Using compose command: ${COMPOSE_CMD[*]}"
}

# ------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------
cmd_up() {
    ensure_docker_ready
    [ -f "$COMPOSE_FILE" ] || { err "docker-compose.yml not found in $SCRIPT_DIR"; exit 1; }
    info "Starting lab targets..."
    if "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d; then
        ok "Lab is up."
        cmd_status
    else
        err "Failed to start containers. Run './lab.sh doctor' for diagnostics."
        exit 1
    fi
}

cmd_down() {
    ensure_docker_ready
    info "Stopping lab targets..."
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down
    ok "Lab stopped."
}

cmd_reset() {
    ensure_docker_ready
    local target="${1:-}"
    local valid_targets=("dvwa" "juiceshop")

    if [ -z "$target" ]; then
        warn "Resetting ALL lab containers (down -v, then up)..."
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down -v
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d
    else
        local valid=0
        for t in "${valid_targets[@]}"; do [ "$t" = "$target" ] && valid=1; done
        if [ "$valid" = "0" ]; then
            err "Unknown target '$target'. Valid options: ${valid_targets[*]}"
            exit 1
        fi
        info "Resetting '$target'..."
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" rm -sf "$target"
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d "$target"
    fi
    ok "Reset complete."
    cmd_status
}

cmd_status() {
    ensure_docker_ready
    echo ""
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps
    echo ""
    info "Checking target reachability..."
    check_target "DVWA" "http://127.0.0.1:8081"
    check_target "Juice Shop" "http://127.0.0.1:3000"
}

check_target() {
    local name="$1" url="$2"
    if curl -s -o /dev/null -m 3 "$url"; then
        ok "$name reachable at $url"
    else
        warn "$name NOT reachable yet at $url (may still be starting — retry in a few seconds)"
    fi
}

cmd_doctor() {
    echo "== Environment check =="
    if command -v docker &> /dev/null; then ok "docker binary found"; else err "docker binary missing"; fi

    if command -v systemctl &> /dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        ok "docker service running"
    else
        warn "docker service not active (or systemctl unavailable — normal in some containers)"
    fi

    if detect_docker_access; then
        ok "current user can reach docker (sudo needed: $NEED_SUDO)"
    else
        err "cannot talk to docker daemon at all"
    fi

    if resolve_compose_cmd; then
        ok "compose command resolved: ${COMPOSE_CMD[*]}"
    else
        err "no working compose command"
    fi

    echo ""
    echo "== Disk / memory =="
    df -h "$SCRIPT_DIR" | awk 'NR==1 || NR==2'
    free -h | awk 'NR==1 || NR==2'

    echo ""
    echo "== Port availability =="
    for p in 8081 3000; do
        if command -v ss &> /dev/null && ss -ltn 2>/dev/null | grep -q ":$p "; then
            warn "Port $p is already in use — this may conflict with the lab"
        else
            ok "Port $p is free"
        fi
    done
}

usage() {
    cat <<EOF
SOM Web Hacking Lab manager

Usage: ./lab.sh <command> [args]

Commands:
  up              Install Docker if needed and start all lab targets
  down            Stop lab targets
  status          Show container state and check target reachability
  reset [name]    Reset one target (dvwa|juiceshop) or all if no name given
  doctor          Diagnose common environment problems
EOF
}

cmd="${1:-}"
[ -n "$cmd" ] && shift
case "$cmd" in
    up)      cmd_up ;;
    down)    cmd_down ;;
    status)  cmd_status ;;
    reset)   cmd_reset "${1:-}" ;;
    doctor)  cmd_doctor ;;
    "")      usage ;;
    *)       err "Unknown command: $cmd"; echo ""; usage; exit 1 ;;
esac