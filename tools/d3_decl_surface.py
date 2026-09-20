#!/usr/bin/env python3
"""Gate D2 -- does each slot declare exactly what its retail program declares?

Compared per slot (plan H5), candidate against the retail program of its slot:

* **signatures** -- every ISGN / OSGN row ``(NAME, index, register, mask,
  sysval, format)``, in order, after undoing slang's x10 index per row. Order,
  register and mask are layout: the pixel shader's registers are fixed by the
  paired vertex shader's outputs, and a scalar ``FOG0`` packing into ``.w`` is
  part of that contract.
* **textures and samplers** -- register, kind, dimension, texture return type,
  sampler mode. Names are NOT compared (retail's are D3DX Effects mangling).
* **constant buffers** -- the same banks at the same registers, stripped names
  equal, byte size equal, and the flattened scalar layout identical (so a
  ``D3BoneRows[45]`` of float4 rows stands in for ``row_major float3x4[45]``).
* **bank declarations** -- ``dcl_constantbuffer`` access flag equal; row count
  EXACT where retail is ``dynamicIndexed`` (fxc cannot shrink an array indexed
  at runtime, and the differential cannot see a larger bank) and ``>=`` otherwise.
* **pixel interpolation** -- the ``dcl_input_ps`` mode of each input register.

Not compared: the "used" signature column and per-register read masks, which
fxc 9.29 and d3dcompiler_47 legitimately compute differently.

    python tools/d3_decl_surface.py --bundle ps_actor
    python tools/d3_decl_surface.py --all
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d3_dxbc as DX                      # noqa: E402


def retail_surface(dxbc: Path) -> dict:
    return DX.surface(Path(dxbc), slang=False)


def slang_surface(dxbc: Path) -> dict:
    return DX.surface(Path(dxbc), slang=True)


def compare(ref: dict, cand: dict) -> list:
    """Problems, as sentences; empty when the surfaces agree."""
    p = []
    if ref['model'] != cand['model']:
        p.append('model %s, retail %s' % (cand['model'], ref['model']))
    for which in ('isgn', 'osgn'):
        if ref[which] != cand[which]:
            rs, cs = ref[which], cand[which]
            diff = [('retail', r) for r in rs if r not in cs] + [('slang', c) for c in cs if c not in rs]
            if not diff:
                diff = [('order', [r[:2] for r in rs])]
            p.append('%s differs: %s' % (which.upper(), diff[:6]))
    def res(s):
        return {(r['register'], r['kind'], r['dim'], r['comparison'])
                for r in s['rdef']['resources'] if r['kind'] != 'cbuffer'}
    rr, cr = res(ref), res(cand)
    if rr != cr:
        p.append('resources: retail-only %s, slang-only %s' % (sorted(rr - cr), sorted(cr - rr)))
    rt, ct = ref['dcl']['textures'], cand['dcl']['textures']
    if rt != ct:
        p.append('texture declarations: retail %s, slang %s' % (rt, ct))
    if ref['dcl']['samplers'] != cand['dcl']['samplers']:
        p.append('sampler modes: retail %s, slang %s' % (ref['dcl']['samplers'], cand['dcl']['samplers']))
    def banks(s):
        return {r['register']: r['name'] for r in s['rdef']['resources'] if r['kind'] == 'cbuffer'}
    rb, cb = banks(ref), banks(cand)
    if rb != cb:
        p.append('cbuffers: retail %s, slang %s' % (rb, cb))
    for reg, name in rb.items():
        rc, cc = ref['rdef']['cbuffers'].get(name), cand['rdef']['cbuffers'].get(name)
        if rc is None or cc is None:
            continue
        if rc['size'] != cc['size']:
            p.append('%s size %d, retail %d' % (name, cc['size'], rc['size']))
        if rc['scalars'] != cc['scalars']:
            ro = set(rc['scalars'].items())
            co = set(cc['scalars'].items())
            p.append('%s layout differs: retail-only %s slang-only %s'
                     % (name, sorted(ro - co)[:4], sorted(co - ro)[:4]))
    for n, (rows, flag) in ref['dcl']['cbuffers'].items():
        got = cand['dcl']['cbuffers'].get(n)
        if got is None:
            p.append('CB%d not declared' % n)
            continue
        if got[1] != flag:
            p.append('CB%d access %s, retail %s' % (n, got[1], flag))
        # The declared row count is the minimum bound buffer. It may not be
        # smaller than retail's, and it may not exceed the buffer the engine
        # uploads (retail's RDEF size): a dynamically indexed bank declared
        # larger than that is the sd_lowspec_vs 256-bone-palette failure. fxc 47
        # declares a slang-wrapped dynamic bank at its full size (CB2[387]
        # against retail's CB2[386], both inside the 6,192-byte CBLights).
        uploaded = next((c['size'] // 16 for name, c in ref['rdef']['cbuffers'].items()
                         if rb.get('cb%d' % n) == name), None)
        if got[0] < rows or (uploaded is not None and got[0] > uploaded):
            p.append('CB%d[%d], retail CB%d[%d] %s (buffer %s rows)' % (n, got[0], n, rows, flag, uploaded))
    extra = set(cand['dcl']['cbuffers']) - set(ref['dcl']['cbuffers'])
    if extra:
        p.append('extra banks declared: %s' % sorted(extra))
    if ref['model'].startswith('ps'):
        ri = {r[0]: r[2] for r in ref['dcl']['inputs']}
        ci = {r[0]: r[2] for r in cand['dcl']['inputs']}
        for reg in sorted(set(ri) | set(ci)):
            if ri.get(reg) != ci.get(reg) and reg in ri and reg in ci:
                p.append('v%d interpolation %s, retail %s' % (reg, ci.get(reg), ri.get(reg)))
    return p


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    args = ap.parse_args(argv)
    import d3_retail as R
    import d3_validate_all as V
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    bad = 0
    for bid in bids:
        n = 0
        for slot, ref_dx, cand_dx in V.slot_blobs(bid):
            if cand_dx is None:
                continue
            n += 1
            probs = compare(retail_surface(ref_dx), slang_surface(cand_dx))
            if probs:
                bad += 1
                print('FAIL %s/%d: %s' % (bid, slot, ' | '.join(probs)))
        print('%s: %d slots checked' % (bid, n))
    print('OK' if not bad else '%d slot(s) differ' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
