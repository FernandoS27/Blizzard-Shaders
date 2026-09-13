"""Whole-family gate for a reconstructed Wc3 uber-shader: every slot, no gaps.

:mod:`wc3_uber_validate` interprets a slot against its retail twin, which is
the real check but costs seconds per slot -- too slow to run over a thousand
permutations at a useful trial count. This runs the same check over the whole
family by exploiting the redundancy in it:

  * compile every slot, and hash the candidate bytecode next to the retail
    bytecode;
  * two slots that share BOTH hashes pose the *same* comparison -- identical
    programs on both sides -- so interpreting one of them is not a sample of
    the other, it is the other. Only one slot per ``(retail, candidate)`` pair
    needs interpreting;
  * separately, and for *every* slot, compare the declaration block and the
    input/output signatures. That is cheap and catches the class of mistake the
    numeric check is worst at -- a resource bound to the wrong register, a
    missing render target, an interpolant the candidate reads and retail does
    not.

The two checks are deliberately one-sided in different directions: a slot fails
if the candidate declares something retail does not *or* the other way round.

    python tools/wc3_uber_sweep.py wc3_re_shaders/hd --trials 32
    python tools/wc3_uber_sweep.py wc3_re_shaders/hd --json sweep.json

Exit code is 0 only when every slot is covered and every check passes.
"""

import argparse
import hashlib
import json
import re
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from wc3_uber_validate import (DECOMPILER, DEFAULT_TOL, DRIVERS,    # noqa: E402
                               compile_perm, disassemble, find_fxc,
                               validate_slot)

#: Declaration lines that say nothing about behaviour -- register allocation
#: and the indexing hint fxc picks are free to differ.
_DECL_IGNORE = re.compile(r'^dcl_(temps|indexableTemp|globalFlags)\b')
#: ``immediateIndexed`` vs ``dynamicIndexed`` is an fxc addressing hint.
_CB_INDEXED = re.compile(r',\s*(immediate|dynamic)Indexed\s*$')


def decl_signature(asm_path):
    """The behavioural half of a shader's preamble, as a comparable set.

    Keeps resource/sampler/constant-buffer/input/output declarations and the
    signature tables; drops temp counts and addressing hints.
    """
    text = Path(asm_path).read_text('utf-8', errors='replace')
    decls = set()
    for line in text.splitlines():
        s = line.strip()
        if not s.startswith('dcl_') or _DECL_IGNORE.match(s):
            continue
        decls.add(_CB_INDEXED.sub('', s))
    sig = set()
    for label in ('Input signature', 'Output signature'):
        m = re.search(rf'// {label}:(.*?)(?=//\s*\n//\s*\n|\nps_|\nvs_)', text, re.S)
        if not m:
            continue
        for row in re.findall(r'^// (\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(\S+)(.*)$',
                              m.group(1), re.M):
            name, idx, mask, reg, sysval, fmt, used = row
            if name in ('Name', '--------------------'):
                continue
            sig.add((label[0], name, idx, mask, reg, sysval, used.strip()))
    return decls, sig


def sweep(folder, *, trials=32, tol=DEFAULT_TOL, decompiler=DECOMPILER,
          driver=None, quiet=False, limit=None):
    folder = Path(folder)
    man = json.loads((folder / 'uber_manifest.json').read_text('utf-8'))
    perms = man['perms']
    profile = man.get('profile', 'ps_5_0')
    entry = man.get('entry', 'main')
    driver = driver or man.get('driver', 'default')
    if driver not in DRIVERS:
        raise SystemExit(f'unknown driver {driver!r}')

    slots = sorted(p.stem[len('perm_'):] for p in folder.glob('perm_*.dxbc'))
    if limit:
        slots = slots[:limit]
    missing = [s for s in slots if s not in perms]
    if missing:
        raise SystemExit(f'manifest omits {len(missing)} slots (e.g. {missing[:5]})')

    fxc = find_fxc()
    results = {}
    struct_fail = {}
    groups = defaultdict(list)
    t0 = time.time()

    with tempfile.TemporaryDirectory(prefix='wc3sweep_') as wd:
        wd = Path(wd)
        # Pass 1: compile every slot and class it by (retail, candidate) hash.
        # Only the hashing happens here -- disassembly costs more than the
        # compile and is identical for every member of a class, so it waits.
        for n, slot in enumerate(slots):
            defines = perms[slot].get('defines') or {}
            cand_dxbc = wd / f'cand_{slot}.dxbc'
            ok, msg = compile_perm(fxc, folder / 'uber.hlsl', profile, entry,
                                   defines, cand_dxbc)
            if not ok:
                results[slot] = {'ok': False, 'reason': msg}
                continue
            ch = hashlib.sha1(cand_dxbc.read_bytes()).hexdigest()[:12]
            rh = hashlib.sha1((folder / f'perm_{slot}.dxbc').read_bytes()).hexdigest()[:12]
            groups[(rh, ch)].append(slot)
            cand_dxbc.unlink()
            if not quiet and (n + 1) % 128 == 0:
                print(f"  compiled {n + 1}/{len(slots)} "
                      f"({time.time() - t0:.0f}s, {len(groups)} classes)",
                      flush=True)

        covers = {members[0]: len(members) for members in groups.values()}
        reps = sorted(covers)
        if not quiet:
            print(f"  {len(slots)} slots -> {len(reps)} distinct "
                  f"(retail, candidate) classes; checking each", flush=True)

        # Pass 2: once per class -- structural check, then interpretation.
        # Every member of a class has byte-identical bytecode on both sides, so
        # the verdict carries over to all of them.
        members_of = {members[0]: members for members in groups.values()}
        rep_result = {}
        for n, slot in enumerate(reps):
            defines = perms[slot].get('defines') or {}
            cand_dxbc = wd / f'cand_{slot}.dxbc'
            compile_perm(fxc, folder / 'uber.hlsl', profile, entry,
                         defines, cand_dxbc)
            cand_asm = disassemble(cand_dxbc, decompiler)

            cd, cs = decl_signature(cand_asm)
            rd, rs = decl_signature(folder / f'perm_{slot}.asm')
            problems = []
            if cd - rd:
                problems.append(f'candidate declares {sorted(cd - rd)}')
            if rd - cd:
                problems.append(f'candidate is missing {sorted(rd - cd)}')
            if cs != rs:
                problems.append(f'signature differs: +{sorted(cs - rs)} '
                                f'-{sorted(rs - cs)}')
            if problems:
                for member in members_of[slot]:
                    struct_fail[member] = '; '.join(problems)

            r = validate_slot(folder, slot, entry, profile, defines, fxc,
                              decompiler, wd, trials, tol, driver,
                              cand_asm=cand_asm)
            rep_result[slot] = r
            cand_dxbc.unlink()
            cand_asm.unlink()
            if not quiet:
                bad = problems or not r['ok']
                mark = 'FAIL' if bad else 'ok  '
                extra = '' if not bad else                     '  ' + '; '.join(filter(None, [r.get('reason', '')] + problems))
                print(f"  [{mark}] {n + 1}/{len(reps)} perm_{slot} "
                      f"(x{covers[slot]}){extra}", flush=True)

    for (rh, ch), members in groups.items():
        rep = members[0]
        r = rep_result[rep]
        for slot in members:
            results[slot] = {'ok': r['ok'] and slot not in struct_fail,
                             'representative': rep,
                             'worst': r.get('worst'),
                             'reason': r.get('reason') or struct_fail.get(slot, '')}
    for slot, why in struct_fail.items():
        results.setdefault(slot, {})['ok'] = False
        results[slot]['reason'] = why

    failed = sorted(s for s, r in results.items() if not r['ok'])
    return {'folder': str(folder), 'slots': len(slots),
            'classes': len(groups), 'trials': trials,
            'structural_failures': len(struct_fail),
            'failed': failed, 'ok': not failed,
            'seconds': round(time.time() - t0, 1),
            'results': results}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('folder')
    ap.add_argument('--trials', type=int, default=32)
    ap.add_argument('--tol', type=float, default=DEFAULT_TOL)
    ap.add_argument('--driver', default=None)
    ap.add_argument('--decompiler', default=DECOMPILER)
    ap.add_argument('--limit', type=int, default=None,
                    help='only the first N slots (smoke test)')
    ap.add_argument('--json', default=None)
    args = ap.parse_args(argv)

    print(f"sweeping {args.folder}", flush=True)
    rep = sweep(args.folder, trials=args.trials, tol=args.tol,
                decompiler=args.decompiler, driver=args.driver,
                limit=args.limit)
    if args.json:
        Path(args.json).write_text(json.dumps(rep, indent=2), encoding='utf-8')
    print()
    print(f"slots          : {rep['slots']}")
    print(f"classes        : {rep['classes']}")
    print(f"structural bad : {rep['structural_failures']}")
    print(f"failed slots   : {len(rep['failed'])}")
    print(f"elapsed        : {rep['seconds']}s")
    if rep['ok']:
        print("ALL SLOTS PASS")
        return 0
    print("FAILING:", rep['failed'][:20],
          '...' if len(rep['failed']) > 20 else '')
    return 1


if __name__ == '__main__':
    sys.exit(main())
