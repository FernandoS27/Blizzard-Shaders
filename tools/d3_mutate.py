#!/usr/bin/env python3
"""Gate D8 -- do D2 and D4 catch a wrong shader?

A green validation means nothing until it has been seen to fail. Each mutation
below breaks exactly one behaviour of one root and must come back CAUGHT: at
least one of the root's built slots fails D2 or D4 against retail. A MISSED
mutation is a hole in the drivers or the schedule -- or a mutation that is a
no-op on the engine's input domain, which must be shown and replaced, never
counted ([[project_wc3_uber_gate_coverage]]).

Two kinds:

* ``src`` -- a text edit to a scratch copy of d3_shaders/ (the installed tree is
  never touched); the edited text must occur exactly once.
* ``cfg`` -- an edit to the compile spec (the declaration defines or the
  specialization): the layout and register classes live in data, not source.

Each root must include the named classes that apply to it: a transport-layout
change, a register shift, an alpha-test tie flip, a NaN injection and (for
skinned roots) a bone-order swap. The schedule is D4's own.

    python tools/d3_mutate.py                      # every root with built slots
    python tools/d3_mutate.py --root actor_vs_main
    python tools/d3_mutate.py --only bone-order-swap
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from dataclasses import dataclass, replace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import compile_all_d3 as CA                # noqa: E402
import compile_all_slang as cas            # noqa: E402
import d3_decl_surface as D2               # noqa: E402
import d3_diff as DF                       # noqa: E402
import d3_drivers as DR                    # noqa: E402
import d3_perm_manifest as M               # noqa: E402
import d3_retail as R                      # noqa: E402
import d3_shaders_cfg as C                 # noqa: E402


@dataclass
class Mutation:
    name: str
    root: str
    kind: str          # 'src' | 'cfg'
    file: str = ''
    old: str = ''
    new: str = ''
    spec: object = None     # cfg: Spec -> Spec (or None when it does not apply)
    cls: str = ''           # named class, for the coverage requirement


_swap_specialize = C.swap_specialize
_widen_first_row = C.widen_first_row
_shift_first_texture = C.shift_first_texture


MUTATIONS = [
    # --- filter_vs -------------------------------------------------------------
    Mutation('filter-taps-swap', 'filter_vs_main', 'src', 'roots/utility/filter.slang',
             'return base.xyxy + Constant0; }', 'return base.xyxy + Constant1; }'),
    Mutation('filter-position-matrix', 'filter_vs_main', 'src', 'roots/utility/filter.slang',
             'o.setPosition(mul(matWorldViewProj, i.position()));',
             'o.setPosition(mul(matWorldView, i.position()));'),
    Mutation('uv-fraction-255', 'filter_vs_main', 'src', 'math/decode.slang',
             'return float2(float(packed.y) + float(packed.x) * (1.0 / 256.0),',
             'return float2(float(packed.y) + float(packed.x) * (1.0 / 255.0),'),
    Mutation('filter-centered-tap-order', 'filter_vs_main', 'src', 'roots/utility/filter.slang',
             'public static float4 taps23(float2 base) { return base.xyxy; }',
             'public static float4 taps23(float2 base) { return base.yxyx; }'),
    Mutation('filter-color-alpha-leak', 'filter_vs_main', 'src', 'roots/utility/filter.slang',
             'o.setColor0(float4(i.color0().xyz, 0.0));', 'o.setColor0(float4(i.color0().xyw, 0.0));'),
    Mutation('filter-transport-width', 'filter_vs_main', 'cfg', spec=_widen_first_row(), cls='transport'),
    # --- blur_ps -----------------------------------------------------------------
    Mutation('blur-alpha-curve', 'blur_ps_main', 'src', 'roots/utility/filter.slang',
             'float alpha = pow(blurred.w, 0.25);', 'float alpha = pow(blurred.w, 0.3);'),
    Mutation('blur-silhouette-threshold', 'blur_ps_main', 'src', 'roots/utility/filter.slang',
             'if (original.w > 0.125)', 'if (original.w > 0.25)'),
    Mutation('blur-luma-weights', 'blur_ps_main', 'src', 'roots/utility/filter.slang',
             'float3(0.222, 0.707, 0.071)', 'float3(0.707, 0.222, 0.071)'),
    Mutation('blur-nan-injection', 'blur_ps_main', 'src', 'roots/utility/filter.slang',
             'float3 rgb = blurred.xyz / luma * pow(luma, 0.25);',
             'float3 rgb = blurred.xyz / luma * pow(luma - 0.5, 0.25);', cls='nan'),
    Mutation('blur-tie-flip', 'blur_ps_main', 'cfg', spec=_swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    Mutation('blur-register-shift', 'blur_ps_main', 'cfg', spec=_shift_first_texture(), cls='register'),
    Mutation('blur-transport-width', 'blur_ps_main', 'cfg', spec=_widen_first_row(), cls='transport'),
    # --- actor_vs ----------------------------------------------------------------
    Mutation('bone-order-swap', 'actor_vs_main', 'src', 'interfaces/skinning.slang',
             'float4 row0 = matBones[bones.x].row0 * weights.x + matBones[bones.y].row0 * weights.y',
             'float4 row0 = matBones[bones.x].row0 * weights.y + matBones[bones.y].row0 * weights.x',
             cls='bone'),
    Mutation('point-light-atten', 'actor_vs_main', 'src', 'math/lights.slang',
             'lightPoints[0].atten.y * sqrt(dist2)', 'lightPoints[0].atten.y * dist2'),
    Mutation('linear-light-clamp', 'actor_vs_main', 'src', 'math/lights.slang',
             'int count = min(int(numLights.x), 16);', 'int count = min(int(numLights.x), 15);'),
    Mutation('cylinder-radius', 'actor_vs_main', 'src', 'math/lights.slang',
             'saturate((lightCylindricals[0].radii.y - perp)', 'saturate((lightCylindricals[0].radii.x - perp)'),
    Mutation('fog-height-axis', 'actor_vs_main', 'src', 'math/fog.slang',
             '(worldZ - wpPlayer.z)', '(worldZ - wpPlayer.y)'),
    Mutation('glow-fade-radius', 'actor_vs_main', 'src', 'roots/actor/actor_vs.slang',
             '(length(toPlayer) - 10.0)', '(length(toPlayer) - 9.0)'),
    Mutation('uv1-range', 'actor_vs_main', 'src', 'math/decode.slang',
             'd3DecodeUv(packed, 0.03125, -4.0)', 'd3DecodeUv(packed, 0.0625, -4.0)'),
    Mutation('clip-plane-index', 'actor_vs_main', 'src', 'math/fog.slang',
             'dot(clipPos, vecClipPlane[5])', 'dot(clipPos, vecClipPlane[4])'),
    Mutation('actor-vs-nan-injection', 'actor_vs_main', 'src', 'math/lights.slang',
             'float perp = sqrt(max(dist2 - axial * axial, 0.0));', 'float perp = sqrt(dist2 - axial * axial);',
             cls='nan'),
    Mutation('actor-vs-transport-width', 'actor_vs_main', 'cfg', spec=_widen_first_row(), cls='transport'),
    # --- actor_ps ----------------------------------------------------------------
    Mutation('alphacomp-fog-direction', 'actor_ps_main', 'src', 'math/fog.slang',
             'return lerp(fogColor.rgb, color, fog);', 'return lerp(color, fogColor.rgb, fog);'),
    Mutation('alphacomp-mask-channel', 'actor_ps_main', 'src', 'roots/actor/actor_ps.slang',
             'texAlphaMask.Sample(texAlphaMask_s, i.texcoord1().xy).a', 'texAlphaMask.Sample(texAlphaMask_s, i.texcoord1().xy).r'),
    Mutation('alphacomp-uv-set', 'actor_ps_main', 'src', 'roots/actor/actor_ps.slang',
             'texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy)', 'texDiffuse.Sample(texDiffuse_s, i.texcoord1().xy)'),
    Mutation('alphacomp-nan-injection', 'actor_ps_main', 'src', 'roots/actor/actor_ps.slang',
             'diffuse.rgb * i.color0().rgb', 'diffuse.rgb * sqrt(i.color0().rgb - 0.5)', cls='nan'),
    Mutation('alphacomp-tie-flip', 'actor_ps_main', 'cfg', spec=_swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    Mutation('alphacomp-register-shift', 'actor_ps_main', 'cfg', spec=_shift_first_texture(), cls='register'),
    Mutation('alphacomp-transport-width', 'actor_ps_main', 'cfg', spec=_widen_first_row(), cls='transport'),
]

#: classes every root of that stage must exercise (bone only for skinned roots)
REQUIRED = {'vs': {'transport'}, 'ps': {'transport', 'register', 'nan'}}
ALPHA_ROOTS = {'blur_ps_main', 'actor_ps_main'}
SKINNED_ROOTS = {'actor_vs_main'}

# translator plugins contribute their roots' mutations (as dicts of Mutation
# fields) and the extra classes those roots must cover
for _plugin in C.PLUGINS:
    MUTATIONS += [m if isinstance(m, Mutation) else Mutation(**m)
                  for m in getattr(_plugin, 'MUTATIONS', [])]
    ALPHA_ROOTS |= set(getattr(_plugin, 'ALPHA_ROOTS', ()))
    SKINNED_ROOTS |= set(getattr(_plugin, 'SKINNED_ROOTS', ()))


def root_slots(root: str) -> list:
    """``[(bundle, slot dict, spec)]`` for every built slot of a root."""
    out = []
    for d, s in R.bundles():
        bid = R.bundle_id(d, s)
        for slot in M.load(bid):
            spec, problem = CA.slot_spec(slot)
            if spec and spec.entry == root and CA.out_path('d3d11', bid, slot['slot']).exists():
                out.append((bid, slot, spec))
    return out


def judge(job):
    bid, slot, blob, compiled = job
    if not compiled:
        return 'nocompile'
    r0 = slot['retail'][0]
    retail = R.key_dxbc(r0)
    if D2.compare(D2.retail_surface(retail), D2.slang_surface(blob)):
        return 'D2'
    res = DF.compare_slot(DF.Leg.load(retail, slang=False), DF.Leg.load(blob, slang=True),
                          slot['measured'], DR.slot_seed(r0['hash']), DF.input_formats(retail))
    return 'pass' if res.ok() else 'D4'


def run_mutation(mut: Mutation, slots: list, pool, jobs: int) -> str:
    with tempfile.TemporaryDirectory(prefix='d3mut_') as td:
        tree = Path(td) / 'd3_shaders'
        shutil.copytree(C.INCLUDE, tree)
        if mut.kind == 'src':
            path = tree / mut.file
            text = path.read_text('utf-8')
            if text.count(mut.old) != 1:
                return 'BAD MUTATION (text occurs %d times)' % text.count(mut.old)
            path.write_text(text.replace(mut.old, mut.new), 'utf-8')
        work = []
        for bid, slot, spec in slots:
            if mut.kind == 'cfg':
                spec = mut.spec(spec)
                if spec is None:
                    continue
            work.append((bid, slot, spec, Path(td) / ('%s_%04d.dxbc' % (bid, slot['slot']))))
        if not work:
            return 'N/A (applies to no built slot)'

        def build(item):
            bid, slot, spec, out = item
            stage = bid.split('_', 1)[0]
            ok = cas.invoke_slangc(spec.entry, 'dxbc', '%s_4_0' % stage, list(spec.specialize), out,
                                   tree / 'd3_shaders.slang', include_dirs=[tree],
                                   defines=list(spec.defines))
            return (bid, slot, out, ok)

        with ThreadPoolExecutor(max_workers=jobs) as ex:
            built = list(ex.map(build, work))
        verdicts = list(pool.map(judge, built))
    caught = [v for v in verdicts if v in ('D2', 'D4')]
    if caught:
        return 'caught (%s on %d/%d slots)' % ('+'.join(sorted(set(caught))), len(caught), len(verdicts))
    if all(v == 'nocompile' for v in verdicts):
        return 'BAD MUTATION (does not compile)'
    return 'MISSED (%d slots pass)' % verdicts.count('pass')


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', action='append', default=[])
    ap.add_argument('--only', action='append', default=[])
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    args = ap.parse_args(argv)
    muts = [m for m in MUTATIONS if (not args.root or m.root in args.root)
            and (not args.only or m.name in args.only)]
    bad = 0
    by_root = {}
    with ProcessPoolExecutor(args.jobs) as pool:
        for mut in muts:
            if mut.root not in by_root and not root_slots(mut.root):
                print('  [n/a ] %-11s %-28s no built slots' % (mut.root.replace('_main', ''), mut.name))
                by_root[mut.root] = []
                continue
            slots = by_root.setdefault(mut.root, root_slots(mut.root))
            verdict = run_mutation(mut, slots, pool, args.jobs)
            ok = verdict.startswith('caught') or verdict.startswith('N/A')
            if not slots:
                continue
            print('  [%s] %-11s %-28s %s' % ('ok  ' if ok else 'MISS', mut.root.replace('_main', ''),
                                              mut.name, verdict), flush=True)
            if not ok:
                bad += 1
    if not args.only:
        for root in sorted({m.root for m in muts}):
            classes = {m.cls for m in muts if m.root == root and m.cls}
            need = set(REQUIRED['ps' if root.endswith('_ps_main') else 'vs'])
            if root in ALPHA_ROOTS:
                need.add('tie')
            if root in SKINNED_ROOTS:
                need.add('bone')
            if need - classes:
                bad += 1
                print('  [MISS] %s lacks required mutation classes %s' % (root, sorted(need - classes)))
    print('D8: %d mutation(s), %s' % (len(muts), 'all caught' if not bad else '%d problem(s)' % bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
