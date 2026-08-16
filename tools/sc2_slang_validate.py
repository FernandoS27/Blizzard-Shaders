"""Behavioral validation harness: original SC2 `.fx` (fxc, the D3D11 *reference*)
vs a slang port (slangc, the D3D11 *candidate*), compared through `dxbc_interp`
on identical random inputs.

Both sides compile to the SAME target — `ps_5_0` / `vs_5_0` DXBC — so the
comparison is entirely within our own toolchain (no Blizzard-fxc drift to fight,
unlike the retail SM3 path).  Alignment:
  * constants  — by cbuffer reflection **name** (fxc and slangc both emit RDEF
                 field names; a value is drawn once per name and written into
                 each side's cbuffer at that side's own offset).
  * inputs     — by input-signature (semantic, index): a varying gets one shared
                 random vec4 regardless of which register each side placed it in.
  * textures   — by resource name -> one shared smooth stand-in field (RemapTex).
  * outputs    — by SV_Target index; LDR targets clamped to UNORM8 before diffing.

Legs:
  reference : sc2_behav_match.compile_native_ps / compile_native_vs  (fxc /Gec)
  candidate : compile_all_slang.invoke_slangc -> .dxbc -> fxc /dumpbin -> .asm
  compare   : compare_d3d11(ref_asm, cand_asm, ...)

Until real SC2 slang exists, `--self-test` proves the comparator is sound by
running a reference permutation against ITSELF (worst must be exactly 0) and,
if a slang file is given, exercises the slangc leg mechanically.
"""
import os
import re
import sys
import random
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dxbc_interp as di
import sc2_behav_match as bm
import sc2_compile_perms as h

REPO_ROOT = os.path.dirname(HERE)


# ---------------------------------------------------------------------------
# shared texture model — each side's slot -> one shared id per logical name
# ---------------------------------------------------------------------------
class RemapTex(di.TextureModel):
    def __init__(self, slot2id):
        self.slot2id = slot2id

    def _id(self, slot):
        return self.slot2id.get(slot, slot + 1000)

    def sample(self, slot, coords):
        return super().sample(self._id(slot), coords)

    def sample_lod(self, slot, coords, lod):
        return super().sample_lod(self._id(slot), coords, lod)

    def sample_compare(self, slot, coords, ref):
        return super().sample_compare(self._id(slot), coords, ref)

    def lod(self, slot, coords):
        return super().lod(self._id(slot), coords)


def _sat(x):
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)


# ---------------------------------------------------------------------------
# candidate leg: slang -> dxbc -> fxc /dumpbin -> fxc-format disassembly
# ---------------------------------------------------------------------------
def disasm_dxbc(dxbc_path, asm_path):
    """fxc /dumpbin -> the same disassembly format dxbc_interp.Program parses.

    Works on ANY DXBC container (fxc- or slangc-produced), so both legs feed
    the interpreter through one parser."""
    if os.path.exists(asm_path):
        os.remove(asm_path)
    subprocess.run([h.FXC, "/nologo", "/dumpbin", "/Fc", asm_path, dxbc_path],
                   capture_output=True, text=True)
    if not os.path.exists(asm_path):
        return None
    return open(asm_path, encoding="latin1").read()


def compile_slang(slang_file, entry, stage, defines, tmp_path,
                  include_dirs=None, specialize=()):
    """Compile a slang entry to ps_5_0/vs_5_0 DXBC, return fxc-format asm.

    `defines` is a list of "NAME=val" permutation defines (same axes as the
    original's b_* set).  Returns (asm, None) or (None, [errors])."""
    if REPO_ROOT not in sys.path:
        sys.path.insert(0, REPO_ROOT)
    import compile_all_slang as cas
    from pathlib import Path
    profile = {"ps": "ps_5_0", "vs": "vs_5_0"}[stage]
    inc = [Path(d) for d in (include_dirs or [os.path.join(REPO_ROOT, "wc3_shaders")])]
    dxbc = tmp_path + ".dxbc"
    ok = cas.invoke_slangc(entry, "dxbc", profile, list(specialize),
                           Path(dxbc), Path(slang_file),
                           include_dirs=inc, defines=list(defines))
    if not ok or not os.path.exists(dxbc):
        return None, ["slangc failed for %s entry=%s" % (slang_file, entry)]
    asm = disasm_dxbc(dxbc, tmp_path + ".asm")
    if asm is None:
        return None, ["fxc /dumpbin failed on %s" % dxbc]
    return asm, None


# ---------------------------------------------------------------------------
# reference leg: original .fx -> ps_5_0/vs_5_0 (fxc), returns asm
# ---------------------------------------------------------------------------
def compile_reference(entry_file, entry, stage, b_values, live, tmp_path,
                      uv_mappings=None):
    if stage == "ps":
        return bm.compile_native_ps(entry_file, entry, b_values, live, tmp_path,
                                    uv_mappings=uv_mappings)
    return bm.compile_native_vs(entry_file, entry, b_values, live, tmp_path,
                                uv_mappings=uv_mappings)


# ---------------------------------------------------------------------------
# comparator
# ---------------------------------------------------------------------------
def _target_regs(asm):
    """reg -> SV_Target index."""
    out = {}
    for reg, (sem, idx) in bm.parse_outsig(asm).items():
        if sem in ("SV_Target", "SV_TARGET", "COLOR"):
            out[reg] = idx
    return out


def _in_keys(asm):
    """input reg -> a stable cross-shader key ('HPos', 'FRONTFACE', or (sem,idx))."""
    out = {}
    for reg, (sem, idx) in bm.parse_insig(asm).items():
        if sem in ("SV_Position", "SV_POSITION"):
            out[reg] = "HPos"
        elif sem in ("SV_IsFrontFace", "SV_ISFRONTFACE"):
            out[reg] = "FRONTFACE"
        else:
            out[reg] = (sem, idx)
    return out


def _texmap(ref_asm, cand_asm):
    r_tex, _ = bm.parse_resources(ref_asm)
    c_tex, _ = bm.parse_resources(cand_asm)
    names = sorted(set(r_tex) | set(c_tex))
    ids = {n: i for i, n in enumerate(names)}
    return (RemapTex({slot: ids[n] for n, slot in r_tex.items()}),
            RemapTex({slot: ids[n] for n, slot in c_tex.items()}))


def compare_d3d11(ref_asm, cand_asm, *, trials=8, seed=0, name_map=None):
    """Per-SV_Target max abs diff between the fxc reference and slangc candidate.

    `name_map` optionally maps candidate cbuffer/resource canon-names to the
    reference's (for when the slang port renames a uniform); default identity.
    Returns ({target_index: worst_abs_diff}, None) or (None, error_string)."""
    nm = name_map or {}

    def cn(n):
        return nm.get(n, n)

    rp = di.Program.from_text(ref_asm)
    cp = di.Program.from_text(cand_asm)

    r_in, c_in = _in_keys(ref_asm), _in_keys(cand_asm)
    r_cb, c_cb = bm.parse_cb(ref_asm), bm.parse_cb(cand_asm)
    r_tgt, c_tgt = _target_regs(ref_asm), _target_regs(cand_asm)
    r_by_t = {t: reg for reg, t in r_tgt.items()}
    c_by_t = {t: reg for reg, t in c_tgt.items()}
    shared_t = sorted(set(r_by_t) & set(c_by_t))
    if not shared_t:
        return None, "no shared SV_Target"
    r_nc, c_nc = bm.out_ncomp(ref_asm), bm.out_ncomp(cand_asm)
    r_tex, c_tex = _texmap(ref_asm, cand_asm)
    rng = random.Random(seed)
    diffs = {t: 0.0 for t in shared_t}

    for _ in range(trials):
        # one shared random vec4 per input key and per constant name
        keys = set(v for v in r_in.values()) | set(v for v in c_in.values())
        vals = {}
        for k in keys:
            if k == "HPos":
                vals[k] = [rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0, 1), 1.0]
            elif k == "FRONTFACE":
                vals[k] = None
            else:
                vals[k] = [rng.uniform(-1, 1) for _ in range(4)]
        cbvals = {}
        for n, o, s in r_cb:
            cbvals.setdefault(n, [rng.uniform(-1, 1) for _ in range(max(1, s // 4))])
        for n, o, s in c_cb:  # ensure candidate-only names still get a value
            cbvals.setdefault(cn(n), [rng.uniform(-1, 1) for _ in range(max(1, s // 4))])

        def mk_in(regmap):
            out = {}
            for reg, k in regmap.items():
                if k == "FRONTFACE":
                    out[reg] = [0xFFFFFFFF] * 4
                else:
                    out[reg] = [bm._f2b(x) for x in vals[k]]
            return out

        def mk_cb(cb_list, asm, rename):
            cb = [[0, 0, 0, 0] for _ in range(bm.cb_rows(asm))]
            for n, o, s in cb_list:
                key = rename(n)
                if key in cbvals:
                    bm.cb_write(cb, o, cbvals[key])
            return cb

        r_i, c_i = mk_in(r_in), mk_in(c_in)
        r_cbv = mk_cb(r_cb, ref_asm, lambda n: n)
        c_cbv = mk_cb(c_cb, cand_asm, cn)
        try:
            ro = di.execute(rp, r_i, {0: r_cbv}, texture=r_tex, max_loop=4096)
            co = di.execute(cp, c_i, {0: c_cbv}, texture=c_tex, max_loop=4096)
        except Exception as e:
            return None, "exec: " + str(e)[:160]
        for t in shared_t:
            rr, cr = r_by_t[t], c_by_t[t]
            nc = min(r_nc.get(rr, 4), c_nc.get(cr, 4))
            for l in range(nc):
                a, b = ro.f(rr, l), co.f(cr, l)
                an, bn = (a == a), (b == b)
                if an and bn:
                    d = abs(_sat(a) - _sat(b))
                elif an != bn:
                    d = 1.0
                else:
                    d = 0.0
                diffs[t] = max(diffs[t], d)
    return diffs, None


# ---------------------------------------------------------------------------
# self-test: identity (ref vs ref -> 0) + optional slangc leg smoke
# ---------------------------------------------------------------------------
_MODEL_40 = ("40000000030bda290200011d0cc085ff045040040400012920ff050404000960ff"
             "1904502129ff0604140009ff030120ff2092dbb266ff1dde80ff07c0ff2f0800"
             "11ff080100000001000814")


def _self_test(slang_file=None, slang_entry=None):
    import sc2_d3d_decode as D, sc2_cache, sc2_model_key_decode as K, sc2_interp as ip
    all_b, _ = h.scan_b_tokens(h.SRC + r"\model.fx")
    KNOWN = set(ip.INTERP_DIM) | set(ip.ARRAY_INTERP) | set(ip.SPECIAL_READS)
    scratch = os.environ.get("SC2_SCRATCH", os.path.join(HERE, "_slang_tmp"))
    os.makedirs(scratch, exist_ok=True)
    cache = D.D3DCache(); _d, _v, recs = sc2_cache.parse_cache(D.D3D_CACHE)
    r = next(r for r in recs if r["key"] == bytes.fromhex(_MODEL_40))
    (_a, _b), vec = sc2_cache.decode_key(r["key"])
    bv, live = K.decode_ps(vec, all_b, KNOWN)
    ref, err = compile_reference(h.SRC + r"\model.fx", "DefaultPixelMain", "ps",
                                 bv, live, os.path.join(scratch, "ref.fx"))
    if ref is None:
        print("REFERENCE COMPILE FAILED:", err); return 1
    print("reference: ps_5_0 OK  (%d instrs)" % len(di.Program.from_text(ref).insns))
    diffs, cerr = compare_d3d11(ref, ref, trials=8)
    if cerr:
        print("IDENTITY COMPARE ERROR:", cerr); return 1
    worst = max(diffs.values())
    print("identity (ref vs ref): per-target=%s  worst=%.6g  %s" %
          ({t: round(v, 6) for t, v in diffs.items()}, worst,
           "PASS" if worst == 0.0 else "FAIL"))
    rc = 0 if worst == 0.0 else 1
    if slang_file:
        casm, e2 = compile_slang(slang_file, slang_entry or "main", "ps", [],
                                 os.path.join(scratch, "cand"))
        if casm is None:
            print("slangc leg: FAILED -", e2)
        else:
            p = di.Program.from_text(casm)
            print("slangc leg: %s -> %s OK  (model=%s, %d instrs)" %
                  (os.path.basename(slang_file), slang_entry, p.model, len(p.insns)))
    return rc


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="slang<->original D3D11 validation harness")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--slang", help="optional .slang file to exercise the slangc leg")
    ap.add_argument("--entry", default="main")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(_self_test(args.slang, args.entry))
    ap.print_help()
