"""Run every per-family shader differential test and summarise the results.

One command to re-validate all the slang shader families that have a
``shader_diff_*`` driver against their retail bytecode. Each driver is run as a
subprocess; this collects the worst divergence / diverging-perm count and prints
a table.

Families flagged ``bug=...`` are known to diverge because of a *real* slang
shader bug this harness found (not a harness limit) — they're expected to fail
until the shader is fixed, so they don't count against the suite. The suite
"passes" when every known-good family still matches AND no known-bug family has
silently started matching (which would mean it got fixed — update the flag).

    python tools/shader_diff_all.py                 # everything
    python tools/shader_diff_all.py --trials 15     # faster
    python tools/shader_diff_all.py --only hd_ps,crystal_ps
    python tools/shader_diff_all.py --good-only      # skip the known-bug families
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent

# name -> (driver, default_trials, bug_note_or_None)
FAMILIES = [
    # --- pixel shaders (known good) ---
    ("popcorn_ps",     ("shader_diff_popcorn.py",        60, None)),
    ("hd_ps",          ("shader_diff_hd_ps.py",          60, None)),
    ("crystal_ps",     ("shader_diff_crystal_ps.py",     60, None)),
    ("sd_on_hd_ps",    ("shader_diff_sd_on_hd_ps.py",    60, None)),
    ("sd_classic_ps",  ("shader_diff_sd_classic_ps.py",  60, None)),
    ("sprite_ps",      ("shader_diff_sprite_ps.py",     100, None)),
    ("postfx",         ("shader_diff_postfx.py",         60, None)),   # 6 post-process families
    ("imgui",          ("shader_diff_imgui.py",          60, None)),   # ps + vs
    # --- vertex shaders (known good) ---
    ("hd_vs",          ("shader_diff_hd_vs.py",          30, None)),
    ("sd_on_hd_vs",    ("shader_diff_sd_on_hd_vs.py",    30, None)),
    ("sd_highspec_vs", ("shader_diff_sd_highspec_vs.py", 30, None)),
    ("popcorn_vs",     ("shader_diff_popcorn_vs.py",     40, None)),
    ("sprite_vs",      ("shader_diff_sprite_vs.py",     100, None)),
    ("water_vs",       ("shader_diff_water_vs.py",       60, None)),
    ("terrain_vs",     ("shader_diff_terrain_vs.py",     40, None)),
    # --- families whose bugs this harness found AND fixed (now known good) ---
    ("terrain_ps",     ("shader_diff_terrain_ps.py",     30, None)),
    ("water_ps",       ("shader_diff_water_ps.py",       40, None)),
    ("foliage_ps",     ("shader_diff_foliage_ps.py",     30, None)),
    ("foliage_vs",     ("shader_diff_foliage_vs.py",     40, None)),
]

_WORST = re.compile(r"worst[ =].*?([0-9]+\.[0-9]+e[+-]?[0-9]+|[0-9]+\.[0-9]+)")


def run_family(driver, trials):
    proc = subprocess.run([sys.executable, str(TOOLS / driver), "--trials", str(trials)],
                          capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    matched = "ALL MATCH" in out and proc.returncode == 0
    worsts = [float(m) for m in _WORST.findall(out)]
    return matched, (max(worsts) if worsts else float("nan")), out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trials", type=int, default=None, help="override per-family trials")
    ap.add_argument("--only", default=None, help="comma-separated family names")
    ap.add_argument("--good-only", action="store_true", help="skip known-bug families")
    args = ap.parse_args(argv)

    only = set(args.only.split(",")) if args.only else None
    fams = [(n, c) for n, c in FAMILIES
            if (not only or n in only) and not (args.good_only and c[2])]

    print(f"{'family':<16} {'result':<10} {'worst':>10}  note")
    print("-" * 70)
    regressions = []; fixed = []
    for name, (driver, def_trials, bug) in fams:
        matched, worst, out = run_family(driver, args.trials or def_trials)
        if bug:
            status = "FIXED?" if matched else "bug"
            note = ("now MATCHES -- update the flag!" if matched else bug)
            if matched:
                fixed.append(name)
        else:
            status = "MATCH" if matched else "REGRESS"
            note = "" if matched else "unexpected divergence"
            if not matched:
                regressions.append(name)
                for line in out.splitlines()[-8:]:
                    note = "see below"
        print(f"{name:<16} {status:<10} {worst:>10.2e}  {note}")
        if not matched and not bug:
            for line in out.splitlines()[-8:]:
                print("    | " + line)
    print("-" * 70)
    known_bugs = [n for n, c in fams if c[2] and n not in fixed]
    if known_bugs:
        print(f"known-bug families (expected diverge): {', '.join(known_bugs)}")
    ok = not regressions and not fixed
    if regressions:
        print(f"REGRESSIONS in known-good families: {', '.join(regressions)}")
    if fixed:
        print(f"known-bug families now matching (update flags): {', '.join(fixed)}")
    print("SUITE OK" if ok else "SUITE ATTENTION NEEDED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
