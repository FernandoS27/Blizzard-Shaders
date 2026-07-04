"""Extract the retail D3D11 DXBC blobs from a shipped ``.bls`` shader bundle.

The game's ``war3.w3mod/shaders/{ps,vs}/<family>.bls`` templates embed one
complete ``DXBC`` container per perm (D3D11 SM5, chunks ISGN/OSGN/SHEX; older
families also carry an ``Aon9`` Level9 fallback + ``SHDR`` SM4 block). This tool
slices those blobs out into ``perm_NNN.dxbc`` and (optionally) disassembles each
to ``perm_NNN.asm`` — populating a ``re_shaders/<family>/`` reference tree so the
``shader_diff_<family>.py`` drivers have retail bytecode to compare against.

    python tools/extract_retail_bls.py war3.w3mod/shaders/vs/popcornfx.bls \
        -o re_shaders/popcornfx_vs \
        --decompiler C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe

A DXBC container is found by its ``DXBC`` magic; its total length is the uint32
at offset +0x18, so each blob is sliced exactly and written in file order
(perm 0, 1, ...). Pass ``--expect N`` to assert the perm count.
"""

import argparse
import struct
import subprocess
import sys
from pathlib import Path


def find_dxbc_blobs(data):
    """Yield ``(offset, bytes)`` for every well-formed DXBC container in ``data``."""
    pos = 0
    while True:
        i = data.find(b'DXBC', pos)
        if i < 0:
            return
        if i + 0x20 <= len(data):
            total = struct.unpack_from('<I', data, i + 0x18)[0]
            nchunks = struct.unpack_from('<I', data, i + 0x1C)[0]
            # sanity: plausible chunk count and the blob fits in the file
            if 0 < nchunks < 32 and 0 < total < len(data) and i + total <= len(data):
                yield i, data[i:i + total]
                pos = i + total
                continue
        pos = i + 4


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('bls', help='path to the shipped .bls bundle')
    ap.add_argument('-o', '--out-dir', required=True,
                    help='output dir for perm_NNN.dxbc (e.g. re_shaders/popcornfx_vs)')
    ap.add_argument('--decompiler', default=None,
                    help='3Dmigoto cmd_Decompiler.exe — if given, also write perm_NNN.asm')
    ap.add_argument('--expect', type=int, default=None,
                    help='assert this many perms were extracted')
    args = ap.parse_args(argv)

    data = Path(args.bls).read_bytes()
    out = Path(args.out_dir); out.mkdir(parents=True, exist_ok=True)

    blobs = list(find_dxbc_blobs(data))
    if not blobs:
        print(f"error: no DXBC blobs found in {args.bls}", file=sys.stderr)
        return 1
    if args.expect is not None and len(blobs) != args.expect:
        print(f"warning: extracted {len(blobs)} blobs, expected {args.expect}",
              file=sys.stderr)

    for idx, (off, blob) in enumerate(blobs):
        dxbc = out / f"perm_{idx:03d}.dxbc"
        dxbc.write_bytes(blob)
        if args.decompiler:
            subprocess.run([args.decompiler, '-d', str(dxbc)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    made_asm = args.decompiler is not None
    print(f"{args.bls}: extracted {len(blobs)} perms -> {out}"
          + ("  (+.asm)" if made_asm else ""))
    if made_asm:
        n_asm = len(list(out.glob('perm_*.asm')))
        print(f"  disassembled: {n_asm}/{len(blobs)} .asm")
    return 0


if __name__ == '__main__':
    sys.exit(main())
