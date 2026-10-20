#!/usr/bin/env python3
"""Gate D4 on the engine target: every ``flakes-d3d11`` slot against its retail
program, through the inputs the engine actually feeds it.

The retail target is fed retail's vertex streams; the engine target is fed the
engine's records (tools/d3_flakes.py), and must rebuild from them exactly what
retail's streams deliver. So each trial starts from PACKED retail data -- the
bytes and floats a retail vertex buffer holds -- and the two programs see it
through their own input assemblers:

* the retail program gets retail's lanes: UBYTE4 bytes as uints, UNORM8 colours
  and weights as the correctly rounded c/255, the float3 position with w = 1;
* the engine program gets the engine record built from the same data: position
  as is, normal and tangent decoded ``b * 2/255 - 1`` in float32, uv0 / uv1
  decoded ``u16 / 512 - 64`` / ``u16 / 8192 - 4``, the colour pair as UNORM16
  ``c0 | c1 << 8``, binormal bytes raw, weights and indices as is (the palette is
  the engine's 256 bones; trial indices stay inside retail's 45).

A stream the engine stream cannot supply exactly (tools/d3_flakes.py
``unsuppliable``) is fed its stand-in on BOTH legs, so the comparison isolates
everything else. Pixel slots read interpolants, which are identical on both
targets, and are fed as in D4.

Each trial runs three programs: retail, the retail-target build (``d3d11``) and
the engine build (``flakes-d3d11``), each classified against retail as D4 does
(``exact`` / ``order-only`` / ``fail``). The gate requires the engine build to be
exact wherever the retail-target build is exact under the same inputs, and at
least order-only where that is order-only. D2 (declarations) stays retail-only:
the engine build declares the engine's streams by design.

    python tools/d3_flakes_gate.py --all [--jobs N] [--sample N]
    python tools/d3_flakes_gate.py --bundle vs_actor [--slot 3]

Needs ``$D3_RE`` (and ``$D3_RE_RESIDUE`` for residue programs) and 3Dmigoto's
cmd_Decompiler, as d3_validate_all.py does.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
import traceback
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import d3_diff as DF                      # noqa: E402
import d3_drivers as DR                   # noqa: E402
import d3_dxbc as DX                      # noqa: E402
import d3_flakes as F                     # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402
import dxbc_interp as DI                  # noqa: E402
from dxbc_interp import f2b               # noqa: E402

#: the engine palette: CBBones rows the engine leg may address
DR.CB_ROWS[1] = 256 * 3
_CUBE_DIMS = ('texturecube', 'texturecubearray')
_CH = {'x': 0, 'y': 1, 'z': 2, 'w': 3}


def f32(x: float) -> float:
    return struct.unpack('<f', struct.pack('<f', x))[0]


def unorm(c: int, bits: int) -> float:
    """The input assembler's UNORM conversion: the correctly rounded c / (2^n - 1)."""
    return f32(c / float((1 << bits) - 1))


_TWO_255 = f32(2.0 / 255.0)


def engine_direction(b: int) -> float:
    """The engine's float32 decode of a direction byte."""
    return f32(f32(b * _TWO_255) - 1.0)


def self_check() -> list:
    """The re-encodes the engine stream does, run on every value the decodes make."""
    bad = []
    for b in range(256):
        n = engine_direction(b)
        if int(round(f32(f32(n + 1.0) * 127.5))) != b:
            bad.append('direction byte %d' % b)
    for c0 in (0, 1, 127, 128, 254, 255):
        for c1 in range(256):
            lane = unorm(c0 | (c1 << 8), 16)
            v = int(round(f32(lane * 65535.0)))
            if (v & 0xFF, v >> 8) != (c0, c1):
                bad.append('colour pair %d,%d' % (c0, c1))
    return bad


# --------------------------------------------------------------------------
# packed trial data
# --------------------------------------------------------------------------

class Packed:
    """One trial's retail vertex data, per retail stream, in retail's lanes."""

    def __init__(self, seed: int, measured: dict, regime: str):
        self.kind = F.stream_kind(measured)
        self.rows = {(n, i): (comp, len(m)) for n, i, _r, m, _s, comp in measured.get('streams') or []}
        self.seed, self.regime = seed, regime
        self.lanes = {}
        for key in self.rows:
            self.lanes[key] = self._gen(key)
        # the stand-ins the engine stream gives (mesh only), on the retail leg too
        if self.kind == 'mesh':
            pos = self.lanes.get(('POSITION', 0))
            for (name, idx), (comp, _w) in self.rows.items():
                if name == 'TEXCOORD' and idx >= 2:
                    if comp == 'float' and idx == 2 and pos:
                        self.lanes[(name, idx)] = list(pos)
                    else:
                        self.lanes[(name, idx)] = [0, 0, 0, 0] if comp != 'float' else [f2b(0.0)] * 4
                elif name == 'TEXCOORD' and comp == 'float':
                    # a float uv0 / uv1 stream: the engine record carries its xy, then 0, 1
                    self.lanes[(name, idx)][2:] = [f2b(0.0), f2b(1.0)]
                elif name == 'TANGENT':
                    self.lanes[(name, idx)][3] = 0

    def _rng(self, name, idx, salt=''):
        return DR._rng(self.seed, 'flakes', name, idx, salt)

    def _bytes(self, rng):
        edge = self.regime in DR.EDGE_REGIMES and rng.random() < 0.25
        if edge:
            return [rng.choice(DR._EDGE_U) for _ in range(4)]
        return [rng.randint(0, 255) for _ in range(4)]

    def _float(self, rng, lo=-2.0, hi=2.0):
        edge = self.regime in DR.EDGE_REGIMES and rng.random() < 0.25
        return f32(rng.choice(DR._EDGE_F)) if edge else f32(rng.uniform(lo, hi))

    def _gen(self, key):
        name, idx = key
        comp, _width = self.rows[key]
        rng = self._rng(name, idx)
        if name == 'BLENDINDICES':
            return [rng.randint(0, DR.MAX_BONE) for _ in range(4)]
        if comp in ('uint', 'int'):
            b = self._bytes(rng)
            if name == 'NORMAL':
                b[3] = 0                       # retail's 4th normal byte is always 0
            return b
        if name == 'POSITION':
            return [f2b(self._float(rng)) for _ in range(3)] + [f2b(1.0)]
        if name == 'BLENDWEIGHT':
            w = [rng.random() for _ in range(4)]
            s = sum(w) or 1.0
            return [f2b(unorm(min(255, int(round(x / s * 255))), 8)) for x in w]
        if name == 'COLOR':
            return [f2b(unorm(b, 8)) for b in self._bytes(rng)]
        # float TEXCOORDs: sprite uvs, the particle centre + spin
        return [f2b(self._float(rng)) for _ in range(4)]

    # -- the engine's view --------------------------------------------------

    def _bytes_of(self, key, salt):
        """A stream's bytes, or random bytes where the slot does not declare it
        (the engine record always carries every element)."""
        if key in self.lanes and self.rows[key][0] != 'float':
            return list(self.lanes[key])
        return self._bytes(self._rng(key[0], key[1], salt))

    def _unorm8_bytes(self, key, salt):
        if key in self.lanes:
            return [int(round(DI.b2f(b) * 255.0)) for b in self.lanes[key]]
        return self._bytes(self._rng(key[0], key[1], salt))

    def engine(self) -> dict:
        """``{(SEMANTIC, 0): lanes}`` of the engine record the same vertex makes."""
        out = {}
        if self.kind == 'particle':
            out[('POSITION', 0)] = self.lanes[('POSITION', 0)][:3] + [f2b(1.0)]
            out[('COLOR', 0)] = list(self.lanes[('COLOR', 0)])
            out[('COLORB', 0)] = list(self.lanes[('COLOR', 1)])
            for n, sem in enumerate(('TEXCOORD', 'TEXCOORDB', 'TEXCOORDC', 'TEXCOORDD', 'TEXCOORDE')):
                out[(sem, 0)] = list(self.lanes[('TEXCOORD', n)])
            out[('TEXCOORDF', 0)] = list(self.lanes[('TEXCOORD', 5)])
            return out
        rng = self._rng('ENGINE', 0)
        pos = self.lanes.get(('POSITION', 0)) or [f2b(self._float(rng)) for _ in range(3)] + [f2b(1.0)]
        out[('POSITION', 0)] = pos[:3] + [f2b(1.0)]
        nb = self._bytes_of(('NORMAL', 0), 'n')
        out[('NORMAL', 0)] = [f2b(engine_direction(b)) for b in nb[:3]] + [f2b(1.0)]
        uv = []
        for idx, (scale, bias) in ((0, (512.0, -64.0)), (1, (8192.0, -4.0))):
            key = ('TEXCOORD', idx)
            if key in self.lanes and self.rows[key][0] == 'float':
                uv += [DI.b2f(b) for b in self.lanes[key][:2]]
            else:
                b = self._bytes_of(key, 'uv')
                uv += [f32((b[0] | (b[1] << 8)) / scale + bias), f32((b[2] | (b[3] << 8)) / scale + bias)]
        out[('TEXCOORD', 0)] = [f2b(x) for x in uv]
        tb = self._bytes_of(('TANGENT', 0), 't')
        out[('TANGENT', 0)] = [f2b(engine_direction(b)) for b in tb[:3]] + [f2b(rng.choice((-1.0, 1.0)))]
        c0 = self._unorm8_bytes(('COLOR', 0), 'c0')
        c1 = self._unorm8_bytes(('COLOR', 1), 'c1')
        out[('COLOR', 0)] = [f2b(unorm(c0[k] | (c1[k] << 8), 16)) for k in range(4)]
        out[('BINORMAL', 0)] = self._bytes_of(('BINORMAL', 0), 'b')
        if ('BLENDWEIGHT', 0) in self.lanes:
            out[('BLENDWEIGHT', 0)] = list(self.lanes[('BLENDWEIGHT', 0)])
        if ('BLENDINDICES', 0) in self.lanes:
            out[('BLENDINDICES', 0)] = list(self.lanes[('BLENDINDICES', 0)])
        return out


# --------------------------------------------------------------------------
# legs
# --------------------------------------------------------------------------

class Textures(DR.Textures):
    """D4's texture model, with a cube read as the hardware does: by direction
    alone, so a cube-array read at slice 0 is the same read."""

    def _coords(self, slot, coords):
        if slot in self.cube:
            coords = list(coords[:3]) + [0.0]
        return super()._coords(slot, coords)


class FlakesLeg(DF.Leg):
    """A program fed from packed trial data: ``view`` is ``retail`` (retail lanes)
    or ``engine`` (the engine record)."""

    view: str = 'retail'
    measured: dict = None

    @classmethod
    def open(cls, dxbc: Path, *, slang: bool, view: str, measured: dict, stage: str) -> 'FlakesLeg':
        base = DF.Leg.load(dxbc, slang=slang)
        leg = cls(base.prog, base.slang, base.cube, base.out_keys, base.depth)
        leg.cube = frozenset(int(r['register'][1:]) for r in DX.rdef(Path(dxbc).read_bytes())['resources']
                             if r['kind'] == 'texture' and r['dim'] in _CUBE_DIMS)
        leg.view, leg.measured, leg.stage = view, measured, stage
        return leg

    def run(self, seed, regime, formats, *, overrides=None, trace=None, wide=False):
        base = 'R0' if regime in ('T', 'N') else regime
        if self.stage == 'vs':
            packed = Packed(seed, self.measured, base)
            sem = packed.engine() if self.view == 'engine' else packed.lanes
            inputs = self.inputs(_Sem(sem), DR.sysvals(seed))
            centre = None
        else:
            sem = DR.Inputs(seed, formats, base)
            centre = None
            if base == 'R4':
                tcs = sorted(i for n, i in formats if n == 'TEXCOORD')
                if tcs:
                    centre = [DI.b2f(b) for b in sem.get(('TEXCOORD', tcs[0]))[:2]]
            inputs = self.inputs(sem, DR.sysvals(seed))
        tex = Textures(seed, base, self.cube, centre)
        banks = DR.Banks(seed, base, overrides)
        return DI.execute(self.prog, inputs, banks, texture=tex, deriv_scale=0.0, trace=trace,
                          wide=wide, ieee=True)


class _Sem:
    """``get(key)`` over a lanes dict; a key the data lacks reads zero."""

    def __init__(self, lanes):
        self.lanes = lanes

    def get(self, key):
        return self.lanes.get(key, [0, 0, 0, 0])


# --------------------------------------------------------------------------
# comparison: retail against both builds, trial by trial
# --------------------------------------------------------------------------

def _classify(ref, cand, diverging, res, formats):
    if res.discard_mismatch:
        res.status = 'fail'
        res.error = 'discard differs on %d trial(s) (%d tie)' % (res.discard_mismatch, res.tie_mismatch)
        return res
    res.diverging_trials = len(diverging)
    if not diverging:
        res.status = 'exact'
        return res
    for regime, seed, overrides in diverging:
        a = ref.run(seed, regime, formats, overrides=overrides, wide=True)
        b = cand.run(seed, regime, formats, overrides=overrides, wide=True)
        if a.discarded or b.discarded:
            if a.discarded != b.discarded:
                res.wide_worst = math.inf
                res.wide_where = '%s seed=%d discard differs in wide mode' % (regime, seed)
            continue
        _same, worst, where = DF._compare_outputs(ref, cand, a, b)
        if worst >= res.wide_worst and where:
            res.wide_worst = worst
            res.wide_where = '%s %s seed=%d ref=%r cand=%r' % (regime, where[0], seed, where[1], where[2])
    res.status = 'order-only' if res.wide_worst <= DF.WIDE_TOL else 'fail'
    if res.status == 'fail':
        res.error = 'diverges beyond evaluation order: wide %.3e at %s' % (res.wide_worst, res.wide_where)
    return res


def compare(ref, cands: dict, measured: dict, seed0: int, formats: dict) -> dict:
    """``{name: SlotResult}`` of every candidate against ``ref`` on one schedule."""
    results, diverging = {}, {}
    for name, cand in cands.items():
        res = DF.SlotResult()
        rk, ck = set(ref.out_keys), set(cand.out_keys)
        if ref.depth != cand.depth or rk != ck:
            res.status = 'fail'
            res.one_sided = sorted(str(k) for k in rk ^ ck)
            res.error = 'output semantics differ: %s' % res.one_sided[:6]
        results[name], diverging[name] = res, []
    live = {n: c for n, c in cands.items() if results[n].status != 'fail'}
    for regime, off in DR.schedule(measured):
        seed = seed0 + off
        overrides = None
        if regime == 'T':
            for r in results.values():
                r.tie_attempts += 1
            overrides, achieved = DF.tie_overrides(ref, seed, formats)
            if not achieved:
                continue
            for r in results.values():
                r.ties_achieved += 1
        elif regime == 'N':
            overrides = {(0, DR.ALPHA_REF_ROW, 3): DR.NAN_BITS}
        a = ref.run(seed, regime, formats, overrides=overrides)
        for name, cand in live.items():
            res = results[name]
            b = cand.run(seed, regime, formats, overrides=overrides)
            res.trials += 1
            if a.discarded != b.discarded:
                res.discard_mismatch += 1
                if regime == 'T':
                    res.tie_mismatch += 1
                continue
            if a.discarded:
                continue
            same, worst, where = DF._compare_outputs(ref, cand, a, b)
            if not same:
                diverging[name].append((regime, seed, overrides))
                if worst >= res.worst_rel:
                    res.worst_rel = worst
                    res.worst_where = '%s %s seed=%d ref=%r cand=%r' % (regime, where[0], seed, where[1], where[2])
    for name, cand in live.items():
        _classify(ref, cand, diverging[name], results[name], formats)
    return results


RANK = {'exact': 0, 'order-only': 1, 'fail': 2}


def check_slot(job):
    bid, slot, retail_target, flakes_target = job
    import compile_all_d3 as CA
    s = M.load(bid)[slot]
    stage = bid.split('_', 1)[0]
    row = {'bid': bid, 'slot': slot}
    try:
        retail = R.key_dxbc(s['retail'][0])
        measured = s['measured']
        formats = DF.input_formats(retail)
        ref = FlakesLeg.open(retail, slang=False, view='retail', measured=measured, stage=stage)
        cands = {'retail-target': FlakesLeg.open(CA.out_path(retail_target, bid, slot), slang=True,
                                                 view='retail', measured=measured, stage=stage),
                 'engine-target': FlakesLeg.open(CA.out_path(flakes_target, bid, slot), slang=True,
                                                 view='engine', measured=measured, stage=stage)}
        res = compare(ref, cands, measured, DR.slot_seed(s['retail'][0]['hash']), formats)
        row['retail'] = res['retail-target'].status
        row['engine'] = res['engine-target'].status
        row['ok'] = RANK[row['engine']] <= RANK[row['retail']] and row['engine'] != 'fail'
        row['result'] = {k: v.as_dict() for k, v in res.items()}
    except Exception as e:                                   # noqa: BLE001
        tb = traceback.extract_tb(e.__traceback__)[-1]
        row.update(ok=False, engine='exception', error='%s: %s @%s:%d' % (
            type(e).__name__, str(e)[:160], Path(tb.filename).name, tb.lineno))
    return row


def jobs_for(bid: str, only=None, sample: int = 0):
    import compile_all_d3 as CA
    out = []
    for s in M.load(bid):
        if only is not None and s['slot'] not in only:
            continue
        a, b = CA.out_path('d3d11', bid, s['slot']), CA.out_path('flakes-d3d11', bid, s['slot'])
        if a.exists() and b.exists():
            out.append((bid, s['slot'], 'd3d11', 'flakes-d3d11'))
    if sample and len(out) > sample:
        step = len(out) / sample
        out = [out[int(k * step)] for k in range(sample)]
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--slot', action='append', type=int, default=[])
    ap.add_argument('--sample', type=int, default=0, help='at most N slots per bundle, evenly spaced')
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    args = ap.parse_args(argv)
    import compile_all_d3 as CA
    bad = self_check()
    for b in bad:
        print('self-check: the engine re-encode does not round-trip %s' % b)
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    if not bids:
        ap.error('pass --bundle <id> or --all')
    jobs = [j for bid in bids for j in jobs_for(bid, set(args.slot) or None, args.sample)]
    with ProcessPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(check_slot, jobs, chunksize=1))
    reports = CA.OUT_ROOT / '_reports'
    reports.mkdir(parents=True, exist_ok=True)
    for bid in bids:
        mine = [r for r in rows if r['bid'] == bid]
        (reports / ('flakes_%s.json' % bid)).write_text(json.dumps(mine, indent=1, default=str), 'utf-8')
        pairs = Counter('%s->%s' % (r.get('retail'), r.get('engine')) for r in mine)
        print('%-11s %4d slot(s)  retail-target->engine-target %s' % (bid, len(mine), dict(sorted(pairs.items()))))
        for r in mine:
            if not r.get('ok'):
                bad.append(r)
                eng = (r.get('result') or {}).get('engine-target', {})
                print('   slot %4d  %s -> %s  %s' % (r['slot'], r.get('retail'), r.get('engine'),
                                                    eng.get('error') or r.get('error', '')))
    print('OK' if not bad else '%d problem(s)' % len(bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
