"""Decode a retail DefaultPixelMain permutation key into its full `b_*` vector.

This closes the loop opened by sc2_ps_decode.py: instead of anchoring one section
at a time, it uses the *complete* family layout recovered from the macOS client:

  * The DefaultPixelMain families (Model / Particle / Ribbon, section-id 1/2/3)
    each reserve an 88-bit header, pack their own axes, then append a FIXED list
    of shared sub-sections to `+776` (via PermSchema_AddSubSections @0x102B5A950
    followed by two direct appends).  The order is identical across the three:

        Common Material Lighting Displacement VectorUI Volume
        MRT TerrainDoodad FOW Reflection Cloaking MainShading VertexWarp

  * PermSchema_FinalizeLayout (@0x102B8C430) then bit-packs every axis
    forward-cumulative by width; the stored cache key is that bitstream (after
    RLE decode by sc2_cache.decode_key).

Section bases are pinned to values *validated* against the 47,708 real (vec,glsl)
pairs from the GL baseline cache (Material@149, Lighting@898, MRT@1148 are
bit-exact; Common@137 and MainShading@1746 anchored the same way).  Sections
between anchors are chained by width; the ANCHORS override the chain so accumulated
width error in the rarely-used vertex-side sub-sections cannot shift a pinned base.

Names/widths come straight from the section builders (sc2_schema_widths.json,
regenerated from PermSchema_RegisterAxis cardinalities: width = card.bit_length()).
"""
import json
import os

import sc2_key_decode as kd

HERE = os.path.dirname(os.path.abspath(__file__))
_SCHEMA = json.load(open(os.path.join(HERE, "sc2_schema_widths.json")))
_BYNAME = {}
for _v in _SCHEMA.values():
    _BYNAME.setdefault(_v.get("name") or "?", _v["axes"])

# Fixed sub-section order for the Model/Particle/Ribbon DefaultPixelMain families
# (recovered from PermSchema_AddSubSections @0x102B5A950 + the two family appends).
SECTION_ORDER = [
    "Common", "Material", "Lighting", "Displacement", "VectorUI", "Volume",
    "MRT", "TerrainDoodad", "FOW", "Reflection", "Cloaking", "MainShading",
    "VertexWarp",
]

# Absolute bit bases pinned by correlation against the GL cache.  Material,
# Lighting and MRT are bit-exact over 47,708 pairs; Common and MainShading are
# anchored the same way (MainShading via the b_iShadingMode 4-bit enum, values 0-8).
ANCHOR = {
    "Common": 137,
    "Material": 149,
    "Lighting": 898,
    "MRT": 1148,
    # MainShading is embedded at the FAMILY FRONT (its object is the key's first state
    # block), so its axes land right after the 88-bit header, ~bit 89 — NOT at a tail
    # sub-section.  Confirmed in IDA: b_hasNormals/b_iLayoutHasColor/b_iUVCoordCount are
    # registered only by BuildMainShadingSection, which is embedded at the family base.
    "MainShading": 89,
}

# Sub-sections whose base is directly pinned (safe to trust their whole decode).
# The others are chained from the nearest preceding anchor and are only reliable
# when zero (their common value on model pixel shaders).
ANCHORED_SECTIONS = set(ANCHOR)

# Reliability tiers (measured vs 12,000 real GL pairs):
#   Material  layers  : LayerEnable agrees 0.87-1.0 with sampler presence (a lower
#                       bound - constant-colour layers legitimately have no sampler);
#                       per-layer Op/UV/Channel validated bit-exact in prior work.
#   Material  globals : b_iNormalBlending 0.998, etc.
#   MRT               : b_emitMRTSpecular 0.994 (base 1148 confirmed).
# These are the ~350 axes that drive DefaultPixelMain's colour output and that the
# oracle search fundamentally cannot recover.  The structural single-bit sections
# (Lighting/MainShading/Common bases) are located to +-a few bits only - PS
# observables drift ~5 bits (lit-feature correlation) and the deterministic width
# chain carries residual error from helper-registered layer sub-groups in the
# vertex-side sections - so treat their per-bit output as provisional.
RELIABLE_SECTIONS = {"Material", "MRT"}


def _section_width(name):
    return sum(w for _, w in _BYNAME[name])


def section_bases():
    """{section: absolute_bit_base} — anchors win, gaps chained by width."""
    bases, pos = {}, None
    for s in SECTION_ORDER:
        if s in ANCHOR:
            pos = ANCHOR[s]
        bases[s] = pos
        pos = None if pos is None else pos + _section_width(s)
    return bases


# ---------------------------------------------------------------------------
# Family header / vertex-transport layout block.
#
# Between the 88-bit key header and the first shared sub-section (Common@137) the
# family object packs its own vertex-transport / interpolant-layout axes
# (b_iLayoutHasColor@89, b_hasNormals@98, and the UV-coord / signed-UV / alpha-test
# fields through ~136).  These control the PS *input signature*, so retail compiles
# a distinct shader for each combination — but the oracle map ignored them, which is
# where ~66% of the previously-collapsed keys hid (bit 135 alone split 1006 pairs).
#
# Bits 76..103 are the schema hash / interp id (constant per family -> noise).
# RESOLVED IN IDA (session 7c7fa883): this front block IS the MainShading section -
# b_hasNormals/b_iLayoutHasColor/b_iUVCoordCount are registered ONLY by
# BuildMainShadingSection, whose object is embedded at the family base (it is the key's
# first state block, see FinalizeMaterialShaderState/BuildShaderPermutationKey).  So
# MainShading is decoded by NAME at base 89 (ANCHOR above), ~89..106.  The residual
# family-layout bits 106..137 (incl. alpha-test @135, the single biggest splitter at
# 1006 pairs) still distinguish permutations and are decoded opaquely.  A recover/split
# sweep vs the 47,708 GL pairs pinned the [106,137) window (no same-shader over-split).
HEADER_LAYOUT_RANGE = (106, 137)
HEADER_NAMED = {}

# Residual tail: the Cloaking / VertexWarp region (~1735-1785) is a few bits off from
# the chained bases (helper-registered layer sub-groups widen those sections), so a
# handful of cloak/vertex-warp permutations still collapse.  Decoded as opaque bits
# until the exact section widths are pinned in IDA.
HEADER_TAIL_RANGE = (1600, 1785)
# A few individual feature-mask bits below the 104 cutoff that also distinguish
# permutations (bit 33 alone splits 41 otherwise-collapsed keys) while sitting
# clear of the 76-103 hash/interp noise band.
HEADER_LOW_BITS = (33, 43, 59, 68)


def decode(vec, only_anchored=False, reliable_only=False, with_header=True):
    """Decode every axis of every section into {b_name: value}.

    only_anchored=True restricts output to the base-pinned sub-sections
    (Common/Material/Lighting/MRT/MainShading).
    reliable_only=True restricts to the bit-exact-validated sub-sections
    (Material + MRT) — the ~350 axes safe to feed a compile verbatim.
    with_header=True also decodes the family vertex-transport layout block, which
    the retail engine uses to distinguish permutations (needed to reproduce the
    full retail permutation set); disable it to get just the named sections.
    """
    bases = section_bases()
    out = {}
    for s in SECTION_ORDER:
        base = bases[s]
        if base is None:
            continue
        if reliable_only and s not in RELIABLE_SECTIONS:
            continue
        if only_anchored and s not in ANCHORED_SECTIONS:
            continue
        off = 0
        for name, w in _BYNAME[s]:
            out[name] = kd.field(vec, base + off, w)
            off += w
    if with_header and not reliable_only:
        lo, hi = HEADER_LAYOUT_RANGE
        for b in range(lo, hi):
            out[HEADER_NAMED.get(b, "_familyLayout_%d" % b)] = kd.bit(vec, b)
        for b in HEADER_LOW_BITS:
            out["_featureMask_%d" % b] = kd.bit(vec, b)
        lo, hi = HEADER_TAIL_RANGE
        nbits = len(vec) * 8
        for b in range(lo, min(hi, nbits)):
            out["_tail_%d" % b] = kd.bit(vec, b)
    return out


def decode_key(key, only_anchored=False, reliable_only=False):
    """Raw retail cache key (bytes) -> {b_name: value}."""
    import sc2_cache
    _, vec = sc2_cache.decode_key(key)
    return decode(vec, only_anchored=only_anchored, reliable_only=reliable_only)


# ---------------------------------------------------------------------------
# Semantic family classification.
#
# Bytes 8..11 of the decoded vec are the family SCHEMA HASH (ComputeSchemaHash,
# PermSchema_ComputeSchemaHash @0x102B8C8A0): a per-family constant that identifies
# which shader family/entry a permutation key belongs to.  Recovered from the Metal
# baselinecache's MTLB `NAME` records (`<Family><hash>_<Entry>_<profile>`), which are
# byte-for-byte the same permutation keys as the opengl3 cache — so this map lets us
# split the opengl3 keys (whose GLSL is stripped/renamed) into their real families.
#
# Cross-CONFIRMED by the decode itself: b_iShadingMode (MainShading@89) is constant
# per family and equals the family's shading-mode enum — Model=0, Ribbon=1,
# SplatDeferred=2, Particle=5, SplatDirect=6, Foliage=7, TerrainBlend=13.  That the
# front-block decode reads one clean value across every key of a family is independent
# evidence the MainShading base is correct for all families, not just Model.
FAMILY_BY_HASH = {
    b"\x01\x1d\x0c\xc0": ("Model", "DefaultPixelMain", "ps_4_0"),
    b"\x02\x21\xd0\x8b": ("Particle", "DefaultPixelMain", "ps_4_0"),
    b"\x03\xea\xba\x02": ("Ribbon", "DefaultPixelMain", "ps_4_0"),
    b"\x0a\xca\x74\x6c": ("SplatDirect", "SplatDirectPixelMain", "ps_4_0"),
    b"\x04\x9a\xee\x72": ("Image", "ImagePixelMain", "ps_4_0"),
    b"\x06\xdf\x0a\xfb": ("PostProcessQuad", "PostProcessQuadPixelMain", "ps_4_0"),
    b"\x18\x5f\x5e\xe4": ("SplatDeferred", "SplatDeferredPixelMain", "ps_4_0"),
    b"\x0b\xfb\xee\xaf": ("Foliage", "DefaultPixelMain", "ps_4_0"),
    b"\x05\x1b\x0c\x95": ("HDR", "HDRPixelMain", "ps_4_0"),
    b"\x07\xdd\xee\x1e": ("DeferredLight", "DeferredLightPixelMain", "ps_4_0"),
    b"\x0c\x18\x53\xdc": ("Water", "WaterPixelMain", "ps_4_0"),
    b"\x12\x87\xae\xfb": ("TerrainBlend", "TerrainBlendPixelMain", "ps_4_0"),
    b"\x17\x4e\x55\xfb": ("Bokeh", "BokehPixelMain", "ps_4_0"),
    b"\x0e\x04\x69\x24": ("Flash", "FlashPixelMain", "ps_4_0"),
    b"\x16\x8b\x62\x6e": ("LensFlare", "LensFlarePixelMain", "ps_4_0"),
    b"\x15\x74\x66\xfb": ("Simple", "SimplePixelMain", "ps_4_0"),
    b"\x10\xe8\xb2\x56": ("MinimapTerrain", "MinimapTerrainPixelMain", "ps_4_0"),
    b"\x14\x13\xb2\x56": ("RenderPlane", "RenderPlanePixelMain", "ps_4_0"),
}


def family_of(vec):
    """(family, entry, profile) for a decoded vec, or None if its schema hash is
    unknown.  Uses bytes 8..11 (the family schema hash)."""
    if len(vec) < 12:
        return None
    return FAMILY_BY_HASH.get(bytes(vec[8:12]))


def _gl_cache_path():
    return os.path.join(os.path.dirname(HERE), "mods", "core.sc2mod",
                        "base.sc2data", "versions", "macshaders41359",
                        "opengl3", "baselinecache.bin")


def iter_ps_vecs(gl_cache=None):
    """Yield (family_tuple, vec) for every pixel-shader permutation key in the
    opengl3 baselinecache, classified by its family schema hash.

    Unlike sc2_ps_decode.vec_glsl_pairs this reads ONLY the key table (payload2)
    and never extracts a GLSL blob, so it is fast; the family hash alone selects
    exactly the same PS permutations (the out_cColor blobs) the GLSL filter did.
    """
    import struct
    import sc2_cache
    D = open(gl_cache or _gl_cache_path(), "rb").read()
    p2o = struct.unpack("<I", D[0x28:0x2c])[0]
    p2s = struct.unpack("<I", D[0x2c:0x30])[0]
    pos, end = p2o, p2o + p2s
    while pos < end:
        d0 = struct.unpack("<I", D[pos:pos + 4])[0]
        ks = d0 & 0xFF
        key = D[pos + 12:pos + 12 + ks]
        _, vec = sc2_cache.decode_key(key)
        fam = family_of(vec)
        if fam is not None and fam[2].startswith("ps"):
            yield fam, vec
        pos += 12 + ks


if __name__ == "__main__":
    # Self-check: report section bases and validate anchored bit positions
    b = section_bases()
    print("section bases (bit):")
    for s in SECTION_ORDER:
        w = _section_width(s)
        tag = " [anchor]" if s in ANCHOR else ""
        print("  %-14s base=%s width=%d%s" % (s, b[s], w, tag))
