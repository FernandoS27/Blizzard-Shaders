"""Differential comparison of one D3 slot against its retail program (plan H2-H4).

Both programs run through the canonical ``dxbc_interp`` on the slot's full trial
schedule (``d3_drivers.schedule``). What is compared, and how:

* **Outputs are keyed by semantic** -- ``(NAME, index, component)`` from each
  program's own output signature, slang's x10 index undone per row -- never by
  register ([[project_wc3_output_register_alignment]]). A key present on one
  side only fails the slot ([[project_gate_intersection_cap]]).
* **Discard parity** is checked on every trial; outputs are compared only when
  neither leg discarded (a discarded fragment has no output).
* **Tie trials** (regime T): run the reference, capture the operand its first
  ``lt|ge`` compares with ``alphaTestRef.w``, set ``alphaTestRef.w`` to exactly
  those bits, re-run the reference and keep the trial only if the compare now
  really sees a tie (``alphaTestRef`` may feed its own operand). Then the
  candidate must discard exactly when the reference does. Random draws never
  produce a tie, which is how ``a <= ref`` and ``a < ref`` both "passed" before.
* **NaN-reference trials** (regime N): ``alphaTestRef.w`` is NaN, which separates
  ``!(ref < a)`` from ``a <= ref`` the way a tie separates ``<`` from ``<=``.
* **Classification** (plan 3.3): ``exact`` when every compared value is equal
  (NaN == NaN, +0 == -0); otherwise every diverging trial is re-run in wide mode
  and the slot is ``order-only`` if all of them then agree within 1e-12
  (relative, floor 1) -- the same real function evaluated in another float32
  order; anything else is ``fail``. No tolerance.

    python tools/d3_diff.py RETAIL.dxbc CANDIDATE.dxbc [--measured-from RETAIL.dxbc]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d3_drivers as DR                   # noqa: E402
import d3_dxbc as DX                      # noqa: E402
import dxbc_interp as DI                  # noqa: E402

WIDE_TOL = 1e-12
_CH = {'x': 0, 'y': 1, 'z': 2, 'w': 3}
_ALPHA_REF = 'cb0[%d]' % DR.ALPHA_REF_ROW


@dataclass
class Leg:
    """One program ready to run."""
    prog: DI.Program
    slang: bool
    cube: frozenset
    out_keys: dict            # (NAME, idx, k) -> (reg, lane)
    depth: bool = False       # writes SV_Depth (oDepth has no register; compared apart)

    @classmethod
    def load(cls, dxbc: Path, *, slang: bool) -> 'Leg':
        dxbc = Path(dxbc)
        asm = DX.asm_path(dxbc, refresh=slang)
        prog = DI.Program.from_file(asm)
        blob = dxbc.read_bytes()
        cube = frozenset(int(r['register'][1:]) for r in DX.rdef(blob)['resources']
                         if r['kind'] == 'texture' and r['dim'] == 'texturecube')
        keys = {}
        depth = False
        for name, idx, reg, mask, sysval, comp in DX.signature(blob, 'OSGN', slang=slang):
            if name.startswith('SV_DEPTH'):
                depth = True
                continue
            for k, ch in enumerate(mask):
                keys[(name, idx, k)] = (reg, _CH[ch])
        # dxbc_interp names outputs by register; the container row gives the mask
        return cls(prog, slang, cube, keys, depth)

    def inputs(self, sem, sv):
        """``{register: lanes}`` from per-semantic values (x10 undone per row)."""
        inp = {}
        for name, idx, mask, reg in self.prog.input_sig:
            if self.slang:
                idx = DX.norm_index(name, idx)
            v = sem.get((name, idx))
            inp.setdefault(reg, [0, 0, 0, 0])
            for di, c in enumerate(ch for ch in mask if ch in _CH):
                inp[reg][_CH[c]] = v[di]
        for name, bits in (sv or {}).items():
            if name in self.prog.sysval_regs:
                inp[self.prog.sysval_regs[name]] = [bits] * 4
        return inp

    def run(self, seed, regime, formats, *, overrides=None, trace=None, wide=False):
        base = 'R0' if regime in ('T', 'N') else regime
        sem = DR.Inputs(seed, formats, base)
        centre = None
        if base == 'R4':
            # the edges of a neighbourhood trial pass through its pixel: the lowest
            # TEXCOORD the retail signature declares (a property of the inputs, never of
            # which tap a leg samples first)
            tcs = sorted(i for n, i in formats if n == 'TEXCOORD')
            if tcs:
                centre = [DI.b2f(b) for b in sem.get(('TEXCOORD', tcs[0]))[:2]]
        tex = DR.Textures(seed, base, self.cube, centre)
        banks = DR.Banks(seed, base, overrides)
        return DI.execute(self.prog, self.inputs(sem, DR.sysvals(seed)), banks,
                          texture=tex, deriv_scale=0.0, trace=trace, wide=wide, ieee=True)


def _same(a: float, b: float) -> bool:
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    return a == b


def _rel(a: float, b: float) -> float:
    if math.isnan(a) or math.isnan(b):
        return 0.0 if (math.isnan(a) and math.isnan(b)) else math.inf
    if math.isinf(a) or math.isinf(b):
        return 0.0 if a == b else math.inf
    return abs(a - b) / max(1.0, abs(a), abs(b))


def input_formats(dxbc: Path) -> dict:
    return {(n, i): comp for n, i, _r, _m, _s, comp in DX.signature(Path(dxbc).read_bytes(), 'ISGN')}


# --------------------------------------------------------------------------
# tie trials
# --------------------------------------------------------------------------

def _alpha_operand(node):
    """``(register operand, ref index)`` if ``node`` compares a register with
    alphaTestRef.w, else None."""
    if node[0] != 'op' or node[1] not in ('lt', 'ge', 'eq', 'ne'):
        return None
    raw = node[4]
    if len(raw) != 3:
        return None
    srcs = node[3]
    for i in (0, 1):
        o = srcs[i]
        other = srcs[1 - i]
        is_ref = (o[0] == 'reg' and o[1] == 'cb' and o[2] == 0
                  and o[3] == ('const', DR.ALPHA_REF_ROW))
        other_is_ref = (other[0] == 'reg' and other[1] == 'cb' and other[2] == 0
                        and other[3] == ('const', DR.ALPHA_REF_ROW))
        # the alpha may be a temporary or a bank value (Legacy tests Factor.w directly)
        if is_ref and other[0] == 'reg' and not other_is_ref:
            return other, o
    return None


def tie_overrides(ref: Leg, seed: int, formats: dict):
    """Capture the reference's alpha operand; ``(overrides, achieved)``."""
    captured = []

    def grab(vm, node, phase):
        if phase != 'pre' or captured:
            return
        hit = _alpha_operand(node)
        if hit:
            other, refop = hit
            lane = refop[4][0]
            captured.append((DI.f2b(vm.fread(other)[0]), lane))

    ref.run(seed, 'T', formats, trace=grab)
    if not captured:
        return None, False
    bits, lane = captured[0]
    overrides = {(0, DR.ALPHA_REF_ROW, lane): bits}
    seen = []

    def verify(vm, node, phase):
        if phase != 'pre' or seen:
            return
        hit = _alpha_operand(node)
        if hit:
            other, refop = hit
            seen.append(DI.f2b(vm.fread(other)[0]) == DI.f2b(vm.fread(refop)[0]))

    ref.run(seed, 'T', formats, overrides=overrides, trace=verify)
    return overrides, bool(seen and seen[0])


# --------------------------------------------------------------------------
# slot comparison
# --------------------------------------------------------------------------

@dataclass
class SlotResult:
    status: str = 'exact'
    trials: int = 0
    discard_mismatch: int = 0
    tie_attempts: int = 0
    ties_achieved: int = 0
    tie_mismatch: int = 0
    worst_rel: float = 0.0
    worst_where: str = ''
    wide_worst: float = 0.0
    wide_where: str = ''
    diverging_trials: int = 0
    one_sided: list = field(default_factory=list)
    error: str = ''

    def ok(self) -> bool:
        return self.status in ('exact', 'order-only')

    def as_dict(self) -> dict:
        return dict(self.__dict__)


def _compare_outputs(ref: Leg, cand: Leg, a, b):
    worst, where, same = 0.0, None, True
    pairs = [(key, a.f(rr, rl), b.f(*cand.out_keys[key])) for key, (rr, rl) in ref.out_keys.items()]
    if ref.depth and not (a.depth is None and b.depth is None):
        # SV_Depth: a depth-only pass (copy_depth) is compared on nothing else; a leg
        # that never wrote it reads as a value no written depth can equal
        pairs.append((('SV_DEPTH', 0, 0), math.nan if a.depth is None else a.depth,
                      math.inf if b.depth is None else b.depth))
    for key, x, y in pairs:
        if not _same(x, y) and not (x == 0 and y == 0):
            same = False
            d = _rel(x, y)
            if d >= worst:
                worst, where = d, (key, x, y)
    return same, worst, where


def compare_slot(ref: Leg, cand: Leg, measured: dict, seed0: int, formats: dict,
                 *, schedule=None) -> SlotResult:
    res = SlotResult()
    rk, ck = set(ref.out_keys), set(cand.out_keys)
    if ref.depth != cand.depth:
        rk, ck = rk | ({('SV_DEPTH', 0, 0)} if ref.depth else set()), ck | ({('SV_DEPTH', 0, 0)} if cand.depth else set())
    if rk != ck:
        res.one_sided = sorted(str(k) for k in rk ^ ck)
        res.status = 'fail'
        res.error = 'output semantics differ: %s' % res.one_sided[:6]
        return res
    diverging = []
    for regime, off in (schedule or DR.schedule(measured)):
        seed = seed0 + off
        overrides = None
        if regime == 'T':
            res.tie_attempts += 1
            overrides, achieved = tie_overrides(ref, seed, formats)
            if not achieved:
                continue
            res.ties_achieved += 1
        elif regime == 'N':
            overrides = {(0, DR.ALPHA_REF_ROW, 3): DR.NAN_BITS}
        a = ref.run(seed, regime, formats, overrides=overrides)
        b = cand.run(seed, regime, formats, overrides=overrides)
        res.trials += 1
        if a.discarded != b.discarded:
            res.discard_mismatch += 1
            if regime == 'T':
                res.tie_mismatch += 1
            continue
        if a.discarded:
            continue
        same, worst, where = _compare_outputs(ref, cand, a, b)
        if not same:
            diverging.append((regime, seed, overrides))
            if worst >= res.worst_rel:
                res.worst_rel = worst
                res.worst_where = '%s %s seed=%d ref=%r cand=%r' % (regime, where[0], seed, where[1], where[2])
    res.diverging_trials = len(diverging)
    if res.discard_mismatch:
        res.status = 'fail'
        res.error = 'discard differs on %d trial(s) (%d tie)' % (res.discard_mismatch, res.tie_mismatch)
        return res
    if not diverging:
        return res
    for regime, seed, overrides in diverging:
        a = ref.run(seed, regime, formats, overrides=overrides, wide=True)
        b = cand.run(seed, regime, formats, overrides=overrides, wide=True)
        if a.discarded or b.discarded:
            if a.discarded != b.discarded:
                res.wide_worst = math.inf
                res.wide_where = '%s seed=%d discard differs in wide mode' % (regime, seed)
            continue
        _same_w, worst, where = _compare_outputs(ref, cand, a, b)
        if worst >= res.wide_worst and where:
            res.wide_worst = worst
            res.wide_where = '%s %s seed=%d ref=%r cand=%r' % (regime, where[0], seed, where[1], where[2])
    res.status = 'order-only' if res.wide_worst <= WIDE_TOL else 'fail'
    if res.status == 'fail':
        res.error = 'diverges beyond evaluation order: wide %.3e at %s' % (res.wide_worst, res.wide_where)
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('retail')
    ap.add_argument('candidate')
    ap.add_argument('--slang', action='store_true', help='candidate is slang output (x10 indices)')
    ap.add_argument('--seed', type=int, default=0)
    args = ap.parse_args(argv)
    import d3_perm_manifest as M
    import d3_retail as R
    measured = M.measured(Path(args.retail), 'ps' if 'pixel' in args.retail else 'vs')
    ref = Leg.load(Path(args.retail), slang=False)
    cand = Leg.load(Path(args.candidate), slang=args.slang)
    r = compare_slot(ref, cand, measured, args.seed, input_formats(Path(args.retail)))
    print(json.dumps(r.as_dict(), indent=1))
    return 0 if r.ok() else 1


if __name__ == '__main__':
    sys.exit(main())
