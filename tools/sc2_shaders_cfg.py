#!/usr/bin/env python3
"""Shared config + manifest access for the sc2_shaders pipeline.

One place for the three sc2_shaders driver tools (validator / slang-compiler /
BLS bundler) to resolve:
  * the family table (sc2_shaders.json: fx file + per-stage fx/slang entries),
  * each (family, stage) permutation manifest (sc2_perms/<Family>_<stage>.json,
    the cache-order slot list with decoded (bv, live) — see sc2_perm_manifest),
  * the b_* -> slangc `-D` define convention (nonzero axes only, mirroring
    wc3_shaders' `-DFLAG=1`-when-on pattern; the `#if b_*` gate reads absent as 0).
"""
import os
import sys
import json

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import sc2_compile_perms as _cp

SC2_CONFIG = os.path.join(REPO_ROOT, "sc2_shaders.json")
SC2_MODULE = os.path.join(REPO_ROOT, "sc2_shaders", "sc2_shaders.slang")
SC2_INCLUDE = os.path.join(REPO_ROOT, "sc2_shaders")
PERMS_DIR = os.path.join(REPO_ROOT, "sc2_perms")
FX_SRC = _cp.SRC            # mods/.../shaders


def load_families():
    """{family: {fx, vs:{fx_entry,slang_entry,...}, ps:{...}}}."""
    with open(SC2_CONFIG) as fp:
        return json.load(fp)["families"]


def family_cfg(family):
    fams = load_families()
    if family not in fams:
        raise KeyError("family %r not in %s (have: %s)"
                       % (family, SC2_CONFIG, ", ".join(sorted(fams))))
    return fams[family]


def fx_path(family):
    return os.path.join(FX_SRC, family_cfg(family)["fx"])


def read_manifest(family, stage):
    """The cache-order permutation manifest for (family, stage), or None."""
    path = os.path.join(PERMS_DIR, "%s_%s.json" % (family, stage))
    if not os.path.exists(path):
        return None
    return json.load(open(path))


def bv_to_defines(bv):
    """slangc `-D` list for a decoded b_* vector: `NAME=value` for every nonzero
    axis (the `#if NAME` / `NAME`-valued gates read an absent define as 0, so
    zero axes are omitted — matches wc3_shaders' convention)."""
    return ["%s=%d" % (k, int(v)) for k, v in sorted(bv.items()) if int(v)]


def interp_defines(live, bv):
    """slangc `-D` list describing the live interpolant transport for the shared-
    interpolant (DefaultPixelMain) families.

    Mirrors sc2_interp.gen_preamble's PS packing EXACTLY so the slang candidate's
    VS->PS interpolant register assignment matches the fxc reference's: the live
    scalar interpolants (INTERP_DIM) are sorted by name and assigned TEXCOORD0,1,2…
    in that order; the per-emitter UV array (if live) follows at the next TEXCOORD,
    sized like gen_preamble (max(1, UV emitter count)).  For each we emit
    `SC2_HAS_<name>=1` (presence gate) and `SC2_SEM_<name>=TEXCOORD<i>` (the exact
    semantic, passed whole so the slang struct needs no token-pasting); UV also
    gets `SC2_UV_COUNT`.  FrontFace/specials are added as the transcription reaches
    the features that use them."""
    import sc2_interp as ip
    scal = sorted(n for n in live if n in ip.INTERP_DIM)
    defs = []
    for i, n in enumerate(scal):
        defs += ["SC2_HAS_%s=1" % n, "SC2_SEM_%s=TEXCOORD%d" % (n, i)]
    if "UV" in live:
        uvc = max(1, ip._uv_count(bv))
        defs += ["SC2_HAS_UV=1", "SC2_SEM_UV=TEXCOORD%d" % len(scal),
                 "SC2_UV_COUNT=%d" % uvc]
    # SV_IsFrontFace is a system-value input (no TEXCOORD slot), so it's gated
    # independently of the scalar packing.  gen_preamble: FrontFace live ->
    # INTERPOLANT_FrontFace = vertOut.FrontFace; else the safety-net `true`.
    if "FrontFace" in live:
        defs.append("SC2_HAS_FrontFace=1")
    return defs


# Families whose PS uses the shared DefaultPixelMain interpolant transport.
_SHARED_TRANSPORT = {"Model", "Particle", "Ribbon", "Foliage"}


def perm_defines(family, stage, bv, live):
    """Full slangc `-D` set for one permutation slot: the b_* axes, plus the
    interpolant-transport defines for the shared-transport families' pixel
    shaders."""
    defs = bv_to_defines(bv)
    if stage == "ps" and family in _SHARED_TRANSPORT:
        defs += interp_defines(live, bv)
    return defs


def iter_slots(family, stage):
    """Yield (slot, bv, live, dedup) per manifest slot in cache order.

    (bv, live) is decoded from each slot's stored KEY on demand (sc2_family_decode
    .decode_perm) rather than read from the manifest — the manifest stores compact
    keys for the big Default families, so this is the one path that scales from
    Simple (7) to Model (~50k).  Raises if the family's schema is unnamed so a
    half-decoded family fails loudly rather than validating the wrong define set."""
    import sc2_cache
    import sc2_family_decode as fd
    man = read_manifest(family, stage)
    if man is None:
        raise FileNotFoundError(
            "no manifest for %s %s (run sc2_perm_manifest.py --family %s)"
            % (family, stage, family))
    if not man.get("decoded"):
        raise ValueError(
            "%s %s manifest is not decoded (schema unnamed in sc2_family_decode)"
            % (family, stage))
    for p in man["perms"]:
        _, vec = sc2_cache.decode_key(bytes.fromhex(p["key"]))
        r = fd.decode_perm(family, stage, vec)
        if r is None:
            raise ValueError("%s %s slot %d failed to decode"
                             % (family, stage, p["slot"]))
        bv, live = r
        yield p["slot"], bv, list(live), int(p.get("dedup", 0))
