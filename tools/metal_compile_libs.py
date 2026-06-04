"""Link slangc-emitted .metal source into .metallib (macOS leg of the build).

``compile_all_slang.py --target metal`` (run on Linux, where slangc needs
no Apple toolchain) emits per-perm Metal *source* under
``slang_out/metal/<family>/perm_NNN.metal`` but cannot produce the
``.metallib`` — that needs Apple's ``metal`` compiler. This script does
only that link step on a macOS runner: for each ``.metal`` it runs
``xcrun metal -c -mmacosx-version-min=<min>`` then ``xcrun metallib``,
writing the ``perm_NNN.metallib`` next to the source so ``build_bls.py``
can pack it. Keeping it standalone means the (more expensive) macOS job
needs only Xcode + Python — no slangc, no slang download.

The ``-mmacosx-version-min`` pin controls the metallib container version
(min=11 → 1.2.5, the lowest slang's Metal-2.3 emit is compatible with),
matching the metallib path in ``compile_all_slang.py``.

Usage (run from the repo root so the default slang_out path resolves):
  python tools/metal_compile_libs.py [--slang-out slang_out] [--macos-min 11] [-j N]
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys
from pathlib import Path


def compile_one(metal_path, macos_min):
    """.metal → .air → .metallib via xcrun. Returns (path, ok, message)."""
    air = metal_path.with_suffix('.air')
    lib = metal_path.with_suffix('.metallib')
    for stale in (air, lib):
        if stale.exists():
            stale.unlink()

    air_proc = subprocess.run(
        ['xcrun', 'metal', '-c', f'-mmacosx-version-min={macos_min}',
         str(metal_path), '-o', str(air)],
        capture_output=True, text=True)
    if air_proc.returncode != 0:
        return metal_path, False, air_proc.stderr or air_proc.stdout

    lib_proc = subprocess.run(
        ['xcrun', 'metallib', str(air), '-o', str(lib)],
        capture_output=True, text=True)
    air.unlink(missing_ok=True)
    if lib_proc.returncode != 0:
        return metal_path, False, lib_proc.stderr or lib_proc.stdout

    if not (lib.exists() and lib.stat().st_size > 0):
        return metal_path, False, 'metallib missing or empty'
    return metal_path, True, ''


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--slang-out', default='slang_out',
                    help='top-level slang_out dir (reads <slang-out>/metal/'
                         '<family>/perm_*.metal). Default: %(default)s')
    ap.add_argument('--macos-min', default='11',
                    help='-mmacosx-version-min passed to xcrun metal '
                         '(controls metallib container version). Default: %(default)s')
    ap.add_argument('--jobs', '-j', type=int, default=os.cpu_count() or 1,
                    help='parallel xcrun processes (default: %(default)s)')
    args = ap.parse_args()

    root = Path(args.slang_out) / 'metal'
    metals = sorted(root.rglob('perm_*.metal'))
    if not metals:
        print(f'no .metal files under {root}', file=sys.stderr)
        return 1

    jobs = max(1, args.jobs)
    print(f'linking {len(metals)} .metal -> .metallib '
          f'(macos-min={args.macos_min}, jobs={jobs})')

    ok = 0
    fails = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for mp, good, msg in pool.map(
                lambda m: compile_one(m, args.macos_min), metals):
            if good:
                ok += 1
            else:
                fails.append((mp, msg))

    print(f'metallib: {ok} OK / {len(fails)} fail')
    for mp, msg in fails[:5]:
        print(f'  FAIL {mp}: {msg.strip()[:300]}', file=sys.stderr)
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())
