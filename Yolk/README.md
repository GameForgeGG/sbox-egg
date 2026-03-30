# Yolk Build Process

This document explains the Docker build and runtime design for the S&Box egg image.

## Files

- `DockerFile`: multi-stage build definition.
- `entrypoint.sh`: runtime orchestration (seed, launch).

## Build Overview

The image uses two stages:

1. Builder stage (`debian:trixie-slim`)
- Installs Wine, winetricks, and build dependencies.
- Creates and provisions a Wine prefix.
- Installs Windows .NET runtime into that prefix.
- Performs a build-time S&Box content bake using SteamCMD into `/work/server`.
- Cleans up temporary build SteamCMD content after bake.

2. Runtime stage (`alpine:edge`)
- Installs runtime packages (Wine, bash, wget, etc.).
- Copies baked Wine prefix and baked server template only.

This avoids runtime compatibility issues caused by carrying a builder-baked SteamCMD into Alpine runtime.

## Build Command

Run from repository root:

```bash
docker build --platform linux/amd64 -f Yolk/DockerFile -t ghcr.io/hyberhost/gameforge-sbox-egg:latest .
```

Optional build args:

```bash
docker build --platform linux/amd64 \
  -f Yolk/DockerFile \
  -t ghcr.io/hyberhost/gameforge-sbox-egg:latest \
  --build-arg BAKE_WIN_DOTNET_VERSION=10.0.0 \
  --build-arg BAKE_SBOX_APP_ID=1892930 \
  .
```

## Runtime Notes

- Startup entrypoint command is `start-sbox`.

## Local Validation

Quick checks before pushing:

```bash
bash -n Yolk/entrypoint.sh
```

Optional image smoke test:

```bash
docker run --rm -it ghcr.io/hyberhost/gameforge-sbox-egg:latest start-sbox
```
