# GameForge s&box Egg

This repository contains Pterodactyl and Pelican eggs and container build assets for running an s&box dedicated server with Wine.

This is now working in production. We use it to offer s&box server hosting: [Looking for a server?](https://gameforge.gg/games/sbox)

## Primary Goal

Provide a production-ready egg that:
- uses `start-sbox` as startup,
- supports common server variables from the panel,
- runs as non-root in container environments,
- seeds runtime files from baked templates (Wine prefix and server template).

## Repository Layout

- `sandbox-pterodactyl.json`: Pterodactyl egg export (import this into your Pterodactyl panel).
- `sandbox-pelican.json`: Pelican egg export (import this into your Pelican panel).
- `Yolk/DockerFile`: Docker image build for the egg runtime.
- `Yolk/entrypoint.sh`: runtime startup logic.
- `ref/`: reference files used during development. (not in the public repo)

## Egg Focus

The egg files are the main integration point. Both eggs are functionally identical, they share the same Docker image, startup command, variables, and runtime behavior.

Key details:
- Startup command: `start-sbox`
- Done detection: `Loading game|Server started`
- Main variables:
  - `GAME`
  - `SERVER_NAME`
  - `MAP`
  - `SBOX_PROJECT`
  - `SBOX_EXTRA_ARGS`

## Runtime Behavior

At container start, `Yolk/entrypoint.sh`:
1. Seeds Wine and server files from baked templates if missing.
2. Starts `sbox-server.exe` under Wine with selected startup args.

Project selection precedence:
1. `SBOX_PROJECT` (absolute path, or value resolved under `/home/container/projects`)
2. `GAME` (with optional `MAP`)

When a project target is selected, startup uses `+game <project-target>`.

## Quick Start

1. Build and push image (see `Yolk/README.md`). (Optional: The egg can import our build)
2. Import the appropriate egg into your panel:
   - **Pterodactyl**: import `sandbox-pterodactyl.json`
   - **Pelican**: import `sandbox-pelican.json`
3. Select your pushed image in egg settings.
4. Create a server and set variables.
5. Start server.

## Notes

- This repo is tuned for Linux/amd64 container runtime.
- Changes to runtime behavior usually belong in `Yolk/entrypoint.sh`.
- Changes to panel UX and variables belong in the egg JSON files.

## Notes for Hosting Providers

While this egg was built for [GameForge](https://gameforge.gg) to sell s&box, we are more than happy to see other providers use this and are open to pull requests.