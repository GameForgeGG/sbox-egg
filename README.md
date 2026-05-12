# GameForge s&box Egg

This repository contains Pterodactyl and Pelican eggs and container build assets for running an s&box dedicated server with Wine on Linux. (Native Linux will be added once facepunch add it to a steam depot.)

This is working in production. We use it to offer s&box server hosting: [Looking for a server?](https://gameforge.gg/games/sbox)

## Primary Goal

Provides a production-ready egg that:
- provides ease of use variables for the server.
- runs as non-root in container environments.
- runs SteamCMD on every boot to keep the server up to date.
- A single stage runtime image based on `steamcmd/steamcmd:alpine` that uses steamcmd to download and keep sbox updated.

## Repository Layout

- `sandbox-pterodactyl.json` — Pterodactyl egg export.
- `sandbox-pelican.json` — Pelican egg export.
- `Yolk/Dockerfile` — Docker image build.
- `Yolk/entrypoint.sh` — Runtime startup and orchestration logic.

## Egg Focus

Both egg files are functionally identical — they share the same Docker image, startup command, variables, and runtime behavior.

Key details:
- Startup command: `start-sbox`
- Done detection: `Loading game|Server started` (This triggers when sbox finishes loading rather than when the game mode loading)`

## Panel Variables

| Variable | Description | Default |
|---|---|---|
| `GAME` | Primary game package (`+game`) | `strikeforce.strikeforce` |
| `SERVER_NAME` | Public server name | `Sandbox Server` |
| `MAP` | Optional map/package identifier | `Empty` |
| `SBOX_PROJECT` | Local `.sbproj` under `/home/container/projects/` | |
| `SBOX_EXTRA_ARGS` | Extra launch arguments | |
| `SBOX_AUTO_UPDATE` | Run SteamCMD update on each boot (`0`/`1`) | `1` |
| `SBOX_BRANCH` | Steam beta branch for updates (e.g. `staging`) | |
| `TOKEN` | Steam game server token | |
| `STEAMCMD_EXTRA_ARGS` | Extra Args for SteamCMD | |

## Runtime Behavior

At container start, `Yolk/entrypoint.sh`:
1. SteamCMD will validate and update s&box as required into `/home/container/sbox`.
2. Launches `sbox-server.exe` under Wine with the configured arguments.
3. Logs into `/home/container/logs`

If SteamCMD times out or fails but a previous `sbox-server.exe` exists, startup continues with existing files and the updater error is logged to `logs/sbox-update.log`.

## Quick Start

1. Import the appropriate egg into your panel:
  - **Pterodactyl**: import `sandbox-pterodactyl.json`
  - **Pelican**: import `sandbox-pelican.json`
2. Set the Docker image to `ghcr.io/GameForgeGG/sbox-egg:latest` (or your own build).
3. Create a server and configure variables.
4. Start the server. On first boot it will seed files and run the updater before launching.

## Notes for Hosting Providers

While this egg was built for [GameForge](https://gameforge.gg) to sell s&box hosting, we are happy to see other providers use it and welcome pull requests.