#!/usr/bin/env bash
set -euo pipefail

# Ensure all output is captured even if the container crashes
exec 2>&1

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
BAKED_SERVER_TEMPLATE="${SBOX_BAKED_SERVER_TEMPLATE:-/opt/sbox-server-template}"
BAKED_STEAMCMD_TEMPLATE="${SBOX_BAKED_STEAMCMD_TEMPLATE:-/opt/sbox-steamcmd-template}"

SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
SBOX_LOG_KEEP="${SBOX_LOG_KEEP:-10}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"

# .NET and Wine configuration
WINEDEBUG="${WINEDEBUG:--all}"
WIN_DOTNET_VERSION="${WIN_DOTNET_VERSION:-10.0.0}"
DOTNET_EnableWriteXorExecute="${DOTNET_EnableWriteXorExecute:-0}"
DOTNET_TieredCompilation="${DOTNET_TieredCompilation:-0}"
DOTNET_ReadyToRun="${DOTNET_ReadyToRun:-0}"
DOTNET_ZapDisable="${DOTNET_ZapDisable:-1}"

GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

# Trap errors and log them before exiting
trap 'echo "error: entrypoint script failed at line ${LINENO}" >&2' ERR

seed_runtime_files() {
    echo "info: seeding runtime files..." >&2
    mkdir -p "${CONTAINER_HOME}" "${WINEPREFIX}" "${SBOX_INSTALL_DIR}" "${CONTAINER_HOME}/logs" "${CONTAINER_HOME}/data" "${CONTAINER_HOME}/sbox/config"

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        echo "info: seeding Wine prefix from ${BAKED_WINEPREFIX}" >&2
        cp -a "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/" || { echo "error: failed to copy Wine prefix" >&2; return 1; }
        chmod -R u+rwX,g+rX,o+rX "${WINEPREFIX}" || true
    elif [ ! -f "${WINEPREFIX}/system.reg" ]; then
        echo "error: Wine prefix not found; expected at ${WINEPREFIX}/system.reg or ${BAKED_WINEPREFIX}/drive_c" >&2
        return 1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ] && [ -d "${BAKED_SERVER_TEMPLATE}" ]; then
        echo "info: seeding S&Box files from ${BAKED_SERVER_TEMPLATE}" >&2
        cp -a "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/" || { echo "error: failed to copy S&Box files" >&2; return 1; }
        chmod -R u+rwX,g+rX,o+rX "${SBOX_INSTALL_DIR}" || true
    elif [ ! -f "${SBOX_SERVER_EXE}" ]; then
        echo "error: S&Box server executable not found; expected at ${SBOX_SERVER_EXE} or ${BAKED_SERVER_TEMPLATE}" >&2
        return 1
    fi

    if [ ! -f "${CONTAINER_HOME}/.steamcmd/steamcmd.sh" ] && [ -d "${BAKED_STEAMCMD_TEMPLATE}" ]; then
        echo "info: seeding SteamCMD from ${BAKED_STEAMCMD_TEMPLATE}" >&2
        mkdir -p "${CONTAINER_HOME}/.steamcmd"
        cp -a "${BAKED_STEAMCMD_TEMPLATE}/." "${CONTAINER_HOME}/.steamcmd/" || { echo "error: failed to copy SteamCMD" >&2; return 1; }
        chmod -R u+rwX,g+rX,o+rX "${CONTAINER_HOME}/.steamcmd" || true
        chmod +x "${CONTAINER_HOME}/.steamcmd/steamcmd.sh" "${CONTAINER_HOME}/.steamcmd/linux64/steamcmd" 2>/dev/null || true
    elif [ ! -f "${CONTAINER_HOME}/.steamcmd/steamcmd.sh" ]; then
        echo "warn: SteamCMD not found; expected at ${CONTAINER_HOME}/.steamcmd/steamcmd.sh or ${BAKED_STEAMCMD_TEMPLATE}" >&2
    fi

    echo "info: runtime seeding complete" >&2
}

update_sbox() {
    local steamcmd_home="${CONTAINER_HOME}/.steamcmd"
    local steamcmd_bin="${STEAMCMD_BIN:-${steamcmd_home}/steamcmd.sh}"
    local -a steam_args

    # If auto-update is explicitly disabled (0), skip entirely
    if [ "${SBOX_AUTO_UPDATE}" != "1" ]; then
        echo "info: SteamCMD auto-update is disabled (SBOX_AUTO_UPDATE=${SBOX_AUTO_UPDATE})" >&2
        return 0
    fi

    # Auto-update is enabled, but we need SteamCMD to actually run it
    if [ ! -r "${steamcmd_bin}" ]; then
        echo "error: auto-update requested but SteamCMD not available at ${steamcmd_bin}" >&2
        echo "error: ensure SBOX_BAKED_STEAMCMD_TEMPLATE=/opt/sbox-steamcmd-template is properly copied in Dockerfile" >&2
        return 1
    fi

    echo "info: running SteamCMD app_update for app ${SBOX_APP_ID}" >&2
    mkdir -p "${SBOX_INSTALL_DIR}"

    steam_args=(
        +@sSteamCmdForcePlatformType "${STEAM_PLATFORM}"
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )

    if [ -n "${SBOX_BRANCH}" ]; then
        steam_args+=( -beta "${SBOX_BRANCH}" )
    fi

    steam_args+=( validate +quit )
    bash "${steamcmd_bin}" "${steam_args[@]}"
}

rotate_logs() {
    local log_dir="${CONTAINER_HOME}/logs"
    local keep_count="${SBOX_LOG_KEEP}"
    
    mkdir -p "${log_dir}"
    
    # If keep count is 0 or less, disable rotation (unlimited log retention as per JSON config)
    if [ "${keep_count}" -le 0 ]; then
        return 0
    fi
    
    # Keep only the N most recent logs, delete older ones
    local threshold=$((keep_count + 1))
    find "${log_dir}" -maxdepth 1 -name 'sbox-*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +${threshold} | awk '{print $2}' \
        | xargs -r rm -f
}

validate_startup() {
    local failed=0

    if ! command -v wine >/dev/null 2>&1; then
        echo "error: wine not found in PATH" >&2
        failed=1
    fi

    if [ ! -d "${WINEPREFIX}" ]; then
        echo "error: missing WINEPREFIX at ${WINEPREFIX}" >&2
        failed=1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        echo "error: missing server executable at ${SBOX_SERVER_EXE}" >&2
        failed=1
    fi

    if [ ! -w "${CONTAINER_HOME}/logs" ]; then
        echo "error: logs directory is not writable at ${CONTAINER_HOME}/logs" >&2
        failed=1
    fi

    if [ ! -w "${CONTAINER_HOME}/data" ]; then
        echo "error: data directory is not writable at ${CONTAINER_HOME}/data" >&2
        failed=1
    fi

    # Intentionally treated as a warning instead of a fatal validation error:
    # some deployments run the server without a default GAME/SBOX_PROJECT so that
    # it can start idle or be configured at runtime. Failing startup here would
    # break those use cases, so we only emit a warning and allow startup to continue.
    if [ -z "${GAME}" ] && [ -z "${SBOX_PROJECT}" ]; then
        echo "warn: neither GAME nor SBOX_PROJECT is set; no startup game/project is configured (server may fail to start or run idle without a game loaded)" >&2
        echo "warn: set GAME env var (e.g., GAME=facepunch.walker) or SBOX_PROJECT to specify a startup target" >&2
    fi

    if [ "${failed}" -ne 0 ]; then
        exit 1
    fi
}

healthcheck() {
    local failed=0

    if ! command -v wine >/dev/null 2>&1; then
        echo "healthcheck: wine not found in PATH" >&2
        failed=1
    fi

    if [ ! -d "${WINEPREFIX}" ]; then
        echo "healthcheck: missing WINEPREFIX at ${WINEPREFIX}" >&2
        failed=1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        echo "healthcheck: missing server executable at ${SBOX_SERVER_EXE}" >&2
        failed=1
    fi

    if [ ! -w "${CONTAINER_HOME}/logs" ]; then
        echo "healthcheck: logs directory is not writable at ${CONTAINER_HOME}/logs" >&2
        failed=1
    fi

    if [ ! -w "${CONTAINER_HOME}/data" ]; then
        echo "healthcheck: data directory is not writable at ${CONTAINER_HOME}/data" >&2
        failed=1
    fi

    if [ "${failed}" -ne 0 ]; then
        exit 1
    fi

    echo "healthcheck: ok"
}

run_sbox() {
    local -a args
    local -a extra
    local -a launch_env
    local log_file="${CONTAINER_HOME}/logs/sbox-$(date -u '+%Y%m%d-%H%M%S').log"

    rotate_logs
    echo "info: logging to ${log_file}" >&2

    if [ -n "${SBOX_PROJECT}" ]; then
        args+=( "${SBOX_PROJECT}" )
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    fi

    if [ -n "${SERVER_NAME}" ]; then
        args+=( +hostname "${SERVER_NAME}" )
    fi

    if [ -n "${TOKEN}" ]; then
        args+=( +net_game_server_token "${TOKEN}" )
    fi

    if [ -n "${SBOX_EXTRA_ARGS}" ]; then
        read -r -a extra <<< "${SBOX_EXTRA_ARGS}"
        args+=( "${extra[@]}" )
    fi

    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64

    launch_env=(
        DOTNET_EnableWriteXorExecute="${DOTNET_EnableWriteXorExecute}"
        COMPlus_TieredCompilation="${DOTNET_TieredCompilation}"
        COMPlus_ReadyToRun="${DOTNET_ReadyToRun}"
        COMPlus_ZapDisable="${DOTNET_ZapDisable}"
    )

    cd "${SBOX_INSTALL_DIR}"
    env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}" 2>&1 \
        | tee "${log_file}"
    exit "${PIPESTATUS[0]}"
}

if [ "${1:-}" = "start-sbox" ]; then
    shift
fi

seed_runtime_files

if [ "${1:-}" = "healthcheck" ]; then
    healthcheck
    exit 0
fi

if [ "${1:-}" = "" ]; then
    validate_startup
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        update_sbox
    fi
    run_sbox
fi

exec "$@"