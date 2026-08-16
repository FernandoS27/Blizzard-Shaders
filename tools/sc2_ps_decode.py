"""Decode the per-layer material `b_*` for a DefaultPixelMain permutation straight
from its retail key vec — the axes the oracle search can't recover.

Anchored against the GLSL oracle over 47,708 real (vec, glsl) pairs:
  Material layer block: base bit 178, stride 40 bits/layer, 18 layers in
  registration order, props packed FORWARD within each layer (LayerEnable lowest).
  Validated: LayerEnable == sampler-presence and UseConstantColor==0 whenever a
  sampler is bound (100% on the common case).

Status: this block (306 per-layer axes) is the hardest part of the key and is
decoded + validated here.  A *complete* map_sc2_DefaultPixelMain(vec) additionally
needs the structural sections (MRT ~bit1151, Lighting, Common, MainShading layout,
Material globals) anchored the same way; bit-exact PS match needs all of them,
since the final colour runs through every stage.  Those sections are the remaining
anchoring pass.  MRT is located near bit 1151 (b_emitMRTDiffuse ~= 1156).
"""
import os
import struct
import sc2_key_decode as kd


def vec_glsl_pairs(gl_cache=None):
    """(vec, glsl) for every DefaultPixelMain-style PS blob in the GL cache.
    Ground truth for anchoring: decode_key(key) is the vec, blob is the GLSL."""
    import sc2_cache
    import sc2_glsl_bridge as bridge
    if gl_cache is None:
        gl_cache = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "mods", "core.sc2mod", "base.sc2data", "versions",
                                "macshaders41359", "opengl3", "baselinecache.bin")
    D = open(gl_cache, "rb").read()
    bs0 = struct.unpack("<I", D[0x20:0x24])[0]
    p2o = struct.unpack("<I", D[0x28:0x2c])[0]
    p2s = struct.unpack("<I", D[0x2c:0x30])[0]
    pos, end, off = p2o, p2o + p2s, bs0
    out = []
    while pos < end:
        d0 = struct.unpack("<I", D[pos:pos + 4])[0]
        ks, bsz = d0 & 0xFF, d0 >> 8
        g = bridge.extract_glsl(D[off:off + bsz])
        if g and "gl_Position" not in g and "out_cColor" in g:
            _, vec = sc2_cache.decode_key(D[pos + 12:pos + 12 + ks])
            out.append((vec, g))
        off += bsz
        pos += 12 + ks
    return out

LAYERS = ["Diffuse", "Decal", "Specular", "SpecularExponent", "Emissive",
          "Emissive2", "Envio", "EnvioMask", "AlphaMask", "AlphaMask2", "Normal",
          "Heightmap", "Lightmap", "AmbientOcclusion", "NormalBlendMask",
          "NormalBlendMask2", "NormalBlendNormal", "NormalBlendNormal2"]

# (offset, width) of each prop within a layer's 40-bit block, forward order
PROPS = [("LayerEnable", 1), ("UVEmitter", 4), ("LayerId", 5), ("TextureType", 2),
         ("ChannelSelect", 3), ("Invert", 1), ("Clamp", 1), ("IsRTTTexture", 1),
         ("TriPlanarUvId", 5), ("UVMapping", 5), ("Op", 3), ("TeamColorMode", 2),
         ("UseMask", 1), ("UseConstantColor", 1), ("FresnelMode", 2),
         ("FresnelTransformMode", 2), ("FresnelSaturate", 1)]
PROP_OFF = {}
_o = 0
for _n, _w in PROPS:
    PROP_OFF[_n] = (_o, _w)
    _o += _w
LAYER_BASE = 178
LAYER_STRIDE = 40


def decode_material_layers(vec):
    """{b_i<Layer><Prop>: value} for all 18 material layers from the vec."""
    out = {}
    for li, layer in enumerate(LAYERS):
        base = LAYER_BASE + LAYER_STRIDE * li
        for prop, (off, w) in PROP_OFF.items():
            out["b_i%s%s" % (layer, prop)] = kd.field(vec, base + off, w)
    return out


# ---------------------------------------------------------------------------
# Material GLOBALS (26 axes) precede the layers in the Material section:
# vec base bit 149 (= layer base 178 - 29 bits of globals).  Confirmed:
# b_iNormalBlending decodes at bit 174 (base+25) at 0.998 agreement.
# Packing (from the client's layout finalizer sub_102B8C430): every axis is
# placed FORWARD, cumulative by width (offset += width) within its block.
# ---------------------------------------------------------------------------
MAT_GLOBAL_BASE = 149
MAT_GLOBALS = [                       # (name, width) in registration order
    ("b_useTeamColorSpecular", 1), ("b_useSpecular", 1), ("b_useVertexColors", 1),
    ("b_useVertexAlpha", 1), ("b_litOnly", 1), ("b_iDebugRenderMode", 3),
    ("b_iSpecularType", 2), ("b_useDepthBlend", 1), ("b_useParallaxMapping", 1),
    ("b_useSimplifiedFresnel", 1), ("b_splatTextureProjectorEnabled", 1),
    ("b_splatAttenuationEnabled", 1), ("b_iLightmapShadow", 1), ("b_iUsePOMNew", 1),
    ("b_iModAlpha", 1), ("b_iClampOutput", 1), ("b_iUseWorldTriPlanarTangentSpace", 1),
    ("b_iUseLocalTriPlanarTangentSpace", 1), ("b_iUseWorldTriPlanarWeights", 1),
    ("b_iUseLocalTriPlanarWeights", 1), ("b_iZOffsetFromUB4N_XY", 1), ("b_iTwoSided", 1),
    ("b_iNormalBlending", 1), ("b_iNormalBlendingEnableMask2", 1),
    ("b_iBlurEnvironmentMap", 1), ("b_iEnvioMultipliers", 1),
]
# MRT block: b_emitMRTSpecular anchored at bit 1153 (idx 5) => base 1148, forward.
MRT_BASE = 1148
MRT_AXES = ["b_emitFinalColor", "b_emitAlpha", "b_emitMRTDepth", "b_emitMRTNormal",
            "b_emitMRTDiffuse", "b_emitMRTSpecular", "b_emitMRTSpecularPower",
            "b_emitMRTAO", "b_blendMRTNormals"]


def decode_material_globals(vec):
    out, off = {}, 0
    for name, w in MAT_GLOBALS:
        out[name] = kd.field(vec, MAT_GLOBAL_BASE + off, w)
        off += w
    return out


def decode_mrt(vec):
    return {name: kd.bit(vec, MRT_BASE + i) for i, name in enumerate(MRT_AXES)}
