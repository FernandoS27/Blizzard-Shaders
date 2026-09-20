"""Input drivers for the Diablo III differential (plan H1, section 3.2).

Every value both legs of a comparison see comes from here: per-semantic vertex
and interpolant inputs, the three constant-buffer banks, and the texture model.
All of it is a pure function of ``(seed, regime)`` and the key being read, so
the two programs are fed bit-identical inputs whatever their register layout.

The **R0** model is the RE validator's (``d3_uber_validate.py``), because it was
already debugged against the corpus:

* inputs are typed from the retail input signature -- ``BLENDINDICES`` is a
  bone number 0..44 (the shader multiplies it by 3 into ``CBBones``), every
  other ``uint`` stream is a UBYTE 0..255, weights are normalized, normals unit;
* banks have their shipped sizes (149 / 135 / 387 rows) and raise out of range;
* ``numLights.x`` is a small count and ``randFloat`` (a per-instance phase that
  indexes an immediate table) is never negative.

Measured on the corpus (plan 1.2), R0 alone leaves 107 compare lanes that never
flip. The other regimes exist for exactly those:

* **R1 edges** -- exact 0 / 1 texels and bank values, full-range textures, flag
  rows from {0, 1}: the ``eq x, 0`` guards, ``bUseDyeType``, the packed-shadow
  ``0.984375`` threshold.
* **R2 lights** -- ``numLights.x`` up to 20, so ``imin(count, 16)`` clamps.
* **R3 alpha** -- ``alphaTestRef.w`` at 0, 1, 1.25 and in [0, 1], so
  Billboard's ``alphaTestRef.w < 1`` gate goes both ways.
* **R4 neighbourhood** -- only for programs that sample with texel offsets
  (FXAA): R1's inputs over bilinear texel-scale strips and parity patterns, so
  an edge search walks to its later steps.

Tie trials (regime **T**) are not an input distribution; ``d3_diff`` builds them
on top of R0 by overriding one bank lane with the value the reference compared.
**N** trials set ``alphaTestRef.w`` to NaN: ``!(ref < a)`` discards and
``a <= ref`` keeps, so a compare spelled right for every number but NaN fails
there (fxc 47 folds ``!(ref < a)`` into ``ge ref, a``; retail kept ``lt`` +
``ieq 0``).

**Cube textures.** A GPU cube lookup ignores the direction's length; the smooth
field in ``dxbc_interp.TextureModel`` does not. A candidate that normalizes the
direction where retail did not is identical on hardware, so for a ``TextureCube``
register the model normalizes first.
"""

from __future__ import annotations

import math
import random
import struct
import zlib

import dxbc_interp as DI
from dxbc_interp import f2b

CB_ROWS = {0: 2384 // 16, 1: 2160 // 16, 2: 6192 // 16}
MAX_BONE = CB_ROWS[1] // 3 - 1
ALPHA_REF_ROW = 1888 // 16
NUM_LIGHTS_ROW = 6160 // 16
NUM_LIGHTS_FLOAT_ROW = 6176 // 16
#: rows whose domain is [0, 1): randFloat (CBMain 1600)
UNIT_ROWS = {0: {1600 // 16}}
#: rows that hold a boolean the shader tests against 0: bUseDyeType (CBMain 1616)
FLAG_ROWS = {0: {1616 // 16}}
#: CBMain viewport (1072) and edgeFilter (1456, the texel step of FXAA's edge search)
VIEWPORT_ROW = 1072 // 16
EDGE_FILTER_ROW = 1456 // 16

REGIMES = ('R0', 'R1', 'R2', 'R3', 'R4', 'T', 'N')
COUNTS = {'R0': 256, 'R1': 128, 'R2': 32, 'R3': 32, 'R4': 384, 'T': 32, 'N': 8}
#: a quiet NaN, the alphaTestRef.w of regime N
NAN_BITS = 0x7FC00000

#: regimes with R1's edge inputs and banks; R4 only changes the texture model
EDGE_REGIMES = ('R1', 'R4')

_EDGE_F = (0.0, 1.0, -1.0, 0.5, 2.0, 16.0, -16.0, 64.0)
_EDGE_U = (0, 255, 128)


def slot_seed(hash_hex: str) -> int:
    return zlib.crc32(hash_hex.encode()) & 0xFFFFFF


def schedule(measured: dict) -> list:
    """``[(regime, trial seed offset)]`` for one slot, from its measured axes."""
    out = [('R0', t) for t in range(COUNTS['R0'])]
    out += [('R1', 1000 + t) for t in range(COUNTS['R1'])]
    if measured.get('offsets'):
        # a program that samples with texel offsets is a neighbourhood filter (FXAA)
        out += [('R4', 6000 + t) for t in range(COUNTS['R4'])]
    if measured.get('lights'):
        out += [('R2', 2000 + t) for t in range(COUNTS['R2'])]
    alpha = measured.get('alphaCompare') or []
    if alpha:
        out += [('R3', 3000 + t) for t in range(COUNTS['R3'])]
    if any('a' in c for c in alpha):
        out += [('T', 4000 + t) for t in range(COUNTS['T'])]
        out += [('N', 5000 + t) for t in range(COUNTS['N'])]
    return out


def _rng(*parts) -> random.Random:
    return random.Random(':'.join(str(p) for p in parts))


# --------------------------------------------------------------------------
# inputs
# --------------------------------------------------------------------------

class Inputs:
    """``get((NAME, index))`` -> 4 uint32 lanes, typed by the retail signature."""

    def __init__(self, seed: int, formats: dict, regime: str):
        self.seed, self.formats, self.regime = seed, formats, regime

    def get(self, key):
        name, idx = key
        rng = _rng(self.seed, 'in', name, idx)
        edge = self.regime in EDGE_REGIMES and rng.random() < 0.25
        fmt = self.formats.get(key, 'float')
        if name == 'BLENDINDICES':
            return [rng.randint(0, MAX_BONE) for _ in range(4)]
        if self.regime == 'R4' and name == 'TEXCOORD' and fmt == 'float':
            # a screen pass's pixel inside the frame, not clamped onto its border
            return [f2b(rng.uniform(0.05, 0.95)) for _ in range(4)]
        if fmt in ('uint', 'int'):
            if edge:
                return [rng.choice(_EDGE_U) for _ in range(4)]
            return [rng.randint(0, 255) for _ in range(4)]
        if name == 'BLENDWEIGHT':
            w = [rng.random() for _ in range(4)]
            s = sum(w) or 1.0
            return [f2b(x / s) for x in w]
        if name in ('NORMAL', 'BINORMAL', 'TANGENT'):
            v = [rng.uniform(-1, 1) for _ in range(3)]
            m = math.sqrt(sum(c * c for c in v)) or 1.0
            return [f2b(c / m) for c in v] + [f2b(rng.choice([-1.0, 1.0]))]
        if edge:
            return [f2b(rng.choice(_EDGE_F)) for _ in range(4)]
        if name == 'COLOR':
            return [f2b(rng.random()) for _ in range(4)]
        return [f2b(rng.uniform(-2, 2)) for _ in range(4)]


def sysvals(seed: int) -> dict:
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --------------------------------------------------------------------------
# banks
# --------------------------------------------------------------------------

class _Rows:
    def __init__(self, banks, slot):
        self.b, self.slot = banks, slot
        self.size = CB_ROWS.get(slot, 4096)

    def __len__(self):
        return self.size

    def __getitem__(self, row):
        if isinstance(row, int) and not (0 <= row < self.size):
            raise IndexError('cb%d row %d outside [0,%d)' % (self.slot, row, self.size))
        return self.b.row(self.slot, row)


class Banks:
    """``cb[slot][row]`` -> 4 lanes. ``overrides`` maps ``(slot, row, lane)`` to bits."""

    def __init__(self, seed: int, regime: str, overrides: dict | None = None):
        self.seed, self.regime = seed, regime
        self.overrides = overrides or {}
        rng = _rng(seed, 'lights')
        if regime == 'R2':
            self.lights = rng.randint(16, 20) if rng.random() < 0.5 else rng.randint(0, 15)
        else:
            self.lights = rng.randint(0, 8)

    def __getitem__(self, slot):
        return _Rows(self, slot)

    def row(self, slot, row):
        if slot == 2 and row == NUM_LIGHTS_ROW:
            lanes = [self.lights] * 4
        elif slot == 2 and row == NUM_LIGHTS_FLOAT_ROW:
            lanes = [f2b(float(self.lights))] * 4
        else:
            rng = _rng(self.seed, 'cb', slot, row)
            unit = row in UNIT_ROWS.get(slot, ())
            flag = row in FLAG_ROWS.get(slot, ())
            if flag and self.regime in EDGE_REGIMES:
                lanes = [f2b(float(rng.randint(0, 1))) for _ in range(4)]
            elif self.regime in EDGE_REGIMES and rng.random() < 0.25:
                pool = (0.0, 0.5) if unit else _EDGE_F
                lanes = [f2b(rng.choice(pool)) for _ in range(4)]
            else:
                lo = 0.0 if unit else -1.0
                lanes = [f2b(rng.uniform(lo, 1)) for _ in range(4)]
            if slot == 0 and self.regime == 'R4':
                # a neighbourhood filter's engine domain: edgeFilter is one or two texels
                # of the 1024 the texture model reports (a random step jumps hundreds of
                # texels and no edge ever continues), the viewport mostly the identity
                if row == EDGE_FILTER_ROW:
                    lanes[0] = f2b(rng.choice((1, 1, 2)) / 1024.0)
                    lanes[1] = f2b(rng.choice((1, 1, 2)) / 1024.0)
                elif row == VIEWPORT_ROW and rng.random() < 0.8:
                    lanes = [f2b(1.0), f2b(0.0), f2b(1.0), f2b(0.0)]
            if slot == 0 and row == ALPHA_REF_ROW and self.regime == 'R3':
                pick = rng.random()
                w = 0.0 if pick < 0.2 else 1.0 if pick < 0.4 else 1.25 if pick < 0.55 else rng.random()
                lanes[3] = f2b(w)
        if self.overrides:
            lanes = list(lanes)
            for k in range(4):
                v = self.overrides.get((slot, row, k))
                if v is not None:
                    lanes[k] = v
        return lanes


# --------------------------------------------------------------------------
# textures
# --------------------------------------------------------------------------

class Textures(DI.TextureModel):
    """Regime-aware texture model shared by both legs of one trial."""

    CELLS = 8.0

    def __init__(self, seed: int, regime: str, cube_slots=(), centre=None):
        self.seed, self.regime = seed, regime
        self.cube = frozenset(cube_slots)
        #: R4: the trial's texture coordinate, which its edges pass through
        self.centre = centre

    #: stand-ins for a non-finite coordinate (a projective divide by an exact-zero w in
    #: R1): the smooth field cannot take one, and each must still read a texel of its own
    _NONFINITE = {math.inf: 4096.0, -math.inf: -4096.0}

    def _coords(self, slot, coords):
        coords = [c if math.isfinite(c) else self._NONFINITE.get(c, 4096.5) for c in coords]
        if slot in self.cube:
            x, y, z = coords[0], coords[1], coords[2]
            n = math.sqrt(x * x + y * y + z * z)
            if n > 0 and math.isfinite(n):
                return [x / n, y / n, z / n, coords[3] if len(coords) > 3 else 0.0]
        return coords

    def _cell(self, slot, coords, tag):
        # 35% of the textures of an R1 trial are FLAT: one value everywhere. A
        # filter's taps then agree, which is the only way a 4-tap soft-shadow
        # mix reaches the exact 0 its `eq moment, 0` guard tests (independent
        # cells would need four zero taps at once). 25% are 1/8-unit CELLS.
        #
        # 20% are FINE: blocks a few texels across (of the 1024 texels resinfo
        # reports), so a neighbourhood filter sees edges that END. FXAA's edge search
        # walks along an edge until the luma changes; on flat textures or 1/8-unit
        # cells its one-texel taps never find an end, and on the smooth field every
        # search stops at its first step.
        #
        # 20% are PARITY: one-texel blocks repeating a 2x2 pattern, so centre, row,
        # column and diagonal neighbours take four different values -- the only way
        # FXAA's 3x3 average moves further from the centre than the cross's range
        # (its subpixel `saturate` clamps).
        #
        # FINE and PARITY are BILINEAR over their texel grid, as a GPU's linear sampler
        # reads them: FXAA samples half a texel off a row, where a filtered read is the
        # average of the two rows, and only then does its edge search keep walking to
        # its 4- and 12-texel steps (point sampling ends every search at step one).
        kind = _rng(self.seed, 'flat', slot).random()
        if self.regime == 'R4':
            # R4 (neighbourhood filters): half the textures are a HARD, SHALLOW EDGE
            # through the trial's pixel -- the aliased staircase FXAA's 1..12-texel search
            # walks along --, a quarter per-texel NOISE, a quarter strips or parity
            r = _rng(self.seed, 'r4', slot)
            if kind < 0.5 and self.centre:
                vertical = r.random() < 0.5
                slope = r.choice((0.0, 1 / 64, 1 / 24, 1 / 12, 1 / 5, r.uniform(-0.2, 0.2)))
                x0 = math.floor(self.centre[0] * self.dims[0]) + r.random()
                y0 = math.floor(self.centre[1] * self.dims[1]) + r.choice((0.0, 0.5, 1.0))
                def block(i, j):
                    a, b, a0, b0 = (j + 0.5, i + 0.5, y0, x0) if vertical else (i + 0.5, j + 0.5, x0, y0)
                    return ('edge', (b - b0) > slope * (a - a0))
                return self._bilinear(slot, coords, block, tag)
            if kind < 0.75:
                return self._bilinear(slot, coords, lambda i, j: ('noise', i, j), tag)
            kind = 0.6 + 0.4 * (kind - 0.75) / 0.25
        if kind < 0.35:
            return self._texel(slot, ('flat',), 'f')
        if kind < 0.6:
            return self._texel(slot, tuple(int(math.floor(c * self.CELLS)) if math.isfinite(c) else 0
                                           for c in coords[:3]), tag)
        if kind < 0.8:
            # mostly STRIPS, one or two texels across and 3..28 long, so an edge runs
            # for a while and then ends -- where the search's later steps land
            r = _rng(self.seed, 'fine', slot)
            long_, thin = r.choice((3, 5, 7, 10, 14, 20, 28)), r.choice((1, 2))
            w, h = (long_, thin) if r.random() < 0.5 else (thin, long_)
            if r.random() < 0.25:
                w, h = r.choice((1, 2, 3, 5, 8, 13, 21)), r.choice((1, 2, 3, 5, 8, 13, 21))
            block = lambda i, j: ('fine', i // w, j // h)
        else:
            block = lambda i, j: ('par', i % 2, j % 2)
        return self._bilinear(slot, coords, block, tag)

    def _bilinear(self, slot, coords, block, tag):
        """A linear-filtered read of a texel grid whose texel (i, j) is ``block(i, j)``."""
        fx = coords[0] * self.dims[0] - 0.5
        fy = coords[1] * self.dims[1] - 0.5
        i0, j0 = int(math.floor(fx)), int(math.floor(fy))
        tx, ty = fx - i0, fy - j0
        corners = [self._texel(slot, block(i0 + di, j0 + dj), tag) for dj in (0, 1) for di in (0, 1)]
        return [(corners[0][k] * (1 - tx) + corners[1][k] * tx) * (1 - ty)
                + (corners[2][k] * (1 - tx) + corners[3][k] * tx) * ty for k in range(4)]

    def _texel(self, slot, idx, tag):
        rng = _rng(self.seed, 'tex', tag, slot, *idx)
        out = []
        for _ in range(4):
            p = rng.random()
            # exact 0, 1 and 0.5: the zero of every `2t - 1` decode, which is what a
            # velocity texel's "is it moving" guard (motion blur, |v - 0.5|^2 < 0.001) tests
            out.append(0.0 if p < 0.125 else 1.0 if p < 0.25 else 0.5 if p < 0.375 else rng.random())
        return out

    def sample(self, slot, coords):
        c = self._coords(slot, coords)
        if self.regime in EDGE_REGIMES:
            return self._cell(slot, c, 's')
        return super().sample(slot, c)

    def sample_lod(self, slot, coords, lod):
        c = self._coords(slot, coords)
        if self.regime in EDGE_REGIMES:
            return self._cell(slot, [c[0], c[1], c[2] + lod], 'l')
        return super().sample_lod(slot, c, lod)

    def sample_compare(self, slot, coords, ref):
        c = self._coords(slot, coords)
        if self.regime in EDGE_REGIMES:
            return 1.0 if ref <= self._cell(slot, c, 'c')[0] else 0.0
        return super().sample_compare(slot, c, ref)
