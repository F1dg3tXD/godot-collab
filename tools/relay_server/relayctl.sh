#!/usr/bin/env bash
#
# Start/stop the Godot Collab relay with all bundled features enabled:
#
#   1. the ENet/UDP relay (Godot, headless)          -> --port      (default 45900/udp)
#   2. the short-code rendezvous service (Python)    -> --rendezvous-port (default 9080/tcp)
#   3. the server-side live project mirror           -> --projects-dir
#
# Both services run in the background, log to tools/relay_server/run/, and are
# tracked with PID files so stop/restart/status work across shells.
#
# Usage:
#   tools/relay_server/relayctl.sh start [options]
#   tools/relay_server/relayctl.sh stop
#   tools/relay_server/relayctl.sh restart [options]
#   tools/relay_server/relayctl.sh status
#
# Options (start/restart):
#   --port <n>             Relay UDP port           (default $RELAY_PORT or 45900)
#   --bind <address>       Relay bind address      (default $RELAY_BIND or *)
#   --max-clients <n>      Max ENet clients        (default $RELAY_MAX_CLIENTS or 64)
#   --rendezvous-port <n>  Rendezvous TCP port     (default $RENDEZVOUS_PORT or 9080)
#   --rendezvous-bind <a>  Rendezvous bind address (default $RENDEZVOUS_BIND or 0.0.0.0)
#   --projects-dir <dir>   Live mirror directory   (default $MIRROR_DIR or tools/relay_server/projects)
#   --godot <path>         Godot binary            (default $GODOT or `godot`)
#   --help                 Show this help
#
# Environment variables with the same names are honoured. Pass
# `--projects-dir ""` to disable the mirror (pure in-memory relay).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
RELAY_PID_FILE="$RUN_DIR/relay.pid"
RENDEZVOUS_PID_FILE="$RUN_DIR/rendezvous.pid"
RELAY_LOG="$RUN_DIR/relay.log"
RENDEZVOUS_LOG="$RUN_DIR/rendezvous.log"
CONFIG_FILE="$RUN_DIR/config.env"

GODOT="${GODOT:-godot}"
RELAY_PORT="${RELAY_PORT:-45900}"
RELAY_BIND="${RELAY_BIND:-*}"
RELAY_MAX_CLIENTS="${RELAY_MAX_CLIENTS:-64}"
RENDEZVOUS_PORT="${RENDEZVOUS_PORT:-9080}"
RENDEZVOUS_BIND="${RENDEZVOUS_BIND:-0.0.0.0}"
MIRROR_DIR="${MIRROR_DIR:-$SCRIPT_DIR/projects}"
START_TIMEOUT="${START_TIMEOUT:-30}"

usage() {
    sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --port) RELAY_PORT="${2:?--port needs a value}"; shift 2 ;;
            --bind) RELAY_BIND="${2:?--bind needs a value}"; shift 2 ;;
            --max-clients) RELAY_MAX_CLIENTS="${2:?--max-clients needs a value}"; shift 2 ;;
            --rendezvous-port) RENDEZVOUS_PORT="${2:?--rendezvous-port needs a value}"; shift 2 ;;
            --rendezvous-bind) RENDEZVOUS_BIND="${2:?--rendezvous-bind needs a value}"; shift 2 ;;
            --projects-dir) MIRROR_DIR="${2?--projects-dir needs a value}"; shift 2 ;;
            --godot) GODOT="${2:?--godot needs a value}"; shift 2 ;;
            --help|-h) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

save_config() {
    {
        printf 'RELAY_PORT=%q\n' "$RELAY_PORT"
        printf 'RELAY_BIND=%q\n' "$RELAY_BIND"
        printf 'RELAY_MAX_CLIENTS=%q\n' "$RELAY_MAX_CLIENTS"
        printf 'RENDEZVOUS_PORT=%q\n' "$RENDEZVOUS_PORT"
        printf 'RENDEZVOUS_BIND=%q\n' "$RENDEZVOUS_BIND"
        printf 'MIRROR_DIR=%q\n' "$MIRROR_DIR"
    } > "$CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

pid_of() {
    local pid_file="$1"
    [ -f "$pid_file" ] || return 1
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    case "$pid" in
        *[!0-9]*) return 1 ;;
    esac
    echo "$pid"
}

is_running() {
    local pid_file="$1" pid
    pid="$(pid_of "$pid_file")" || return 1
    kill -0 "$pid" 2>/dev/null
}

port_open() {
    local host="$1" port="$2"
    [ "$host" = "0.0.0.0" ] && host="127.0.0.1"
    [ "$host" = "*" ] && host="127.0.0.1"
    python3 - "$host" "$port" <<'PY' >/dev/null 2>&1
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(1.0)
try:
    sock.connect((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

wait_ready() {
    local deadline=$((SECONDS + START_TIMEOUT))
    local relay_log_offset
    relay_log_offset="$(wc -c < "$RELAY_LOG" 2>/dev/null || echo 0)"
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! is_running "$RELAY_PID_FILE"; then
            echo "Relay exited during startup:" >&2
            tail -n 20 "$RELAY_LOG" >&2 2>/dev/null || true
            return 1
        fi
        if ! is_running "$RENDEZVOUS_PID_FILE"; then
            echo "Rendezvous exited during startup:" >&2
            tail -n 20 "$RENDEZVOUS_LOG" >&2 2>/dev/null || true
            return 1
        fi
        local relay_ready=0 rendezvous_ready=0
        if tail -c +"$((relay_log_offset + 1))" "$RELAY_LOG" 2>/dev/null | grep -q "Godot Collab relay running"; then
            relay_ready=1
        fi
        if port_open "$RENDEZVOUS_BIND" "$RENDEZVOUS_PORT"; then
            rendezvous_ready=1
        fi
        if [ "$relay_ready" -eq 1 ] && [ "$rendezvous_ready" -eq 1 ]; then
            return 0
        fi
        sleep 0.2
    done
    echo "Timed out after ${START_TIMEOUT}s waiting for the services to become ready." >&2
    return 1
}

start_services() {
    if is_running "$RELAY_PID_FILE" || is_running "$RENDEZVOUS_PID_FILE"; then
        echo "Already running (use 'restart' to apply new options)."
        status_services
        return 0
    fi
    if ! command -v "$GODOT" >/dev/null 2>&1; then
        echo "Godot binary not found: $GODOT (set GODOT or --godot)." >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 is required for the rendezvous service." >&2
        return 1
    fi

    mkdir -p "$RUN_DIR"
    if [ -n "$MIRROR_DIR" ]; then
        mkdir -p "$MIRROR_DIR"
    fi

    cd "$PROJECT_DIR"
    if [ ! -f .godot/global_script_class_cache.cfg ]; then
        echo "Building GDScript class cache (first run)..."
        "$GODOT" --headless --import >/dev/null 2>&1 || true
    fi

    save_config

    trap ':' TERM INT
    : > "$RELAY_LOG"
    : > "$RENDEZVOUS_LOG"

    local relay_args=(--port "$RELAY_PORT" --max-clients "$RELAY_MAX_CLIENTS" --bind "$RELAY_BIND")
    if [ -n "$MIRROR_DIR" ]; then
        relay_args+=(--projects-dir "$MIRROR_DIR")
    fi

    nohup "$GODOT" --headless --script tools/relay_server/relay_server.gd -- "${relay_args[@]}" \
        >> "$RELAY_LOG" 2>&1 &
    echo $! > "$RELAY_PID_FILE"

    nohup python3 tools/rendezvous_server/rendezvous_server.py \
        --host "$RENDEZVOUS_BIND" --port "$RENDEZVOUS_PORT" \
        >> "$RENDEZVOUS_LOG" 2>&1 &
    echo $! > "$RENDEZVOUS_PID_FILE"

    if ! wait_ready; then
        stop_services quiet
        return 1
    fi

    echo "Relay started."
    status_services
}

stop_services() {
    local quiet="${1:-}"
    local stopped=0
    for pid_file in "$RELAY_PID_FILE" "$RENDEZVOUS_PID_FILE"; do
        local pid
        if pid="$(pid_of "$pid_file")" && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            local deadline=$((SECONDS + 10))
            while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
            stopped=1
        fi
        rm -f "$pid_file"
    done
    if [ "$quiet" != "quiet" ]; then
        if [ "$stopped" -eq 1 ]; then
            echo "Relay stopped."
        else
            echo "Not running."
        fi
    fi
}

status_services() {
    local relay_state="stopped" rendezvous_state="stopped"
    local relay_pid rendezvous_pid
    relay_pid="$(pid_of "$RELAY_PID_FILE" || true)"
    rendezvous_pid="$(pid_of "$RENDEZVOUS_PID_FILE" || true)"
    if [ -n "$relay_pid" ] && kill -0 "$relay_pid" 2>/dev/null; then
        relay_state="running (pid $relay_pid)"
    fi
    if [ -n "$rendezvous_pid" ] && kill -0 "$rendezvous_pid" 2>/dev/null; then
        rendezvous_state="running (pid $rendezvous_pid)"
    fi
    echo "Relay:      $relay_state  udp/$RELAY_BIND:$RELAY_PORT"
    echo "Rendezvous: $rendezvous_state  tcp/$RENDEZVOUS_BIND:$RENDEZVOUS_PORT"
    if [ -n "$MIRROR_DIR" ]; then
        echo "Mirror:     $MIRROR_DIR"
    else
        echo "Mirror:     disabled"
    fi
    echo "Logs:       $RUN_DIR"
    if [ "$relay_state" != "stopped" ]; then
        echo "Invite URL: http://<relay-host>:$RENDEZVOUS_PORT (for short codes)"
    fi
}

command="${1:-}"
case "$command" in
    start) shift; parse_args "$@"; start_services ;;
    stop) stop_services ;;
    restart) shift; parse_args "$@"; stop_services quiet; start_services ;;
    status) load_config; status_services ;;
    --help|-h|help|"") usage ;;
    *) echo "Unknown command: $command" >&2; usage >&2; exit 2 ;;
esac
