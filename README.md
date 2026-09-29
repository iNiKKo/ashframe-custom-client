# Ashframe Custom Client

Client-side cache for the Ashframe Cubyz server. On other servers it
behaves exactly like stock Cubyz 0.4.1.

## What it does

- Skips re-unpacking server addons when unchanged.
- Caches chunks and lighting on disk; rejoins serve from disk and RAM.
- Meshes wait for light data, so lighting is correct on arrival.
- Reveals the world once nearby light is resident and the clock synced.
- Faster handshake on high-latency links; stable ping readout.
- Edited areas re-download; old data expires on its own.
- Delete `~/.cubyz/ashframeCache/` anytime to force a full redownload.

## Vanilla vs custom (measured, high-latency link)

| | Vanilla 0.4.1 | Ashframe client |
|---|---|---|
| Repeat join | 28–42 s | ~7–13 s |
| Asset pack re-download | every join (~17–29 s) | skipped when unchanged |
| Revisit / teleport back | full re-stream | instant from disk |
| Dark shadows / night bright flash | yes | no |
| Cached rejoin, first serve pass | streams | fast (one disk read per region file) |
| Disk cache | re-downloads | capped, default 256 MB |
| Extra RAM | — | ~128 MB cap + write buffer |
| Chat width | 256 px fixed | configurable |

First join downloads everything once; repeats skip it.

## Install

1. Get clean Cubyz 0.4.1 source (tag `0.4.1`).
2. Copy `src/` over the matching paths.
3. Build normally.
4. Optional `launchConfig.zon` tweaks (see `launchConfig.example.zon`).

## Notes

- Derived from Cubyz 0.4.1 (GPLv3, see LICENSE).
- 10 changed files, marked `ASHFRAME CUSTOM CLIENT` in the source.
