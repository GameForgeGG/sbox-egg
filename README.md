# GameForge s&box Egg

This repository contains Pterodactyl and Pelican eggs and container build assets for running an s&box dedicated server with Wine on Linux.

This is working in production. We use it to offer s&box server hosting: [Looking for a server?](https://gameforge.gg/games/sbox)

## Primary Goal

Provide a production-ready egg that:
- uses `start-sbox` as the startup command,
- supports common server variables from the panel,
- runs as non-root in container environments,
- seeds runtime files from baked templates (Wine prefix and server template),
- runs SteamCMD on every boot to keep the server up to date.

## Repository Layout

- `sandbox-pterodactyl.json` — Pterodactyl egg export (import into your Pterodactyl panel).
- `sandbox-pelican.json` — Pelican egg export (import into your Pelican panel).
- `Yolk/Dockerfile` — Docker image build definition.
- `Yolk/entrypoint.sh` — Runtime startup and orchestration logic.
- `Yolk/README.md` — Image build and runtime notes.
- `ref/` — Reference files used during development (not in the public repo).

## Architecture

The image uses a two-stage build:

1. **Builder** (`debian:trixie-slim`) — Installs Wine, winetricks, Windows .NET, and bakes S&Box Windows server content via SteamCMD into `/work/server`.
2. **Runtime** (`steamcmd/steamcmd:alpine`) — Official Valve SteamCMD Alpine image. Wine and runtime packages are installed on top. The baked Wine prefix and server template are copied from the builder.

SteamCMD is provided by the base image and runs at container startup to update the server.

## Egg Focus

Both egg files are functionally identical — they share the same Docker image, startup command, variables, and runtime behavior.

Key details:
- Startup command: `start-sbox`
- Done detection: `Loading game|Server started`
- Install script: no-op (all content is baked into the image)

## Panel Variables

| Variable | Description | Default |
|---|---|---|
| `GAME` | Primary game package (`+game`) | `facepunch.walker` |
| `SERVER_NAME` | Public server name | `Pterodactyl Sandbox Server` |
| `MAP` | Optional map/package identifier | |
| `SBOX_PROJECT` | Local `.sbproj` under `/home/container/projects/` | |
| `SBOX_EXTRA_ARGS` | Extra launch arguments | |
| `MAX_PLAYERS` | Maximum player count | |
| `SBOX_AUTO_UPDATE` | Run SteamCMD update on each boot (`0`/`1`) | `1` |
| `SBOX_BRANCH` | Steam beta branch for updates (e.g. `staging`) | |
| `SBOX_STEAMCMD_TIMEOUT` | Max seconds to wait for each SteamCMD probe/update call (`0` disables timeout) | `600` |
| `QUERY_PORT` | Server query port for direct connect | |
| `ENABLE_DIRECT_CONNECT` | Bypass Steam relay (`0`/`1`) | `0` |
| `TOKEN` | Steam game server token | |
| `WIN_DOTNET_VERSION` | Informational — .NET version baked into image | `10.0.0` |

## Runtime Behavior

At container start, `Yolk/entrypoint.sh`:
1. Seeds Wine prefix from baked template if not already present.
2. Seeds S&Box server files from baked template if `/home/container/sbox` is missing or empty.
3. Runs SteamCMD to update S&Box to the latest version (if `SBOX_AUTO_UPDATE=1`) with a bounded timeout per call.
4. Launches `sbox-server.exe` under Wine with the configured arguments.

If SteamCMD times out or fails but a previous `sbox-server.exe` exists, startup continues with existing files and the updater error is logged to `logs/sbox-update.log`.

Project selection precedence:
1. `SBOX_PROJECT` (resolved under `/home/container/projects/` or absolute path)
2. `GAME` (with optional `MAP`)

## Quick Start

1. Import the appropriate egg into your panel:
  - **Pterodactyl**: import `sandbox-pterodactyl.json`
  - **Pelican**: import `sandbox-pelican.json`
2. Set the Docker image to `ghcr.io/hyberhost/gameforge-sbox-egg:latest` (or your own build — see `Yolk/README.md`).
3. Create a server and configure variables.
4. Start the server. On first boot it will seed files and run the updater before launching.

## Notes

- Tuned for `linux/amd64` container runtime.
- Runtime behavior changes belong in `Yolk/entrypoint.sh`.
- Panel UX and variable changes belong in the egg JSON files.
- The `.wine` prefix and `sbox/` install directory live under `/home/container` (the Pterodactyl volume mount) and are populated on first boot.

## Notes for Hosting Providers

While this egg was built for [GameForge](https://gameforge.gg) to sell s&box hosting, we are happy to see other providers use it and welcome pull requests.