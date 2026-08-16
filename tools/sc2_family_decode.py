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


def _decode_simple_vs(vec):
    # SimpleVertexMain has no compile-time axis.
    return ({}, [])


# (family, stage) -> callable(vec) -> (b_values, live)
_SCHEMAS = {
    ("Simple", "ps"): _decode_simple_ps,
    ("Simple", "vs"): _decode_simple_vs,
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


def decode_perm(family, stage, vec):
    """Unified (b_values, live) for any decodable (family, stage), else None.

    Dispatches: per-family schema (Simple, ...) first, then the shared
    DefaultPixelMain PS decode for the four Default families.  This is the single
    decode entry point the manifest and the drivers both go through, so storage
    can stay compact (key only) and (bv, live) is recovered from the key on
    demand — essential for Model PS (~50k perms × ~780 axes would be gigabytes if
    materialised)."""
    r = decode_family(family, stage, vec)
    if r is not None:
        return r
    if stage == "ps" and family in DEFAULT_PS_FAMILIES:
        import sc2_model_key_decode as K
        allb, known = _default_ps_ctx()
        bv, live = K.decode_ps(vec, allb, known)
        return bv, sorted(live)
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
