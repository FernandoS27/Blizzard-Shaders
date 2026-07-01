"""Run every per-family shader differential test and summarise the results.

One command to re-validate all the slang shader families that have a
``shader_diff_<family>.py`` driver against their retail bytecode. Each driver is
run as a subprocess; this collects the worst divergence / diverging-perm count
and prints a table, exiting non-zero if any family diverges.

    python tools/shader_diff_all.py                 # all families, default trials
    python tools/shader_diff_all.py --trials 15     # faster, lighter coverage
    python tools/shader_diff_all.py --only hd_ps,crystal_ps
    python tools/shader_diff_all.py --perms 0,1,2   # tiny smoke test per family

Note: each driver disassembles its slang ``.dxbc`` perms via 3Dmigoto on every
run, so a full sweep across all families takes a few minutes. Use ``--perms`` or
``--only`` for a quick smoke check.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent

# family -> (driver filename, perm count, default per-family trial count)
FAMILIES = [
    ("popcorn_ps",     "shader_diff_popcorn.py",        1152, 60),
    ("hd_ps",          "shader_diff_hd_ps.py",           512, 60),
    ("crystal_ps",     "shader_diff_crystal_ps.py",      512, 60),
    ("sd_on_hd_ps",    "shader_diff_sd_on_hd_ps.py",     384, 60),
    ("sd_classic_ps",  "shader_diff_sd_classic_ps.py",   200, 60),
    ("hd_vs",          "shader_diff_hd_vs.py",           144, 30),
    ("sd_on_hd_vs",    "shader_diff_sd_on_hd_vs.py",     144, 30),
    ("sd_highspec_vs", "shader_diff_sd_highspec_vs.py",  162, 30),
]

_WORST = re.compile(r"worst divergence\s*:\s*([0-9.eE+-]+)")
_DIVERG = re.compile(r"perms diverging\s*:\s*(\d+)")


def run_family(name, driver, trials, perms):
    cmd = [sys.executable, str(TOOLS / driver), "--trials", str(trials)]
    if perms:
        cmd += ["--perms", perms]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    worst = _WORST.search(out)
    diverg = _DIVERG.search(out)
    ok = proc.returncode == 0 and "ALL MATCH" in out
    return {
        "ok": ok,
        "worst": float(worst.group(1)) if worst else float("nan"),
        "diverging": int(diverg.group(1)) if diverg else -1,
        "output": out,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trials", type=int, default=None,
                    help="override per-family trial count (default: per-family)")
    ap.add_argument("--perms", default=None,
                    help="comma-separated perm subset passed to every driver (smoke test)")
    ap.add_argument("--only", default=None,
                    help="comma-separated family names to run (default: all)")
    args = ap.parse_args(argv)

    only = set(args.only.split(",")) if args.only else None
    families = [f for f in FAMILIES if not only or f[0] in only]

    print(f"{'family':<16} {'perms':>6}  {'result':<9} {'worst':>10}  diverging")
    print("-" * 56)
    all_ok = True
    for name, driver, nperms, def_trials in families:
        trials = args.trials or def_trials
        r = run_family(name, driver, trials, args.perms)
        all_ok &= r["ok"]
        status = "MATCH" if r["ok"] else "DIVERGE"
        print(f"{name:<16} {nperms:>6}  {status:<9} {r['worst']:>10.2e}  {r['diverging']}")
        if not r["ok"]:
            # surface the tail of a failing run for quick diagnosis
            for line in r["output"].splitlines()[-12:]:
                print("    | " + line)
    print("-" * 56)
    print("ALL FAMILIES MATCH" if all_ok else "SOME FAMILIES DIVERGE")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
