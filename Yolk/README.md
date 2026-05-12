# Yolk Build Process

This document explains the Docker build and runtime design for the S&Box egg image.

## Files

- `DockerFile` - single-stage runtime image definition.
- `entrypoint.sh` - runtime orchestration (prepare directories, update, launch).

## Build Overview

The image now uses a single runtime stage:

- Base image: `steamcmd/steamcmd:alpine`.
- Adds runtime packages required by the server (`wine`, `bash`, `wget`, etc.).
- Uses SteamCMD at container startup to install or update app `1892930` into `/home/container/sbox`.

No build-time prebake is performed for Wine prefixes or server files.

## Build Command

Run from repository root:

```bash
docker build --platform linux/amd64 -f Yolk/DockerFile -t ghcr.io/hyberhost/gameforge-sbox-egg:latest .
```

## Runtime Notes

- Startup entrypoint command: `start-sbox`.
- SteamCMD is provided directly by the `steamcmd/steamcmd:alpine` base image.
- Server files are managed in `/home/container/sbox`.
- Logs are written to `/home/container/logs/`.

## Local Validation

```bash
# Shell syntax check
bash -n Yolk/entrypoint.sh

# Smoke test against a fresh volume
docker run --rm -it -v sbox-test:/home/container ghcr.io/gameforgegg/sbox-egg:latest start-sbox
```
