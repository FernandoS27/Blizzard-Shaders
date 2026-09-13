"""Validate a reconstructed Warcraft-III uber-shader against retail permutations.

Same contract as :mod:`wow_uber_validate` -- a family folder holding
``uber.hlsl`` + ``uber_manifest.json`` next to the retail
``perm_NNNN.dxbc``/``.asm`` -- but with the *driven* constant buffers, inputs
and structured buffers that the 3.0.0 Wc3 shaders need.

Why a separate tool: the 3.0.0 ``hd`` pixel shader is a clustered-forward
renderer. Its loop bounds come out of a constant buffer (cascade count, shadow
light count) and out of a structured cluster/light-index buffer, so the generic
"random floats everywhere" harness either runs a loop ``asuint(0.37)`` times --
which trips dxbc_interp's iteration cap -- or never enters the light loop at
all and silently validates nothing. The drivers below put sane integers in the
discriminant slots so every branch is reachable, and hand both the candidate
and the retail shader the *same* values.

    python tools/wc3_uber_validate.py wc3_re_shaders/hd
    python tools/wc3_uber_validate.py wc3_re_shaders/hd --slots all --trials 48

Exit code is 0 only when every checked slot passes.
"""

import argparse
import json
import math
import random
import subprocess
import sys
import tempfile
import traceback
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dxbc_interp import Program, TextureModel, f2b, i2b            # noqa: E402
from shader_diff import compare                                    # noqa: E402

DECOMPILER = r'C:\Tools\3Dmigoto\cmd_Decompiler\cmd_Decompiler.exe'
DEFAULT_TOL = 1e-3


# ==========================================================================
# hd driver -- Wc3 3.0.0 HD mesh pixel shader
# ==========================================================================

class HdTextures(TextureModel):
    """Texture stand-in with the two properties the HD shader's branches need.

    * t7 is the scene depth buffer and the shader treats a non-positive texel
      as "nothing drawn here". The base model never returns one, so the guard
      would be dead code and a candidate could drop it unnoticed.
    * The base ``sample_compare`` throws the array slice away, which makes every
      cascade / cube face read the same texel -- a wrong slice or a wrong face
      index then looks identical. This one keys on the whole coordinate.
    """

    @staticmethod
    def _safe(v):
        # A degenerate projection (w == 0) can hand us inf; sin(inf) raises.
        return v if -1e30 < v < 1e30 else 0.0

    def sample(self, slot, coords):
        out = super().sample(slot, [self._safe(c) for c in coords])
        if slot == 7:
            # Straddle zero so the "is there anything here" test is live.
            return [v * 2.2 + -0.9 for v in out]
        return out

    def sample_lod(self, slot, coords, lod):
        # The base model folds the LOD in at 0.01 weight, which is small enough
        # that swapping two mip levels moves the result less than the tolerance.
        # Weight it like a real coordinate so a wrong mip is visible.
        return self.sample(slot, [coords[0], coords[1], coords[2],
                                  self._safe(coords[3]) + self._safe(lod) * 0.37])

    def sample_compare(self, slot, coords, ref):
        v = math.sin(self._safe(ref) * 1.7 + slot * 0.53)
        for j, co in enumerate(coords):
            v += math.sin(self._safe(co) * (0.37 + 0.09 * j) + slot * 0.31 + j)
        return 0.5 + 0.5 * math.sin(v)


def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]


def _depth(r):
    """View depth: mostly ordinary, sometimes behind the eye, sometimes far."""
    x = r.random()
    if x < 0.30:
        return r.uniform(-6.0, 0.5)
    if x < 0.55:
        return r.uniform(40000.0, 90000.0)
    return r.uniform(0.5, 60.0)


def hd_inputs(seed):
    """Per-semantic varyings for the HD mesh PS.

    TEXCOORD10 is the *world* position (shadow-cascade projection, volumetric
    fog and the debug stripe all read it), TEXCOORD11 the blight-map UV.
    TEXCOORD1.w is the clip-distance the shader discards on, so it straddles
    zero deliberately: a candidate that drops the discard must be caught.
    """
    r = random.Random(9100 + seed)
    n = _unit(r)
    t = _unit(r)
    return {
        ("SV_POSITION", 0): [f2b(r.uniform(0, 1920)), f2b(r.uniform(0, 1080)),
                             f2b(r.uniform(0, 1)), f2b(1.0)],
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],
        # viewPos.xyz, .z doubles as fog depth; .w is the clip distance.
        # .z straddles zero (the manual depth test's "is anything here" guard
        # is unreachable while z stays positive) and occasionally exceeds the
        # 32768 the volumetric fog switches on.
        ("TEXCOORD", 1): [f2b(r.uniform(-20, 20)), f2b(r.uniform(-20, 20)),
                          f2b(_depth(r)), f2b(r.uniform(-0.3, 2.0))],
        ("TEXCOORD", 2): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],
        ("TEXCOORD", 3): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                          f2b(r.choice([-1.0, 1.0]))],
        # worldPos (homogeneous: .w == 1 so the cascade matrices behave).
        # The span matters: the light debug overlay stripes world space with a
        # ~15-unit period, so a range narrower than that leaves the striped
        # branch reachable only in a sliver. The cascade matrices below are
        # scaled to suit this range.
        ("TEXCOORD", 10): [f2b(r.uniform(-20, 20)), f2b(r.uniform(-20, 20)),
                           f2b(r.uniform(-5, 15)), f2b(1.0)],
        ("TEXCOORD", 11): [f2b(r.uniform(-2, 2)) for _ in range(4)],
    }


#: cluster grid used by the driver (cb1[41].yz) -- 16x16 tiles.
_GRID = 16
#: light-list / light-array base offsets (cb1[40].zw, cb1[41].x) are kept at 0.
_MAX_LIGHTS = 8


def hd_cbufs(seed):
    """cb1 (clustered lighting + shadows) and cb2 (per-draw), discriminants driven.

    Driven slots:
      cb1[36].x  cascade count          uint loop bound
      cb1[36].y  shadow-light count     uint range check on light.shadowIndex
      cb1[39].w  light debug mode       uint (>=1 and >=2 gates)
      cb1[40].xy inverse cluster dims   float divisor -> tile index
      cb1[40].zw light-index/list bases int
      cb1[41].xyz cluster base, grid    int
      cb1[42]    viewport rect          float
      cb2[0].y   blend mode             switch selector (0..10)
      cb2[3].w   volumetric fog flag    int != 0
      cb2[22].yw cloak / blight toggles float
      cb2[23].w  depth-clip toggle      float (> 0.5)
      cb2[25].xy IBL mip ends           bound iff x*y != 0
      cb2[26].w  specular-AA toggle     raw-bit movc selector
      cb2[27].yz light enable, fog mode raw-bit gate / int (0..6)
    """
    rng = random.Random(seed * 7919 + 31)

    def rows(n, lo=-1.0, hi=1.0):
        return [[f2b(rng.uniform(lo, hi)) for _ in range(4)] for _ in range(n)]

    cb1 = rows(160, -0.35, 0.35)
    cb2 = rows(40)

    # Cascade matrices (sets at cb1[12] and cb1[24], four rows per cascade).
    # Built as scale+bias rather than noise: a random matrix almost never puts
    # the shaded point inside a cascade, so the PCF body would never run.
    for base in (12, 24):
        for c in range(3):
            m = base + c * 4
            sx = rng.uniform(0.02, 0.09)
            sy = rng.uniform(0.02, 0.09)
            sz = rng.uniform(0.02, 0.12)    # wide enough for c.z >= 1 sometimes
            cb1[m + 0] = [f2b(sx), f2b(0.0), f2b(0.0), f2b(0.0)]
            cb1[m + 1] = [f2b(0.0), f2b(sy), f2b(0.0), f2b(0.0)]
            cb1[m + 2] = [f2b(0.0), f2b(0.0), f2b(sz), f2b(0.0)]
            cb1[m + 3] = [f2b(rng.uniform(-0.5, 0.5)), f2b(rng.uniform(-0.5, 0.5)),
                          f2b(rng.uniform(-0.2, 1.1)), f2b(0.0)]

    # --- cb1: clustered-lighting control -----------------------------------
    cb1[36][0] = i2b(rng.randint(0, 3))          # cascade count
    cb1[36][1] = i2b(rng.randint(1, 3))          # shadow-light count
    cb1[36][2] = f2b(0.0)
    cb1[36][3] = f2b(0.0)
    cb1[39][3] = i2b(rng.choice([0, 1, 1, 2, 2, 3]))  # light debug mode
    cb1[40][0] = f2b(1.0 / _GRID)                # inverse cluster dims
    cb1[40][1] = f2b(1.0 / _GRID)
    cb1[40][2] = i2b(0)                          # light-array base
    cb1[40][3] = i2b(0)                          # light-index-list base
    cb1[41][0] = i2b(0)                          # cluster base
    cb1[41][1] = i2b(_GRID)
    cb1[41][2] = i2b(_GRID)
    cb1[42][0] = f2b(0.0)                        # viewport rect (x0,y0,x1,y1)
    cb1[42][1] = f2b(0.0)
    cb1[42][2] = f2b(1920.0)
    cb1[42][3] = f2b(1080.0)
    # cube-shadow records: [+0] world pos, [+1] = (near, far, strength)
    for sl in range(4):
        b = 43 + sl * 26
        cb1[b] = [f2b(rng.uniform(-15, 15)) for _ in range(3)] + [f2b(0.0)]
        # Three regimes, because two different tests key off `near`. A small
        # near keeps the SHELL (near < d < far) the common case, which is what
        # the PCF body needs. But the light positions above and the world
        # positions the driver feeds are both spread over tens of units, so a
        # near plane of a couple of units is never actually in front of the
        # shaded point -- and the `near < cubeDist` half of the range test is
        # then dead code that a candidate can drop unnoticed. The third regime
        # puts the near plane past the typical light-to-pixel distance, which
        # is the only way that half of the test becomes observable.
        x = rng.random()
        if x < 0.45:
            near = rng.uniform(0.05, 2.0)
        elif x < 0.70:
            near = rng.uniform(6.0, 16.0)
        else:
            near = rng.uniform(18.0, 45.0)
        cb1[b + 1] = [f2b(near), f2b(near + rng.uniform(10.0, 30.0)),
                      f2b(rng.uniform(0.35, 1.0)), f2b(0.0)]
        # Six faces x four rows; only .zw is read, as clip z and w. Keep w well
        # away from zero -- z/w must stay finite or the comparison is garbage.
        for face in range(6):
            f = b + 2 + face * 4
            # .xy is never read by the shader, but leaving it zero would make a
            # candidate that reads the wrong pair produce 0/0 = NaN rather than
            # a wrong number -- keep it live so that stays detectable.
            def row(zlo, zhi, wlo, whi):
                return [f2b(rng.uniform(-1, 1)), f2b(rng.uniform(-1, 1)),
                        f2b(rng.uniform(zlo, zhi)), f2b(rng.uniform(wlo, whi))]
            cb1[f + 0] = row(-0.3, 0.3, -0.02, 0.02)
            cb1[f + 1] = row(-0.3, 0.3, -0.02, 0.02)
            cb1[f + 2] = row(-0.3, 0.3, -0.1, 0.1)
            cb1[f + 3] = row(0.2, 1.2, 1.5, 3.0)

    # --- cb2: per-draw ------------------------------------------------------
    cb2[0][0] = f2b(rng.uniform(0.0, 0.9))       # alpha ref
    cb2[0][1] = i2b(rng.randint(0, 10))          # blend mode (switch selector)
    cb2[1][3] = f2b(rng.uniform(1.0, 10.0))      # fog start
    cb2[2][0] = f2b(rng.uniform(12.0, 60.0))     # fog end
    cb2[2][1] = f2b(rng.uniform(0.0, 0.3))       # fog density
    cb2[2][2] = f2b(rng.uniform(2.0, 30.0))      # volumetric height top
    cb2[2][3] = f2b(rng.uniform(-5.0, 2.0))      # volumetric height bottom
    cb2[3][0] = f2b(rng.uniform(1.0, 10.0))      # radial inner
    cb2[3][1] = f2b(rng.uniform(12.0, 60.0))     # radial outer
    cb2[3][2] = f2b(rng.uniform(0.0, 1.0))       # radial strength
    cb2[3][3] = i2b(rng.randint(0, 1))           # volumetric "always" flag
    cb2[20][0] = f2b(rng.uniform(-20, 20))       # fog centre
    cb2[20][1] = f2b(rng.uniform(-20, 20))
    cb2[20][2] = f2b(rng.uniform(-5, 15))
    cb2[22][0] = f2b(rng.uniform(0.0, 1.0))      # alpha multiplier
    cb2[22][1] = f2b(rng.choice([0.0, rng.uniform(0.1, 0.5),
                                 rng.uniform(0.5, 1.0)]))            # cloak
    cb2[22][2] = f2b(rng.uniform(0.0, 1.5))      # fresnel team colour
    # Threshold toggles get values either side of the threshold, not just the
    # two extremes: a candidate that compares against the wrong constant has to
    # see an input between the two constants to be caught.
    cb2[22][3] = f2b(rng.choice([0.0, 1.0, rng.uniform(0.3, 0.7)]))   # blight
    cb2[23][3] = f2b(rng.choice([0.0, 1.0, rng.uniform(0.3, 0.7)]))   # depth clip
    cb2[24] = [f2b(rng.uniform(0, 1.4)) for _ in range(3)] + [f2b(rng.uniform(0, 1))]
    ibl = rng.random() < 0.7
    cb2[25][0] = f2b(rng.uniform(1.0, 8.0) if ibl else 0.0)
    cb2[25][1] = f2b(rng.uniform(1.0, 8.0) if ibl else 0.0)
    cb2[25][2] = f2b(rng.uniform(0, 1))
    cb2[26][1] = f2b(rng.uniform(0, 2))          # emissive gain
    cb2[26][2] = f2b(rng.uniform(0, 0.05))       # shadow depth bias
    cb2[26][3] = f2b(rng.choice([0.0, 1.0]))     # specular AA toggle
    cb2[27][0] = f2b(rng.uniform(0.2, 2.0))      # normal strength
    cb2[27][1] = f2b(rng.choice([0.0, 1.0, 1.0]))  # main light enable
    # mode 4 (volumetric) is a whole second fog implementation, so give it
    # more weight than a uniform draw over the seven modes would.
    cb2[27][2] = i2b(rng.choice([0, 1, 2, 3, 4, 4, 4, 5, 6]))   # fog mode
    cb2[27][3] = f2b(0.0)
    cb2[28] = [f2b(rng.uniform(0, 0.3)) for _ in range(3)] + [f2b(rng.uniform(0, 2))]
    cb2[29] = [f2b(rng.uniform(0, 1.2)) for _ in range(3)] + [f2b(0.0)]
    d = _unit(rng)
    cb2[30] = [f2b(d[0]), f2b(d[1]), f2b(d[2]), f2b(0.0)]
    return {1: cb1, 2: cb2}


class HdStructured:
    """Cluster grid (t18), light-index list (t17) and light array (t16).

    A pure function of (slot, element, byte offset) as the interpreter
    requires, but shaped like real data: small light counts, in-range light
    indices, and radiance magnitudes that straddle the 1/255 sentinels the
    debug path keys off.
    """

    def __init__(self, seed):
        self.seed = seed

    def _rng(self, *key):
        return random.Random(f"{self.seed}:{':'.join(str(k) for k in key)}")

    def load(self, slot, index, byte_offset):
        if slot == 18:                       # cluster record: count | offset<<10
            r = self._rng(18, index)
            count = r.choice([0, 1, 1, 2, 3])
            offset = r.randrange(0, 24)
            v = (offset << 10) | count
            return [v, v, v, v]
        if slot == 17:                       # two packed 16-bit light indices
            r = self._rng(17, index)
            lo = r.randrange(0, _MAX_LIGHTS)
            hi = r.randrange(0, _MAX_LIGHTS)
            v = (hi << 16) | lo
            return [v, v, v, v]
        if slot == 16:                       # light record, stride 40
            r = self._rng(16, index)
            shadow = r.choice([-1, -2, -2, 0, 0, 1, 1, 2])
            pos = [r.uniform(-12, 12), r.uniform(-12, 12), r.uniform(-5, 45)]
            if r.random() < 0.5:
                # Ordinary light. The attenuation has to stay gentle: the
                # shader culls anything whose radiance falls under 1/255, and
                # a realistic inverse-square falloff over these distances puts
                # every light under that -- the loop body would never run.
                quad = r.uniform(0.0, 0.004)
                lin = r.uniform(0.0, 0.03)
                expc = r.uniform(0.0, 0.0004)
                colour = [r.uniform(0.2, 2.0) for _ in range(3)]
            else:
                # Debug gizmo. With the attenuation neutralised the radiance
                # magnitude IS |colour|, so it can be aimed at the 1/255-step
                # sentinel brackets the debug overlay keys off.
                quad = lin = expc = 0.0
                mag = r.choice([0.0020, 0.0042, 0.0042, 0.0050,
                                0.0065, 0.0065, 0.0090, 0.5])
                d = [r.uniform(-1, 1) for _ in range(3)]
                n = math.sqrt(sum(c * c for c in d)) or 1.0
                colour = [abs(c) / n * mag for c in d]
            words = [f2b(colour[0]), f2b(colour[1]), f2b(colour[2]), i2b(shadow),
                     f2b(pos[0]), f2b(pos[1]), f2b(pos[2]), f2b(quad),
                     f2b(lin), f2b(expc)]
            out = []
            for k in range(4):
                w = byte_offset // 4 + k
                out.append(words[w] if 0 <= w < len(words) else 0)
            return out
        r = self._rng(slot, index, byte_offset)
        return [f2b(r.uniform(-1, 1)) for _ in range(4)]


def hd_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# ==========================================================================
# hd_vs driver -- Wc3 3.0.0 HD mesh vertex shader
# ==========================================================================
#
# A vertex shader has no textures and no loops, so the failure mode that made
# the pixel-shader driver hard (data-driven loop bounds) does not exist here.
# What does exist is a handful of branches that random floats never reach:
#
#   * ``dot(weights, 1) != 0`` -- the unskinned fall-through. Four random floats
#     never sum to exactly zero, so the else-branch is dead without help.
#   * two ``length(v) > 0`` guards -- only a *zero* normal or tangent attribute
#     takes the fallback arm; a random one never does.
#   * ``abs(n.z) < 0.999`` -- picks the reference axis for the generated tangent
#     frame. ``n`` is a normalised transformed normal, so a random basis puts
#     it past 0.999 about one trial in five hundred.
#   * ``saturate()`` on the blight UV -- if the rect is random relative to the
#     world position, every sample clamps to 0 or 1 and the transform inside it
#     is invisible.
#
# Bone indices additionally have to stay in range: the palette is a 256-bone
# constant buffer, and dxbc_interp raises on an out-of-bounds constant read
# rather than quietly returning zero.

#: Bones in the constant-buffer palette. cb3 holds 256 x 3 rows.
_VS_BONES = 256


class HdVsBones:
    """Bone palette for the ``t16`` structured buffer (stride 48, three rows).

    A pure function of (element, byte offset) like every structured stand-in,
    so both shaders in a comparison read the same matrix.
    """

    def __init__(self, seed):
        self.seed = seed

    def load(self, slot, index, byte_offset):
        r = random.Random(f"{self.seed}:{slot}:{index}:{byte_offset}")
        # Rows are affine 3x4: three basis components and a translation.
        return [f2b(r.uniform(-1.2, 1.2)) for _ in range(3)] + \
               [f2b(r.uniform(-4.0, 4.0))]


def hd_vs_inputs(seed):
    """Vertex attributes, with the degenerate cases the guards need.

    ATTR5/ATTR6 are the bone indices (uint) and weights; the weights are
    sometimes all-zero and sometimes merely *sum* to zero, because that is the
    condition the shader actually tests. ATTR1/ATTR7 are sometimes the zero
    vector so the two ``length > 0`` fallbacks are reachable.
    """
    r = random.Random(90210 + seed)

    def vec3(zero_p):
        x = r.random()
        if x < zero_p:
            return [0.0, 0.0, 0.0]
        v = _unit(r)
        if x < zero_p + 0.12:
            # Nonzero but far shorter than one. The shader normalises whatever
            # it gets, so this is indistinguishable from a unit vector
            # *except* at the `length > 0` guard -- which is the only way to
            # tell that guard apart from a `length > epsilon` one.
            v = [c * math.exp(r.uniform(math.log(1e-5), math.log(1e-2)))
                 for c in v]
        return v

    w = r.random()
    if w < 0.18:
        weights = [0.0, 0.0, 0.0, 0.0]          # unskinned vertex
    elif w < 0.26:
        a = r.uniform(0.2, 1.0)                  # sums to zero without being zero
        weights = [a, -a, 0.0, 0.0]
        r.shuffle(weights)
    elif w < 0.40:
        # Negative weights, so the sum is sometimes below zero: that is the only
        # thing separating the shader's `!= 0` test from a `> 0` one.
        weights = [r.uniform(-1.0, 1.0) for _ in range(4)]
    else:
        weights = [r.uniform(0.0, 1.0) for _ in range(4)]

    n = vec3(0.12)
    t = vec3(0.12)
    return {
        ("ATTR", 0): [f2b(r.uniform(-3, 3)) for _ in range(3)] + [f2b(1.0)],
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],
        ("ATTR", 2): [f2b(r.uniform(0, 1)) for _ in range(4)],
        ("ATTR", 3): [f2b(r.uniform(-2, 2)) for _ in range(4)],
        ("ATTR", 4): [f2b(r.uniform(-2, 2)) for _ in range(4)],
        # Bone indices are raw uints and index a 256-entry palette.
        ("ATTR", 5): [i2b(r.randrange(0, _VS_BONES)) for _ in range(4)],
        ("ATTR", 6): [f2b(x) for x in weights],
        ("ATTR", 7): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                      f2b(r.choice([-1.0, 1.0]))],
    }


def hd_vs_cbufs(seed):
    """cb1 (blight rect), cb2 (matrices and per-draw), cb3 (bone palette).

    The one shaped choice is the worldView basis in cb2[4..6]. A third of the
    time it is flattened towards the Z axis by a log-uniform epsilon, which is
    what makes ``abs(n.z) < 0.999`` a live branch: the resulting normal lands
    on both sides of that threshold, and across the epsilon range it lands
    *near* it often enough that a wrong comparison constant shows up too.
    """
    rng = random.Random(seed * 6151 + 17)

    def rows(n, lo=-1.0, hi=1.0):
        return [[f2b(rng.uniform(lo, hi)) for _ in range(4)] for _ in range(n)]

    cb1 = rows(1)
    cb2 = rows(23)

    # --- cb2[0..11]: world / worldView / worldViewProj -----------------------
    for base in (0, 4, 8):
        for k in range(3):
            cb2[base + k] = [f2b(rng.uniform(-1, 1)) for _ in range(4)]
        cb2[base + 3] = [f2b(rng.uniform(-2, 2)) for _ in range(4)]

    if rng.random() < 0.35:
        # Flatten the worldView basis onto Z. Any normal then transforms to
        # roughly (eps*n.x, eps*n.y, n.z), so the normalised z approaches 1 --
        # the log-uniform epsilon sweeps it across the 0.999 threshold.
        eps = math.exp(rng.uniform(math.log(2e-3), math.log(0.35)))
        cb2[4] = [f2b(eps), f2b(0.0), f2b(0.0), cb2[4][3]]
        cb2[5] = [f2b(0.0), f2b(eps), f2b(0.0), cb2[5][3]]
        cb2[6] = [f2b(0.0), f2b(0.0), f2b(1.0), cb2[6][3]]

    # --- cb2[16..22]: per-draw ----------------------------------------------
    cb2[16][2] = f2b(rng.uniform(-3, 3))                 # clip height
    cb2[16][3] = f2b(rng.choice([0.0, 1.0, -1.0,         # under-water sign
                                 rng.uniform(-1, 1)]))
    cb2[17][0] = i2b(rng.randrange(0, 32))               # bone-buffer base
    cb2[18] = [f2b(rng.uniform(0, 2)) for _ in range(4)]  # diffuse tint
    for m in (19, 20, 21, 22):
        cb2[m] = [f2b(rng.uniform(-2, 2)) for _ in range(4)]

    # --- cb1[0]: blight rect -------------------------------------------------
    # Placed against the world-position range the matrices above produce, so
    # the UV genuinely straddles the saturate: an origin far outside it would
    # clamp every sample to 0 or 1 and hide the transform.
    cb1[0] = [f2b(rng.uniform(-5, 0)), f2b(rng.uniform(-5, 0)),
              f2b(rng.uniform(0.08, 0.5)), f2b(rng.uniform(0.08, 0.5))]

    # --- cb3: bone palette, three rows per bone ------------------------------
    cb3 = []
    for b in range(_VS_BONES):
        br = random.Random(f"{seed}:bone:{b}")
        for _ in range(3):
            cb3.append([f2b(br.uniform(-1.2, 1.2)) for _ in range(3)] +
                       [f2b(br.uniform(-4.0, 4.0))])
    return {1: cb1, 2: cb2, 3: cb3}


DRIVERS = {
    # deriv_scale > 0 matters: with zero derivatives the geometric specular-AA
    # roughness collapses to sqrt(roughness^2) == roughness and the cb2[26].w
    # toggle becomes unobservable. The synthetic derivative is a pure function
    # of the value, so both shaders still see identical numbers.
    'hd': dict(inputs_fn=hd_inputs, cbufs_fn=hd_cbufs, sysvals_fn=hd_sysvals,
               structured=lambda seed: HdStructured(seed), texture=HdTextures(),
               deriv_scale=1.0),
    # A vertex shader has no system values worth driving and no derivatives.
    'hd_vs': dict(inputs_fn=hd_vs_inputs, cbufs_fn=hd_vs_cbufs,
                  sysvals_fn=lambda seed: {},
                  structured=lambda seed: HdVsBones(seed),
                  texture=TextureModel(), deriv_scale=0.0),
    'default': dict(texture=TextureModel()),
}


# ==========================================================================
# compile + compare
# ==========================================================================

def _blame(exc):
    """Deepest frame inside our own tools -- where a harness bug actually is."""
    here = str(Path(__file__).resolve().parent).lower()
    frames = traceback.extract_tb(exc.__traceback__)
    ours = [f for f in frames if str(Path(f.filename).resolve()).lower().startswith(here)]
    f = (ours or frames)[-1] if (ours or frames) else None
    return f"{Path(f.filename).name}:{f.lineno}" if f else "?"


def find_fxc():
    """Newest fxc.exe from the installed Windows SDKs."""
    roots = [Path(r'C:\Program Files (x86)\Windows Kits\10\bin'),
             Path(r'C:\Program Files\Windows Kits\10\bin')]
    cands = []
    for root in roots:
        if root.is_dir():
            cands += list(root.glob('*/x64/fxc.exe')) + list(root.glob('*/x86/fxc.exe'))
    if not cands:
        raise FileNotFoundError("no fxc.exe found in the Windows SDK")
    return sorted(cands)[-1]


def compile_perm(fxc, hlsl, profile, entry, defines, out_dxbc):
    cmd = [str(fxc), '/nologo', '/T', profile, '/E', entry, '/Fo', str(out_dxbc)]
    for k, v in (defines or {}).items():
        cmd += ['/D', f'{k}={v}' if v not in (None, '') else str(k)]
    cmd.append(str(hlsl))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not Path(out_dxbc).exists():
        msg = (r.stderr or r.stdout or '').strip().splitlines()
        return False, ('fxc: ' + (msg[-1] if msg else f'exit {r.returncode}'))
    return True, ''


def disassemble(dxbc, decompiler):
    asm = Path(dxbc).with_suffix('.asm')
    subprocess.run([str(decompiler), '-d', str(dxbc)], capture_output=True, text=True)
    if not asm.exists():
        raise RuntimeError(f"no .asm produced for {dxbc}")
    return asm


def output_regs_of(prog):
    regs = {reg for name, _i, _m, reg in prog.output_sig
            if not name.upper().startswith('SV_DEPTH')}
    return tuple(sorted(regs))


def validate_slot(folder, slot, entry, profile, defines, fxc, decompiler,
                  workdir, trials, tol, driver, keep=None, cand_asm=None):
    """Compile (unless ``cand_asm`` is already built) and differentially compare."""
    retail_asm = folder / f'perm_{slot}.asm'
    if not retail_asm.exists():
        return {'slot': slot, 'ok': False, 'reason': 'retail .asm missing'}
    if cand_asm is None:
        out_dxbc = Path(keep or workdir) / f'cand_{slot}.dxbc'
        ok, msg = compile_perm(fxc, folder / 'uber.hlsl', profile, entry,
                               defines, out_dxbc)
        if not ok:
            return {'slot': slot, 'ok': False, 'reason': msg}
    try:
        cand = Program.from_file(cand_asm if cand_asm is not None
                                 else disassemble(out_dxbc, decompiler))
        gold = Program.from_file(retail_asm)
    except Exception as e:                                    # noqa: BLE001
        return {'slot': slot, 'ok': False, 'reason': f'parse: {e}'}

    # One-sided on purpose: an output the retail shader writes and the
    # candidate does not is a real miss, so compare the union and let a
    # never-written register read as 0 on the side that lacks it.
    regs = tuple(sorted(set(output_regs_of(gold)) | set(output_regs_of(cand))))
    if not regs:
        regs = (0,)
    try:
        res = compare(cand, gold, trials=trials, output_regs=regs, tol=tol,
                      seed0=zlib.crc32(str(slot).encode()) & 0xFFFF,
                      **DRIVERS[driver])
    except NotImplementedError as e:
        return {'slot': slot, 'ok': False, 'interp_error': True,
                'reason': f'interpreter does not support this shader: {e} '
                          f'(at {_blame(e)})'}
    except (IndexError, KeyError, ValueError, ZeroDivisionError, RuntimeError,
            OverflowError, RecursionError) as e:
        return {'slot': slot, 'ok': False,
                'reason': f'execution failed: {type(e).__name__}: {e} '
                          f'(at {_blame(e)})'}
    except Exception as e:                                    # noqa: BLE001
        return {'slot': slot, 'ok': False, 'harness_error': True,
                'reason': f'HARNESS BUG ({type(e).__name__}: {e}) at '
                          f'{_blame(e)} -- a defect in the validation tooling, '
                          f'not in uber.hlsl'}
    ok = res.worst <= tol and res.discard_mismatches == 0
    if ok:
        reason = ''
    elif res.discard_mismatches and res.worst <= tol:
        reason = (f'DISCARD differs on {res.discard_mismatches}/{res.trials} '
                  f'trials (numeric outputs identical) -- the clip/discard '
                  f'condition is wrong')
    else:
        reason = (f'worst={res.worst:.3e} @seed {res.worst_seed} '
                  f'{res.worst_where}, discard_mismatch='
                  f'{res.discard_mismatches}/{res.trials}')
    return {'slot': slot, 'ok': ok, 'worst': res.worst, 'trials': res.trials,
            'discard_mismatches': res.discard_mismatches, 'regs': list(regs),
            'reason': reason}


def validate_folder(folder, *, slots='sample', sample_size=12, trials=32,
                    tol=DEFAULT_TOL, decompiler=DECOMPILER, seed=0, quiet=False,
                    driver=None, keep=None, jobs=1):
    folder = Path(folder)
    man_path = folder / 'uber_manifest.json'
    if not man_path.exists() or not (folder / 'uber.hlsl').exists():
        return {'folder': str(folder), 'ok': False, 'results': [],
                'reason': 'uber.hlsl / uber_manifest.json missing'}
    man = json.loads(man_path.read_text('utf-8'))
    perms = man.get('perms') or {}
    profile = man.get('profile') or 'ps_5_0'
    entry = man.get('entry') or 'main'
    driver = driver or man.get('driver') or 'default'
    if driver not in DRIVERS:
        return {'folder': str(folder), 'ok': False, 'results': [],
                'reason': f'unknown driver {driver!r}'}

    present = sorted(p.stem[len('perm_'):] for p in folder.glob('perm_*.dxbc'))
    missing = [s for s in present if s not in perms]
    if missing:
        return {'folder': str(folder), 'ok': False, 'results': [],
                'reason': f'manifest omits {len(missing)} slots '
                          f'(e.g. {missing[:5]})'}

    if slots == 'all':
        chosen = present
    elif isinstance(slots, (list, tuple)):
        chosen = [s for s in slots if s in perms]
    else:
        rng = random.Random(seed)
        chosen = sorted(rng.sample(present, min(sample_size, len(present))))

    fxc = find_fxc()
    results = []
    with tempfile.TemporaryDirectory(prefix='wc3uber_') as wd:
        for slot in chosen:
            d = perms[slot].get('defines') if isinstance(perms[slot], dict) else {}
            r = validate_slot(folder, slot, entry, profile, d or {}, fxc,
                              decompiler, wd, trials, tol, driver, keep=keep)
            results.append(r)
            if not quiet:
                mark = 'ok  ' if r['ok'] else 'FAIL'
                extra = '' if r['ok'] else f"  {r.get('reason', '')}"
                print(f"  [{mark}] perm_{slot}{extra}", flush=True)

    failed = [r for r in results if not r['ok']]
    harness = [r for r in failed if r.get('harness_error')]
    interp = [r for r in failed if r.get('interp_error')]
    bits = []
    if harness:
        bits.append(f'{len(harness)} HARNESS BUG')
    if interp:
        bits.append(f'{len(interp)} interpreter-unsupported')
    return {'folder': str(folder), 'ok': not failed, 'checked': len(results),
            'failed': len(failed), 'harness_errors': len(harness),
            'interp_errors': len(interp),
            'reason': '' if not failed else
                      (f'{len(failed)}/{len(results)} slots failed'
                       + (' (' + ', '.join(bits) + ')' if bits else '')),
            'results': results}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('folder')
    ap.add_argument('--slots', default='sample',
                    help='"sample" (default), "all", or a comma-separated list')
    ap.add_argument('--sample-size', type=int, default=12)
    ap.add_argument('--trials', type=int, default=32)
    ap.add_argument('--tol', type=float, default=DEFAULT_TOL)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--driver', default=None)
    ap.add_argument('--decompiler', default=DECOMPILER)
    ap.add_argument('--keep', default=None,
                    help='keep the compiled candidates in this directory')
    ap.add_argument('--json', default=None)
    args = ap.parse_args(argv)

    slots = args.slots
    if slots not in ('sample', 'all'):
        slots = [s.strip() for s in slots.split(',') if s.strip()]

    print(f"validating {args.folder}")
    rep = validate_folder(args.folder, slots=slots, sample_size=args.sample_size,
                          trials=args.trials, tol=args.tol, seed=args.seed,
                          decompiler=args.decompiler, driver=args.driver,
                          keep=args.keep)
    if args.json:
        Path(args.json).write_text(json.dumps(rep, indent=2), encoding='utf-8')
    if rep['ok']:
        print(f"PASS: {rep.get('checked', 0)} slots, worst within {args.tol}")
        return 0
    print(f"FAIL: {rep.get('reason', '')}")
    return 1


if __name__ == '__main__':
    sys.exit(main())
