#!/usr/bin/env bash
set -euo pipefail

# Pre flight checks and variable defaults
CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
BAKED_SERVER_TEMPLATE="${SBOX_BAKED_SERVER_TEMPLATE:-/opt/sbox-server-template}"

# S&Box Specific variables with defaults
SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
SBOX_STEAMCMD_TIMEOUT="${SBOX_STEAMCMD_TIMEOUT:-600}"

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

# Computed variables
SERVER_PID=""

# Logging
LOG_DIR="${CONTAINER_HOME}/logs"
LOG_FILE="${LOG_DIR}/sbox-server.log"
ERROR_LOG="${LOG_DIR}/sbox-error.log"
UPDATE_LOG="${LOG_DIR}/sbox-update.log"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
mkdir -p "${LOG_DIR}"

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE}"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" | tee -a "${LOG_FILE}" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${ERROR_LOG}" >&2
}

# ============================================================================
# RUNTIME FILE SEEDING
# ============================================================================

seed_runtime_files() {
    local seed_sbox=0
    local seed_reason=""
    local baked_server_exe="${BAKED_SERVER_TEMPLATE}/sbox-server.exe"

    if [ ! -d "${SBOX_INSTALL_DIR}" ]; then
        seed_sbox=1
        seed_reason="missing install directory"
    elif [ -z "$(find "${SBOX_INSTALL_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        seed_sbox=1
        seed_reason="empty install directory"
    fi

    mkdir -p "${WINEPREFIX}"

    if [ "${seed_sbox}" = "1" ]; then
        mkdir -p "${SBOX_INSTALL_DIR}"
    fi

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        log_info "seeding Wine prefix from ${BAKED_WINEPREFIX}"
        cp -r "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi

    if [ "${seed_sbox}" = "1" ] && [ -f "${baked_server_exe}" ]; then
        log_info "seeding S&Box files from ${BAKED_SERVER_TEMPLATE} (${seed_reason})"
        cp -r "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/"
        if [ -f "${SBOX_SERVER_EXE}" ]; then
            log_info "prebaked S&Box seed complete (${SBOX_SERVER_EXE})"
        else
            log_warn "prebaked seed copy completed but ${SBOX_SERVER_EXE} is still missing"
        fi
    elif [ "${seed_sbox}" = "1" ]; then
        log_warn "${SBOX_INSTALL_DIR} requires reseed (${seed_reason}) but prebaked Windows template is missing ${baked_server_exe}"
    fi
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

    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64

    launch_env=(
        LD_LIBRARY_PATH=/usr/lib:/lib
        DOTNET_EnableWriteXorExecute=0
        DOTNET_TieredCompilation=0
        DOTNET_ReadyToRun=0
        DOTNET_ZapDisable=1
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
    log_info "Command: wine \"${SBOX_SERVER_EXE}\" ${redacted_args[*]}"

    cd "${SBOX_INSTALL_DIR}"
    # Run server in foreground so Pterodactyl can track the main process.
    # Tee stdout to `${LOG_FILE}` and stderr to `${ERROR_LOG}` while preserving console output.
    exec env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}" \
        > >(tee -a "${LOG_FILE}") \
        2> >(tee -a "${ERROR_LOG}" >&2)
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
        log_info "updating S&Box server files on boot..."
        update_sbox
    fi
    
    run_sbox "$@"
fi

exec "$@"