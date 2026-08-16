"""Decode an SC2 permutation key (decoded `vec`) into its exact `b_*` state.

Schema recovered from the client's constant-registration string table
(tools/sc2_schema_names.json) + validated against the retail GLSL:

  vec layout (bit granularity, LSB-first within each decoded byte):
    bits  0-31 : header  [0,0][vs_ver][ps_ver] and reserved
    bits 32-59 : interpolant liveness mask (bit 32+k = interpolant[k]), FORWARD order
    bytes 8-12 : family hash
    per-section b_* blocks: each section is packed CONTIGUOUS in REVERSE
                 registration order (higher registration index -> lower bit),
                 each axis `width = ceil(log2(cardinality))` bits.

A "section" is a contiguous run of `b_*` in the registration table (e.g. the
MRT block, the MainShading layout block, the big material/lighting key block,
the per-family blocks).  For a given family we anchor each section by one axis
whose value is directly observable in the GLSL, then decode the rest by the
reverse-order + width rule.

This module provides the primitives; per-family section anchors live in
`SECTIONS`.  `decode(vec, family)` returns `{b_axis: value}` for the active set.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = json.load(open(os.path.join(HERE, "sc2_schema_names.json")))
INTERPOLANTS = SCHEMA["interpolants"]          # 28, mask order
KEY_BLOCK = SCHEMA["key_block"]                # 655 axes, registration order


def bit(vec, b):
    byi, bii = b // 8, b % 8
    return (vec[byi] >> bii) & 1 if byi < len(vec) else 0


def field(vec, start, width):
    """Little-endian integer from `width` bits starting at bit `start`."""
    return sum(bit(vec, start + i) << i for i in range(width))


def decode_mask(vec, base=32):
    """The interpolant liveness set (forward order from `base`)."""
    return {INTERPOLANTS[k] for k in range(len(INTERPOLANTS))
            if bit(vec, base + k)}


def decode_section(vec, axes, widths, top_bit):
    """Decode a section packed in REVERSE registration order.

    `axes` is the section's axis-name list in ascending registration order.
    The last-registered axis occupies the lowest bits; `top_bit` is the highest
    bit of the first-registered axis.  Returns {axis: value}."""
    # walk registration order high->low bit: first axis gets the top slot
    out = {}
    b = top_bit
    for name in axes:
        w = widths.get(name, 1)
        b -= (w - 1)
        out[name] = field(vec, b, w)
        b -= 1
    return out


# Exact per-axis bit widths recovered from the client's schema-registration code
# (sub_102B8D1C0: width = cardinality.bit_length()).  Loaded from
# tools/sc2_schema_widths.json, which the IDA extractor writes with one entry per
# registered axis.  These REPLACE the earlier guessed widths (e.g. b_iShadingMode
# is 4 bits, not 3; b_iBlendWeightCount card=5 -> 3; b_iUVEmitterCount card=8 -> 4).
_WIDTHS = {}
try:
    _sw = json.load(open(os.path.join(HERE, "sc2_schema_widths.json")))
    for _sec in _sw.values():
        for _entry in _sec.get("axes", []):
            _WIDTHS[_entry[0]] = _entry[1]      # [name, width] (+ optional cardinality)
except (OSError, ValueError, IndexError):
    pass

# fallback widths for the per-layer material props (loop-registered; not yet in
# the JSON) — from the SLayerConfig enum cardinalities in the .fx
_LAYER_PROP_WIDTH = {
    "UVMapping": 5, "TeamColorMode": 2, "ChannelSelect": 3, "TextureType": 2,
    "FresnelMode": 2, "FresnelTransformMode": 2, "Op": 3, "LayerId": 5,
    "UVEmitter": 4, "TriPlanarUvId": 5,
}
# back-compat alias
ENUM_WIDTH = _WIDTHS


def axis_width(name):
    if name in _WIDTHS:                 # exact, from the client
        return _WIDTHS[name]
    for suf, w in _LAYER_PROP_WIDTH.items():
        if name.endswith(suf) and name.startswith("b_i"):
            return w
    return 1
