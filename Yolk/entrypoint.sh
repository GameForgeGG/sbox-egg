#!/usr/bin/env bash
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
BAKED_SERVER_TEMPLATE="${SBOX_BAKED_SERVER_TEMPLATE:-/opt/sbox-server-template}"

SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"

GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

# Backward compatibility for older eggs that used HOSTNAME.
# Avoid using Docker's auto-generated container hostname (typically a hex ID).
if [ -z "${SERVER_NAME}" ] && [ -n "${HOSTNAME:-}" ] && ! [[ "${HOSTNAME}" =~ ^[0-9a-f]{12,64}$ ]]; then
    SERVER_NAME="${HOSTNAME}"
fi

seed_runtime_files() {
    mkdir -p "${CONTAINER_HOME}" "${WINEPREFIX}" "${SBOX_INSTALL_DIR}" "${CONTAINER_HOME}/logs"

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        echo "info: seeding Wine prefix from ${BAKED_WINEPREFIX}" >&2
        cp -r "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ] && [ -d "${BAKED_SERVER_TEMPLATE}" ]; then
        echo "info: seeding S&Box files from ${BAKED_SERVER_TEMPLATE}" >&2
        cp -r "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/"
    fi

}


run_sbox() {
    local -a args
    local -a extra
    local -a launch_env

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
        DOTNET_EnableWriteXorExecute=0
        COMPlus_TieredCompilation=0
        COMPlus_ReadyToRun=0
        COMPlus_ZapDisable=1
    )

    cd "${SBOX_INSTALL_DIR}"
    exec env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}"
}

if [ "${1:-}" = "start-sbox" ]; then
    shift
fi

seed_runtime_files

if [ "${1:-}" = "" ]; then
    run_sbox
fi

exec "$@"