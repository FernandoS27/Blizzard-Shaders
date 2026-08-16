"""Behavioural differential: retail D3D SM3 shader vs our native ps_3_0 compile.

Both shaders are run through the SAME interpreter (sm3_exec) on identical random
inputs/constants/textures, and their colour outputs are compared.  Because both
come from the SAME original `.fx` source, once register ALIGNMENT is correct the
outputs must match bit-for-bit (float64) for a correct permutation decode.

Alignment (retail-reg <-> native-reg for c#, v#, s#) is pluggable via an
`Align` object.  With a faithful engine-reproducing compile the alignment is the
IDENTITY (c0=c0, v0=v0, s0=s0); until the engine register map is wired in, pass a
custom Align.  This module supplies the interpreter plumbing; the register map is
filled in by the engine-RE work.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sc2_d3d_decode as D
import sm3_parse as S
import sm3_exec as E
import sc2_cache
import sc2_ps_layout as L

try:
    import dxbc_interp as di
except Exception:
    di = None


class SharedTex(di.TextureModel if di else object):
    """Texture model where the sampler slot is first mapped through the sampler
    alignment to a canonical id, so a logical texture reads identically on both
    sides regardless of each shader's local s# numbering.  Coords are truncated to
    the sampler's dimensionality (2D->xy, cube/volume->xyz) so garbage z/w a 2D
    tex2D ignores don't spuriously differ between native and retail."""

    _DIMLANES = {2: 2, 3: 3, 4: 3}          # sampler dim (sm3_parse) -> coord lanes

    def __init__(self, slot_to_canon, slot_to_dim=None):
        if di:
            di.TextureModel.__init__(self)
        self.slot_to_canon = slot_to_canon
        self.slot_to_dim = slot_to_dim or {}

    def sample(self, slot, coords):
        canon = self.slot_to_canon.get(slot, slot)
        lanes = self._DIMLANES.get(self.slot_to_dim.get(slot, 2), 2)
        c = [coords[i] if i < lanes else 0.0 for i in range(4)]
        return di.TextureModel.sample(self, canon, c)


def _used(prog, rtype):
    return {o.num for ins in prog.instrs for o in ins.operands
            if o.rtype == rtype and o.rel is None}


def compare(retail, native, align, trials=4, seed=0):
    """Run both programs on identical aligned random inputs; return the worst
    per-output-component abs difference across trials, or (None, reason).

    `align` maps native-reg -> canonical-id for each of consts/inputs/samplers;
    the retail side uses its own reg as the canonical id (identity), so
    align.const[native_c] must equal the retail c that means the same thing."""
    r_out = retail.outputs
    n_out = native.outputs
    shared = sorted(r_out & n_out)
    if not shared:
        return None, "no shared colour output"
    rnd = random.Random(seed)

    # canonical value pools (keyed by canonical id)
    def rand4():
        return [rnd.uniform(-1.5, 1.5) for _ in range(4)]

    worst = 0.0
    for _ in range(trials):
        cval, vval, mval = {}, {}, {}

        def canon_const(cid):
            if cid not in cval:
                cval[cid] = rand4()
            return cval[cid]

        def canon_input(vid):
            if vid not in vval:
                vval[vid] = rand4()
            return vval[vid]

        def canon_misc(mid):
            if mid not in mval:
                mval[mid] = rand4()
            return mval[mid]

        # vFace (D3DSMO_FACE, misc reg 1): native folds the two-sided-normal flip to
        # the FRONT branch and never declares vFace, so feed vFace a positive (front)
        # scalar broadcast on both sides; vPos (reg 0) keeps the shared-random value.
        def misc_val(canon):
            reg = canon[1] if isinstance(canon, tuple) else canon
            return [1.0, 1.0, 1.0, 1.0] if reg == 1 else canon_misc(canon)

        # retail side: identity canonical ids
        r_consts = {c: canon_const(("c", c)) for c in _used(retail, S.RT_CONST)}
        r_inputs = {v: canon_input(("v", v)) for v in retail.inputs}
        r_misc = {m: misc_val(("m", m)) for m in retail.misc}
        r_tex = SharedTex({s: s for s in retail.samplers}, retail.samplers)

        # native side: map through align to the same canonical ids
        n_consts = {c: canon_const(align.const.get(c, ("c", c)))
                    for c in _used(native, S.RT_CONST)}
        n_inputs = {v: canon_input(align.input.get(v, ("v", v)))
                    for v in native.inputs}
        n_misc = {m: misc_val(align.misc.get(m, ("m", m))) for m in native.misc}
        n_tex = SharedTex({s: align.sampler.get(s, s) for s in native.samplers},
                          native.samplers)

        rvm = E.execute(retail, inputs=r_inputs, consts=r_consts, textures=r_tex, misc=r_misc)
        nvm = E.execute(native, inputs=n_inputs, consts=n_consts, textures=n_tex, misc=n_misc)
        for t in shared:
            ro = rvm.oC.get(t, [0, 0, 0, 0])
            no = nvm.oC.get(t, [0, 0, 0, 0])
            for k in range(4):
                a = min(1.0, max(0.0, ro[k]))         # LDR UNORM8 targets
                b = min(1.0, max(0.0, no[k]))
                worst = max(worst, abs(a - b))
    return worst, None


class Align:
    """native-reg -> canonical-id maps.  Empty = identity alignment."""
    def __init__(self, const=None, input=None, sampler=None, misc=None):
        self.const = const or {}
        self.input = input or {}
        self.sampler = sampler or {}
        self.misc = misc or {}


IDENTITY = Align()


def d3d_cache_path():
    return D.D3D_CACHE


if __name__ == "__main__":
    # smoke: identity alignment on retail-vs-retail (must be 0.0 everywhere)
    cache = D.D3DCache()
    _d, _v, records = sc2_cache.parse_cache(D.D3D_CACHE)
    n = 0
    worst_all = 0.0
    for r in records:
        blob = cache.data[r["blob_off"]:r["blob_off"] + r["blobsize"]]
        if blob[0] or (blob[9] & 1) == 0:
            continue
        f = L.family_of(sc2_cache.decode_key(r["key"])[1])
        if not f or f[0] != "Model":
            continue
        toks, _desc = cache.decode_blob(r["blob_off"], r["blobsize"])
        p = S.SM3Program.from_tokens(toks)
        w, err = compare(p, p, IDENTITY, trials=2)   # a shader vs ITSELF -> 0
        if err:
            continue
        worst_all = max(worst_all, w)
        n += 1
        if n >= 200:
            break
    print("retail-vs-itself over %d shaders: worst diff = %.3g (expect 0.0)"
          % (n, worst_all))
