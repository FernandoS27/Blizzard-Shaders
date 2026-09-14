"""Differential test of the slang ``water_ps`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** water pixel shader: 128 permutations, 49
programs::

    bit 0 SHADOW_CASCADE2   1 DEPTH_PREPASS (empty)   2 LIGHT_DEBUG
    bit 3 POINT_SHADOWS     4 SHADOW_CASCADE          5-6 SSR quality (0/16/32/64)

**The lighting driver is ``DRIVERS['hd']``**: water moved onto the HD banks and
runs HD's main light, cluster loop and cascade walk. Everything water adds is
driven here, each for a reason rather than for decoration:

* **depth in view-depth units.** Refraction, the shore fades and the glow all
  compare the scene depth (t1, read with ``Load``) against the pixel's view Z.
  A texel in [0.1, 0.9] against view depths of 0.5..60 would put every pixel
  "above" the scene -- refraction fade 0, shore 0, glow 0 -- and hide most of
  the composite. t1 spans about [-2, 52] and the view Z [-4, 45], so
  both signs of ``depth - viewZ`` are common, and the "refracted tap lands in
  front of the water" select goes both ways.
* **the constant-probe flag** (cb1[37].w) on both sides of 0.5, which swaps the
  probe source, the tint and the glow clamp at once.
* **the artist refraction range** (cb1[38].xy): its select is
  ``min > 0 || max < 1``, so min is exactly 0 half the time and max exactly 1
  half the time, making both arms common.
* **the fade scale** (cb1[39].x) sometimes exactly 0, where the ``max(1e-4)``
  guard is the only thing between the shader and a division by zero.
* **the two depth-fade distances** (cb2[23].xy) kept positive and finite.
* **a coherent scene for the reflection march** (SSR perms): a perspective
  view -> clip (cb2[16..19]), a near-identity depth-UV remap (cb2[21]), view
  positions that project on screen, and a t2 tile-bounds texture that really
  bounds t1 (see `WaterTextures`). Random rows and fields sent almost every ray
  off screen at the first tile.

Outputs compared: SV_TARGET0 and SV_TARGET1 (view Z).

    python tools/shader_diff_water_ps.py
    python tools/shader_diff_water_ps.py --perms 0,16,32
"""

import argparse
import hashlib
import math
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import b2f, f2b, i2b                                       # noqa: E402
from shader_diff import load, compare, perm_path                    # noqa: E402
from wc3_uber_validate import (DRIVERS, HdStructured, HdTextures,  # noqa: E402
                               hd_cbufs, hd_inputs)

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "water"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "water_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 128
OUTPUT_REGS = (0, 1)


def scene_depth(px, py):
    """The scene depth at a depth-buffer texel, in view-depth units: a floor
    receding up the screen with ripples on it, spanning about [-2, 52]."""
    return 5.0 + 40.0 * (py / 1024.0) + 4.0 * math.sin(px * 0.07) + 3.0 * math.sin(py * 0.11)


class WaterTextures(HdTextures):
    """hd's texture model with a COHERENT depth scene for water.

    t1 is `scene_depth` at the loaded texel, and t2 -- the 64x64 tile depth
    bounds the reflection march walks first -- genuinely bounds it: .x at or
    below the tile's nearest depth, .y at or above its farthest. Two
    independent random fields would make the coarse test ("can the ray's depth
    span meet this tile at all?") admit almost no tile, leaving the fine
    per-pixel DDA essentially unexecuted -- measured at 5-7% of trials changing
    the output before this model existed.
    """

    def sample(self, slot, coords):
        if slot == 1:
            d = scene_depth(coords[0], coords[1])
            return [d, d, d, 1.0]
        if slot == 2:
            i, j = coords[0], coords[1]
            near = 5.0 + 40.0 * (16.0 * j / 1024.0) - 7.0
            far = 5.0 + 40.0 * ((16.0 * j + 16.0) / 1024.0) + 7.0
            # Tighten each bound by a per-tile amount up to 3 units, so the
            # coarse test's 2-unit thickness boundary is actually approached;
            # exact conservative bounds sit so far from it that a wrong
            # thickness constant was unobservable (P11 G7b).
            r = random.Random(f"hiz:{i}:{j}")
            return [near + r.uniform(0.0, 3.0), far - r.uniform(0.5, 6.5), 0.0, 1.0]
        return super().sample(slot, coords)

    def sample_compare(self, slot, coords, ref):
        # Both shadow maps at ten or more times hd's frequency: the cube map
        # (t9) keyed on the tap DIRECTION, the cascade atlas (t10) on its UV.
        # At hd's 0.37 rad per unit, water's ripple push -- up to a radian on
        # the cube kernel's centre, up to a UV unit on the cascade walk's start
        # -- moved the comparison by a few percent before the 9-tap average and
        # the light weight; dropping either push went unobserved (P11 G7b).
        s = self._safe
        if slot == 9:
            v = math.sin(s(ref) * 1.7 + 4.77)
            for j, co in enumerate(coords[:3]):
                v += math.sin(s(co) * 4.0 * (1.0 + 0.23 * j) + 2.79 + j)
            v += math.sin(s(coords[3]) * 0.46 + 3.0)
            return 0.5 + 0.5 * math.sin(v)
        if slot == 10:
            v = math.sin(s(ref) * 1.7 + 1.9)
            for j, co in enumerate(coords[:2]):
                v += math.sin(s(co) * 6.0 * (1.0 + 0.31 * j) + 0.7 + j)
            v += math.sin(s(coords[2]) * 0.9 + 2.2)
            return 0.5 + 0.5 * math.sin(v)
        return super().sample_compare(slot, coords, ref)


class WaterStructured(HdStructured):
    """hd's light buffers with ORDINARY lights dimmed to a third -- on one seed
    in four no debug gizmos at all, and on another no lights whatever.

    Water folds its lit colour through ``min(lit, tint)`` with a tint of at most
    one, so hd's light radiance (colours up to 2 with gentle attenuation)
    saturated that clamp on most trials and hid everything the light loop does
    -- including the ripple offset of the point-light shadow kernel, which went
    unobserved at 128 trials. Debug gizmos (attenuation all zero) keep their
    exact magnitudes: the overlay keys off 1/255 brackets.

    Half of hd's lights are gizmos, and their shadow index is drawn
    independently of that, so most lights that run a cube-shadow kernel have a
    radiance of ~0.005: shadowing them fully cannot move the output by 1e-3.
    On ``seed % 4 == 0`` every record is an ordinary shadow-casting light (the
    same colour / attenuation ranges, already dimmed) so the kernel's result
    actually reaches the frame.

    On ``seed % 4 == 2`` every cluster is empty, so the main light is the only
    light: see ``water_cbufs``' exposed-main-light regime.
    """

    def load(self, slot, index, byte_offset):
        if slot == 18 and self.seed % 4 == 2:
            return [0, 0, 0, 0]
        if slot == 16 and self.seed % 4 == 0:
            r = random.Random(f"ord:{self.seed}:{index}")
            shadow = r.choice([-1, 0, 0, 1, 1, 2])
            pos = [r.uniform(-12, 12), r.uniform(-12, 12), r.uniform(-5, 45)]
            words = ([f2b(0.33 * r.uniform(0.2, 2.0)) for _ in range(3)] + [i2b(shadow)]
                     + [f2b(c) for c in pos]
                     + [f2b(r.uniform(0.0, 0.004)), f2b(r.uniform(0.0, 0.03)),
                        f2b(r.uniform(0.0, 0.0004))])
            w0 = byte_offset // 4
            return [words[w0 + k] if 0 <= w0 + k < len(words) else 0 for k in range(4)]
        out = super().load(slot, index, byte_offset)
        if slot == 16 and byte_offset == 0:
            atten = super().load(slot, index, 28)
            if any(atten[k] != 0 for k in range(3)):
                out = [f2b(b2f(out[k]) * 0.33) for k in range(3)] + out[3:]
        return out


def water_inputs(seed):
    inp = dict(hd_inputs(seed))
    r = random.Random(4242 + seed)
    # One fragment in six sits on or just past a screen edge, where the
    # refraction offset leaves the texture and the texel clamps decide the
    # fetch; interior fragments never reach them.
    edge = r.random() < 1 / 6
    def coord():
        return r.choice([r.uniform(-3, 3), r.uniform(1021, 1027)]) if edge else r.uniform(0, 1024)
    inp[("SV_POSITION", 0)] = [f2b(coord()), f2b(coord()), f2b(r.uniform(0, 1)), f2b(1.0)]
    z = r.uniform(-4, 0.5) if r.random() < 0.15 else r.uniform(0.5, 45)
    # On screen under the driver's projection (|x|, |y| < z) most of the time.
    span = max(abs(z), 1.0) * 0.9
    inp[("TEXCOORD", 1)] = [f2b(r.uniform(-span, span)), f2b(r.uniform(-span, span)),
                            f2b(z), f2b(0.0)]
    return inp


def water_cbufs(seed):
    cb = hd_cbufs(seed)
    r = random.Random(seed * 313 + 9)
    c1, c2 = cb[1], cb[2]
    c1[37] = [f2b(r.uniform(0, 2)) for _ in range(3)] + [f2b(r.choice([0.0, 1.0]))]
    c1[38] = [f2b(0.0 if r.random() < 0.5 else r.uniform(0, 1)),
              f2b(1.0 if r.random() < 0.5 else r.uniform(0, 1.5)),
              f2b(r.uniform(0, 1)), f2b(r.uniform(0, 2))]
    fade_scale = 0.0 if seed % 13 == 6 else r.uniform(0.05, 2)
    c1[39] = [f2b(fade_scale), f2b(r.uniform(0, 3)), f2b(r.uniform(0, 2)), c1[39][3]]
    c2[22] = [f2b(r.uniform(0, 2)) for _ in range(3)] + [c2[22][3]]
    c2[23] = [f2b(r.uniform(1, 40)), f2b(r.uniform(1, 40))] + c2[23][2:]
    c2[26] = [f2b(r.uniform(-4000, 4000))] + c2[26][1:]
    # A real perspective projection (clip.xy = f * view.xy, clip.w = view.z,
    # rows read as .xyw columns) and a near-identity depth-UV remap, so the
    # reflection ray projects onto the screen instead of off it.
    f = r.uniform(0.8, 1.4)
    c2[16] = [f2b(f), f2b(r.uniform(-0.05, 0.05)), f2b(0.0), f2b(r.uniform(-0.02, 0.02))]
    c2[17] = [f2b(r.uniform(-0.05, 0.05)), f2b(f), f2b(0.0), f2b(r.uniform(-0.02, 0.02))]
    c2[18] = [f2b(r.uniform(-0.1, 0.1)), f2b(r.uniform(-0.1, 0.1)), f2b(0.0), f2b(1.0)]
    c2[19] = [f2b(0.0), f2b(0.0), f2b(0.0), f2b(0.0 if seed % 17 else 1e-7)]
    c2[21] = [f2b(r.uniform(0.9, 1.0)), f2b(r.uniform(0.9, 1.0)),
              f2b(r.uniform(0, 0.05)), f2b(r.uniform(0, 0.05))]
    # A LIT-EXPOSED regime on half the trials. Lighting reaches water's output
    # only through the shore / glow blends, the depth fade and a weak reflection
    # layer; with independent draws those gates multiply to near zero on most
    # trials, and a change inside the light loop (the ripple offset of the
    # point-shadow kernel) was observable on 0.27% of trials. Here: shallow
    # fade distances (shore saturates), a fast fade, a weak reflection and an
    # unclamped glow.
    if seed % 2 == 0:
        c2[23] = [f2b(r.uniform(0.3, 2.0)), f2b(r.uniform(0.3, 2.0))] + c2[23][2:]
        c1[39][0] = f2b(r.uniform(0.02, 0.2))
        # A strong ripple: the shadow jitter is 0.1 x this, and at <= 0.3 the
        # PCF kernel barely moves under a smooth comparison field.
        c1[39][1] = f2b(r.uniform(2.0, 10.0))
        c1[38][2] = f2b(r.uniform(0.0, 0.15))
        c2[22] = [f2b(2.0), f2b(2.0), f2b(2.0), c2[22][3]]
        c1[37] = [f2b(r.uniform(1.0, 2.0)) for _ in range(3)] + [f2b(1.0)]
    # With the main light on, min(lit, tint) is usually already saturated by
    # it and nothing the cluster loop adds survives the clamp: a full on/off
    # of every point shadow changed the output on 1 trial in 128. On the seeds
    # whose lights are all ordinary (WaterStructured), the main light is off.
    if seed % 4 == 0:
        c2[27] = [c2[27][0], f2b(0.0)] + c2[27][2:]
    # An EXPOSED MAIN LIGHT on the seeds whose clusters are empty. The cascade
    # shadow reaches the lit colour only through max(0, N.L) and the ambient /
    # direct terms, and hd's random rows leave N.L negative half the time and
    # an IBL specular (scaled by ambientAdd.w) of several units on top, which
    # min(lit, tint) clamps away: a full on/off of the cascade shadow was
    # visible on 3 trials in 128, and dropping water's jitter of the cascade
    # walk on 1-2. Here the light faces the surface (either sign of the
    # interpolated normal, since the ripple frame may flip it), the cascade
    # walk has something to walk, and the ambient stays under the tint.
    if seed % 4 == 2:
        rr = random.Random(f"mainlight:{seed}")
        c1[36] = [i2b(rr.randint(1, 3))] + c1[36][1:]
        c2[27] = [c2[27][0], f2b(1.0)] + c2[27][2:]
        c2[28] = [f2b(rr.uniform(0.0, 0.05)) for _ in range(3)] + [f2b(rr.uniform(0.0, 0.1))]
        c2[29] = [f2b(rr.uniform(0.2, 0.8)) for _ in range(3)] + [c2[29][3]]
        normal = [b2f(b) for b in water_inputs(seed)[("TEXCOORD", 2)][:3]]
        sign = 1.0 if seed % 8 == 2 else -1.0
        v = [sign * x + rr.uniform(-0.3, 0.3) for x in normal]
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        c2[30] = [f2b(x / n) for x in v] + [c2[30][3]]
    # Point-light shadow shells that contain the shaded point most of the time
    # (hd's regimes put it outside on purpose, to reach the range test; water
    # needs the kernel itself).
    for sl in range(4):
        b = 43 + sl * 26
        if r.random() < 0.75:
            near = r.uniform(0.05, 1.0)
            c1[b + 1] = [f2b(near), f2b(near + 80.0), f2b(1.0), f2b(0.0)]
    return cb


DRIVER = dict(DRIVERS['hd'])
# deriv_scale 6: water's roughness is a fixed 0.1675 before specular AA, and at
# hd's scale of 1 the synthetic derivative moved it so little that AA changed
# the output by under 2e-4 -- dropping AA entirely went unobserved (P11 G7b).
DRIVER.update(inputs_fn=water_inputs, cbufs_fn=water_cbufs, texture=WaterTextures(),
              structured=lambda seed: WaterStructured(seed), sysvals_fn=lambda s: {},
              deriv_scale=6.0)

_BITS = (("SC2", 1), ("DP", 2), ("DBG", 4), ("PTS", 8), ("SC", 16))


def feat(idx):
    f = [name for name, bit in _BITS if idx & bit]
    ssr = (idx >> 5) & 3
    if ssr:
        f.append(f"SSR{(0, 16, 32, 64)[ssr]}")
    return "+".join(f) if f else "base"


def body_hash(asm_path):
    """Declarations + instruction stream; a sweep dedup, never a fold count."""
    h = hashlib.sha1()
    for line in Path(asm_path).read_text('utf-8', errors='replace').splitlines():
        s = line.strip()
        if s and not s.startswith('//'):
            h.update(s.encode('utf-8') + b'\n')
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--rel-scale', type=float, default=1.0)
    ap.add_argument('--perms', default=None)
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail, slang = Path(args.retail_dir), Path(args.slang_dir)
    t0 = time.time()
    worst_all, diverging, dm_total, seen = 0.0, [], 0, {}
    for idx in perms:
        retail_asm = perm_path(retail, idx, "asm")
        slang_dxbc = perm_path(slang, idx, "dxbc")
        prog_r = load(retail_asm)
        prog_s = load(slang_dxbc, decompiler=args.decompiler)
        key = (body_hash(retail_asm), body_hash(slang_dxbc.with_suffix('.asm')))
        if key in seen:
            first, failure = seen[key]
            if failure is not None:
                diverging.append((idx,) + failure)
                print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: same program as perm_{first:03d}")
            continue
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, rel_scale=args.rel_scale, **DRIVER)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            seen[key] = (idx, (res.worst, res.discard_mismatches))
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} (seed {res.worst_seed})")
        else:
            seen[key] = (idx, None)

    print(f"\n=== water_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"distinct classes : {len(seen)}")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print(f"elapsed          : {time.time() - t0:.1f}s")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
