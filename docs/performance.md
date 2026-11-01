# Performance validation

The 0.33.2.2 changes target CPU stalls on large maps rather than lowering detail or the simulation rate:

- Colony-site searches keep their candidate order and run one probe per simulation step, round-robin across bots. Completed, captured, eliminated, human-controlled, or unaffordable searches are cancelled. Pending searches survive saves. The scheduler uses operation counts, not wall-clock time, so peer CPU speed does not affect its decisions.
- AI construction/spending decisions count facility kinds once per decision. The inventory is not retained across builds or captures; destroyed facilities keep the original counting semantics.
- Unit/facility spatial queries avoid allocating empty arrays for unoccupied grid cells. Route checks reuse the already computed water cells, including the original sample order and bridge clearance.
- Save entity encoding keeps the dictionary supplied by Godot and converts only container/reference fields. It preserves field values, entity reference order, and the save format. Autosaves freeze shared packed arrays before background serialization/compression; thumbnails use the same frozen terrain and ownership.

The PC version was advanced to 0.33.2.2 because the AI scheduling order changed. Multiplayer peers must use the same build.

## Reproduce

Python 3 and the pinned Godot 4.7.2 editor are required. The runner packs the current source into a temporary PCK; a Windows export template is not needed. It isolates user data, preserves the tracked import cache, checks process status and script/runtime errors, and rejects missing or empty reports.

```sh
# Differential and scheduling/save regressions (fast)
python3 tools/check_performance.py

# Small-map startup and live simulation
python3 tools/check_performance.py --mode benchmark --size 512 --bots 2 \
  --warmup 60 --seconds 20 --dt 0.0333333333333333 --out dist/performance/small

# Large map, four bots, one simulated hour before sampling. Can take several minutes.
python3 tools/check_performance.py --mode benchmark --size 2048 --bots 4 \
  --warmup 3600 --seconds 300 --checkpoint dist/performance/late.save \
  --out dist/performance/current

# Compare a previous executable/PCK and current source from one identical checkpoint.
# Run sequentially, and reverse the order in a second pair to expose host CPU variance.
python3 tools/check_performance.py --mode benchmark --pack /path/to/baseline.exe \
  --load dist/performance/late.save --warmup 0 --seconds 300 --out dist/performance/before
python3 tools/check_performance.py --mode benchmark \
  --load dist/performance/late.save --warmup 0 --seconds 300 --out dist/performance/after
```

`--dt 0.2` is an accelerated-simulation stress workload. Use `--dt 0.0166666666666667 --seconds 10` with `--load ... --warmup 0` for a short 1x-style workload. These measurements time `_sim_step`, not the complete rendered frame. Background jobs, rendering, HUD work and OS scheduling can affect a running game separately.

## Checks and limits

The regressions compare water/bridge and ownership sampling against the original algorithms, including out-of-map coordinates; spatial query membership/order; inventories after ownership/build changes; bounded, fair colony probes and cancellation; reference/cycle preservation for every save entity type; save/load of pending searches; and save/thumbnail isolation while the live state changes.

All 2422 regression checks passed. An additional Main/HUD integration run passed 11 checks: opening the menu, loading the original large checkpoint, advancing the live game at 1x/5x/20x, writing an autosave and a manual save, and loading the new save with unchanged city/facility/unit counts and player money. Its evidence is in `dist/performance/integration.json` and `integration.log`. This ran headless, so it validates the interface code paths without assessing their visual appearance.

The late-game checkpoint used during this change was a 2048×2048 map with seed 20261016, four bots plus an idle player, 87 cities, 439 facilities and 234 units at 3600 simulated seconds. The 300-second replay adds 1500 samples at dt=0.2. JSON and logs for the measured runs are retained under `dist/performance/` in this workspace.

Final source versus the original `03ea866` executable on this cloud host:

| CPU measurement | Original | Final source |
| --- | ---: | ---: |
| Mean simulation step | 21.02 ms | 20.30 ms |
| 99th percentile | 62.64 ms | 58.64 ms |
| Largest simulation step | 279.83 ms | 82.88 ms |
| Steps over 100 ms | 2 / 1500 | 0 / 1500 |
| Median of three autosave main-thread calls | 100.81 ms | 84.22 ms |

The largest measured stall fell by about 70%; the average step time changed little. Earlier forward/reverse-order replays recorded original maxima of 272–280 ms and modified maxima of 76–128 ms, while average times varied between 20 and 23 ms. Treat the smaller averages/percentiles as host-sensitive, not a guaranteed FPS improvement. Full result files are `dist/performance/before/benchmark.json`, `before2/benchmark.json`, `after/benchmark.json`, `after2/benchmark.json`, and `final/benchmark.json`.

Linux headless tests cannot validate GPU frame pacing on an RTX 3070, Windows audio/input, Steam, WebRTC, or the updater. The repository ships only Windows native extensions; missing Linux extension messages and the existing shutdown resource-leak diagnostics are recorded in the logs. No engine assertions or simulation checks are disabled. A lower largest CPU stall does not establish that every freeze is eliminated or that average FPS improved.
