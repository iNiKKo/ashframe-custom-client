# Ashframe Custom Client

Client-side cache for the Ashframe Cubyz server. On other servers it behaves
exactly like stock Cubyz 0.4.1.

## What it does

- Skips re-unpacking server addons when they didn't change.
- Saves downloaded chunks and lighting to disk, reuses them on revisit.
  Writes are batched in RAM and flushed periodically, not on every chunk.
- Edited areas re-download automatically. Old data expires on its own.
- Meshes built before their light data arrives are re-lit automatically.
- Faster handshake ramp on high-latency links (send pacing only).
- Delete `~/.cubyz/ashframeCache/` anytime to force a full redownload.

## Install

1. Get clean Cubyz 0.4.1 source (tag `0.4.1`).
2. Copy the `src/` files from here over the matching paths.
3. Build normally.
4. Optional `launchConfig.zon` settings (defaults work out of the box;
   see `launchConfig.example.zon` for all keys with comments):
   `.ashframeCache = true`, `.ashframeServer = "cubyz.ashframe.net"`,
   `.ashframeCacheTTLHours = 24`, `.ashframeFlushMaxMB = 124`,
   `.ashframeFlushIntervalMinutes = 5`, `.ashframeCacheMaxMB = 1024`,
   `.ashframeDebug = true`, `.chatWidth = 480`.

## Notes

- Derived from Cubyz 0.4.1 (GPLv3, see LICENSE).
- 8 changed files, marked `ASHFRAME CUSTOM CLIENT` in the source.
