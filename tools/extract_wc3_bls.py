"""Extract every shader permutation from the Warcraft III 3.0.0 ``.bls`` bundles.

The shipped bundles live in ``war3.w3mod/shaders/{ps,vs}/<family>.bls`` and use
the uncompressed HSXG v1.8 container (see ``re_shaders_old/extract_bls.py`` for
the byte-level notes).  Layout recap::

    +0x00  char[4] "HSXG"   +0x04 u16 minor=8   +0x06 u16 major=1
    +0x08  u32 pre_meta=0x14 +0x0c u32 num_perms
    +0x10  u32 off_data      +0x14 u32 pad=0
    +0x18  u32 cum[num_perms]   cumulative END offsets, relative to off_data

Perm *i* occupies ``off_data + cum[i-1] .. off_data + cum[i]``; a zero-length
entry is a *null* variant (the family does not build that feature combination)
and is skipped while still consuming its slot number.  Inside a perm, the DXBC
container starts at +0x50, with its byte size at +0x48.

Output mirrors ``re_shaders_old/``: one directory per family (pixel shaders keep
the bare family name, vertex shaders get a ``_vs`` suffix) holding
``perm_NNN.dxbc`` plus an ``index.csv`` describing every slot, including nulls.

    python tools/extract_wc3_bls.py -o wc3_re_shaders \
        --decompiler "C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe"
"""

import argparse
import concurrent.futures
import os
import struct
import subprocess
import sys
from pathlib import Path

PERM_HEADER_SIZE = 0x50  # bytes of perm metadata before the DXBC blob


def parse_bls(path):
    data = Path(path).read_bytes()

    if data[:4] != b'HSXG':
        raise ValueError(f"{path}: not a BLS file (bad magic {data[:4]!r})")

    minor, major = struct.unpack_from('<HH', data, 4)
    if (major, minor) != (1, 8):
        raise ValueError(f"{path}: unsupported version v{major}.{minor}")

    pre_meta, num_perms, off_data, pad = struct.unpack_from('<4I', data, 8)
    if pre_meta != 0x14 or pad != 0:
        raise ValueError(f"{path}: unexpected header "
                         f"pre_meta={pre_meta:#x} pad={pad:#x}")

    cum = struct.unpack_from(f'<{num_perms}I', data, 0x18)
    if 0x18 + num_perms * 4 != off_data:
        raise ValueError(f"{path}: cum table end {0x18 + num_perms * 4:#x} "
                         f"!= off_data {off_data:#x}")
    if off_data + cum[-1] != len(data):
        raise ValueError(f"{path}: last cum {off_data + cum[-1]:#x} "
                         f"!= file size {len(data):#x}")

    perms, prev = [], 0
    for i, end in enumerate(cum):
        start, size, prev = off_data + prev, end - prev, end
        if size == 0:
            perms.append(None)
            continue
        if size < PERM_HEADER_SIZE + 4:
            raise ValueError(f"{path}: perm {i} size {size} too small")

        buf = data[start:start + size]
        payload_size, stage = struct.unpack_from('<2I', buf, 0x14)
        dxbc_size, dxbc_tag = struct.unpack_from('<2I', buf, 0x48)

        if 0x18 + payload_size > size:
            raise ValueError(f"{path}: perm {i} payload {payload_size:#x} "
                             f"overflows perm size {size:#x}")
        if dxbc_tag != 4:
            raise ValueError(f"{path}: perm {i} bad dxbc tag {dxbc_tag:#x}")
        if PERM_HEADER_SIZE + dxbc_size > size:
            raise ValueError(f"{path}: perm {i} dxbc {dxbc_size:#x} "
                             f"overflows perm size {size:#x}")

        dxbc = buf[PERM_HEADER_SIZE:PERM_HEADER_SIZE + dxbc_size]
        if dxbc[:4] != b'DXBC':
            raise ValueError(f"{path}: perm {i} blob is not DXBC")
        # the container's own length field must agree with the BLS record
        total = struct.unpack_from('<I', dxbc, 0x18)[0]
        if total != dxbc_size:
            raise ValueError(f"{path}: perm {i} container size {total:#x} "
                             f"!= record size {dxbc_size:#x}")

        perms.append({'index': i, 'file_offset': start, 'perm_size': size,
                      'payload_size': payload_size, 'stage': stage,
                      'dxbc_size': dxbc_size, 'dxbc': dxbc})

    return {'path': str(path), 'num_perms': num_perms,
            'off_data': off_data, 'perms': perms}


def extract(bls_path, out_root, dir_name):
    info = parse_bls(bls_path)
    target = Path(out_root) / dir_name
    target.mkdir(parents=True, exist_ok=True)

    width = max(3, len(str(info['num_perms'] - 1)))
    written, null = 0, 0
    lines = [f"# Variants extracted from {bls_path}",
             f"# num_perms = {info['num_perms']}",
             f"# off_data  = {info['off_data']:#x}",
             "# index,file_offset,perm_size,payload_size,stage,dxbc_size,output"]

    for i, p in enumerate(info['perms']):
        if p is None:
            null += 1
            lines.append(f"{i},,,,,,<null>")
            continue
        name = f"perm_{p['index']:0{width}d}.dxbc"
        (target / name).write_bytes(p['dxbc'])
        written += 1
        lines.append(f"{p['index']},{p['file_offset']:#x},{p['perm_size']},"
                     f"{p['payload_size']},{p['stage']},{p['dxbc_size']},{name}")

    (target / 'index.csv').write_text('\n'.join(lines) + '\n')
    return {'dir': dir_name, 'total': info['num_perms'],
            'written': written, 'null': null, 'target': target}


def run_decompiler(exe, files, flag):
    """Invoke cmd_Decompiler over batches of blobs; returns the files that failed."""
    failed = []
    # keep each argv comfortably under the ~32k Windows command-line limit
    batches, batch, budget = [], [], 0
    for f in files:
        cost = len(str(f)) + 3
        if batch and budget + cost > 24000:
            batches.append(batch)
            batch, budget = [], 0
        batch.append(f)
        budget += cost
    if batch:
        batches.append(batch)

    for b in batches:
        proc = subprocess.run([exe, flag] + [str(x) for x in b],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        if proc.returncode != 0:
            # one bad blob fails the whole batch, so retry it file by file
            for f in b:
                r = subprocess.run([exe, flag, str(f)],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                if r.returncode != 0:
                    failed.append(f)
    return failed


def decompile_dir(exe, target, jobs):
    """Write perm_NNN.asm (disassembly) and perm_NNN.hlsl (decompilation)."""
    blobs = sorted(Path(target).glob('perm_*.dxbc'))
    if not blobs:
        return {'asm': 0, 'hlsl': 0, 'total': 0,
                'asm_failed': [], 'hlsl_failed': []}

    chunks = [c for c in (blobs[i::jobs] for i in range(max(jobs, 1))) if c]

    def work(chunk):
        return (run_decompiler(exe, chunk, '-d'),
                run_decompiler(exe, chunk, '-D'))

    asm_failed, hlsl_failed = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        for a, h in pool.map(work, chunks):
            asm_failed += a
            hlsl_failed += h

    n_asm = len(list(Path(target).glob('perm_*.asm')))
    n_hlsl = len(list(Path(target).glob('perm_*.hlsl')))
    return {'asm': n_asm, 'hlsl': n_hlsl, 'total': len(blobs),
            'asm_failed': asm_failed, 'hlsl_failed': hlsl_failed}


def discover(shader_root):
    """Yield (bls_path, out_dir_name) for every bundle under ps/ and vs/."""
    root = Path(shader_root)
    for stage in ('ps', 'vs'):
        suffix = '_vs' if stage == 'vs' else ''
        for bls in sorted((root / stage).glob('*.bls')):
            yield bls, bls.stem + suffix


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-s', '--shader-root', default='war3.w3mod/shaders',
                    help='directory holding ps/ and vs/ (default: %(default)s)')
    ap.add_argument('-o', '--out-dir', default='wc3_re_shaders',
                    help='output tree (default: %(default)s)')
    ap.add_argument('--decompiler', default=None,
                    help='3Dmigoto cmd_Decompiler.exe - also write .asm/.hlsl')
    ap.add_argument('-j', '--jobs', type=int, default=os.cpu_count() or 4,
                    help='parallel decompiler processes (default: %(default)s)')
    ap.add_argument('--only', action='append', default=None,
                    help='restrict to these output dir names (repeatable)')
    args = ap.parse_args(argv)

    bundles = list(discover(args.shader_root))
    if args.only:
        wanted = set(args.only)
        bundles = [b for b in bundles if b[1] in wanted]
    if not bundles:
        print(f"error: no .bls bundles under {args.shader_root}", file=sys.stderr)
        return 1

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    print(f"output: {out}")

    grand = {'total': 0, 'written': 0, 'null': 0, 'asm': 0, 'hlsl': 0}
    problems = []
    for bls, dir_name in bundles:
        try:
            r = extract(bls, out, dir_name)
        except ValueError as exc:
            print(f"  !! {dir_name}: {exc}", file=sys.stderr)
            problems.append(dir_name)
            continue
        grand['total'] += r['total']
        grand['written'] += r['written']
        grand['null'] += r['null']
        line = (f"  {dir_name:<28} {r['total']:>5} perms "
                f"({r['written']} dxbc, {r['null']} null)")

        if args.decompiler:
            d = decompile_dir(args.decompiler, r['target'], args.jobs)
            grand['asm'] += d['asm']
            grand['hlsl'] += d['hlsl']
            line += f"  -> {d['asm']} asm, {d['hlsl']} hlsl"
            if d['asm'] < d['total'] or d['hlsl'] < d['total']:
                line += "  [incomplete]"
                problems.append(dir_name)
        print(line, flush=True)

    print(f"\ntotal: {grand['total']} slots, {grand['written']} dxbc, "
          f"{grand['null']} null")
    if args.decompiler:
        print(f"       {grand['asm']} asm, {grand['hlsl']} hlsl")
    if problems:
        print(f"incomplete/failed: {', '.join(sorted(set(problems)))}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
