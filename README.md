# GameForge s&box Eggs

This repository contains Pterodactyl and Pelican eggs for running s&box dedicated servers on Linux using Wine. It also includes an alternative native Linux egg built from Facepunch's public source and a managed-console Wine egg.

## Repository Layout

* `sandbox-pterodactyl-wine-managed.json` — Wine with a managed console that accepts panel commands.
* `sandbox-pterodactyl-linux-native.json` — Native Linux alternative built from pinned public source.
* `Yolk/Dockerfile` — Docker image build.
* `Yolk/entrypoint.sh` — runtime startup and orchestration logic.

### Primary Egg
`sandbox-pterodactyl-wine-managed.json` runs the Windows dedicated server under Wine with a managed console that accepts commands from the panel.

### Native Linux
`sandbox-pterodactyl-linux-native.json` builds and installs Facepunch's public Linux source at the pinned commit:
`70647f994acb16cf780654dcfe3b5fee738a9f15`

The initial installation compiles the source and may take several minutes on a fresh volume.

## Panel Variables

| Variable              | Description                                       | Default                   |
| --------------------- | ------------------------------------------------- | ------------------------- |
| `GAME`                | Game package identifier (`+game`)                 | `strikeforce.strikeforce` |
| `SERVER_NAME`         | Public server name                                | `Sandbox Server`          |
| `MAP`                 | Optional map or package identifier                | `Empty`                   |
| `SBOX_PROJECT`        | Local `.sbproj` under `/home/container/projects/` |                           |
| `SBOX_EXTRA_ARGS`     | Additional launch arguments                       |                           |
| `SBOX_AUTO_UPDATE`    | Run SteamCMD updates on each boot (`0`/`1`)       | `1`                       |
| `SBOX_BRANCH`         | Steam beta branch, such as `staging`              |                           |
| `TOKEN`               | Steam game server token                           |                           |
| `STEAMCMD_EXTRA_ARGS` | Additional SteamCMD arguments                     |                           |

Available variables depend on the selected egg.

The eggs do not expose an arbitrary shell command or a package-install-on-start variable. Use `GAME` to select the game or package. Optional startup values are s&box console commands, not shell commands.

## Networking and Shutdown

The alternative eggs require separate UDP allocations for the game and query ports.

* Leave `PORT` blank to use the server's primary Pterodactyl allocation automatically.
* Set `QUERY_PORT` to the separately allocated UDP query port.
* Normal panel shutdown sends `quit`; use Kill only for recovery.

## Quick Start

1. Import the appropriate egg into your panel:

   * **Pterodactyl:** import the relevant `sandbox-pterodactyl-*.json` file.
   * **Pelican:** import the relevent `sandbox-pelican-*.json` file.
2. Configure the Docker image for the selected egg.
3. Create a server and configure its variables and allocations.
4. Start the server. On first boot, the primary Wine egg downloads and updates the game files before launching.

## Hosting Providers

This repository was built for [GameForge](https://gameforge.gg/games/sbox) to provide s&box server hosting. Other providers are welcome to use it and contribute improvements.
