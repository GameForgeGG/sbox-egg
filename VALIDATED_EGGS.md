# Validated alternative Pterodactyl eggs

These imports are additive alternatives to GameForge's existing Wine/Pelican pair. They use the runtime images maintained by Sacred Servers and the reproducible validation work in [`Dopamine-Sbox/Dedicated-Server-Benchmarks`](https://github.com/Dopamine-Sbox/Dedicated-Server-Benchmarks).

## Imports

- `sandbox-pterodactyl-linux-native.json` builds and installs Facepunch's public Linux source at the pinned commit `70647f994acb16cf780654dcfe3b5fee738a9f15`.
- `sandbox-pterodactyl-wine-managed.json` runs the Windows dedicated server under Wine with a managed console path that accepts panel commands.

The validated runtime images are:

```text
sacredservers/sbox-dedicated-native:public-70647f9-stopfix1
sha256:3abf160c2350581bf67f3e9d5373c6cf4b4691d39da11061fbaa8367d8880e1d

sacredservers/sbox-dedicated-wine:validated-20260822
sha256:86e77b48e7c9264c359a3f4aa903784f726fbcd68adc58cdd9ed9e2a0f9c15b3
```

## Acceptance results

Both eggs were imported into isolated Pterodactyl servers and tested through public allocations on 2026-08-22.

| Check | Native Linux | Managed Wine |
| --- | --- | --- |
| Steam readiness | Pass | Pass |
| Real Steam client join | Pass; 63-second session | Pass; two consecutive joins, including 76 seconds |
| Public A2S_INFO | Pass | Pass |
| Panel `quit` stop | Pass; offline in 21.685 seconds | Pass; offline in 21.059-21.445 seconds |
| Forced-kill recovery | Pass | Pass |
| Sandbox + Flatgrass | Pass | Pass |
| Flatgrass scene test | Pass | Pass |
| Bomb Royale | Pass | Pass |

One earlier Wine client attempt stalled during connection before two controlled repeats passed. Keep repeated joins and longer soak sessions in the regression set. `facepunch.walker` currently fails on both runtimes with the same package-whitelist/API compatibility error and is not considered an egg-specific failure.

## Deployment requirements

- Allocate separate UDP game and query ports.
- Leave `PORT` blank to use the server's primary Pterodactyl allocation automatically.
- Set `QUERY_PORT` to the separately allocated UDP port.
- Normal panel shutdown sends `quit`; use Kill only for recovery.
- Readiness is the engine's `Connected to Steam` line.
- The native install compiles an exact public-source commit and can take several minutes on a fresh volume.

The eggs intentionally do not expose an arbitrary shell command or "package install on start" variable. Select the game/package with `GAME`; optional startup values are s&box console commands, not shell commands.
