"""Differential test of the slang ``popcorn_ps`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** PopcornFX particle pixel shader: 288
permutations, indexed ``idx = inner | 32*outer`` with ``outer = mode*3 + uv`` ::

    inner bit 0 GBUFFER   1 SOFT_PARTICLES   2 ALPHA_LUT
              3 VERTEX_COLOR                 4 LIT
    uv        0 NoUV      1 COLOR pass       2 MOTION pass
    mode      0 Basic     1 Billboard        2 Atlas

The engine folds whole axes away per pass, so the 288 slots hold far fewer
distinct programs. Measured over the shipped blobs (body hash of the retail
disassembly, comments stripped):

    uv 0 (NoUV)    96 slots ->  16 classes   (mode and ALPHA_LUT are dead)
    uv 1 (COLOR)   96 slots ->  96 classes   (nothing folds)
    uv 2 (MOTION)  96 slots ->  32 classes   (GBUFFER dead; ALPHA_LUT dead
                                              in modes Basic/Billboard, live
                                              only in Atlas)
                  ---                 ---
                  288                 144

Every slot is still checked -- a candidate that folds differently from retail
is exactly the bug worth catching -- but two slots that pose an *identical*
comparison on BOTH legs are interpreted once.

**144 is not the fold count, and must never be quoted as one.** The engine ships
**160** distinct blobs; 144 is how many distinct INSTRUCTION STREAMS those 160
hold. The gap is entirely the motion pass, where ALPHA_LUT and LIT change only
the input signature: ``perm_064`` is 1104 bytes and ``perm_068`` is 1128, one
extra ISGN entry and not one instruction different. The body hash below drops
every ``//`` line, and the signature lives there -- which is the right thing for
this module, because the comparison aligns inputs by semantic and those two
slots therefore do pose the same comparison. It is the wrong number for the fold
gate, which hashes blob bytes: see ``tools/wc3_perm_partition.py`` (G1) and the
G4 check, both of which say 160.

**The drivers are hd_ps's**, because 3.0.0 unified the particle pipeline onto
the same clustered-forward banks as the HD mesh shader: ``t16`` light array
(stride 40), ``t17`` packed 16-bit light-index list, ``t18`` cluster grid,
``b1`` rows 40/41/42 for the tile lookup, and the same ``b2`` per-draw layout
for fog / IBL / main light. ``HdStructured`` and ``hd_cbufs`` therefore drive
popcorn's discriminants unchanged. Two things they do NOT shape, and this
module adds:

  * ``cb2[16..19].xyw`` -- the view->clip projection. Both passes divide by
    ``clip.w`` and sample the scene depth at the resulting UV; fed plain noise
    the quotient is unbounded, and a large coordinate turns the texture
    stand-in's ``sin()`` field chaotic, so a few ulps of scheduling difference
    between the two legs explodes into a phantom divergence. See
    :func:`_proj_rows`.
  * ``cb2[21]`` -- the depth-buffer UV scale/bias, kept near (1,1,0,0).

and one texture tweak, :class:`PopcornTextures`, documented on the class: the
scene depth lives at ``t4`` here (hd's is ``t7``), and it is compared against a
*view depth*, not against zero.

Outputs compared: SV_TARGET0, plus the two deferred targets on GBUFFER perms.

Run from the repo root::

    python tools/shader_diff_popcorn.py                  # full sweep
    python tools/shader_diff_popcorn.py --perms 48,176   # specific perms
    python tools/shader_diff_popcorn.py --trials 64

State at the time this driver was written: all 288 slots MATCH (144 distinct
classes, worst 3.2e-07, no discard mismatches, 70s).

MEASURED TRIAL CURVE
--------------------
Retail against retail: two SHIPPED permutations that differ in exactly one
axis, so whatever divergence shows up IS that axis and nothing else. A trial
count at which a row reads 0.0 is a trial count at which that axis is
invisible, and a sweep there would report it green without ever executing it.
Scored the way the sweep scores (rel_scale 1.0, outputs 0/1/2):

    trials                    8        16        32        64       128       256
    LIT       032/048   9.5e-01   9.9e-01   9.9e-01   1.2e+00   1.2e+00   1.2e+00
    SOFT      032/034   8.8e-01   9.0e-01   9.0e-01   9.0e-01   9.0e-01   9.0e-01
    ALPHA_LUT 032/036   5.9e-01   6.0e-01   6.2e-01   6.2e-01   6.2e-01   6.2e-01
    VERTEXCOL 032/040   7.6e-01   7.6e-01   8.5e-01   8.5e-01   8.5e-01   8.5e-01
    GBUFFER   032/033   1.0e+00   1.0e+00   1.0e+00   1.0e+00   1.0e+00   1.0e+00
    MOTION SP 064/066   7.7e-01   1.4e+00   1.4e+00   1.4e+00   1.5e+00   1.5e+00

Unlike hd_ps, no axis of this family hides below a trial count: every one
clears the 1e-3 tolerance by nearly three orders of magnitude at 8 trials.
Nothing here argues for 128 on its own.

The default is 128 anyway, for what the table cannot show. Those rows are
per-AXIS probes -- one feature bit against its sibling -- and the things that
need many seeds here are the discriminants *inside* a single program, each
redrawn once per trial:

    cb2[0].y    blend mode      11 cases
    cb2[27].z   fog mode         7 cases (4 is a whole second, volumetric
                                 implementation, so hd_cbufs weights it 3x)
    cb2[25].xy  IBL probe bound / not bound
    t18         cluster light count 0..3, then a 1/255 radiance cull per light
    clip.w      1 trial in 6 degenerate (see :func:`_proj_rows`)

128 draws is roughly 12 visits to each fog mode and each blend case. At 32 a
given perm would miss several of them outright, and the sweep would be
reporting on code it never ran. The cost is linear and the whole 288-slot
sweep folds to 144 interpreted classes, so 128 is affordable.

Coverage this driver deliberately buys, with the numbers (4000 draws):

  * view->clip projection: ndc.x inside [-1,1] 67% of trials, ndc.y 67%,
    |clip.w| < 0.1 on 16% -- i.e. the depth UV is usually a plausible screen
    coordinate and occasionally a degenerate one, rather than always noise.
  * MOTION pass: it ``discard``s wherever ``sceneDepth < viewZ`` and then
    computes ``sqrt(1000 / viewZ)``, which is NaN for the behind-the-eye view
    depths :func:`_depth` deliberately produces -- and NaN on both legs scores
    as agreement (see :func:`shader_diff.output_diff`). The two conditions are
    very nearly complementary, so the pass is only observable on the trials
    that satisfy both. With hd's texture model verbatim that is 9 trials in
    256 (3.5%); with :class:`PopcornTextures` it is 92 in 256 (36%). At the
    default trial count that is the difference between 4 samples of the motion
    math and 46.

Caveats, stated rather than hidden:

  * ``cb2[26].w`` (specular AA) is driven by ``hd_cbufs`` and consumed through
    ``deriv_rtx_coarse``; the interpreter's derivative is synthetic, so the
    toggle is exercised but only approximately matched. That, and the IBL
    reprojections accumulating their dot products in a different order than
    fxc scheduled them, is why the tolerance is 1e-3 rather than 0.
  * The soft-particle fade ``saturate((sceneDepth - viewZ) * cb2[22].x)``
    lands strictly *inside* its saturate on about 4% of trials; the rest pin
    at 0 or 1. Widening the depth texture's range trades that against the
    MOTION coverage above and does not improve it (measured across six
    ranges: 3.6%-5.5%). Leaving hd's own texture model in place would raise it
    to 12% at the cost of collapsing MOTION to 3.5%, which is the worse trade.
    ~5 interior samples per perm per sweep is thin but not blind.
"""

import argparse
import hashlib
import math
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b                                        # noqa: E402
from shader_diff import load, compare, perm_path                   # noqa: E402
from wc3_uber_validate import (DRIVERS, HdStructured, HdTextures,   # noqa: E402
                               hd_cbufs, _depth, _unit)

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "popcornfx"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "popcorn_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 288

#: SV_TARGET0 always; 1 and 2 exist only on the GBUFFER perms and read as zero
#: on both legs elsewhere, so comparing all three unconditionally is safe.
OUTPUT_REGS = (0, 1, 2)

#: Probability that a trial gets a near-zero / wrong-signed ``clip.w``.
_DEGENERATE_W = 1.0 / 6.0


# ==========================================================================
# textures
# ==========================================================================

class PopcornTextures(HdTextures):
    """hd's texture stand-in, with the scene depth moved to ``t4``.

    3.0.0 gave the particle shader the same resource banks as the HD mesh
    shader for everything it shares -- ``t0`` diffuse, ``t2`` normal, ``t3``
    smooth/metal, ``t11``/``t12`` IBL cube arrays, ``t13`` BRDF LUT -- but the
    scene depth it reads for soft particles and for the motion pass is ``t4``,
    not hd's ``t7``. Two consequences:

    * hd's straddle-zero remap keys on slot 7 and so never fires here. That is
      harmless: popcorn does not test the depth against zero.
    * popcorn compares the texel against a *view depth*, not against zero:
      ``saturate((depth - viewZ) * cb2[22].x)`` for soft particles, and
      ``discard(depth < viewZ)`` in the motion pass. The base model returns
      [0.1, 0.9] while :func:`_depth` feeds view depths of 0.5..60 (plus a
      behind-the-eye and a 40000+ regime), so with it ``depth - viewZ`` is
      negative on 70% of trials -- and on most of the rest viewZ was negative,
      which sends the motion pass's ``sqrt(1000 / viewZ)`` to NaN on BOTH legs,
      where :func:`shader_diff.output_diff` scores it as agreement. Measured:
      the motion pass produces a finite, non-discarded, actually-compared
      output on 9 trials in 256 with hd's model and 92 in 256 with this one.
      Four samples per perm was not enough to gate a pass on.

    Putting the texel in the same units as the view depth is what makes the
    discard go both ways. It does NOT help the soft-particle fade, which lands
    inside its saturate about as rarely either way (4% here, 12% with hd's
    model); see the module docstring for that trade.
    """

    #: View-depth range the scene-depth texel is spread over. The low end is
    #: behind the eye and the high end is past the far end of the ordinary
    #: :func:`_depth` band, so the comparison against viewZ resolves both ways.
    #: Chosen by measuring six ranges against the two things it trades off --
    #: motion-pass observability and soft-fade interior hits -- not guessed.
    DEPTH_RANGE = (-3.0, 60.0)

    def sample(self, slot, coords):
        out = super().sample(slot, coords)
        if slot == 4:
            lo, hi = self.DEPTH_RANGE
            # The base field is 0.5 + 0.4*sin(...), i.e. [0.1, 0.9]; renormalise
            # to [0,1] before stretching so the whole range is reachable.
            return [lo + (hi - lo) * min(1.0, max(0.0, (v - 0.1) / 0.8))
                    for v in out]
        return out


# ==========================================================================
# varyings
# ==========================================================================

def _view(seed):
    """The view-space position fed as TEXCOORD7, on its own RNG stream.

    Both :func:`popcorn_inputs` and :func:`popcorn_cbufs` need it: the inputs
    hand it to the shader, and the projection rows are solved against it (see
    :func:`_proj_rows`). Keyed by seed alone so the two agree no matter what
    order the rest of either generator draws in.
    """
    r = random.Random(f"popcorn:view:{seed}")
    return (r.uniform(-20, 20), r.uniform(-20, 20), _depth(r))


def popcorn_inputs(seed):
    """Per-semantic varyings for the 3.0.0 PopcornFX PS.

    All 288 perms declare TEXCOORD7 (view position) and TEXCOORD8 (world
    position); the rest come and go with the feature mask, and retail PACKS
    some of them -- the Atlas perms put TEXCOORD1.x and TEXCOORD7.yzw in one
    register, so the view depth is read from ``v2.w`` there and ``v2.z``
    elsewhere. :func:`shader_diff.map_inputs` places each semantic's
    components at its own masked channels, so nothing here has to know that.
    """
    r = random.Random(9200 + seed)
    n = _unit(r)
    t = _unit(r)
    vx, vy, vz = _view(seed)
    return {
        # Really used: the LIT colour perms take the cluster tile index from
        # this against cb1[42]'s viewport rect, which hd_cbufs sets to
        # (0, 0, 1920, 1080). Noise here would put every pixel in tile 0.
        ("SV_POSITION", 0): [f2b(r.uniform(0, 1920)), f2b(r.uniform(0, 1080)),
                             f2b(r.uniform(0, 1)), f2b(1.0)],
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],
        # uv: float2 in Basic/Billboard, float4 (two sets) in Atlas.
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],
        # slot1: float4 in Billboard, the Atlas blend factor in .x.
        ("TEXCOORD", 1): [f2b(r.uniform(-2, 2)) for _ in range(4)],
        ("TEXCOORD", 2): [f2b(r.uniform(-2, 2)) for _ in range(4)],   # uvAxis
        # alpha-LUT random stream, a scalar the shader reads from whichever
        # channel it was packed into -- fill all four.
        ("TEXCOORD", 3): [f2b(r.uniform(0, 1))] * 4,
        ("TEXCOORD", 4): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],  # normal (view)
        ("TEXCOORD", 5): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                          f2b(r.choice([-1.0, 1.0]))],                # tangent (view)
        # View position. .z is the depth the fog, the soft-particle fade and
        # the motion pass's depth test all key off, so it uses the same
        # three-regime draw hd_ps does: mostly ordinary, sometimes behind the
        # eye, sometimes past the 32768 that switches volumetric fog to sky.
        ("TEXCOORD", 7): [f2b(vx), f2b(vy), f2b(vz), f2b(1.0)],
        # World position, in the band hd_cbufs builds the volumetric fog
        # centre (cb2[20].xyz) and height band (cb2[2].zw) for.
        ("TEXCOORD", 8): [f2b(r.uniform(-20, 20)), f2b(r.uniform(-20, 20)),
                          f2b(r.uniform(-5, 15)), f2b(1.0)],
    }


def popcorn_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# ==========================================================================
# constant buffers
# ==========================================================================

def _proj_rows(rng, view):
    """``cb2[16..19]`` -- the view->clip projection, as four 4-lane rows.

    Only ``.xyw`` of each row is read, so the transform is three dot products::

        clip.x = dot(view, (cb[16].x, cb[17].x, cb[18].x)) + cb[19].x
        clip.y = dot(view, (cb[16].y, cb[17].y, cb[18].y)) + cb[19].y
        clip.w = dot(view, (cb[16].w, cb[17].w, cb[18].w)) + cb[19].w

    and the shader then forms ``ndc = clip.xy / clip.w``, maps it to [0,1] with
    a flipped y, and scales/biases by ``cb2[21]`` to sample the scene depth.

    Left as noise, ``clip.w`` is a small number of random sign and the quotient
    runs to hundreds; the texture stand-in is a ``sin()`` field, so at a
    coordinate of that size a few ulps of difference in how the two legs
    schedule the dot product become a completely different texel. That is a
    phantom divergence, not a shader bug, and it would swamp the real ones.

    So the rows are **solved backwards** from a target NDC: pick where the
    sample should land, then pick the row entries that put it there. The shape
    stays a perspective matrix -- ``clip.w`` comes from the view z, each of
    ``clip.x``/``clip.y`` is dominated by its own focal term and the two
    off-axis focal entries are zero, exactly as in a real projection -- but the
    z-skew and translation entries are deliberately left non-zero, so a
    candidate that grabs the wrong row or the wrong lane for those still shows
    up. Each of the three terms summed into an axis is kept proportional to the
    target, which is what keeps the sum free of catastrophic cancellation --
    the failure mode a literal "small w = big bias" construction walks straight
    into when the view depth is in the 40000+ regime.

    Measured over 4000 draws: ``|ndc.x| <= 1`` on 67% of trials, same for y,
    and ``|clip.w| < 0.1`` on 16%.

    One trial in :data:`_DEGENERATE_W` gets a tiny and possibly negative
    ``clip.w`` together with a target NDC well outside the frustum, which is
    what exercises the divide-by-w case. It is never exactly zero.
    """
    vx, vy, vz = view

    if rng.random() < _DEGENERATE_W:
        w = rng.choice((-1.0, 1.0)) * rng.uniform(2e-3, 8e-2)
        lim = 6.0
    else:
        # A real perspective: clip.w tracks the view depth, including its sign.
        w = (vz if abs(vz) > 0.75 else math.copysign(0.75, vz or 1.0))
        w *= rng.uniform(0.85, 1.2)
        lim = 1.3            # ~77% of draws inside the frustum

    # clip.w = vz*aw + bw, both terms O(|w|).
    kb = rng.uniform(-0.2, 0.2)
    if abs(vz) > 0.5:
        aw, bw = (1.0 - kb) * w / vz, kb * w
    else:
        aw, bw = 0.0, w

    rows = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(4)]
    for k, val in ((0, 0.0), (1, 0.0), (2, aw), (3, bw)):
        rows[k][3] = f2b(val)             # .w lanes

    for lane, vc in ((0, vx), (1, vy)):   # clip.x from .x lanes, clip.y from .y
        ndc = rng.uniform(-lim, lim)
        kz = rng.uniform(-0.2, 0.2)       # view-z skew, as a fraction of w
        kt = rng.uniform(-0.2, 0.2)       # translation, as a fraction of w
        if abs(vz) <= 0.5:
            kz = 0.0
        focal = (ndc - kz - kt) * w / (vc if abs(vc) > 1e-3 else 1e-3)
        rows[0][lane] = f2b(focal if lane == 0 else 0.0)
        rows[1][lane] = f2b(0.0 if lane == 0 else focal)
        rows[2][lane] = f2b(kz * w / vz if abs(vz) > 0.5 else 0.0)
        rows[3][lane] = f2b(kt * w)
    return rows


def popcorn_cbufs(seed):
    """``hd_cbufs`` plus the two row groups it leaves as noise.

    Everything popcorn reads out of ``b1`` (rows 40/41/42, the cluster tile
    lookup) and almost everything it reads out of ``b2`` -- the eleven-case
    blend switch at ``cb2[0].y``, the fog block at ``cb2[1..3]``, the
    view->probe rotation at ``cb2[8..10]``, the volumetric fog centre at
    ``cb2[20].xyz``, the IBL mip ends at ``cb2[25].xy`` (the probe counts as
    bound iff their product is non-zero), the specular-AA bit at ``cb2[26].w``,
    the main-light gate and fog mode at ``cb2[27].yz``, the ambient and light
    direction at ``cb2[28..30]`` -- is already driven correctly by the HD mesh
    shader's generator, because 3.0.0 gave the two families the same buffer.

    What hd never touches, because its own shader does not read them there:

      * ``cb2[16..19]`` the view->clip projection  (see :func:`_proj_rows`)
      * ``cb2[21]``     the depth-buffer UV scale (.xy) and bias (.zw)
    """
    cbufs = hd_cbufs(seed)
    cb2 = cbufs[2]
    rng = random.Random(f"popcorn:cb:{seed}")

    for i, row in enumerate(_proj_rows(rng, _view(seed))):
        cb2[16 + i] = row
    cb2[21] = [f2b(rng.uniform(0.9, 1.1)), f2b(rng.uniform(0.9, 1.1)),
               f2b(rng.uniform(-0.05, 0.05)), f2b(rng.uniform(-0.05, 0.05))]
    return cbufs


#: Same structured-buffer and derivative model as hd_ps -- popcorn's t16/t17/t18
#: are the identical clustered-light banks, down to the stride-40 light record
#: and the 1/255 radiance cull -- with popcorn's own varyings, constant buffers
#: and scene-depth texture.
DRIVER = dict(DRIVERS['hd'],
              inputs_fn=popcorn_inputs,
              cbufs_fn=popcorn_cbufs,
              sysvals_fn=popcorn_sysvals,
              structured=lambda seed: HdStructured(seed),
              texture=PopcornTextures())


# ==========================================================================
# perm labels
# ==========================================================================

_BITS = (("GBUF", 1), ("SOFT", 2), ("ALUT", 4), ("VC", 8), ("LIT", 16))
_UV = ("NoUV", "Color", "Motion")
_MODE = ("Basic", "BB", "Atlas")


def feat(idx):
    """Human-readable label for a permutation index."""
    inner = idx & 31
    outer = idx >> 5
    f = [name for name, bit in _BITS if inner & bit]
    f.append(f"{_UV[outer % 3]}-{_MODE[outer // 3]}")
    return "+".join(f)


def body_hash(asm_path):
    """Hash of a disassembly's behavioural content.

    Comment lines carry the disassembler's timestamp and the reflection dump
    (which the retail blobs do not have at all), so they are dropped; what is
    left is the declarations plus the instruction stream.
    """
    h = hashlib.sha1()
    for line in Path(asm_path).read_text('utf-8', errors='replace').splitlines():
        s = line.strip()
        if s and not s.startswith('//'):
            h.update(s.encode('utf-8'))
            h.update(b'\n')
    return h.hexdigest()


# ==========================================================================
# driver
# ==========================================================================

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # See the MEASURED TRIAL CURVE in the module docstring. Every feature axis
    # is visible at 8 trials; 128 is for the discriminants *inside* a program
    # (11 blend cases, 7 fog modes, the IBL bound test, the 0..3 cluster light
    # count), each of which is drawn once per trial.
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    # The score is RELATIVE above magnitude 1 (see shader_diff.output_diff).
    # Particle colour is pre-multiplied by a light sum, so a LIT perm can sit
    # well above 1 where its unlit sibling sits near 0.2; scoring absolutely
    # would test the bright one far more strictly than the dim one for no
    # reason. Set to 0 to score absolutely.
    ap.add_argument('--rel-scale', type=float, default=1.0,
                    help='magnitude floor for the diff score (0 = absolute)')
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 288)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir)
    slang = Path(args.slang_dir)

    t0 = time.time()
    worst_all = 0.0
    diverging = []
    dm_total = 0
    seen = {}

    for n, idx in enumerate(perms):
        retail_asm = perm_path(retail, idx, "asm")
        slang_dxbc = perm_path(slang, idx, "dxbc")
        prog_r = load(retail_asm)
        prog_s = load(slang_dxbc, decompiler=args.decompiler)

        # Two slots that share BOTH hashes pose the same comparison, so the
        # second is not a sample of the first -- it IS the first.
        key = (body_hash(retail_asm), body_hash(slang_dxbc.with_suffix('.asm')))
        if key in seen:
            first, failure = seen[key]
            if failure is not None:
                diverging.append((idx, failure[0], failure[1]))
                print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: same program as "
                      f"perm_{first:03d}")
            continue

        res = compare(prog_s, prog_r, trials=args.trials,
                      output_regs=OUTPUT_REGS, tol=args.tol,
                      rel_scale=args.rel_scale, **DRIVER)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            seen[key] = (idx, (res.worst, res.discard_mismatches))
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} "
                  f"(seed {res.worst_seed})")
        else:
            seen[key] = (idx, None)

        if n and n % 32 == 0:
            print(f"  ...perm {idx} ({len(seen)} classes, "
                  f"worst {worst_all:.1e}, {time.time() - t0:.0f}s)",
                  file=sys.stderr)

    print(f"\n=== popcorn_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
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
