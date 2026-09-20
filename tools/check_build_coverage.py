"""Fail a build when it silently produced less than the whole grid.

Neither half of the pipeline can fail on its own: ``compile_all_slang.py``
ends in an unconditional ``return 0`` and ``build_bls.py`` catches every
per-family exception and still exits 0. So a family that stopped
compiling, a template that went missing from ``wc3_bls_templates.json``,
or a macOS leg that linked nothing at all all produce a *green* run with a
quietly partial artifact — ``if-no-files-found: error`` only notices when
the whole tree is empty. This script is the gate that turns those into
build failures.

Two independent checks, either or both per invocation:

``--compiled TARGET``
    Every core family has ``perm_000..perm_{n-1}`` present and non-empty
    under ``<slang-out>/<subdir>/<family>/``, with ``n`` taken from
    ``wc3_shaders.json``. Catches a compiler that aborted mid-sweep, a
    family whose perm_count moved without its mapper, and the macOS
    ``.metal -> .metallib`` link dropping perms.

``--packed TARGET``
    Every core family has its ``.bls`` bundle in the expected tree(s),
    the container header parses, and its perm count matches the config.
    When ``wc3_bls_templates.json`` has a template for the family, the
    rebuilt null-perm pattern must match the shipped one exactly — that
    is what catches a bundle built through build_bls.py's "no template"
    fallback, which fills slots the game expects to be empty.

Known-impossible combinations are allowlisted explicitly rather than
tolerated globally, so a *new* failure is never mistaken for an old one:

  --allow ffxcmaaedge1:webgpu --allow ffxcmaaedgecombine:webgpu

Usage (from the repo root):
  python tools/check_build_coverage.py --compiled metal
  python tools/check_build_coverage.py --compiled metallib --packed metal
  python tools/check_build_coverage.py --compiled vulkan --compiled webgpu \
      --packed vulkan --packed webgpu --allow ffxcmaaedge1:webgpu
"""

import argparse
import glob
import json
import os
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from shader_config import load_families  # noqa: E402  (needs REPO_ROOT on path)

BLS_MAGIC = b'HSXG'

# target -> (slang_out subdir, per-perm file extension). `metallib` is not
# a slangc target: it is the macOS link product that lands next to the
# .metal source, and checking it separately is what proves the Apple leg
# ran over the whole grid rather than the first few families.
COMPILED = {
    'd3d11':    ('d3d11',  'dxbc'),
    'd3d12':    ('d3d12',  'dxil'),
    'vulkan':   ('vulkan', 'spv'),
    'opengl':   ('opengl', 'glsl'),
    'metal':    ('metal',  'metal'),
    'metallib': ('metal',  'metallib'),
    'webgpu':   ('webgpu', 'wgsl'),
}

# target -> (v1.8 stage-dir attribute or None, v1.14 api subdir or None).
# The engine only loads v1.8 for DX and Metal; every other backend exists
# solely as v1.14, so there is nothing to check in the v1.8 tree for them.
PACKED = {
    'd3d11':  ('dx_dir',    'dx_5_0'),
    'd3d12':  (None,        'dx_6_0'),
    'metal':  ('metal_dir', 'mtl_1_1'),
    'vulkan': (None,        'spv_*'),     # exact version is a slangc property
    'webgpu': (None,        'wgsl_1_0'),
}

V14_STAGE_DIR = {'ps': 'pixel', 'vs': 'vertex'}


def perm_sizes(data, path):
    """Per-perm payload sizes from a v1.8 or v1.14 BLS outer container.

    Returns (version_string, [size, ...]). Raises ValueError when the file
    is not a BLS or its header is inconsistent — a truncated upload and a
    zero-length write both land here rather than passing silently.
    """
    if len(data) < 0x18 or data[:4] != BLS_MAGIC:
        raise ValueError(f'not a BLS container ({path})')
    minor, major = struct.unpack_from('<HH', data, 4)

    if (major, minor) == (1, 8):
        num_perms, off_data = struct.unpack_from('<2I', data, 12)
        table = 0x18
        if len(data) < table + num_perms * 4:
            raise ValueError('v1.8 cum-size table truncated')
        cum = struct.unpack_from(f'<{num_perms}I', data, table)
        sizes, prev = [], 0
        for c in cum:
            sizes.append(c - prev)
            prev = c
        return '1.8', sizes

    if (major, minor) == (1, 14):
        off_perms, num_perms = struct.unpack_from('<2I', data, 12)
        cursor = off_perms + 4                 # 4-byte padding prefix
        if len(data) < cursor + num_perms * 24:
            raise ValueError('v1.14 perm table truncated')
        return '1.14', [struct.unpack_from('<I', data, cursor + i * 24)[0]
                        for i in range(num_perms)]

    raise ValueError(f'unsupported BLS version {major}.{minor} ({path})')


def template_nulls(templates, fam, target):
    """Shipped null-perm pattern for one family, or None when unknown.

    Metal carries its own pattern; every other backend is packed against
    the DX one (``build_bls.py`` passes ``dx_nulls`` through), so that is
    what they are compared against.
    """
    entry = (templates or {}).get(fam)
    if not entry:
        return None
    if target == 'metal':
        metal = entry.get('metal')
        return list(metal['nulls']) if metal else None
    dx = entry.get('dx')
    return [p is None for p in dx['perms']] if dx else None


def check_compiled(fams, slang_out, target, allowed, fails):
    subdir, ext = COMPILED[target]
    root = Path(slang_out) / subdir
    checked = 0
    for name, cfg in fams.items():
        if (name, target) in allowed:
            print(f'  ALLOW  {name} [{target}] (known-unsupported)')
            continue
        d = root / name
        missing, empty = [], []
        for i in range(cfg.perm_count):
            p = d / f'perm_{i:03d}.{ext}'
            try:
                if p.stat().st_size == 0:
                    empty.append(i)
            except OSError:
                missing.append(i)
        if missing or empty:
            fails.append(
                f'{name} [{target}]: {len(missing)} missing + {len(empty)} empty '
                f'of {cfg.perm_count} perms under {d}'
                + (f' (first missing: perm_{missing[0]:03d})' if missing else ''))
        checked += 1
    print(f'  compiled/{target}: {checked} families x perms checked')
    return checked


def check_packed(fams, out_base, target, templates, allowed, fails):
    v18_attr, v14_api = PACKED[target]
    checked = 0
    for name, cfg in fams.items():
        if (name, target) in allowed:
            print(f'  ALLOW  {name} [{target}] (known-unsupported)')
            continue

        paths = []
        if v18_attr:
            paths.append(Path(f'{out_base}_1_8') / getattr(cfg, v18_attr)
                         / cfg.bls_name)
        if v14_api:
            v14_root = (Path(f'{out_base}_1_14') / 'shaders'
                        / V14_STAGE_DIR[cfg.stage])
            if '*' in v14_api:
                # The SPIR-V api dir carries the emitted SPIR-V version,
                # which is a property of the slangc build, not of us.
                matches = sorted(glob.glob(str(v14_root / v14_api / cfg.bls_name)))
                if not matches:
                    fails.append(f'{name} [{target}]: no bundle matching '
                                 f'{v14_root / v14_api / cfg.bls_name}')
                    continue
                paths.extend(Path(m) for m in matches)
            else:
                paths.append(v14_root / v14_api / cfg.bls_name)

        expect_nulls = template_nulls(templates, name, target)
        for p in paths:
            try:
                data = p.read_bytes()
            except OSError:
                fails.append(f'{name} [{target}]: missing bundle {p}')
                continue
            try:
                ver, sizes = perm_sizes(data, str(p))
            except ValueError as e:
                fails.append(f'{name} [{target}]: {e}')
                continue
            if len(sizes) != cfg.perm_count:
                fails.append(f'{name} [{target}]: {p.name} (v{ver}) has '
                             f'{len(sizes)} perms, config says {cfg.perm_count}')
                continue
            live = sum(1 for s in sizes if s)
            if live == 0:
                fails.append(f'{name} [{target}]: {p} is entirely null')
                continue
            if expect_nulls is not None:
                got = [s == 0 for s in sizes]
                if got != expect_nulls:
                    diff = [i for i, (a, b) in enumerate(zip(got, expect_nulls))
                            if a != b]
                    fails.append(
                        f'{name} [{target}]: {p.name} null pattern differs from '
                        f'the shipped template at {len(diff)} perms '
                        f'(first: perm_{diff[0]:03d})')
        checked += 1
    print(f'  packed/{target}: {checked} families checked')
    return checked


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--compiled', action='append', default=[],
                    choices=list(COMPILED),
                    help='verify per-perm compiler output for this target '
                         '(repeatable)')
    ap.add_argument('--packed', action='append', default=[],
                    choices=list(PACKED),
                    help='verify the rebuilt .bls bundles for this target '
                         '(repeatable)')
    ap.add_argument('--slang-out', default=str(REPO_ROOT / 'slang_out'),
                    help='compile output base (default: %(default)s)')
    ap.add_argument('--bls-out', default=str(REPO_ROOT / 'bls_out'),
                    help="build_bls.py's --output base, without the _1_8 / "
                         '_1_14 suffix (default: %(default)s)')
    ap.add_argument('--templates-json',
                    default=str(REPO_ROOT / 'wc3_bls_templates.json'),
                    help='extracted template metadata, used to check the '
                         'null-perm pattern (default: %(default)s)')
    ap.add_argument('--allow', action='append', default=[], metavar='FAMILY:TARGET',
                    help='skip one family/target pair that is known not to '
                         'build (repeatable). Anything not listed here is a '
                         'failure.')
    ap.add_argument('--include-custom', action='store_true',
                    help='also check custom_shaders.json families (default: '
                         'core wc3 families only, matching what CI builds)')
    args = ap.parse_args()

    if not args.compiled and not args.packed:
        ap.error('nothing to check: pass --compiled and/or --packed')

    allowed = set()
    for entry in args.allow:
        fam, _, target = entry.partition(':')
        if not target:
            ap.error(f'--allow expects FAMILY:TARGET (got {entry!r})')
        allowed.add((fam, target))

    fams = load_families()
    if not args.include_custom:
        fams = {k: v for k, v in fams.items() if v.module == 'wc3'}
    if not fams:
        print('no families to check', file=sys.stderr)
        return 2

    templates = None
    if os.path.isfile(args.templates_json):
        with open(args.templates_json) as fp:
            templates = json.load(fp).get('families', {})
    else:
        print(f'WARNING: {args.templates_json} missing — null patterns unchecked',
              file=sys.stderr)

    unknown = allowed - {(f, t) for f in fams
                         for t in (*args.compiled, *args.packed)}
    for fam, target in sorted(unknown):
        print(f'WARNING: --allow {fam}:{target} matches nothing being checked',
              file=sys.stderr)

    print(f'checking {len(fams)} families '
          f'({sum(c.perm_count for c in fams.values())} perms)')
    fails = []
    for target in args.compiled:
        check_compiled(fams, args.slang_out, target, allowed, fails)
    for target in args.packed:
        check_packed(fams, args.bls_out, target, templates, allowed, fails)

    if fails:
        print(f'\nFAILED: {len(fails)} problem(s)', file=sys.stderr)
        for f in fails:
            print(f'  {f}', file=sys.stderr)
        return 1
    print('\nOK: full grid present')
    return 0


if __name__ == '__main__':
    sys.exit(main())
