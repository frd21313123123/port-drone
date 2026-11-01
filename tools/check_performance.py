#!/usr/bin/env python3
"""Run CPU regressions or a repeatable headless simulation benchmark.

Builds a temporary PCK from the current source; never imports into the tracked
game/.godot cache or writes to the player's saves. No Windows template needed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", type=Path, default=ROOT / "godot_dl/godot")
    ap.add_argument("--pack", type=Path, help="Explicit reference PCK/exe instead of current source")
    ap.add_argument("--mode", choices=("regression", "benchmark"), default="regression")
    ap.add_argument("--size", type=int, choices=(512, 1024, 2048), default=2048)
    ap.add_argument("--bots", type=int, choices=range(1, 8), default=4)
    ap.add_argument("--seed", type=int, default=20261016)
    ap.add_argument("--warmup", type=float, default=1800.0, help="Simulated seconds before sampling")
    ap.add_argument("--seconds", type=float, default=300.0, help="Simulated seconds to sample")
    ap.add_argument("--dt", type=float, default=0.2, help="Simulation step, <= 0.2 seconds")
    ap.add_argument("--load", type=Path, help="Replay a checkpoint instead of generating a world")
    ap.add_argument("--checkpoint", type=Path, help="Write a checkpoint after warmup")
    ap.add_argument("--out", type=Path, default=ROOT / "dist/performance")
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()
    if not 0 < args.dt <= 0.2 or args.seconds <= 0 or args.warmup < 0:
        ap.error("dt must be in (0, 0.2], seconds > 0, warmup >= 0")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    report = args.out / f"{args.mode}.json"
    log = args.out / f"{args.mode}.log"
    # Remove only the prior report so a stale result cannot turn a failed run green.
    report.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="dfperf_") as tmp:
        work = Path(tmp)
        env = os.environ.copy()
        env.update(XDG_DATA_HOME=str(work / "data"), XDG_CONFIG_HOME=str(work / "config"),
                   XDG_CACHE_HOME=str(work / "cache"), DF_NO_UPDATE="1")
        for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            Path(env[name]).mkdir(parents=True)
        godot = str(args.godot.resolve())
        pack = args.pack.resolve() if args.pack else work / "game.pck"
        if not args.pack:
            subprocess.run([godot, "--headless", "--path", str(ROOT / "tools/packproj"),
                            "--script", "res://pack.gd", "--", str(ROOT / "game"), str(pack)],
                           cwd=ROOT, env=env, check=True, timeout=60)
        script = ROOT / "tools" / ("performance_regression.gd" if args.mode == "regression" else "performance_benchmark.gd")
        cmd = [godot, "--headless", "--main-pack", str(pack), "--script", str(script), "--",
               f"--out={report}", f"--size={args.size}", f"--bots={args.bots}", f"--seed={args.seed}",
               f"--warmup={args.warmup}", f"--seconds={args.seconds}", f"--dt={args.dt}"]
        if args.load:
            cmd.append(f"--load={args.load.resolve()}")
        if args.checkpoint:
            cmd.append(f"--checkpoint={args.checkpoint.resolve()}")
        with log.open("w") as output:
            result = subprocess.run(cmd, cwd=ROOT, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=args.timeout)
        text = log.read_text()
        unexpected = [line for line in text.splitlines() if line.startswith("ERROR:")
                      and not (any(name in line for name in ("addons/webrtc_native/", "addons/godotsteam/"))
                               or re.match(r"ERROR: \d+ resources still in use at exit", line))]
        if result.returncode or "SCRIPT ERROR:" in text or unexpected or not report.exists():
            print(text[-12000:])
            raise SystemExit(result.returncode or 1)
        data = json.loads(report.read_text())
        if not data.get("passed") or data.get("checks", data.get("samples", 0)) <= 0:
            raise SystemExit(f"No successful checks/samples: {report}")
        print(json.dumps(data, indent=2))
        print(f"Log: {log}")


if __name__ == "__main__":
    main()
