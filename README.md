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

- `sandbox-pterodactyl.json` — Pterodactyl egg export for the Wine-based runtime image.
- `sandbox-linux-native-pterodactyl.json` — Pterodactyl egg export for Debian native Linux builds from `DrakeFruit/sbox-public` (`linux-fixes`).
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

The repository now includes two Pterodactyl egg tracks:
- `sandbox-pterodactyl.json`: Wine-based runtime image path (stable production path).
- `sandbox-linux-native-pterodactyl.json`: native Linux source-build path for Debian using `DrakeFruit/sbox-public` `linux-fixes`.

The Pelican egg mirrors the Wine-based track.

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
| `QUERY_PORT` | Server query port for direct connect | |
| `ENABLE_DIRECT_CONNECT` | Bypass Steam relay (`0`/`1`) | `0` |
| `TOKEN` | Steam game server token | |
| `WIN_DOTNET_VERSION` | Informational — .NET version baked into image | `10.0.0` |

## Runtime Behavior

At container start, `Yolk/entrypoint.sh`:
1. Seeds Wine prefix from baked template if not already present.
2. Seeds S&Box server files from baked template if `/home/container/sbox` is missing or empty.
3. Runs SteamCMD to update S&Box to the latest version (if `SBOX_AUTO_UPDATE=1`).
4. Launches `sbox-server.exe` under Wine with the configured arguments.

Project selection precedence:
1. `SBOX_PROJECT` (resolved under `/home/container/projects/` or absolute path)
2. `GAME` (with optional `MAP`)

## Quick Start

1. Import the appropriate egg into your panel:
  - **Pterodactyl (Wine path)**: import `sandbox-pterodactyl.json`
  - **Pterodactyl (Native Linux path)**: import `sandbox-linux-native-pterodactyl.json`
  - **Pelican (Wine path)**: import `sandbox-pelican.json`
2. Set the Docker image defined by the egg you selected.
3. Create a server and configure variables.
4. Start the server. On first boot it will run the configured install/start workflow for that egg.

## Notes

- Tuned for `linux/amd64` container runtime.
- Runtime behavior changes belong in `Yolk/entrypoint.sh`.
- Panel UX and variable changes belong in the egg JSON files.
- The `.wine` prefix and `sbox/` install directory live under `/home/container` (the Pterodactyl volume mount) and are populated on first boot.

## Notes for Hosting Providers

While this egg was built for [GameForge](https://gameforge.gg) to sell s&box hosting, we are happy to see other providers use it and welcome pull requests.