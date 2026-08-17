#!/usr/bin/env python3
"""Per-family permutation-key schema decode for the sc2_shaders module.

`sc2_model_key_decode.decode_ps` is exact ONLY for the four DefaultPixelMain
families (Model/Particle/Ribbon/Foliage) — it IS the shared material/shading
schema.  Every OTHER family (and every vertex shader) packs its own, smaller set
of `b_*` axes into the key vec at family-specific byte positions.  This module is
the growing registry of those per-family schemas, keyed by (family, stage).

    decode_family(family, stage, vec) -> (b_values, live) | None

`b_values` is the `{b_*: int}` the engine would have compiled that key with;
`live` is the set of live interpolant NAMES (for the shared-interpolant families;
empty for families that carry their own IO structs, like Simple).  Returns None
when no schema is known for (family, stage) yet — the caller then keeps the raw
decoded vec (manifest passthrough) so enumeration still works.

Schemas are added family-by-family as they're reversed (design §7 / the M-series
milestones).  Each entry is argued against the cache's own structure (the dedup
pattern, the Metal name split, the family `.fx` `#if b_*` closure) rather than a
retail D3D11 reference — the behavioral harness validates slang==fx for a decoded
define set, and the decode's *fidelity to retail* is argued structurally here.

------------------------------------------------------------------------------
Simple  (simple.fx : SimpleVertexMain / SimplePixelMain)
------------------------------------------------------------------------------
The Simple PS is a two-instruction shader:

    float4 cResult = sample2D(p_sTexture, input.vUV.xy) * input.cColor;
    AlphaTest(cResult.a);        // common.fx: if (b_iAlphaTest) clip(a - p_fAlphaThreshold);
    return cResult;

so its ONLY compile-time axis is `b_iAlphaTest`.  The retail cache carries 6
Simple-PS perms, of which only slots 0 and 1 are non-dedup (distinct blobs); the
other four are dedup refs.  Two distinct shaders => one boolean axis, and it maps
exactly onto key byte 15 bit 0x80:

    slot 0  b15=0x00  dedup=0   -> alpha OFF  (shader A)
    slot 1  b15=0x80  dedup=0   -> alpha ON   (shader B)
    slot 2  b15=0x80  dedup=1   -> alpha ON   (== B)
    slot 3  b15=0x80  dedup=1   -> alpha ON   (== B)
    slot 4  b15=0x00  dedup=1   -> alpha OFF  (== A)
    slot 5  b15=0x00  dedup=1   -> alpha OFF  (== A)

The other varying byte (14 in {0,0x2C,0x50}) does not change the PS output (it is
a VS/colour-side axis) — consistent with all four alpha-ON/OFF dedups folding onto
the two distinct blobs.  The Simple VS (SimpleVertexMain) has no compile-time
axis at all (1 perm, all-default vec).

------------------------------------------------------------------------------
Model / Particle / Ribbon / Foliage  VERTEX stage  (the `decode_vs` of design §7)
------------------------------------------------------------------------------
The VS is NOT a second schema: a family's PermSchema covers the WHOLE family, both
stages, and the stage is a single boolean byte in the key vec (design §2).  So a
Model VS key is decoded by the SAME physically-anchored section table the (proven)
`sc2_model_key_decode.decode_ps` uses.  Measured on the 25,696 Model-VS records:

  * all 40 `b_*` the VS include-closure references are already in the section
    table — except `b_useVertexLighting`, which is dead source (its only reference
    is `if ( false ) //b_useVertexLighting` in common.fx:95);
  * cross-checked against the RETAIL SM3 vertex blobs (`sm3_parse` on the decoded
    D3D-cache blob, 2,942 non-dedup Model VS shaders), every layout axis in the
    MainShading section satisfies "blob USES the input  =>  decode DECLARES it"
    with **zero violations** — `b_iUVCoordCount`, `b_iLayoutHasColor` (COLOR0),
    `b_iLayoutHasCustomUB4N1` (COLOR1), `b_iLayoutHasNoVertexBlendWeights`
    (BLENDWEIGHT), `b_iLayoutHasNoVertexBlendIndices` (BLENDINDICES).  Only the
    implication holds, not equality, because the D3D9 compiler drops declared-but-
    unread inputs.

ONE axis needed a new anchor.  `b_iBlendWeightCount` (skinning bone count) is not
produced by the PS decode at all — the registration-order table puts it at bit 88,
which reads a constant 6 on real keys.  Sweeping every (base, width) against the
retail blobs' skinning-input signature pins it at **MSB bit 104, width 3**:

    blob uses neither BLENDWEIGHT nor BLENDINDICES  <-> value 0   (Skin() is dead)
    blob uses BLENDINDICES only                     <-> value 1   (single-bone arm
                                                       reads iBoneIndices[0] only)
    blob uses both                                  <-> value 2 or 4 (weighted arm)

2,942/2,942 consistent (the 4 apparent exceptions are exactly the
`b_iLayoutHasNoVertexBlendWeights=1` keys, where model.fx passes literal 0s to
Skin so neither input is read).  Values observed: {0,1,2,3,4} — the real bone
counts, vs the bogus constant 6 at bit 88.

------------------------------------------------------------------------------
Where each family puts the shared sections  (FAMILY_SECTION_SHIFT)
------------------------------------------------------------------------------
All four Default families share ONE section table, but not its absolute offsets.
Per PermSchema_FinalizeLayout, a family's OWN axes pack first (from physical bit
104) and the header is then ceil'd to a byte boundary, so the shared sections
start at `104 + ceil(own_axis_bits / 8) * 8`.

Both halves of that are now read straight out of the retail binary rather than
fitted — `FAMILY_OWN_AXES` below transcribes each `<Family>_BuildFamily`'s
`PermSchema_RegisterAxis` sequence, and `FAMILY_SECTION_SHIFT` is COMPUTED from
it.  The four families come out as:

    Foliage    0 own axes  ( 0 bits) -> sections at 104   (shift  -8)
    Model      1 own axis  ( 3 bits) -> sections at 112   (shift   0)
    Particle   9 own axes  (18 bits) -> sections at 128   (shift +16)
    Ribbon    15 own axes  (23 bits) -> sections at 128   (shift +16)

which reproduces the earlier statistical fit exactly, on all four families.

Three independent checks confirm the blocks against retail, not just against
themselves:

  * Ribbon's `b_iRibbonSimTech` is predicted at **bit 124 width 3** by the
    registration order — and that is exactly where it had already been pinned
    1030/1030 against the retail SM3 vertex blobs' input signatures (ribbon.fx
    gates `VertDecl` on it: TEXCOORD8 implies LEGACY, TEXCOORD7 implies
    MIXED_PRECOMPUTED_TANGENT-or-LEGACY, any of TEXCOORD1..5 rules out
    SPLINE_RIBBON).  Its block ends at bit 126, so the header ceils to 128.
  * Ribbon's block is internally cross-checked over all 2,192 VS perms: three
    separate bitfields agree with `b_iRibbonSimTech`'s semantics PER PERM —
    `b_gpuSplineRibbon == (simTech==SPLINE_RIBBON)`, `b_precomputedTangent ==
    (simTech==MIXED_PRECOMPUTED_TANGENT)` and `b_precomputedAge ==
    (simTech==LEGACY)`, each 2192/2192.  A one-bit misalignment destroys that.
  * Particle's block is checked against 4,390 non-dedup retail VS blobs:
    `sincos` present  <->  `b_iInstanceType` is a rotation arm OR
    `b_enableVertexWarps` (MakeRotation is reached from six of the eleven
    instance-type arms and from ApplyWarps), 4390/4390; and "blob declares
    vInterpolator1  =>  b_useProceduralPosition or a velocity-driven arm",
    4390/4390.

Cardinality also bounds every multi-valued axis, and no perm ever exceeds it:
`b_iRibbonType` (card 4, w3) is only ever 0..3 across 2,192 perms, and
`b_iInstanceType` (card 11, w4) only ever 0..10 across 6,154.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)


def _decode_simple_ps(vec):
    # b_iAlphaTest is key byte 15 bit 0x80 (see module docstring).
    alpha = 1 if (len(vec) > 15 and (vec[15] & 0x80)) else 0
    return ({"b_iAlphaTest": alpha}, [])


# ------------------------------------------------------------------------------
# SplatDirect  (splatdirect.fx : SplatDirectPixelMain)
# ------------------------------------------------------------------------------
# SplatDirect_BuildFamily @0x102b92430 links the IDENTICAL shared sub-sections as
# Model (PermFamily_LinkSharedSubSections, same order) and appends MainShading —
# but NOT VertexWarp.  Its ONLY own key axis is b_stencilFillPass (width 1); the
# rest of its registrations are uniforms/samplers (no key bits).  By
# PermSchema_FinalizeLayout @0x102b8c430: direct family axes pack from FinalizeLayout
# bit 88 (== physical vec bit 104, the +16 origin offset), then the header ceils to a
# byte (both Model's b_iBlendWeightCount w3 and SplatDirect's b_stencilFillPass w1 land
# in byte 12, ceil -> byte 12), so the shared sub-sections start at the SAME physical
# base for both families.  => SplatDirect's shared/MainShading layout is BIT-IDENTICAL
# to Model's; validated behaviorally: splatdirect.fx:SplatDirectPixelMain (b_stencilFillPass=0)
# == model.fx:DefaultPixelMain, worst=0.0000, for every decoded perm.  The Model
# decode_ps therefore decodes SplatDirect's shared axes exactly; only b_stencilFillPass
# (physical bit 104) is added here.
SPLAT_STENCIL_FILL_BIT = 104


def _decode_splatdirect_ps(vec):
    import sc2_model_key_decode as K
    allb, known = _default_ps_ctx()
    bv, live = K.decode_ps(vec, allb, known)
    bv["b_stencilFillPass"] = K.extract(vec, SPLAT_STENCIL_FILL_BIT, 1)
    return bv, sorted(live)


# ------------------------------------------------------------------------------
# SplatDeferred  (splatdeferred.fx : SplatDeferredPixelMain)
# ------------------------------------------------------------------------------
# SplatDeferred_BuildFamily @0x102b91d20 registers THREE own axes (each width 1, so
# packed forward from physical bit 104) before linking the shared sub-sections +
# MainShading: b_iUseHardwareDepth@104, b_iUseMinimumHeight@105, b_iSplatBoxRender@106.
# Header ceils to byte 12 (3 own bits), so the shared sections land at the same bases
# as Model — the Model decode_ps decodes them exactly (same argument as SplatDirect).
# b_iUseMinimumHeight is inert in the PS (VS-only); the box-render preamble reads the
# other two.
def _decode_splatdeferred_ps(vec):
    import sc2_model_key_decode as K
    allb, known = _default_ps_ctx()
    bv, live = K.decode_ps(vec, allb, known)
    bv["b_iUseHardwareDepth"] = K.extract(vec, 104, 1)
    bv["b_iUseMinimumHeight"] = K.extract(vec, 105, 1)
    bv["b_iSplatBoxRender"] = K.extract(vec, 106, 1)
    return bv, sorted(live)


# ------------------------------------------------------------------------------
# TerrainBlend  (terrainblend.fx : TerrainBlendPixelMain) — carries its OWN IO
# structs (VertexTransport{vUV0,vUV1,vClip}), so live is empty (like Simple).
# ------------------------------------------------------------------------------
# TerrainBlend_BuildSection @0x102b93de0 registers three own axes (widths from
# PermSchema_RegisterAxis cardinality.bit_length): b_iUnSwizzleDXNNormalMaps@104(w1,
# card 1), b_iTerrainDebugMode@105(w1, card 1), b_iTerrainBlendMode@106(w4, card 9 ->
# 9 blend modes 0..8), then links ONLY the shared Common sub-section (@ physical 112).
# The PS also reads the Common encoding axes (b_iInEncoding/b_iOutEncoding etc.).
def _decode_terrainblend_ps(vec):
    import sc2_model_key_decode as K
    bv = {
        "b_iUnSwizzleDXNNormalMaps": K.extract(vec, 104, 1),
        "b_iTerrainDebugMode": K.extract(vec, 105, 1),
        "b_iTerrainBlendMode": K.extract(vec, 106, 4),
    }
    for k, v in K.decode_section(vec, "Common").items():
        bv[k] = v
    return bv, []


# ------------------------------------------------------------------------------
# Water  (water.fx : WaterPixelMain) — SHARED DefaultPixelMain interpolant transport
# (VertexTransportRaw + InitShader + INTERPOLANT_*), so live IS mask-derived.
# ------------------------------------------------------------------------------
# Water_BuildFamily @0x102b98af0 registers FIVE own axes (each w1, card 1) at physical
# bits 104-108: b_iCheapWater, b_useCaustics, b_useWaterDepthEffects, b_envMapPass,
# b_useCubemapReflections; then links a CUSTOM sub-section subset in this order:
# Common, Lighting, MRT, FOW (NOT the full Model chain).  Per FinalizeLayout (5 own
# bits ceil to byte 12), the physical bases are Common@112, Lighting@136, MRT@168,
# FOW@184.  Common shares Model's base so decode_section works; Lighting/FOW are read
# at Water's own bases here.  MRT is inert (WaterPixelMain returns a single COLOR).
_WATER_SECTION_BASE = {"Common": 112, "Lighting": 136, "MRT": 168, "FOW": 184}


def _decode_section_at(vec, name, base):
    import sc2_model_key_decode as K
    g = base
    out = {}
    for axis, w in K._AXES_BY_NAME[name]:
        out[axis] = K.extract(vec, g, w)
        g += w
    return out


def _decode_water_ps(vec):
    import sc2_model_key_decode as K
    import sc2_interp as ip
    bv = {
        "b_iCheapWater": K.extract(vec, 104, 1),
        "b_useCaustics": K.extract(vec, 105, 1),
        "b_useWaterDepthEffects": K.extract(vec, 106, 1),
        "b_envMapPass": K.extract(vec, 107, 1),
        "b_useCubemapReflections": K.extract(vec, 108, 1),
    }
    for sec in ("Common", "Lighting", "FOW"):
        for k, v in _decode_section_at(vec, sec, _WATER_SECTION_BASE[sec]).items():
            bv[k] = v
    known = set(ip.INTERP_DIM) | set(ip.ARRAY_INTERP) | set(ip.SPECIAL_READS)
    return bv, sorted(K.live_names(vec, known))


def _decode_simple_vs(vec):
    # SimpleVertexMain has no compile-time axis.
    return ({}, [])


# (family, stage) -> callable(vec) -> (b_values, live)
_SCHEMAS = {
    ("Simple", "ps"): _decode_simple_ps,
    ("Simple", "vs"): _decode_simple_vs,
    ("SplatDirect", "ps"): _decode_splatdirect_ps,
    ("SplatDeferred", "ps"): _decode_splatdeferred_ps,
    ("TerrainBlend", "ps"): _decode_terrainblend_ps,
    ("Water", "ps"): _decode_water_ps,
}


def has_schema(family, stage):
    return (family, stage) in _SCHEMAS


def decode_family(family, stage, vec):
    """(b_values, live) for a known (family, stage) schema, else None."""
    fn = _SCHEMAS.get((family, stage))
    if fn is None:
        return None
    return fn(vec)


# Families whose PS uses DefaultPixelMain and whose PS key decode is the
# validated shared material/shading schema (sc2_model_key_decode.decode_ps).
DEFAULT_PS_FAMILIES = {"Model", "Particle", "Ribbon", "Foliage"}
_DEFAULT_PS_CTX = None    # cache of (all_b, known_interp) for decode_ps


def _default_ps_ctx():
    global _DEFAULT_PS_CTX
    if _DEFAULT_PS_CTX is None:
        import sc2_compile_perms as cp
        import sc2_interp as ip
        allb, _ = cp.scan_b_tokens(os.path.join(cp.SRC, "model.fx"))
        known = set(ip.INTERP_DIM) | set(ip.ARRAY_INTERP) | set(ip.SPECIAL_READS)
        _DEFAULT_PS_CTX = (allb, known)
    return _DEFAULT_PS_CTX


# Families whose VERTEX stage shares the same family PermSchema as the PS (see the
# module docstring).  All four Default families decode through the same section
# table; only their absolute placement differs (FAMILY_SECTION_SHIFT).
DEFAULT_VS_FAMILIES = {"Model", "Foliage", "Ribbon", "Particle"}

# ---------------------------------------------------------------------------
# PER-FAMILY OWN-AXIS BLOCK  (and the section shift it induces)
# ---------------------------------------------------------------------------
# Every family's key begins with a header holding the axes that family registers
# ITSELF, packed MSB-first from physical bit 104 in *registration order*; the
# shared sub-sections are then linked after the header is ceil'd to a byte.  So
# the four Default families share ONE section table but NOT its absolute offsets.
#
# These blocks are read straight out of `<Family>_BuildFamily` in the retail
# binary (sc2.i64) — the sequence of `PermSchema_RegisterAxis` calls before
# `PermFamily_LinkSharedSubSections` — rather than fitted:
#
#     Model_BuildFamily    @0x102b61590      Foliage_BuildFamily  @0x102b496b0
#     Particle_BuildFamily @0x102b62290      Ribbon_BuildFamily   @0x102b66630
#
# `PermSchema_RegisterAxis` @0x102b8d1c0 derives each axis's WIDTH from its
# cardinality argument as `cardinality.bit_length()` (the `while(c){c>>=1;++w}`
# loop writing desc+30), which is what the (name, width) pairs below encode.
FAMILY_OWN_AXIS_BASE = 104

FAMILY_OWN_AXES = {
    # Model: one axis.  b_iBlendWeightCount card 5 -> w3, matching the width and
    # base independently anchored against the retail blobs' skinning signature.
    "Model": [("b_iBlendWeightCount", 3)],
    # Foliage registers ZERO own axes (only uniforms), so its header is empty and
    # the shared sections start at 104 itself.  It is also the one Default family
    # that appends MainShading WITHOUT VertexWarp — consistent with foliage.fx,
    # which neither includes VSVertexWarp.fx nor references b_enableVertexWarps.
    "Foliage": [],
    # Ribbon: 23 bits (104..126).  b_useCompressedVerts is registered but never
    # referenced by ribbon.fx (dead axis, like b_useVertexLighting) — it still
    # consumes its bit, so it must stay in the list.
    "Ribbon": [
        ("b_iRibbonType", 3),                 # 104  card 4  (BILLBOARD/PLANAR/CYLINDER/STAR)
        ("b_iRibbonSizeInterpolation", 3),    # 107  card 5
        ("b_iRibbonColorInterpolation", 3),   # 110  card 5
        ("b_precomputedAge", 1),              # 113
        ("b_precomputedTangent", 1),          # 114
        ("b_proceduralPosition", 1),          # 115
        ("b_computeUFromAge", 1),             # 116
        ("b_useCompressedVerts", 1),          # 117  (dead in ribbon.fx)
        ("b_ribbonLocalSpace", 1),            # 118
        ("b_clampTail", 1),                   # 119
        ("b_tintRibbonRed", 1),               # 120
        ("b_gpuSplineRibbon", 1),             # 121
        ("b_compressedVertex", 1),            # 122
        ("b_splineRibbon", 1),                # 123
        ("b_iRibbonSimTech", 3),              # 124  card 5
    ],
    # Particle: 18 bits (104..121).
    "Particle": [
        ("b_iInstanceType", 4),                    # 104  card 11
        ("b_localSpace", 1),                       # 108
        ("b_useProceduralPosition", 1),            # 109
        ("b_iParticleSizeInterpolation", 3),       # 110  card 5
        ("b_iParticleColorInterpolation", 3),      # 113  card 5
        ("b_iParticleRotationInterpolation", 3),   # 116  card 5
        ("b_randomFlipBookStart", 1),              # 119
        ("b_fixedTailLength", 1),                  # 120
        ("b_clampedTailLength", 1),                # 121
    ],
}


def own_axis_bits(family):
    return sum(w for _, w in FAMILY_OWN_AXES[family])


def decode_own_axes(vec, family):
    """{axis: value} for a family's OWN header block, packed from bit 104."""
    import sc2_model_key_decode as K
    g = FAMILY_OWN_AXIS_BASE
    out = {}
    for axis, w in FAMILY_OWN_AXES[family]:
        out[axis] = K.extract(vec, g, w)
        g += w
    return out


# Shared sections start at `104 + ceil(own_axis_bits/8)*8`; the table in
# sc2_model_key_decode holds MODEL's bases (Common @112), so the per-family shift
# is that minus 112.  Derived, not fitted — but it reproduces the earlier fit
# exactly (Model +0, Foliage -8, Ribbon +16, Particle +16), and Ribbon's block in
# particular predicts b_iRibbonSimTech at bit 124 w3, which was pinned
# independently at 1030/1030 against the retail SM3 vertex input signatures.
FAMILY_SECTION_SHIFT = {
    f: ((own_axis_bits(f) + 7) // 8) * 8 - 8 for f in FAMILY_OWN_AXES
}

# THE SAME SHIFT APPLIES TO THE PIXEL STAGE.  A family's schema covers BOTH stages,
# so `decode_ps` needs the family offset exactly as `decode_default_vs` does; it used
# to hardcode Model's bases and therefore mis-read Particle/Ribbon/Foliage.  That did
# NOT show up as a validation failure — both legs are driven from the same `bv`, so a
# wrong `bv` is merely self-consistent — it just meant the compiled permutation was
# not the retail one.  `decode_perm` now passes `shift=FAMILY_SECTION_SHIFT[family]`.
#
# Measured against 400 non-dedup retail PS blobs per family, the shift is decisive:
#
#            enabled material layers      TextureType==2D    median sampler gap
#   Ribbon      15  ->  1083                 100%  -> 99.5%      3 -> 1
#   Particle    15  ->  1139                86.7%  ->  100%      4 -> 1
#   Foliage    268  ->   563                 100%  ->  100%      6 -> 4
#   Model     1635      (unchanged, shift 0)  93.8%              2
#
# 15 enabled layers across 400 perms is absurd — a drawable shader needs at least a
# diffuse layer — and the "sampler gap" is (samplers the retail blob declares) minus
# (distinct texture sources the decode needs), which lands on Model's own profile
# once shifted.  Model, SplatDirect, SplatDeferred, TerrainBlend and Water are all
# shift 0, so their long-validated decodes are byte-for-byte untouched.

# Back-compat aliases (b_iBlendWeightCount is now just Model's own-axis block).
BLEND_WEIGHT_COUNT_BIT = FAMILY_OWN_AXIS_BASE
BLEND_WEIGHT_COUNT_WIDTH = 3

# Sections whose axes the VERTEX include-closures reference.  Everything a Default
# family's VS can branch on lives in one of these; the pixel-only sections (MRT,
# Volume, Reflection, Cloaking, VectorUI, Displacement) are omitted.
_VS_SECTIONS = ("Common", "Lighting", "MainShading", "TerrainDoodad", "VertexWarp",
                "FOW")


def decode_default_vs(vec, family="Model"):
    """(b_values, live) for a Default-family VERTEX permutation key.

    Built from the PHYSICALLY-ANCHORED sections only (plus the family shift), not
    from `decode_ps`.  `decode_ps` starts from the older LSB-first fit and then
    overrides it section by section — but it never adopts **VertexWarp**, so its
    `b_enableVertexWarps` / `b_iWarpCount` come from that old fit.  Ground truth
    settles it: `MakeRotation`'s `sincos` is a unique marker for the warp path, and
    across the 2,942 non-dedup retail Model VS blobs the anchored VertexWarp@1688
    section agrees **2942/2942** while the old fit agrees 2299/2942 — it reports
    "no warps" on every one of the 643 blobs that actually warp.  A VS built from
    `decode_ps` would therefore compile ~21% of Model slots without warps *on both
    legs*: green, but not the retail shader.

    Three axis groups the pixel decode never produces are added here:
      * `b_iBlendWeightCount` (absent from decode_ps entirely — see the docstring);
      * `b_iUVMapping0..7` / `b_UVRandomOffsetEnable0..7`, ARRAY elements
        (`int b_iUVMapping[8]`, InitShader-filled) that `scan_b_tokens` classes as
        non-define, so decode_ps never copies them out of the MainShading section.
        Harmless for a pixel shader (its layers carry their own scalar
        `b_i<Layer>UVMapping`), decisive for a vertex one: the emitter loop
        dispatches `GenUV` on exactly these.
      * the VertexWarp section above.

    NOTE on `b_UVRandomOffsetEnable`: only particle.fx reads that array; the other
    families just forward it to InitShader.  `sc2_interp.gen_preamble` hard-zeroes
    it, which is exact everywhere except Particle — the decoded values are carried
    here so that gap is visible in the data rather than hidden."""
    import sc2_model_key_decode as K
    allb, known = _default_ps_ctx()
    shift = FAMILY_SECTION_SHIFT[family]

    bv = {b: 0 for b in allb}
    for name in _VS_SECTIONS:
        for k, v in K.decode_section(vec, name, shift).items():
            bv[k] = v
    # Material GLOBALS carry the splat / triplanar / Z-offset / parallax axes the
    # vertex bodies branch on.  (The 18-layer array in the same section is pixel-only
    # and reads all-zero on vertex keys, so copying it is inert.)
    for k, v in K.decode_material(vec, shift).items():
        bv[k] = v
    # The family's OWN header block (Model's b_iBlendWeightCount, Ribbon's
    # simulation/interpolation axes, Particle's instance/tail axes).  Packed from
    # bit 104 — i.e. BEFORE the shift, which is itself a consequence of this
    # block's size.
    bv.update(decode_own_axes(vec, family))
    ms = K.decode_section(vec, "MainShading", shift)
    for i in range(8):
        bv["b_iUVMapping%d" % i] = ms["b_iUVMapping%d" % i]
        bv["b_UVRandomOffsetEnable%d" % i] = ms["b_UVRandomOffsetEnable%d" % i]

    live = K.live_names(vec, known)
    # The live mask is the VS's own write set, so it is the authority on which
    # feature gates must be on (decode_ps applies the same derivation).
    bv = K.derive_feature_axes(bv, vec)
    return bv, sorted(live)


def decode_perm(family, stage, vec):
    """Unified (b_values, live) for any decodable (family, stage), else None.

    Dispatches: per-family schema (Simple, ...) first, then the shared family
    schema for the four Default families — `decode_ps` for the pixel stage,
    `decode_default_vs` (same sections + b_iBlendWeightCount) for the vertex
    stage.  This is the single decode entry point the manifest and the drivers
    both go through, so storage can stay compact (key only) and (bv, live) is
    recovered from the key on demand — essential for Model (~50k PS + ~26k VS
    perms × ~780 axes would be gigabytes if materialised)."""
    r = decode_family(family, stage, vec)
    if r is not None:
        return r
    if stage == "ps" and family in DEFAULT_PS_FAMILIES:
        import sc2_model_key_decode as K
        allb, known = _default_ps_ctx()
        # The shared sections sit at a per-family offset (FAMILY_SECTION_SHIFT) in
        # the PIXEL key exactly as they do in the vertex one — `decode_ps` was
        # reading Particle/Ribbon/Foliage at MODEL's bases.  Model is shift 0, so
        # its long-validated decode is untouched.
        bv, live = K.decode_ps(vec, allb, known, shift=FAMILY_SECTION_SHIFT[family])
        # Ribbon/Particle own axes live in the family header (bit 104) and are read
        # by the PIXEL closure too (b_iRibbonType/b_tintRibbonRed via the shared
        # material path, b_iInstanceType via psmainshading's flipbook gates).
        bv.update(decode_own_axes(vec, family))
        return bv, sorted(live)
    if stage == "vs" and family in DEFAULT_VS_FAMILIES:
        return decode_default_vs(vec, family)
    return None


def _self_check():
    """Decode the Simple manifests (if present) and print the per-slot axes."""
    import json
    perms_dir = os.path.join(os.path.dirname(HERE), "sc2_perms")
    for stage in ("ps", "vs"):
        path = os.path.join(perms_dir, "Simple_%s.json" % stage)
        if not os.path.exists(path):
            print("Simple_%s.json not found (run sc2_perm_manifest first)" % stage)
            continue
        data = json.load(open(path))
        print("Simple %s: %d perms" % (stage, data["count"]))
        for p in data["perms"]:
            vec = bytes.fromhex(p["key"])
            # the manifest stores the decoded key; re-derive from the raw key
            import sc2_cache
            _, dvec = sc2_cache.decode_key(vec)
            bv, live = decode_family("Simple", stage, dvec)
            print("  slot %d dedup=%d  b15=0x%02x -> %s live=%s"
                  % (p["slot"], p["dedup"], dvec[15] if len(dvec) > 15 else 0,
                     bv, list(live)))


if __name__ == "__main__":
    _self_check()
