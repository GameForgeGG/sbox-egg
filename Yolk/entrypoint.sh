#!/usr/bin/env bash
set -euo pipefail

# Pre flight checks and variable defaults
CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"

# S&Box Specific variables with defaults
SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
SBOX_STEAMCMD_TIMEOUT="${SBOX_STEAMCMD_TIMEOUT:-600}"
STEAMCMD_EXTRA_ARGS="${STEAMCMD_EXTRA_ARGS:-}"

# Optional server configuration variables
GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
HOSTNAME_FALLBACK="${HOSTNAME:-}"
QUERY_PORT="${QUERY_PORT:-}"
MAX_PLAYERS="${MAX_PLAYERS:-}"
ENABLE_DIRECT_CONNECT="${ENABLE_DIRECT_CONNECT:-0}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_PROJECTS_DIR="${SBOX_PROJECTS_DIR:-${CONTAINER_HOME}/projects}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"
RUNTIME_MODE="${RUNTIME_MODE:-wine}"

# Logging
LOG_DIR="${CONTAINER_HOME}/logs"
UPDATE_LOG="${LOG_DIR}/sbox-update.log"
SBOX_LOG="${SBOX_INSTALL_DIR}/logs/sbox-server.log"
# Named FIFO used to inject commands into wine's stdin (created at server launch).
# Both the Pterodactyl console relay and the metrics loop write to this path.
SBOX_CMD_FIFO="${CONTAINER_HOME}/.sbox-cmd.fifo"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
mkdir -p "${LOG_DIR}"

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# ============================================================================
# RUNTIME FILE SEEDING
# ============================================================================

seed_runtime_files() {
    # Ensure runtime directories exist before SteamCMD updates/install.
    mkdir -p "${WINEPREFIX}"
    mkdir -p "${SBOX_INSTALL_DIR}"
}

# ============================================================================
# PATH RESOLUTION HELPERS
# ============================================================================

canonicalize_existing_path() {
    local input_path="$1"
    local input_dir=""
    local input_base=""

    if [ -z "${input_path}" ] || [ ! -e "${input_path}" ]; then
        return 1
    fi

    input_dir="$(dirname "${input_path}")"
    input_base="$(basename "${input_path}")"

    (
        cd "${input_dir}" 2>/dev/null || exit 1
        printf '%s/%s' "$(pwd -P)" "${input_base}"
    )
}

path_is_within_root() {
    local candidate_path="$1"
    local root_path="$2"

    case "${candidate_path}" in
        "${root_path}"|"${root_path}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_project_target() {
    local project_target=""
    local projects_root=""
    local candidate=""
    local resolved_candidate=""

    if [ -z "${SBOX_PROJECT}" ]; then
        printf '%s' ""
        return 0
    fi

    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    if [ -z "${projects_root}" ]; then
        printf '%s' ""
        return 0
    fi

    if [[ "${SBOX_PROJECT}" = /* ]]; then
        candidate="${SBOX_PROJECT}"
    else
        candidate="${SBOX_PROJECTS_DIR}/${SBOX_PROJECT}"
    fi

    if [ -f "${candidate}" ]; then
        resolved_candidate="$(canonicalize_existing_path "${candidate}" || true)"
        if [ -n "${resolved_candidate}" ] && [[ "${resolved_candidate}" = *.sbproj ]] && path_is_within_root "${resolved_candidate}" "${projects_root}"; then
            project_target="${resolved_candidate}"
        fi
    fi

    if [ -z "${project_target}" ] && [[ "${candidate}" != *.sbproj ]] && [ -f "${candidate}.sbproj" ]; then
        resolved_candidate="$(canonicalize_existing_path "${candidate}.sbproj" || true)"
        if [ -n "${resolved_candidate}" ] && path_is_within_root "${resolved_candidate}" "${projects_root}"; then
            project_target="${resolved_candidate}"
        fi
    fi

    printf '%s' "${project_target}"
}

ensure_project_libraries_dir() {
    local project_target="$1"
    local project_path=""
    local projects_root=""
    local project_dir=""
    local libraries_dir=""

    if [ -z "${project_target}" ]; then
        return 0
    fi

    if [[ "${project_target}" = /* ]]; then
        project_path="${project_target}"
    else
        project_path="${SBOX_PROJECTS_DIR}/${project_target}"
    fi

    if [ ! -f "${project_path}" ]; then
        return 1
    fi

    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    project_path="$(canonicalize_existing_path "${project_path}" || true)"

    if [ -z "${projects_root}" ] || [ -z "${project_path}" ]; then
        return 1
    fi

    if [[ "${project_path}" != *.sbproj ]] || ! path_is_within_root "${project_path}" "${projects_root}"; then
        return 1
    fi

    project_dir="$(dirname "${project_path}")"
    if ! path_is_within_root "${project_dir}" "${projects_root}"; then
        return 1
    fi

    libraries_dir="${project_dir}/Libraries"
    if [ ! -d "${libraries_dir}" ]; then
        mkdir -p "${libraries_dir}"
        log_info "created required local project folder ${libraries_dir}"
    fi
}

# ============================================================================
# STEAMCMD HELPERS
# ============================================================================

resolve_steamcmd_binary() {
    local candidate=""

    for candidate in \
        "/usr/bin/steamcmd" \
        "/usr/games/steamcmd"
    do
        if [ -f "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    return 1
}

run_steamcmd() {
    local -a args=("$@")
    local steamcmd_bin=""
    local steamcmd_library_path="/lib:/usr/lib/games/steam"

    mkdir -p "${CONTAINER_HOME}/.steam" "${CONTAINER_HOME}/.local/share" "${CONTAINER_HOME}/Steam"
    ln -sfn "${CONTAINER_HOME}/Steam" "${CONTAINER_HOME}/.steam/root"
    ln -sfn "${CONTAINER_HOME}/Steam" "${CONTAINER_HOME}/.steam/steam"

    steamcmd_bin="$(resolve_steamcmd_binary || true)"

    if [ -z "${steamcmd_bin}" ]; then
        log_warn "SteamCMD binary not found in expected locations"
        return 1
    fi

    HOME="${CONTAINER_HOME}" LD_LIBRARY_PATH="${steamcmd_library_path}" "${steamcmd_bin}" "${args[@]}"
}

run_steamcmd_with_timeout() {
    local timeout_seconds="$1"
    shift
    local -a args=("$@")
    local steamcmd_bin=""
    local steamcmd_library_path="/lib:/usr/lib/games/steam"

    mkdir -p "${CONTAINER_HOME}/.steam" "${CONTAINER_HOME}/.local/share" "${CONTAINER_HOME}/Steam"
    ln -sfn "${CONTAINER_HOME}/Steam" "${CONTAINER_HOME}/.steam/root"
    ln -sfn "${CONTAINER_HOME}/Steam" "${CONTAINER_HOME}/.steam/steam"

    steamcmd_bin="$(resolve_steamcmd_binary || true)"
    if [ -z "${steamcmd_bin}" ]; then
        log_warn "SteamCMD binary not found in expected locations"
        return 1
    fi

    # Normalize timeout_seconds to integer by stripping fractional part
    if [[ "${timeout_seconds}" == *.* ]]; then
        timeout_seconds="${timeout_seconds%%.*}"
    fi
    # Default to 0 if empty after stripping
    if [ -z "${timeout_seconds}" ]; then
        timeout_seconds=0
    fi

    if [ "${timeout_seconds}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        HOME="${CONTAINER_HOME}" LD_LIBRARY_PATH="${steamcmd_library_path}" timeout "${timeout_seconds}" "${steamcmd_bin}" "${args[@]}"
        return $?
    fi

    HOME="${CONTAINER_HOME}" LD_LIBRARY_PATH="${steamcmd_library_path}" "${steamcmd_bin}" "${args[@]}"
}

# ============================================================================
# UPDATE FUNCTIONS
# ============================================================================

update_sbox() {
    local -a steam_args
    local -a steam_args_retry
    local -a probe_args
    local force_platform="windows"
    local steamcmd_status=0

    : > "${UPDATE_LOG}"

    probe_args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +quit
    )

    steam_args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sSteamCmdForcePlatformType "${force_platform}"
    )

    if [ -n "${STEAMCMD_EXTRA_ARGS}" ]; then
        read -ra _extra_args <<< "${STEAMCMD_EXTRA_ARGS}"
        steam_args+=( "${_extra_args[@]}" )
    fi

    steam_args+=(
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )

    if [ -n "${SBOX_BRANCH}" ]; then
        steam_args+=( -beta "${SBOX_BRANCH}" )
    fi

    steam_args_retry=("${steam_args[@]}")
    steam_args+=( validate +quit )
    steam_args_retry+=( +quit )

    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${probe_args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    steamcmd_status=${PIPESTATUS[0]}
    set -e
    if [ "${steamcmd_status}" -ne 0 ]; then
        log_warn "SteamCMD runtime probe failed; cannot run auto-update"
        if [ "${steamcmd_status}" -eq 124 ]; then
            log_warn "SteamCMD probe timed out after ${SBOX_STEAMCMD_TIMEOUT}s (common hang point: Steam API/user info)"
        fi
        log_warn "see ${UPDATE_LOG} for details"
        if [ ! -f "${SBOX_SERVER_EXE}" ]; then
            log_error "${SBOX_SERVER_EXE} was not found"
            log_error "run the egg installation script, or enable auto-update after SteamCMD has been installed"
            return 1
        fi
        log_warn "continuing startup with existing server files because ${SBOX_SERVER_EXE} already exists"
        return 0
    fi

    log_info "running SteamCMD app_update for app ${SBOX_APP_ID} with forced platform '${force_platform}'"
    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${steam_args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    steamcmd_status=${PIPESTATUS[0]}
    set -e
    if [ "${steamcmd_status}" -ne 0 ]; then
        if grep -q "Missing configuration" "${UPDATE_LOG}"; then
            log_warn "SteamCMD reported missing configuration; retrying app_update once without validate"
            set +e
            run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${steam_args_retry[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
            steamcmd_status=${PIPESTATUS[0]}
            set -e
        fi

        if [ "${steamcmd_status}" -eq 0 ]; then
            log_info "SteamCMD retry completed successfully"
            return 0
        fi

        log_warn "SteamCMD update failed with forced platform '${force_platform}'; refusing Linux fallback to preserve Wine-compatible server files"
        if [ "${steamcmd_status}" -eq 124 ]; then
            log_warn "SteamCMD update timed out after ${SBOX_STEAMCMD_TIMEOUT}s"
        fi
        log_warn "see ${UPDATE_LOG} for details"
        if [ -f "${SBOX_SERVER_EXE}" ]; then
            log_warn "continuing startup with existing server files because ${SBOX_SERVER_EXE} already exists"
            return 0
        fi
        return 1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ] && [ -d "${SBOX_INSTALL_DIR}/linux64" ]; then
        log_warn "update finished but Windows server executable is still missing while linux64 content exists in ${SBOX_INSTALL_DIR}"
    fi
}

# ============================================================================
# MAIN SERVER EXECUTION
# ============================================================================

# Send a console command to the running server via the stdin FIFO.
# Available once run_sbox has created the FIFO; silently ignored before then.
send_server_cmd() {
    if [ -p "${SBOX_CMD_FIFO:-}" ]; then
        printf '%s\n' "$*" > "${SBOX_CMD_FIFO}" 2>/dev/null &
    else
        log_warn "send_server_cmd: '$*' ignored (server FIFO not ready)"
    fi
}

# ============================================================================
# EGG-METRICS INTEGRATION
# ============================================================================
# Posts system + player metrics to an egg-metrics server at a regular interval.
#
# Egg variables to expose in Pterodactyl (all optional):
#   EGG_METRICS_URL      base URL, e.g. https://metrics.example.com
#   EGG_METRICS_ENABLED  set to "0" to opt out of reporting (default: "1")
#   EGG_METRICS_GAME     game slug sent to the API (default: "sbox")
#   EGG_METRICS_INTERVAL seconds between metric pushes (default: 30)
#
# The following Pterodactyl built-in variables are used automatically and do
# NOT need to be re-exposed as egg variables:
#   P_SERVER_UUID  → server identifier
#   SERVER_IP      → reported IP address
#   SERVER_MEMORY  → allocated memory limit in MB (used as memory_max)
# ============================================================================

EGG_METRICS_URL="http://185.242.225.133:2458"
EGG_METRICS_ENABLED="1"
EGG_METRICS_GAME="sbox"
EGG_METRICS_INTERVAL="10"


# Fire-and-forget JSON POST — never fatal.
egg_metrics_post() {
    local endpoint="$1" payload="$2"
    [ "${EGG_METRICS_ENABLED:-1}" = "1" ] || return 0
    [ -n "${EGG_METRICS_URL:-}" ] || return 0
    if command -v curl > /dev/null 2>&1; then
        curl -sf --connect-timeout 5 -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${EGG_METRICS_URL%/}${endpoint}" > /dev/null 2>&1 || true
    else
        wget -q -O /dev/null --timeout=5 \
            --header="Content-Type: application/json" \
            --post-data="$payload" \
            "${EGG_METRICS_URL%/}${endpoint}" > /dev/null 2>&1 || true
    fi
}

# Return a stable server UUID.
# Priority: P_SERVER_UUID (Pterodactyl) → PTERODACTYL_SERVER_UUID → persisted
# file at /home/container/uuid → newly generated UUID (persisted for next run).
_get_server_uuid() {
    [ -n "${P_SERVER_UUID:-}" ]              && printf '%s' "${P_SERVER_UUID}"              && return 0
    [ -n "${PTERODACTYL_SERVER_UUID:-}" ]    && printf '%s' "${PTERODACTYL_SERVER_UUID}"    && return 0
    local uuid_file="${CONTAINER_HOME}/uuid"
    if [ -f "$uuid_file" ]; then
        local saved
        saved="$(cat "$uuid_file" 2>/dev/null || true)"
        [ -n "$saved" ] && printf '%s' "$saved" && return 0
    fi
    local new_uuid
    if [ -r /proc/sys/kernel/random/uuid ]; then
        new_uuid="$(cat /proc/sys/kernel/random/uuid)"
    elif command -v uuidgen > /dev/null 2>&1; then
        new_uuid="$(uuidgen)"
    else
        new_uuid="$(hostname)-$(date +%s)"
    fi
    printf '%s\n' "$new_uuid" > "$uuid_file" 2>/dev/null || true
    printf '%s' "$new_uuid"
}

# Register the server with egg-metrics on startup.
# Call once just before launching the server process.
egg_metrics_start() {
    [ -n "${EGG_METRICS_URL:-}" ] || return 0
    local uuid
    uuid="$(_get_server_uuid)"
    # SERVER_IP / SERVER_PORT are Pterodactyl built-ins; combine into host:port.
    local _start_ip="${SERVER_IP:-}"
    [ -n "${SERVER_PORT:-}" ] && _start_ip="${_start_ip}:${SERVER_PORT}"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local payload
    payload="$(printf '{
  "server_uuid": "%s",
  "game": "%s",
  "ip": ["%s"],
  "verables": [
    {"key":"SERVER_NAME","value":"%s"},
    {"key":"MAP","value":"%s"},
    {"key":"GAME","value":"%s"},
    {"key":"MAX_PLAYERS","value":"%s"}
  ],
  "timestamp": "%s",
  "api_version": "1.0"
}' \
        "$uuid" "${EGG_METRICS_GAME:-sbox}" "$_start_ip" \
        "${SERVER_NAME:-}" "${MAP:-}" "${GAME:-}" "${MAX_PLAYERS:-0}" \
        "$ts")"

    egg_metrics_post "/api/ingest/start" "$payload"
    log_info "[egg-metrics] registered server ${uuid} with ${EGG_METRICS_URL}"
}

# Post a lifecycle event (start / stop / crash).
# Usage: egg_metrics_event <event_type> [event_name] [description]
egg_metrics_event() {
    [ -n "${EGG_METRICS_URL:-}" ] || return 0
    local event_type="$1" event_name="${2:-}" description="${3:-}"
    local uuid
    uuid="$(_get_server_uuid)"
    local payload
    payload="$(printf '{"server_uuid":"%s","game":"%s","event_type":"%s","event_name":"%s","description":"%s"}' \
        "$uuid" "${EGG_METRICS_GAME:-sbox}" "$event_type" "$event_name" "$description")"
    egg_metrics_post "/api/ingest/event" "$payload"
}

# Collect all PIDs in the process tree rooted at $1 via a single awk pass
# over /proc/[0-9]*/stat.  Handles comm names that contain spaces or parens.
_proc_tree_pids() {
    local root="$1"
    awk -v root="$root" '
    {
        pid = $1
        # Locate the closing ") " to extract ppid without being confused by
        # spaces inside the comm field.
        close_paren = index($0, ") ")
        rest = substr($0, close_paren + 2)
        split(rest, f, " ")
        ppid = f[2]
        children[ppid] = (ppid in children ? children[ppid] " " : "") pid
    }
    END {
        n = 1; queue[1] = root
        while (n > 0) {
            p = queue[1]
            for (i = 1; i < n; i++) queue[i] = queue[i+1]
            delete queue[n]; n--
            print p
            if (p in children) {
                cnt = split(children[p], ch)
                for (i = 1; i <= cnt; i++) { n++; queue[n] = ch[i] }
            }
        }
    }
    ' /proc/[0-9]*/stat 2>/dev/null
}

# Sum utime+stime (fields 14+15 in /proc/pid/stat) for each PID argument.
_sum_proc_ticks() {
    local total=0 pid t
    for pid in "$@"; do
        [ -f "/proc/${pid}/stat" ] || continue
        t="$(awk '{
            close_paren = index($0, ") ")
            rest = substr($0, close_paren + 2)
            split(rest, f, " ")
            print f[12] + f[13]
        }' "/proc/${pid}/stat" 2>/dev/null)" || continue
        total=$(( total + ${t:-0} ))
    done
    echo "$total"
}

# Sample wine process-tree CPU usage over 1 s; returns CPU% × 10
# (e.g. 1080 = 108.0%).  Scoped to wine and all its descendants so that
# activity in other containers does not pollute the reading.
# Falls back to system-wide /proc/stat only when wine is not running yet.
_metrics_read_cpu() {
    local root_pid
    root_pid="$(pgrep -x wine 2>/dev/null | head -1 || pgrep -x wine64 2>/dev/null | head -1 || true)"

    # ── fallback: system-wide /proc/stat (server not started yet) ───────────
    if [ -z "$root_pid" ]; then
        local _u1 _n1 _s1 _i1 _io1 _u2 _n2 _s2 _i2 _io2
        read -r _ _u1 _n1 _s1 _i1 _io1 _ _ < /proc/stat
        sleep 1
        read -r _ _u2 _n2 _s2 _i2 _io2 _ _ < /proc/stat
        local total1=$(( _u1 + _n1 + _s1 + _i1 + _io1 ))
        local total2=$(( _u2 + _n2 + _s2 + _i2 + _io2 ))
        local dtotal=$(( total2 - total1 ))
        local didle=$(( _i2 - _i1 ))
        [ "$dtotal" -eq 0 ] && echo "0" && return
        local ncpus
        ncpus=$(grep -c '^cpu[0-9]' /proc/stat 2>/dev/null || echo 1)
        echo $(( (dtotal - didle) * 1000 * ncpus / dtotal ))
        return
    fi

    # ── wine process tree ────────────────────────────────────────────────────
    local clk_tck
    clk_tck="$(getconf CLK_TCK 2>/dev/null || echo 100)"

    local -a tree_pids
    mapfile -t tree_pids < <(_proc_tree_pids "$root_pid")

    local ticks1 ticks2
    ticks1="$(_sum_proc_ticks "${tree_pids[@]}")"
    sleep 1
    # Refresh tree: short-lived wineserver threads may have spawned/exited.
    mapfile -t tree_pids < <(_proc_tree_pids "$root_pid")
    ticks2="$(_sum_proc_ticks "${tree_pids[@]}")"

    local delta=$(( ticks2 - ticks1 ))
    [ "$delta" -lt 0 ] && delta=0

    # delta ticks / CLK_TCK = CPU-seconds consumed in the 1 s window.
    # * 1000 → CPU% × 10 (same reporting unit as the /proc/stat fallback path):
    # e.g. wine using 2 cores fully = 200 ticks → 2000 → reported as 200.0%.
    echo $(( delta * 1000 / clk_tck ))
}

# Returns "<used_bytes> <total_bytes>" scoped to this container.
# Reads cgroup memory files (accurate inside Docker/Pterodactyl containers).
# Falls back to /proc/meminfo only when no cgroup files are present.
#
# Cgroup v2: memory.current / memory.max  (values already in bytes)
# Cgroup v1: memory.usage_in_bytes / memory.limit_in_bytes minus total_cache
# /proc/meminfo fallback: host-level, used as last resort only.
_metrics_read_memory() {
    local used=0 total=0

    # ── cgroup v2 ────────────────────────────────────────────────────────────
    if [ -f /sys/fs/cgroup/memory.current ]; then
        used="$(cat /sys/fs/cgroup/memory.current 2>/dev/null)" || used=0
        local _max_raw
        _max_raw="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)" || _max_raw="max"
        # "max" means unlimited; treat as 0 (caller overrides with SERVER_MEMORY)
        if [ "$_max_raw" = "max" ] || [ -z "$_max_raw" ]; then
            total=0
        else
            total="$_max_raw"
        fi
        # Subtract inactive file cache — kernel considers it reclaimable
        if [ -f /sys/fs/cgroup/memory.stat ]; then
            local _inactive_file
            _inactive_file="$(grep '^inactive_file ' /sys/fs/cgroup/memory.stat 2>/dev/null | awk '{print $2}')" || _inactive_file=0
            used=$(( used - ${_inactive_file:-0} ))
            [ "$used" -lt 0 ] && used=0
        fi
        echo "${used:-0} ${total:-0}"
        return
    fi

    # ── cgroup v1 ────────────────────────────────────────────────────────────
    if [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
        used="$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)" || used=0
        total="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)" || total=0
        # Large sentinel value (≥ 1 TiB) means unlimited
        if [ "${total:-0}" -gt $(( 1024 * 1024 * 1024 * 1024 )) ] 2>/dev/null; then
            total=0
        fi
        # Subtract page cache (total_cache) — not actual RSS
        if [ -f /sys/fs/cgroup/memory/memory.stat ]; then
            local _cache
            _cache="$(grep '^total_cache ' /sys/fs/cgroup/memory/memory.stat 2>/dev/null | awk '{print $2}')" || _cache=0
            used=$(( used - ${_cache:-0} ))
            [ "$used" -lt 0 ] && used=0
        fi
        echo "${used:-0} ${total:-0}"
        return
    fi

    # ── /proc/meminfo fallback (host-scoped; inaccurate inside containers) ───
    local available=0 free=0 buffers=0 cached=0 sreclaimable=0 key val
    while IFS=: read -r key val; do
        key="${key// /}"; val="${val//[^0-9]/}"
        case "$key" in
            MemTotal)     total="$val"        ;;
            MemAvailable) available="$val"    ;;
            MemFree)      free="$val"         ;;
            Buffers)      buffers="$val"      ;;
            Cached)       cached="$val"       ;;
            SReclaimable) sreclaimable="$val" ;;
        esac
    done < /proc/meminfo
    if [ "${available:-0}" -gt 0 ] 2>/dev/null; then
        used=$(( total - available ))
    else
        used=$(( total - free - buffers - cached - sreclaimable ))
    fi
    [ "${used:-0}" -lt 0 ] && used=0
    # /proc/meminfo values are in kB; convert to bytes
    echo "$(( used * 1024 )) $(( total * 1024 ))"
}

# Returns "<used_bytes> <total_bytes>" for the container home directory.
# used  = actual bytes consumed by files inside /home/container (via du).
# total = total capacity of the underlying filesystem (via df -B1).
_metrics_read_storage() {
    local used=0 total=0 df_line
    if command -v du &>/dev/null; then
        used="$(du -sb "${CONTAINER_HOME}" 2>/dev/null | awk '{print $1}')" || used=0
    fi
    if command -v df &>/dev/null; then
        df_line="$(df -B1 "${CONTAINER_HOME}" 2>/dev/null | tail -1)" || df_line=""
        if [ -n "$df_line" ]; then
            read -r _ total _ _ _ _ <<< "$df_line" || true
        fi
    fi
    echo "${used:-0} ${total:-0}"
}

# Returns "<rx_bytes> <tx_bytes>" cumulative for all non-loopback interfaces.
_metrics_read_net() {
    local rx=0 tx=0
    if [ -f /proc/net/dev ]; then
        while IFS= read -r line; do
            [[ "$line" == *"Inter"* || "$line" == *"face"* ]] && continue
            [[ "$line" =~ ^[[:space:]]*lo: ]] && continue
            local _iface _r _t
            read -r _iface _r _ _ _ _ _ _ _ _t _ <<< "${line//:/ }"
            (( rx += _r )) || true
            (( tx += _t )) || true
        done < /proc/net/dev
    fi
    echo "$rx $tx"
}

# Inject 'status' into the server's stdin via TIOCSTI (ioctl 0x5412).
# TIOCSTI inserts bytes directly into the PTY's input queue, exactly as if
# the operator typed them.  The 'ttyinject' binary (compiled in the image)
# calls ioctl(0, TIOCSTI, &char) for each character of its argument.
#
# Requirements:
#   - ttyinject must be present at /usr/local/bin/ttyinject (built in DockerFile)
#   - fd 0 must be the container PTY slave (standard Pterodactyl/Pelican setup)
#   - kernel dev.tty.legacy_tiocsti must be 1 (default on most hosts; restricted
#     on explicitly hardened distros such as RHEL 9 / Fedora 38+)
_metrics_send_status_cmd() {
    command -v ttyinject > /dev/null 2>&1 || return 0
    ttyinject 'status' 2>/dev/null || true
}

# Parse the S&Box server log and return a JSON array of currently connected players.
#
# Reads the last "PLAYERS ----------" section written by the `status` command.
# Actual player line format (whitespace-separated fields):
#   HH:MM:SS  Generic  UUID  SteamID64  State  DisplayName...  M/D/YYYY  H:MM:SS  AM/PM  +TZ
# 'State' is e.g. 'Welcome' (joining) or 'Connected' — not a fixed string.
_metrics_parse_players() {
    local log_file="$1"
    [ -f "$log_file" ] || { echo "[]"; return; }

    # Only scan the last 300 lines so the awk stays fast on long-running servers.
    local json
    json="$(tail -n 300 "$log_file" | awk '
        /PLAYERS[[:space:]]+-+/ { in_s=1; n=0; delete sid; delete nm; next }
        in_s && NF >= 10 &&
            $4 ~ /^[0-9]+$/ && length($4) >= 10 &&
            $3 ~ /^[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-/ {
            steamid = $4
            name = ""
            for (i = 6; i <= NF-4; i++) name = name (i>6 ? " " : "") $i
            gsub(/"/, "\\\"", name)
            sid[n] = steamid; nm[n] = name; n++
        }
        END {
            printf "["
            for (i=0; i<n; i++) {
                if (i>0) printf ","
                printf "{\"identifier\":\"%s\",\"display_name\":\"%s\"}", sid[i], nm[i]
            }
            printf "]"
        }
    ')"
    echo "${json:-[]}"
}

# ── Main metrics loop ────────────────────────────────────────────────────────

# Poll system stats + player list and push to the egg-metrics API every interval.
# Falls back to local-only logging when EGG_METRICS_URL is not set.
start_metrics_loop() {
    local interval="${EGG_METRICS_INTERVAL:-${SBOX_METRICS_INTERVAL:-30}}"

    if [ -z "${EGG_METRICS_URL:-}" ]; then
        log_warn "[egg-metrics] EGG_METRICS_URL not set; writing player counts to local log only"
        _start_local_metrics_loop "$interval"
        return
    fi

    local uuid
    uuid="$(_get_server_uuid)"
    local ingest_url="${EGG_METRICS_URL%/}/api/ingest"
    # SERVER_IP / SERVER_PORT are Pterodactyl built-ins; combine into host:port.
    local _ip="${SERVER_IP:-}"
    [ -n "${SERVER_PORT:-}" ] && _ip="${_ip}:${SERVER_PORT}"

    (
        # Disable strict-mode inside this long-running background loop so that
        # individual metric-read failures (e.g. grep returning 1 for no matches,
        # a temporarily unavailable /proc file, etc.) do not kill the subshell.
        set +eo pipefail

        # Wait up to 60 s for the server log to appear before the first push.
        waited=0
        while [ ! -f "${SBOX_LOG}" ] && [ "$waited" -lt 60 ]; do
            sleep 2; waited=$(( waited + 2 ))
        done

        prev_rx=0 prev_tx=0 first=1

        while true; do
            # _metrics_read_cpu sleeps 1 s internally; adjust the remaining wait.
            sleep "$(( interval > 1 ? interval - 1 : interval ))"

            # Send 'status' now; the 1 s CPU sleep below gives the server time
            # to write the PLAYERS section to the log before we parse it.
            _metrics_send_status_cmd || true

            # ── system metrics ───────────────────────────────────────────────
            cpu_raw="$(_metrics_read_cpu)"
            cpu="$(( cpu_raw / 10 )).$(( cpu_raw % 10 ))"

            read -r mem_used mem_max <<< "$(_metrics_read_memory)"
            # SERVER_MEMORY is the Pterodactyl-allocated limit in MB; prefer it
            # over the kernel-reported total which may reflect the whole host.
            if [ -n "${SERVER_MEMORY:-}" ] && [ "${SERVER_MEMORY}" -gt 0 ] 2>/dev/null; then
                mem_max=$(( SERVER_MEMORY * 1024 * 1024 ))
            fi
            read -r stor_used stor_max <<< "$(_metrics_read_storage)"
            read -r cur_rx    cur_tx   <<< "$(_metrics_read_net)"

            if [ "$first" -eq 1 ]; then
                net_rx=0; net_tx=0; first=0
            else
                net_rx=$(( (cur_rx - prev_rx) / interval ))
                net_tx=$(( (cur_tx - prev_tx) / interval ))
                [ "$net_rx" -lt 0 ] && net_rx=0
                [ "$net_tx" -lt 0 ] && net_tx=0
            fi
            prev_rx=$cur_rx; prev_tx=$cur_tx

            # ── player list (status was sent above; parsed from log now) ──────
            players_json="$(_metrics_parse_players "${SBOX_LOG}")"
            # Use a brace group so grep's exit-1 (no matches) doesn't propagate
            # as a pipeline failure and kill the loop under set -o pipefail.
            player_count="$(printf '%s' "$players_json" | { grep -o '"identifier"' || true; } | wc -l)"

            # ── POST to /api/ingest ──────────────────────────────────────────
            mem_used_mb=$(( mem_used / 1024 / 1024 ))
            stor_used_mb=$(( stor_used / 1024 / 1024 ))
            ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            payload="$(printf '{
  "server_uuid": "%s",
  "game": "%s",
  "ip": ["%s"],
  "metrics": {
    "cpu": %s,
    "memory": %s,
    "storage": %s,
    "network_rx": %s,
    "network_tx": %s,
    "players": %s
  },
  "current_players": %s,
  "timestamp": "%s",
  "api_version": "1.0"
}' \
                "$uuid" "${EGG_METRICS_GAME:-sbox}" "$_ip" \
                "$cpu" \
                "$mem_used_mb" \
                "$stor_used_mb" \
                "$net_rx" "$net_tx" \
                "$player_count" \
                "$players_json" \
                "$ts")"

            _post_ok=0
            if command -v curl > /dev/null 2>&1; then
                curl -sf --connect-timeout 5 -X POST \
                    -H "Content-Type: application/json" \
                    -d "$payload" \
                    "$ingest_url" > /dev/null 2>&1 && _post_ok=1 || true
            else
                wget -q -O /dev/null --timeout=5 \
                    --header="Content-Type: application/json" \
                    --post-data="$payload" \
                    "$ingest_url" > /dev/null 2>&1 && _post_ok=1 || true
            fi
            if [ "$_post_ok" -eq 1 ]; then
                : #log_info "[egg-metrics] cpu=${cpu}% mem=${mem_used_mb}MB net_rx=${net_rx}B/s players=${player_count}"
            else
                : #log_warn "[egg-metrics] failed to post metrics to ${ingest_url}"
            fi
        done
    ) &
}

# Minimal fallback used when EGG_METRICS_URL is not configured.
_start_local_metrics_loop() {
    local interval="$1"
    local metrics_log="${LOG_DIR}/sbox-metrics.log"
    (
        waited=0
        while [ ! -f "${SBOX_LOG}" ] && [ "$waited" -lt 30 ]; do
            sleep 1; waited=$(( waited + 1 ))
        done
        while true; do
            sleep "$interval"
            [ -f "${SBOX_LOG}" ] || continue
            connects=$(grep -c "connected$" "${SBOX_LOG}" 2>/dev/null || echo 0)
            disconnects=$(grep -c "disconnected\|dropped\|timed out" "${SBOX_LOG}" 2>/dev/null || echo 0)
            player_count=$(( connects - disconnects ))
            [ "$player_count" -lt 0 ] && player_count=0
            printf '[%s] METRICS: players_online=%d\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$player_count" >> "$metrics_log"
        done
    ) &
}

run_sbox() {
    local -a cli_args=("$@")
    local -a args=()
    local -a extra=()
    local -a launch_env=()
    local -a redacted_args=()
    local project_target=""
    local resolved_server_name="${SERVER_NAME}"
    local cli_has_game_flag=0
    local cli_arg=""
    local server_status=0

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        log_error "${SBOX_SERVER_EXE} was not found. Cannot start S&Box server."
        log_info "try deleting the /sbox folder to trigger a reseed from the prebaked template."
        exit 1
    fi

    project_target="$(resolve_project_target)"

    for cli_arg in "${cli_args[@]}"; do
        if [ "${cli_arg}" = "+game" ]; then
            cli_has_game_flag=1
            break
        fi
    done

    if [ -n "${project_target}" ]; then
        ensure_project_libraries_dir "${project_target}"
        args+=( +game "${project_target}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    elif [ "${cli_has_game_flag}" = "1" ]; then
        :
    else
        log_error "missing startup target; set a project target (SBOX_PROJECT) or provide GAME and MAP (current: GAME='${GAME:-}', MAP='${MAP:-}')"
        exit 1
    fi

    if [ -n "${TOKEN}" ]; then
        args+=( +net_game_server_token "${TOKEN}" )
    fi

    # Adds Max Players argument if the variable is set and greater than 0 or "" 
    if [ -n "${MAX_PLAYERS}" ] && [ "${MAX_PLAYERS}" -gt 0 ]; then
        args+=( +maxplayers "${MAX_PLAYERS}" )
    fi

    # Add direct connect option if enabled
    if [ "${ENABLE_DIRECT_CONNECT}" = "1" ]; then
        args+=( +net_hide_address 0 +port ${SERVER_PORT:-27015} )
    fi

    if [ -n "${QUERY_PORT:-}" ]; then
        args+=( +net_query_port "${QUERY_PORT}" )
    fi

    if [ -n "${SBOX_EXTRA_ARGS}" ]; then
        read -ra extra <<< "${SBOX_EXTRA_ARGS}"
        args+=( "${extra[@]}" )
    fi

    if [ "${#cli_args[@]}" -gt 0 ]; then
        args+=( "${cli_args[@]}" )
    fi

    if [ -n "${resolved_server_name}" ]; then
        args+=( +hostname "${resolved_server_name}" )
    fi

    launch_env=(
        LD_LIBRARY_PATH=/usr/lib:/lib
        DOTNET_EnableWriteXorExecute=0
        DOTNET_TieredCompilation=0
        DOTNET_ReadyToRun=0
        DOTNET_ZapDisable=1
        DOTNET_ROOT_X64=Z:\\opt\\sbox-dotnet
        DOTNET_ROOT=Z:\\opt\\sbox-dotnet
    )

    i=0
    while [ $i -lt ${#args[@]} ]; do
        arg="${args[$i]}"
        if [[ "$arg" == "+net_game_server_token" ]]; then
            redacted_args+=( "+net_game_server_token" "[REDACTED]" )
            i=$((i+2))
            continue
        fi
        if [[ "$arg" == "+hostname" && $((i+1)) -lt ${#args[@]} ]]; then
            # Log +hostname and its value as two separate elements, but quote the value for the log output
            redacted_args+=( "+hostname" )
            redacted_args+=( "\"${args[$((i+1))]}\"" )
            i=$((i+2))
            continue
        fi
        redacted_args+=( "$arg" )
        i=$((i+1))
    done

    if [ "${ENABLE_DIRECT_CONNECT}" = "1" ]; then
        log_info "Starting S&Box server in direct-connect mode (port=${SERVER_PORT:-27015}, query_port=${QUERY_PORT:-unset})"
    else
        log_info "Starting S&Box server in Steam relay mode"
    fi
    log_info "Command: ${RUNTIME_MODE} \"${SBOX_SERVER_EXE}\" ${redacted_args[*]}"

    # Register server and post the start event before handing off to the process.
    egg_metrics_start
    egg_metrics_event "start" "server_start" "S&Box server starting (runtime=${RUNTIME_MODE:-wine})"

    cd "${SBOX_INSTALL_DIR}"

    if [ "${RUNTIME_MODE}" = "proton" ]; then
        if [ -x "/home/container/.local/share/Proton/proton" ]; then
            launch_env+=( STEAM_COMPAT_DATA_PATH="${WINEPREFIX}" )
            exec "/home/container/.local/share/Proton/proton" run "${SBOX_SERVER_EXE}" "${args[@]}"
        else
            log_error "Proton runtime selected but /home/container/.local/share/Proton/proton not found or not executable"
            exit 1
        fi
    elif [ "${RUNTIME_MODE}" = "linux" ]; then
        log_error "Linux native runtime mode is not yet supported; please switch to wine or proton while this is being worked on and tested"
        exit 1
    else # default to wine
        # S&Box writes its own logs to ${SBOX_INSTALL_DIR}/logs/sbox-server.log.
        # Pass wine stdout/stderr straight to the console with no extra pipe.
        # Not using exec so we can capture the exit code and post a stop/crash event.
        #
        # NOTE: wine uses GetConsoleMode()/isatty() to decide whether to process
        # stdin as console input.  When stdin is a pipe or FIFO, wine's wineconserver
        # stops accepting console commands — so wine MUST inherit the container PTY
        # directly.  The PTY master is held by Docker and is not writable from within
        # the container, so automatic command injection (e.g. 'status' for metrics)
        # is not possible without elevated capabilities.  Users can type commands
        # directly in the Pterodactyl/Pelican console as normal.
        set +e
        env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}"
        server_status=$?
        set -e
    fi

    # Exit codes 130 (SIGINT/^C) and 143 (SIGTERM) are clean shutdowns, not errors.
    if [ "${server_status}" -ne 0 ] && [ "${server_status}" -ne 130 ] && [ "${server_status}" -ne 143 ]; then
        log_error "sbox-server exited with status ${server_status}"
        log_error "startup failed after launch command; inspect recent Wine output above for root cause"
        egg_metrics_event "crash" "server_crash" "S&Box exited with non-zero status ${server_status}"
    else
        egg_metrics_event "stop" "server_stop" "S&Box server stopped cleanly (status=${server_status})"
    fi

    exit "${server_status}"
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if [ "${1:-}" = "start-sbox" ]; then
    shift
fi

seed_runtime_files

if [ "${1:-}" = "" ] || [[ "${1}" = +* ]]; then
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        update_sbox
    fi

    start_metrics_loop
    run_sbox "$@"
fi

exec "$@"