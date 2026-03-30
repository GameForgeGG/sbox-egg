# GameForge S&Box Pterodactyl Egg

This repository contains a Pterodactyl egg and container build assets for running an S&Box dedicated server with Wine.

## Primary Goal

Provide a production-ready Pterodactyl egg that:
- uses `start-sbox` as startup,
- supports common server variables from the panel,
- runs as non-root in container environments,
- seeds runtime files from baked templates (Wine prefix and server template).

## Repository Layout

- `sandbox-pterodactyl.json`: Pterodactyl egg export (import this into your panel).
- `Yolk/DockerFile`: Docker image build for the egg runtime.
- `Yolk/entrypoint.sh`: runtime startup logic.
- `ref/`: reference files used during development.

## Pterodactyl Egg Focus

The egg in `sandbox-pterodactyl.json` is the main integration point.

Key details:
- Startup command: `start-sbox`
- Done detection: `Loading game|Server started`
- Main variables:
  - `GAME`
  - `SERVER_NAME`
  - `MAP`
  - `TOKEN`
  - `SBOX_PROJECT`
  - `SBOX_EXTRA_ARGS`

## Runtime Behavior

At container start, `Yolk/entrypoint.sh`:
1. Seeds Wine and server files from baked templates if missing.
2. Starts `sbox-server.exe` under Wine with selected startup args.

## Quick Start

1. Build and push image (see `Yolk/README.md`).
2. Import `sandbox-pterodactyl.json` into Pterodactyl.
3. Select your pushed image in egg settings.
4. Create a server and set variables.
5. Start server.

## Notes

- This repo is tuned for Linux/amd64 container runtime.
- Changes to runtime behavior usually belong in `Yolk/entrypoint.sh`.
- Changes to panel UX and variables belong in `sandbox-pterodactyl.json`.