"""Engine-EXACT decode of a Model-family permutation key -> {b_*: value}.

Reversed from the client's PermSchema layout finalizer (subagent RE, IDB
16ee6550): PermSchema_FinalizeLayout @0x102b8c430, PermSchema_EmitAxisDefines
@0x102b8d4c0, PermSchema_EmitShaderDefines @0x102b8d9b0, Model_BuildFamily
@0x102b61590.

Layout facts (differ from the older LSB-first sc2_ps_decode fit):
  * The key is a byte-granular concatenation of SECTIONS.  Each section starts
    on a whole byte (`byte_base` below).  Within a section, axes are packed
    FORWARD-cumulative by width, MSB-first, from the section's local bit 0.
  * The Model family block is a 88-bit (11-byte) header (holds key metadata +
    the schema hash at bytes 8..11) followed by b_iBlendWeightCount (w3) at bit
    88; the first real section (Common) starts at byte 12.
  * Extraction is big-endian within the field: the field's MSB is at the lowest
    bit offset (EmitAxisDefines does `((key[bo]&maskHi)<<8 | key[bo+1]&maskLo)
    >> shift`).

`extract()` below is the byte-for-byte equivalent of EmitAxisDefines.  The
absolute origin (whether vec[0] == the engine key pointer) is locked
empirically via `SHIFT_BITS`; see sweep in __main__ / callers.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sc2_ps_decode as dec   # reuse the (already-correct) axis NAME lists


def _byte(key, i):
    return key[i] if 0 <= i < len(key) else 0


def extract(key, gbit, width):
    """MSB-first big-endian bitfield read of `width` bits starting at absolute
    bit `gbit` (bit (7-(g&7)) of byte g>>3).  Byte-for-byte == EmitAxisDefines.
    Out-of-range bytes read as 0 (RLE drops trailing default fields)."""
    v = 0
    for i in range(width):
        b = gbit + i
        v = (v << 1) | ((_byte(key, b >> 3) >> (7 - (b & 7))) & 1)
    return v


def _layer(layer):
    return [("b_i%s%s" % (layer, p), w) for p, w in dec.PROPS]


_MAT = list(dec.MAT_GLOBALS)
for _L in dec.LAYERS:
    _MAT += _layer(_L)

_MAINSHADING = [
    ("b_iShadingMode", 4), ("b_hasNormals", 1), ("b_iUseDynamicAO", 1),
    ("b_usePackedUVEmitter", 1), ("b_iWriteFogDensityIntoRed", 1),
    ("b_haloPass", 1), ("b_iLayoutHasCustomUB4N1", 1),
    ("b_iLayoutHasNoVertexBlendWeights", 1),
    ("b_iLayoutHasNoVertexBlendIndices", 1), ("b_iUseSignedIntUVs", 1),
    ("b_iLayoutHasColor", 1), ("b_iUVCoordCount", 3),
    ("b_iUVEmitterCount", 4), ("b_iUVEmitterArraySize", 4),
] + [("b_iUVMapping%d" % i, 5) for i in range(8)] \
  + [("b_UVRandomOffsetEnable%d" % i, 1) for i in range(8)]

# (section name, byte_base, [(axis, width), ...]).  Family is special: its axis
# sits at absolute bit 88 (byte 11) inside the 12-byte family block.
SECTIONS = [
    ("family", 0, [("b_iBlendWeightCount", 3)]),          # NOTE: axis at bit 88
    ("Common", 12, [
        ("b_fogScaleByAlpha", 1), ("b_useBlendAdd", 1), ("b_useIdentityBasis", 1),
        ("b_useModelInstancing", 1), ("b_iDebugMode", 5), ("b_iInEncoding", 2),
        ("b_iOutEncoding", 2), ("b_iUse8BitHDR", 1), ("b_iNormalizeDeffNormal", 1),
        ("b_iLowResNormal", 1), ("b_iAlphaTest", 1)]),
    ("Material", 15, _MAT),
    # Lighting_BuildSection@0x102b55180: 16 direct lighting axes, then the SHADOW
    # sub-section (sub_102B54BE0, 7 axes/11 bits) is registered BETWEEN b_iUseSpecular
    # and b_UseLightingRegions, then b_UseLightingRegions.  Bit bases (Lighting@888):
    # b_useShadows@907 usePCF@908 iBiasAdjustment@909 iUseSoftShadows@910
    # iUseExplicitShadowTest@911 iSoftShadowTaps@912(w5) useTransparentShadows@917
    # UseLightingRegions@918.  (Earlier work mis-read bit907 as UseLightingRegions --
    # it is really b_useShadows; the real LR sits at 918.)
    ("Lighting", 109, [
        ("b_useLighting", 1), ("b_iVertexLightingMode", 2), ("b_useDblLambert", 1),
        ("b_iLightingMode", 3), ("b_iLightingModel", 1), ("b_DXNStyleNormalMaps", 1),
        ("b_UseVertexBasedAmbientOcclusion", 1), ("b_iVertexAOFromVertexColor", 1),
        ("b_useNormalMapping", 1), ("b_iNormalizeHalfVector", 1),
        ("b_iFakeEnergyConservingSpec", 1), ("b_UseAmbientEnvironment", 1),
        ("b_iDirectionalLightCount", 2), ("b_iAffectedByAO", 1),
        ("b_iUseSpecular", 1),
        ("b_useShadows", 1), ("b_usePCF", 1), ("b_iBiasAdjustment", 1),
        ("b_iUseSoftShadows", 1), ("b_iUseExplicitShadowTest", 1),
        ("b_iSoftShadowTaps", 5), ("b_useTransparentShadows", 1),
        ("b_UseLightingRegions", 1)]),
    ("Displacement", 112, [("b_iDisplacementPass", 2)] + _layer("Displacement")
        + _layer("DisplacementStrength")
        + [("b_distortionDepthFix", 1), ("b_useVertexAlphaStrength", 1)]),
    ("VectorUI", 123, [
        ("b_iDrawType", 2), ("b_additiveSplat", 1), ("b_renderBlack", 1),
        ("b_lowEndShaders", 1), ("b_dashedCircleSplats", 1)]),
    ("Volume", 124, [
        ("b_iVolumeType", 2), ("b_iVolumePass", 3), ("b_iVolumeFalloffType", 2),
        ("b_iVolumeMod", 1), ("b_iVolumeCamPos", 2)] + _layer("VolumeColor")
        + _layer("VolumeNoise1") + _layer("VolumeNoise2")),
    ("MRT", 141, [(n, 1) for n in dec.MRT_AXES]),
    ("TerrainDoodad", 143, _layer("TerrainAlphaMask") + [
        ("b_iSolidColor", 1), ("b_creepEnabled", 1), ("b_no8BitHDR", 1),
        ("b_computeHeight", 1), ("b_iCreepPass", 2), ("b_iCreepOutputMode", 3),
        ("b_iTriPlanarCreep", 1), ("b_iCreepUseGroundNormalMap", 1),
        ("b_iUseVisualization", 1), ("b_iBlockVisualization", 1)]),
    ("FOW", 150, [
        ("b_FOWEnabled", 1), ("b_SampleFOW", 1), ("b_FOWMode", 3),
        ("b_FastFOW", 1), ("b_FOWAdditiveScale", 1)]),
    ("Reflection", 151, [("b_blurPass", 1)] + _layer("ReflectionNormal")
        + _layer("ReflectionStrength") + _layer("ReflectionBlurMask")),
    ("Cloaking", 167, [("b_iCloakingPass", 2)] + _layer("CloakingAlphaMask")
        + _layer("CloakingEnvio") + _layer("CloakingEnvioMask")
        + _layer("CloakingAlphaTest") + _layer("CloakingAlphaMaskOriginal")
        + _layer("CloakingNormal")),
    ("MainShading", 198, _MAINSHADING),
    ("VertexWarp", 208, [("b_enableVertexWarps", 1), ("b_iWarpCount", 1)]),
]


def decode(vec, shift_bits=0):
    """{axis_name: value} using the SUBAGENT REGISTRATION-ORDER table.

    WARNING: this table is the axis registration order, which is NOT the physical
    byte order of sections in the stored key.  Empirically (500 real Model D3D
    keys) the physical section order differs (e.g. MainShading is embedded at the
    family front @~bit89, and the Material layer array is at MSB bit 165, not the
    tabled byte-15 base).  Use `decode_material()` / `b_values()` for the parts
    physically anchored against the real cache; this stays for reference only.
    """
    out = {}
    for name, byte_base, axes in SECTIONS:
        gbit = byte_base * 8 + shift_bits
        if name == "family":
            gbit = 88 + shift_bits            # family axis lives at bit 88
        for axis, w in axes:
            out[axis] = extract(vec, gbit, w)
            gbit += w
    return out


# ---------------------------------------------------------------------------
# PHYSICALLY-ANCHORED layout (verified vs 500 real Model D3D cache keys).
#
# The stored key is MSB-first bit-packed (subagent FinalizeLayout: field MSB at
# the lowest bit offset).  Section BYTE bases from the registration walk do NOT
# match the physical key, so each section is anchored empirically by brute-forcing
# a discriminating axis.  Material is locked: LayerEnable/TextureType/LayerId/
# UVMapping/Op all decode sanely ONLY at MSB layer-base 165 (TextureType==2D=0 for
# 94% of enabled layers vs 68% LSB-first — this both confirms MSB-first for
# multi-bit fields and pins the base; neighbours 158..173 all misalign).
# Globals (29 bits) sit immediately before -> base 136.
# ---------------------------------------------------------------------------
MAT_GLOB_BASE = 136       # MSB-first bit; 26 globals, 29 bits
MAT_LAYER_BASE = 165      # MSB-first bit; 18 layers x 40 bits (dec.PROPS order)


def decode_material(vec, shift=0):
    """{material b_*: value} decoded MSB-first at the anchored bases.  Verified:
    recovers the material-layer samplers the older LSB-first fit dropped.
    `shift` is the per-family section offset (see decode_section)."""
    out = {}
    g = MAT_GLOB_BASE + shift
    for name, w in dec.MAT_GLOBALS:
        out[name] = extract(vec, g, w)
        g += w
    for li, layer in enumerate(dec.LAYERS):
        base = MAT_LAYER_BASE + shift + 40 * li
        off = 0
        for prop, w in dec.PROPS:
            out["b_i%s%s" % (layer, prop)] = extract(vec, base + off, w)
            off += w
    return out


def b_values(vec, all_b, shift_bits=0):
    """Best current Model decode: the fitted structural decode (shading mode /
    MRT / lighting, with b_emitFinalColor forced) OVERRIDDEN by the physically-
    anchored MSB-first Material decode.  This is what a native ps_3_0 compile
    should use to reproduce a retail D3D shader's material sampling.

    `shift_bits` is accepted for API compatibility with decode() but ignored.
    """
    import sc2_compile_perms as _C
    bv = _C.decode_perm_bvalues(vec, all_b)          # fitted structural sections
    for k, v in decode_material(vec).items():        # anchored MSB material
        if k in bv:
            bv[k] = v
    return _clamp_cardinalities(bv)


def _clamp_cardinalities(bv):
    """Re-apply the schema's cardinality clamps (shared by both decode bases)."""
    maxe = 0
    for k in list(bv):
        if k.endswith("UVEmitter"):
            bv[k] = min(bv[k], 7); maxe = max(maxe, bv[k])
        elif k.endswith("TriPlanarUvId"):
            # TriPlanarUvId is 0..17 = "reference layer N's triplanar UVs", 18 (==c_maxNumLayers)
            # = "self/master, compute own".  Clamping to 17 (as for LayerId) destroyed EVERY master
            # -> no triplanar perm computed its atlas UVs (missing p_v*AtlasParams, worst=1.0 on all
            # ~104 triplanar perms).  Allow the 18 self-sentinel; >=18 all mean self (gate is >=18).
            bv[k] = min(bv[k], 18)
        elif k.endswith("LayerId"):
            bv[k] = min(bv[k], 17)
    if maxe + 1 > bv.get("b_iUVEmitterCount", 0):
        bv["b_iUVEmitterCount"] = maxe + 1
    return bv


def _anchored_base(vec, all_b, shift):
    """Base b_* map for a family whose sections are SHIFTED off Model's bases.

    `b_values`' structural half is `sc2_compile_perms.decode_perm_bvalues`, an
    LSB-first fit made against MODEL's key layout.  For a family whose sections
    start 8 or 16 bits away that fit's bases are wrong *by construction*, and
    "shifting a fit" is not a meaningful operation — so it is dropped entirely
    here rather than shifted.

    What survives is the axis NAME SET (layout-independent, and the only source of
    the token-pasted material-layer axes such as `b_iDiffuseUVMapping`, which
    `scan_b_tokens` cannot see), with every value zeroed, plus the physically-
    anchored material section read at the family's own offset.  `decode_ps`'s
    per-section overrides then supply the rest.

    Dropping the fit loses nothing: the anchored table covers 675 of the 681 PS
    axes, and the six it misses read a constant 0 on every retail key
    (`b_alphaEnable`, `b_useParallaxOcclusion`, `b_useEmissiveMultiplier`,
    `b_LayoutUseSignedIntUVs`, `b_useVertexLighting` — the last is `if (false)`
    dead source — plus `b_iBlendWeightCount`, which is a VERTEX own-axis supplied
    by `sc2_family_decode.decode_own_axes`)."""
    import sc2_compile_perms as _C
    bv = {k: 0 for k in _C.decode_perm_bvalues(vec, all_b)}
    for k, v in decode_material(vec, shift).items():
        if k in bv:
            bv[k] = v
    return _clamp_cardinalities(bv)


# ---------------------------------------------------------------------------
# LIVE INTERPOLANT MASK  (subagent RE: BuildStageCacheKey@0x102b8bd50 records a
# 32-bit live-interpolant mask in the key; g_interpolantTable@0x1043D4130).
#
# The mask is a 32-bit LE word at **vec[4:8]** (empirically located: decoding it
# via the interpolant table yields a textbook Model varying set -- Normal 100%,
# FogColor 99%, UV 93%, HalfVec 62%, Tangent/Binormal ~60%, ShadowMapUV 38%).
# Bit i -> INTERP_TABLE[i].  This is the DIRECT, opengl3-free source of the PS's
# live interpolant set AND (via the packer) its dcl_texcoord signature.
# ---------------------------------------------------------------------------
import struct as _struct

# (name, components, semanticClass, gate_axis_or_None); class 1/2=TEXCOORD,
# 3=COLOR, 4=WPOS/ScreenPos, 5=VFACE.  Gated entries take `axis` slots (UV[]).
INTERP_TABLE32 = [
    ("HPosAsUV", 4, 2, None), ("WorldPos", 4, 2, None), ("ViewPos", 3, 2, None),
    ("Normal", 4, 1, None), ("Tangent", 4, 1, None), ("Binormal", 3, 1, None),
    ("UV", 4, 1, "b_iUVEmitterArraySize"), ("HalfVec", 3, 1, None),
    ("VertexColor", 4, 3, None), ("Diffuse", 3, 3, None), ("Specular", 3, 3, None),
    ("ShadowMapUV", 4, 2, None),
    ("GaussianBlurSample", 4, 1, "b_iSampleInterpolantCount"),
    ("FogColor", 4, 3, None), ("TerrainUV", 4, 2, None), ("FrontFace", 1, 5, None),
    ("VectorUI0", 4, 2, None), ("VectorUI1", 4, 2, None), ("VectorUI2", 4, 2, None),
    ("EyeToVertexFresnel", 3, 2, None), ("ParallaxVector", 3, 2, None),
    ("ShadowLightTS", 3, 1, None), ("DownscaleUV0", 4, 1, None),
    ("DownscaleUV1", 4, 1, None), ("FOWUV", 3, 1, None), ("BackBufferUV", 2, 2, None),
    ("Vector4", 4, 2, None), ("EyeToVertex", 3, 2, None), ("ShadowDiffuse", 3, 3, None),
    ("ShadowSpecular", 3, 3, None), ("ScreenPos", 2, 4, None),
    ("TriPlanarWeights", 4, 2, None),
]
_INAME = [e[0] for e in INTERP_TABLE32]
_IIDX = {n: i for i, n in enumerate(_INAME)}


def live_mask(vec):
    """32-bit live-interpolant mask (bit i -> INTERP_TABLE32[i]), from vec[4:8]."""
    return _struct.unpack("<I", bytes(vec[4:8]))[0]


def live_names(vec, known=None):
    """Set of live interpolant NAMES (optionally intersected with the names the
    preamble generator understands, `known`)."""
    m = live_mask(vec)
    out = {_INAME[i] for i in range(32) if (m >> i) & 1}
    return out & known if known is not None else out


def derive_feature_axes(bv, vec):
    """Fill the STANDALONE-sampler / lighting feature axes the material decode
    doesn't cover, from the live mask (the VS-provided interpolants are a
    reliable proxy for which shading features are active).  Only standalone
    features (shadows, FOW) + the lighting gate -- material-layer samplers stay
    with decode_material (forcing normal-map/specular here overshoots)."""
    m = live_mask(vec)
    has = lambda n: (m >> _IIDX[n]) & 1
    if has("Normal"):
        bv["b_hasNormals"] = 1
    if has("HalfVec"):
        # HalfVec live -> lighting is on (per-pixel or partial).  b_iVertexLightingMode
        # itself now comes from the EXACT Lighting@889 decode (adopted above) -- do NOT
        # force it to 0 here: that broke VERTEXLIGHTING_PARTIAL perms (vlm=1 use HalfVec
        # AND precomputed COLOR), diverging from retail's partial light-constant set.
        bv["b_useLighting"] = 1
    # NOTE: ShadowMapUV live does NOT imply lighting -- a deferred shadow-only pass writes the
    # shadow map with b_useShadows=1 but b_useLighting=0 (e.g. Envio/emissive perms).  The real
    # b_useLighting is now adopted from Lighting@888, so the old "ShadowMapUV => lighting" force
    # (which over-set it to 1 -> worst=1.0) is removed; b_useShadows comes from the shadow @907 bit.
    if has("FOWUV"):
        bv["b_SampleFOW"] = 1
        bv["b_FOWEnabled"] = 1
    if has("Diffuse") or has("Specular"):
        # precomputed vertex lighting (Diffuse/Specular COLOR interpolants) -> lighting
        # is ON; else pslighting.fx folds cLightDiffuse=1 and drops those varyings.
        # Regression-safe (0/900 sampler regressions); fixes vertex-lit behavioral diffs.
        bv["b_useLighting"] = 1
    return bv


# MRT section: MSB-first bit base 1152 (byte 144) -- located by matching the
# emit-MRT axes against retail oC1/oC2/oC3 output registers: agreement 400/400.
# emitFinalColor/emitAlpha read constant in the key (engine-derived at compile,
# like the old fit decoder's forced emitFinalColor), so we DERIVE those.
MRT_BASE = 1152
MRT_AXES = ["b_emitFinalColor", "b_emitAlpha", "b_emitMRTDepth", "b_emitMRTNormal",
            "b_emitMRTDiffuse", "b_emitMRTSpecular", "b_emitMRTSpecularPower",
            "b_emitMRTAO", "b_blendMRTNormals"]


def decode_mrt(vec, shift=0):
    """{MRT emit axis: value} MSB-first at bit 1152.  The emitMRT* axes exactly
    reproduce retail's oC1/oC2/oC3 output set (validated 400/400).
    `shift` is the per-family section offset (see decode_section)."""
    return {MRT_AXES[i]: extract(vec, MRT_BASE + shift + i, 1) for i in range(9)}


# Per-section physical MSB-first bit bases, verified vs the real D3D corpus by the
# 18-agent workflow (each section anchored + regression-checked against retail).
# NB Displacement@920 (NOT 912): the Lighting section is byte-aligned to 4 pad bits
# (908-911) + a shadow-quality subfield (912-919) before Displacement.
SECTION_BASE = {
    "Common": 112, "Lighting": 888, "MainShading": 1608, "FOW": 1224,
    "Displacement": 920, "VectorUI": 1008, "Volume": 1016, "TerrainDoodad": 1168,
    "Reflection": 1232, "Cloaking": 1360, "VertexWarp": 1688,
}
_AXES_BY_NAME = {name: axes for name, _b, axes in SECTIONS}
# Lighting axes to NOT adopt from the section: b_useLighting/b_UseAmbientEnvironment
# regress the native sampler count (mask-derivation handles them).  b_iVertexLightingMode
# IS adopted from the section (real per-perm value) -- the HalfVec->vlm=0 override in
# derive_feature_axes runs AFTER and forces per-pixel only when HalfVec is live, so
# vertex-lit perms (no HalfVec) keep the correct non-zero vlm (fixes the vertex-lighting
# constant mismatch that broke ~20 behavioral diffs).
# b_UseAmbientEnvironment is re-derived @902 below; b_useLighting IS adopted from the section
# @888 now (the OLD b_values fit set it to 1 on some lighting-OFF perms -- e.g. Envio/emissive-only
# and decal-only perms with no HalfVec/ShadowMapUV/Diffuse/Specular varying -- which derive_feature_axes
# could never correct back to 0 since it only forces it ON; adopting the real bit fixes those worst=1.0
# perms, and derive still forces it ON when the live mask indicates lighting).
_LIGHTING_SKIP = {"b_UseAmbientEnvironment"}


def decode_section(vec, name, shift=0):
    """{axis: value} for a section at its verified physical MSB-first base.

    `shift` offsets every base by a whole-family constant.  The four Default
    families share ONE section table but place it at different absolute bit
    offsets (their key headers differ in size): Model +0, Foliage -8, Ribbon +16,
    Particle +16 — see sc2_family_decode.FAMILY_SECTION_SHIFT.  Default 0 keeps
    every existing caller byte-for-byte unchanged."""
    g = SECTION_BASE[name] + shift
    out = {}
    for axis, w in _AXES_BY_NAME[name]:
        out[axis] = extract(vec, g, w)
        g += w
    return out


def shadow_quality(vec):
    """(b_iUseSoftShadows, b_iSoftShadowTaps) from the per-key shadow-quality field
    at MSB bits 913..914 (0->hard, 1->soft/6-tap, 3->soft/12-tap); 97.5% purity vs
    retail shadow-map tap-count over 13,572 shadowed Model PS keys."""
    f = extract(vec, 913, 2)
    if f == 0:
        return 0, 0
    return 1, (12 if f == 3 else 6)


def decode_ps(vec, all_b, known_interp=None, shift=0):
    """The full opengl3-FREE Model PS permutation: returns (b_values, live).

    OLD-fit base + anchored MSB material, then EXACT per-section overrides
    (Common/Lighting/MainShading/MRT/FOW, verified regression-safe by the
    section-anchoring workflow), mask-derived feature gates, exact emit flags,
    and the shadow-quality field.  live = mask-derived interpolant name set."""
    # Model (shift 0) keeps its long-validated OLD-fit base byte-for-byte; a
    # shifted family cannot use a fit made against Model's layout (see
    # _anchored_base) and is built from the anchored sections alone.
    bv = (b_values(vec, all_b) if shift == 0
          else _anchored_base(vec, all_b, shift))
    # exact-anchored section overrides (win over the OLD LSB fit)
    for k, v in decode_section(vec, "Common", shift).items():
        if k in bv:
            bv[k] = v
    # Adopt the exact Lighting section INCLUDING the shadow sub-section
    # (b_useShadows/b_usePCF/b_iBiasAdjustment/b_iUseSoftShadows/b_iUseExplicitShadowTest/
    # b_iSoftShadowTaps/b_useTransparentShadows) and the REAL b_UseLightingRegions@918.
    # The shadow axes are inserted between b_iUseSpecular and b_UseLightingRegions in the
    # engine's Lighting_BuildSection, so bit907 is b_useShadows (NOT LightingRegions -- the
    # old "force LR=0" hack was compensating for reading LR at the wrong bit).  These axes
    # are absent from the OLD fit -> set unconditionally (b_usePCF is a bit-alignment axis
    # not used by model.fx; an unused #define is harmless).
    for k, v in decode_section(vec, "Lighting", shift).items():
        if k not in _LIGHTING_SKIP:
            bv[k] = v
    for k, v in decode_section(vec, "MainShading", shift).items():
        if k in bv:
            bv[k] = v
    for k, v in decode_mrt(vec, shift).items():              # exact oC1/2/3 + emit flags
        if k in bv:
            bv[k] = v
    # mask-derived gates (win over section for the two Lighting axes that regress,
    # and for vertex-lighting-mode which the mask nails on complex shaders)
    bv = derive_feature_axes(bv, vec)
    # AmbientEnvironment IBL cube (p_sAmbientEnvironmentTexture) is the real Lighting axis
    # @bit902 -- adopt it directly.  (The old "& per-pixel (vlm==0)" gate wrongly forced 0
    # on vertex/partial-lit perms that DO sample the cube, e.g. vlm=2 -> -1 sampler undershoot.)
    if "b_UseAmbientEnvironment" in bv:
        bv["b_UseAmbientEnvironment"] = extract(vec, 902 + shift, 1)
    for k, v in decode_section(vec, "FOW", shift).items():   # exact FOW > FOWUV heuristic
        if k in bv:
            bv[k] = v
    # TerrainDoodad section (@1168): creep pass/output-mode + terrain alpha-mask layer.
    # The OLD LSB fit mis-decodes b_iCreepPass (gives 0 where the physical anchor gives
    # the real 1), which drops the creep ApplyFog lerp + p_cFogColor uniform -> the one
    # remaining behavioral outlier (worst=1.0).  Adopting the anchored section fixes it
    # bit-exact (13/13 consts); b_no8BitHDR/mask axes are physically anchored here too.
    for k, v in decode_section(vec, "TerrainDoodad", shift).items():
        if k in bv:
            bv[k] = v
    # Volume section (@1016, NOT the earlier 1008): b_iVolumeType(2)@1016 +
    # b_iVolumePass(3)@1018 + FalloffType/Mod/CamPos + the 3 volume layers.  Adopt only
    # for SHADINGMODE_VOLUME (b_iShadingMode==4) -- psvolume.fx is #if'd out otherwise, so
    # the axes are irrelevant to the 31,300 STANDARD perms.  The OLD b_values fit left
    # b_iVolumePass stuck at 0 (PASS_CLEAR -> `return 0`, 0 samplers) for every volume perm,
    # undershooting the p_sNormalDepthMap / p_sThickness sampler that passes 3/4/5 declare.
    # Anchor verified: pass@1018(w3) reproduces all 14 volume perms bit-exact (was 1/14).
    if bv.get("b_iShadingMode") == 4:
        for k, v in decode_section(vec, "Volume", shift).items():
            if k in bv:
                bv[k] = v
    # Displacement section (@920): psdisplacement.fx layers are compiled only under
    # SHADINGMODE_DISPLACEMENT (b_iShadingMode==1).  Same unadopted-section issue as Volume
    # -- the OLD b_values fit mis-reads the Displacement layer axes (e.g. LayerEnable=0 +
    # UVEmitter=4 where the anchored section gives LayerEnable=1 + UVEmitter=0), which both
    # diverges behaviour and overflows sc2UV[] (GetUVEmitter(4) with count=1 -> X3504).
    if bv.get("b_iShadingMode") == 1:
        for k, v in decode_section(vec, "Displacement", shift).items():
            if k in bv:
                bv[k] = v
    # VectorUI section (@1008, NOT 1000 -- same +8 physical shift as Volume): psvectorui.fx
    # is compiled only under SHADINGMODE_VECTORUI (b_iShadingMode==2).  b_iDrawType(2)@1008
    # selects the splat-draw path; the OLD fit left it 0 for every VectorUI perm.  Anchored
    # base reproduces b_iDrawType for all 11 clean perms (mix of 1/2).
    if bv.get("b_iShadingMode") == 2:
        for k, v in decode_section(vec, "VectorUI", shift).items():
            if k in bv:
                bv[k] = v
    # Reflection section (@1232, base already correct -- just never adopted): psreflection.fx
    # is compiled under SHADINGMODE_REFLECTION (b_iShadingMode==6).  b_blurPass + the 3 reflection
    # layers (ReflectionNormal/Strength/BlurMask) drive the sampler set; the OLD fit mis-read the
    # layer enables -> -1/-2 sampler undershoot.  Adopting fixes all 11 reflection perms bit-exact.
    if bv.get("b_iShadingMode") == 6:
        for k, v in decode_section(vec, "Reflection", shift).items():
            if k in bv:
                bv[k] = v
    # Cloaking section (@1360, base already correct -- never adopted): pscloaking.fx is compiled
    # under SHADINGMODE_CLOAKING (b_iShadingMode==7).  b_iCloakingPass + SIX cloaking layers
    # (AlphaMask/Envio/EnvioMask/AlphaTest/AlphaMaskOriginal/Normal); the OLD fit mis-read the
    # layer enables -> up to -4 sampler undershoot on 94/97 perms.  Adopting fixes them bit-exact.
    if bv.get("b_iShadingMode") == 7:
        for k, v in decode_section(vec, "Cloaking", shift).items():
            if k in bv:
                bv[k] = v
    # (Shadows are now decoded EXACTLY from the Lighting shadow sub-section above --
    # b_useShadows@907, b_iUseSoftShadows@910, b_iSoftShadowTaps@912(w5),
    # b_useTransparentShadows@917 -- so the old ShadowMapUV-live heuristic + shadow-quality
    # subfield gate are retired.)
    # UV-emitter-count clamp: only layers that ACTUALLY sample index the emitter array.
    # A UseConstantColor=1 layer returns p_cConstantColor before GetUVEmitter, so its
    # UVEmitter field must NOT force b_iUVEmitterCount up (retail keeps count=0 when every
    # enabled layer is constant-color; over-bumping to 1 diverged the shader -> worst=1.0).
    # The sc2UV[] interpolant array is sized to cover EVERY enabled non-constant layer's
    # emitter index regardless of shading mode (it's a compile-time struct size), so scan
    # ALL layer families (Displacement/Volume/Reflection/Cloaking/Terrain, not just the
    # standard dec.LAYERS) -- e.g. a Displacement layer with UVEmitter=4 needs count>=5, or
    # READ_INTERPOLANT_UV(4) -> sc2UV[4] overflows sc2UV[1] (fxc X3504 array-out-of-bounds).
    # Env-mapped layers (Envio/EnvioMask) sample via the reflection vector, NOT GetUVEmitter, so
    # they must NOT contribute to the emitter count -- an Envio-only perm keeps retail's count=0
    # (counting it forced 0->1 -> worst=1.0).  Regular UV layers use emitter 0 by default, so they
    # DO force count>=1 even at UVEmitter==0 (else b_iUVEmitterCount diverges from retail's).
    maxe = -1
    for k in list(bv):
        if not k.endswith("UVEmitter"):
            continue
        Lyr = k[3:-len("UVEmitter")]          # 'b_iDisplacementUVEmitter' -> 'Displacement'
        if "Envio" in Lyr:
            continue
        if bv.get("b_i%sLayerEnable" % Lyr) and not bv.get("b_i%sUseConstantColor" % Lyr):
            maxe = max(maxe, bv.get(k, 0) or 0)
    if maxe >= 0 and maxe + 1 > bv.get("b_iUVEmitterCount", 0):
        bv["b_iUVEmitterCount"] = maxe + 1
    return bv, live_names(vec, known_interp)


def _gfx_in_set_2_6():
    return False           # native D3D ps_3_0 is NOT the GL profile


def pack_ps_dcl(mask, ver, eval_axis, stage_is_ps=True, GL=False):
    """Reproduce the retail PS dcl list from the live `mask` (subagent
    EmitInterpolantStruct spec).  `ver`=PIXEL_SHADER_VERSION (key[1]); eval_axis(i)
    = slot count for gated entry i (b_iUVEmitterArraySize for UV[]).  Returns an
    ordered list (name, semantic, index_or_None, components) == retail dcls, for
    register alignment.  HPos:POSITION prologue is implicit (emitted first)."""
    TC_CAP = (6 if ver <= 7 else 8 if ver <= 10 else (8 if GL else 10) if ver == 11
              else (8 if GL else 11))
    TOT_CAP = 11 if ver >= 12 else 10
    presum = sum(eval_axis(i) if INTERP_TABLE32[i][3] else 1
                 for i in range(32) if (mask >> i) & 1)
    out = [("HPos", "POSITION", None, 4)]
    tc_idx = col_idx = total = 0
    for i in range(32):
        if i == 15 or not (mask >> i) & 1:
            continue
        name, comp, sem, gate = INTERP_TABLE32[i]
        n = eval_axis(i) if gate else 1
        if i == 30 and ver == 11 and stage_is_ps:
            out.append((name, "WPOS" if GL else "VPOS", None, 2 if GL else 4))
            continue
        is_tc = sem in (1, 2)
        if (((is_tc or n + col_idx >= 3) and n + tc_idx > TC_CAP) or n + total > TOT_CAP):
            mask &= ~(1 << i)
            continue
        if sem == 3:
            spill = (n + col_idx > 2) or (presum <= 8 and GL)
            if not spill:
                out.append((name, "COLOR", col_idx, comp)); col_idx += n; total += n
                continue
            sem = 1
        if sem in (1, 2):
            if ver >= 12 and tc_idx == 10:
                out.append((name, "BINORMAL", None, comp))
            else:
                out.append((name, "TEXCOORD", tc_idx, comp))
            tc_idx += n
        elif sem == 0:
            out.append((name, "POSITION", None, comp))
        total += n
    if stage_is_ps and (mask >> 15) & 1:
        out.append(("FrontFace", "VFACE", None, 1))
    return out


if __name__ == "__main__":
    import sc2_cache
    import sc2_d3d_decode as D
    import sc2_ps_layout as L
    import sc2_compile_perms as C
    all_b, _ = C.scan_b_tokens(C.SRC + r"\model.fx")
    known = set(all_b)
    covered = [a for _n, _b, axes in SECTIONS for a, _w in axes if a in known]
    print("axes in model.fx covered by decoder:", len(set(covered)), "/", len(known))
    missing = sorted(known - set(covered))
    print("model.fx b_* NOT covered (%d):" % len(missing))
    for m in missing:
        print("   ", m)
