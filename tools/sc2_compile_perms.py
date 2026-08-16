"""Compile SC2 `.fx` shader permutation groups to D3D11 bytecode (ps_5_0 / vs_5_0).

The SC2 engine compiles each `.fx` entry point (a "family") many times, once per
`b_*` compile-time feature vector (a "permutation"), constant-folding the `b_*`
switches into a flat, feature-specific shader.  This tool reproduces that: for a
family it enumerates its permutations, emits the `#define b_* <value>` block the
engine would inject (plus, for the shared-interpolant families, the engine's
`VertexTransport` / `InitShader` machinery), and drives `fxc` to emit real DXBC.

Retail shaders are `ps_4_0` / `vs_4_0` with legacy `COLOR`/`POSITION` semantics
and are compiled with the D3D backwards-compat flag; we target SM5 (`ps_5_0` /
`vs_5_0`) with `/Gec` (D3DCOMPILE_ENABLE_BACKWARDS_COMPATIBILITY), which accepts
those legacy semantics.

See docs/SC2_SHADER_FAMILIES.md for the family / axis catalogue.

Usage:
    python tools/sc2_compile_perms.py [--family NAME] [--list] [--jobs N]
"""
import argparse
import hashlib
import itertools
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sc2_interp

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "mods", "core.sc2mod", "base.sc2data", "shaders")
OUT_ROOT = os.path.join(HERE, "sc2_dxbc")


def find_fxc():
    import glob
    pats = [
        r"C:\Program Files (x86)\Windows Kits\10\bin\*\x64\fxc.exe",
        r"C:\Program Files (x86)\Windows Kits\8*\bin\x64\fxc.exe",
    ]
    hits = []
    for p in pats:
        hits += glob.glob(p)
    if not hits:
        sys.exit("fxc.exe not found (install the Windows SDK)")
    hits.sort()
    return hits[-1]


FXC = find_fxc()

# ---------------------------------------------------------------------------
# transitive #include resolution + b_* token scan
# ---------------------------------------------------------------------------
_INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
# a b_* token that is NOT immediately followed by '[' (array decls like
# `int b_iUVMapping[8]` are engine-filled arrays, not scalar #defines)
_BTOK_RE = re.compile(r'\bb_[A-Za-z_][A-Za-z0-9_]*')


def _resolve_include(name):
    # .fx includes are case-insensitive references into the shaders dir
    cand = os.path.join(SRC, name)
    if os.path.exists(cand):
        return cand
    low = name.lower()
    for f in os.listdir(SRC):
        if f.lower() == low:
            return os.path.join(SRC, f)
    return None


def transitive_sources(entry_file):
    """Return the set of .fx paths reachable from entry_file via #include."""
    seen = set()
    stack = [entry_file]
    while stack:
        f = stack.pop()
        if f in seen or f is None or not os.path.exists(f):
            continue
        seen.add(f)
        text = open(f, encoding="latin1").read()
        for inc in _INCLUDE_RE.findall(text):
            r = _resolve_include(inc)
            if r and r not in seen:
                stack.append(r)
    return seen


# HLSL type keywords that mark a b_* token as a *declaration* (a struct field or
# local variable — e.g. SLayerConfig's `int b_iUVMapping;`) rather than a global
# compile-time switch.  Such tokens must NOT be #defined.
_DECL_RE = re.compile(
    r'\b(?:bool|u?int[1-4]?|float[1-4]?(?:x[1-4])?|double|half|'
    r'HALF[2-4]?)\s+(b_[A-Za-z_][A-Za-z0-9_]*)')


def scan_b_tokens(entry_file):
    """All distinct b_* tokens referenced in the transitive include closure.

    Returns (define_tokens, decl_or_array_tokens).  A token is a *define* only if
    it is never used as a declaration (`<type> b_X`) or an array (`b_X[..]`):
    those are engine-populated per-instance fields / arrays (e.g. SLayerConfig
    fields, the InitShader-filled `b_iUVMapping[8]`), not global switches."""
    toks = set()
    nondef = set()   # declared as field/local, or subscripted array
    for f in transitive_sources(entry_file):
        text = open(f, encoding="latin1").read()
        for m in _BTOK_RE.finditer(text):
            tok = m.group(0)
            if text[m.end():m.end() + 1] == "[":
                nondef.add(tok)
            toks.add(tok)
        for m in _DECL_RE.finditer(text):
            nondef.add(m.group(1))
    toks.discard("b_i")
    return (toks - nondef), nondef


# ---------------------------------------------------------------------------
# family registry
# ---------------------------------------------------------------------------
# Each axis: (name, [values]).  Boolean axes are [0, 1]; enums list their range.
# mode: "selfcontained" families define their own VertexTransport and need no
# engine interpolant machinery (only a trivial InitShader/READ_INTERPOLANT stub).
B = [0, 1]
ENC = [0, 1, 2]

FAMILIES = {
    "TerrainBlend_VS": dict(
        file="terrainblend.fx", stage="vs", entry="TerrainBlendVertexMain",
        mode="selfcontained",
        axes=[("b_iTerrainBlendMode", list(range(9)))]),
    "TerrainBlend_PS": dict(
        file="terrainblend.fx", stage="ps", entry="TerrainBlendPixelMain",
        mode="selfcontained",
        axes=[("b_iTerrainBlendMode", list(range(9))),
              ("b_iTerrainDebugMode", B),
              ("b_iUnSwizzleDXNNormalMaps", B)]),
    "Bokeh_VS": dict(
        file="bokeh.fx", stage="vs", entry="BokehVertexMain",
        mode="selfcontained",
        axes=[("b_iBokehPass", list(range(7)))]),
    "Bokeh_PS": dict(
        file="bokeh.fx", stage="ps", entry="BokehPixelMain",
        mode="selfcontained",
        axes=[("b_iBokehPass", list(range(7))),
              ("b_emitMRTAO", B), ("b_emitMRTDepth", B), ("b_emitMRTDiffuse", B),
              ("b_emitMRTNormal", B), ("b_emitMRTSpecular", B),
              ("b_iInEncoding", ENC), ("b_iNormalizeDeffNormal", B),
              ("b_iOutEncoding", ENC)]),
    "NoiseQuad_VS": dict(
        file="noisequad.fx", stage="vs", entry="NoiseQuadVertexMain",
        mode="selfcontained",
        axes=[("b_normalGenerationPass", B), ("b_shadowGenerationPass", B)]),
    "NoiseQuad_PS": dict(
        file="noisequad.fx", stage="ps", entry="NoiseQuadPixelMain",
        mode="selfcontained",
        axes=[("b_hackPass", B), ("b_normalGenerationPass", B),
              ("b_shadowGenerationPass", B)]),
    "PerlinNoise_VS": dict(
        file="perlinnoise.fx", stage="vs", entry="PerlinNoiseVertexMain",
        mode="selfcontained", axes=[]),
    "PerlinNoise_PS": dict(
        file="perlinnoise.fx", stage="ps", entry="PerlinNoisePixelMain",
        mode="selfcontained",
        axes=[("b_emitMRTAO", B), ("b_emitMRTDepth", B), ("b_emitMRTDiffuse", B),
              ("b_emitMRTNormal", B), ("b_emitMRTSpecular", B),
              ("b_iInEncoding", ENC), ("b_iNormalizeDeffNormal", B),
              ("b_iOutEncoding", ENC)]),
    "RenderPlane_VS": dict(
        file="renderplane.fx", stage="vs", entry="RenderPlaneVertexMain",
        mode="selfcontained", axes=[]),
    "RenderPlane_PS": dict(
        file="renderplane.fx", stage="ps", entry="RenderPlanePixelMain",
        mode="selfcontained",
        axes=[("b_FOWAdditiveScale", B), ("b_FOWEnabled", B), ("b_FOWMode", B),
              ("b_FastFOW", B), ("b_SampleFOW", B), ("b_useBlendAdd", B)]),
    "LensFlare_VS": dict(
        file="lensflare.fx", stage="vs", entry="LensFlareVertexMain",
        mode="selfcontained", axes=[]),
    "LensFlare_PS": dict(
        file="lensflare.fx", stage="ps", entry="LensFlarePixelMain",
        mode="selfcontained",
        axes=[("b_FOWAdditiveScale", B), ("b_FOWEnabled", B), ("b_FOWMode", B),
              ("b_FastFOW", B), ("b_SampleFOW", B), ("b_shaderMode", B),
              ("b_useBlendAdd", B)]),
}

# --- Shared-interpolant (uber) families ------------------------------------
# These rely on the engine's injected VertexTransport/InitShader machinery,
# reconstructed by sc2_interp.  They carry 150-300+ axes (the material-layer
# cross-product), so exact retail enumeration needs the key schema; until then
# a curated set of *structural* axes is cross-producted to emit representative
# valid permutations (the 300+ pasted layer axes default to 0).
SHADINGMODE = [0, 3]        # STANDARD, TERRAIN (others need extra state)
UBER_STRUCTURAL = [
    ("b_iShadingMode", [0]),
    ("b_useLighting", B), ("b_iLightingMode", [0, 1, 2]),
    ("b_useNormalMapping", B), ("b_useShadows", B),
    ("b_useSpecular", B), ("b_FOWEnabled", B),
    ("b_emitMRTDiffuse", B), ("b_emitMRTNormal", B), ("b_emitMRTDepth", B),
    ("b_iUVEmitterCount", [1, 2]),
    ("b_iDiffuseLayerEnable", [1]), ("b_iNormalLayerEnable", B),
    ("b_iSpecularLayerEnable", B), ("b_emitFinalColor", [1]), ("b_emitAlpha", [1]),
]


def _uber(family, file, stage, entry, extra_axes=()):
    return dict(file=file, stage=stage, entry=entry, mode="uber",
                family=family, axes=list(UBER_STRUCTURAL) + list(extra_axes))


UBER_FAMILIES = {
    "Model_ModelVertexMain":   _uber("Model", "model.fx", "vs", "ModelVertexMain"),
    "Model_DefaultPixelMain":  _uber("Model", "model.fx", "ps", "DefaultPixelMain"),
    "Particle_ParticleVertexMain": _uber("Particle", "particle.fx", "vs", "ParticleVertexMain"),
    "Particle_DefaultPixelMain":   _uber("Particle", "particle.fx", "ps", "DefaultPixelMain"),
    "Ribbon_RibbonVertexMain": _uber("Ribbon", "ribbon.fx", "vs", "RibbonVertexMain"),
    "Ribbon_DefaultPixelMain": _uber("Ribbon", "ribbon.fx", "ps", "DefaultPixelMain"),
    "Foliage_FoliageVertexMain": _uber("Foliage", "foliage.fx", "vs", "FoliageVertexMain"),
    "Foliage_DefaultPixelMain":  _uber("Foliage", "foliage.fx", "ps", "DefaultPixelMain"),
    "SplatDirect_SplatDirectVertexMain": _uber("SplatDirect", "splatdirect.fx", "vs", "SplatDirectVertexMain"),
    "SplatDirect_SplatDirectPixelMain":  _uber("SplatDirect", "splatdirect.fx", "ps", "SplatDirectPixelMain"),
    "SplatDeferred_SplatDeferredVertexMain": _uber("SplatDeferred", "splatdeferred.fx", "vs", "SplatDeferredVertexMain"),
    "SplatDeferred_SplatDeferredPixelMain":  _uber("SplatDeferred", "splatdeferred.fx", "ps", "SplatDeferredPixelMain"),
}
FAMILIES.update(UBER_FAMILIES)

PROFILE = {"vs": "vs_5_0", "ps": "ps_5_0"}

# Shader-version enum values from shadersystem.fx (for the SM4+ texture path).
SHADER_VERSION_VS_40 = 4
SHADER_VERSION_PS_40 = 12


def stage_defines(stage, b_values, arrays):
    """The #define block the engine would inject for one permutation."""
    lines = ["#define CPP_SHADER 0"]
    if stage == "vs":
        lines += ["#define VERTEX_SHADER 1",
                  "#define VERTEX_SHADER_VERSION %d" % SHADER_VERSION_VS_40,
                  "#define PIXEL_SHADER_VERSION %d" % SHADER_VERSION_PS_40]
    else:
        lines += ["#define PIXEL_SHADER 1",
                  "#define PIXEL_SHADER_VERSION %d" % SHADER_VERSION_PS_40,
                  "#define VERTEX_SHADER_VERSION %d" % SHADER_VERSION_VS_40]
    for name in sorted(b_values):
        if name in arrays:
            continue  # engine-filled array, not a scalar define
        lines.append("#define %s %d" % (name, b_values[name]))
    return "\n".join(lines)


def selfcontained_stubs(used):
    """Trivial interpolant stubs for families that define their own
    VertexTransport but still reference InitShader / READ_INTERPOLANT_UV."""
    s = []
    if "InitShader" in used:
        s.append("#define InitShader(...)")
    if "READ_INTERPOLANT_UV" in used and "#define READ_INTERPOLANT_UV" not in used:
        s.append("#define READ_INTERPOLANT_UV(i) float4(0,0,0,0)")
    return "\n".join(s)


def _entry_body(text, entry):
    """The brace-balanced body of the entry function (for stage-scoped scans)."""
    epos = text.find(entry + "(")
    if epos < 0:
        return ""
    br = text.find("{", epos)
    if br < 0:
        return ""
    depth, i = 0, br
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[br:i + 1]
        i += 1
    return text[br:]


def _initshader_arity(text, entry):
    """Arg count of the InitShader() call inside the entry function body (or -1)."""
    m = re.search(r"InitShader\s*\(([^)]*)\)", _entry_body(text, entry))
    if not m:
        return -1
    inner = m.group(1).strip()
    return 0 if inner == "" else inner.count(",") + 1


def selfcontained_stubs(entry_file, entry):
    """Trivial interpolant stubs for families that define their own
    VertexTransport but reference the engine's InitShader / Raw / UV macros.

    Usage is detected across the transitive #include closure; InitShader is
    stubbed at the exact arity the *entry body* uses (fxc has neither variadic
    nor 0-arg function-like macros, so the 0-arg form becomes a real no-op
    function).  VertexTransportRaw aliases the in-file VertexTransport (no
    register packing); 2-arg InitShader copies raw->logical."""
    text = open(entry_file, encoding="latin1").read()
    trans = "".join(open(f, encoding="latin1").read()
                    for f in transitive_sources(entry_file))
    stub = []
    if "VertexTransportRaw" in text:
        stub.append("#define VertexTransportRaw VertexTransport")
    if "InitShader" in trans and "#define InitShader" not in trans:
        ar = _initshader_arity(text, entry)
        if ar == 0:
            stub.append("void InitShader() {}")     # fxc rejects `#define f()`
        elif ar == 1:
            stub.append("#define InitShader(a) ")
        elif ar == 2:
            stub.append("#define InitShader(a,b) (b)=(a)")
    if "READ_INTERPOLANT_UV(" in trans and "#define READ_INTERPOLANT_UV" not in trans:
        stub.append("#define READ_INTERPOLANT_UV(i) float4(0,0,0,0)")
    return "\n".join(stub)


def build_source(fam, b_values, arrays):
    """Generate the full HLSL source (preamble + #include family) for one perm."""
    entry_file = os.path.join(SRC, fam["file"])
    entry_path = entry_file.replace("\\", "/")
    pre = [stage_defines(fam["stage"], b_values, arrays)]
    if fam["mode"] == "selfcontained":
        pre.append(selfcontained_stubs(entry_file, fam["entry"]))
    pre.append('#include "%s"' % entry_path)
    return "\n".join(p for p in pre if p) + "\n"


def build_source_uber(fam, b_values, nondef, tmp_path):
    """Assemble uber-family source: b_* defines + reconstructed interpolant
    preamble (liveness = VS-writes ∩ PS-reads) + auto-discovered pasted axes."""
    entry_file = os.path.join(SRC, fam["file"])
    inc = entry_file.replace("\\", "/")
    tmp_dir = os.path.dirname(tmp_path)
    tag = os.path.splitext(os.path.basename(tmp_path))[0]
    sdef_vs = stage_defines("vs", b_values, nondef)
    sdef_ps = stage_defines("ps", b_values, nondef)
    writes, reads, _ = sc2_interp.liveness(FXC, SRC, entry_file, sdef_vs, sdef_ps,
                                           tmp_dir, tag=tag)
    live = writes & reads
    etext = open(entry_file, encoding="latin1").read()
    pre = sc2_interp.gen_preamble(fam["stage"], live, b_values, etext, fam["entry"])

    def assemble(bv):
        return (stage_defines(fam["stage"], bv, nondef) + "\n" + pre +
                '\n#include "%s"\n' % inc)

    extra = sc2_interp.discover_undefined_b(
        FXC, SRC, assemble(b_values), os.path.join(tmp_dir, "_%s_disc.fx" % tag))
    bv = dict(b_values)
    for e in extra:
        bv.setdefault(e, 0)
    return assemble(bv)


def compile_one(fam, b_values, nondef, tmp_path):
    if fam["mode"] == "uber":
        src = build_source_uber(fam, b_values, nondef, tmp_path)
    else:
        src = build_source(fam, b_values, nondef)
    open(tmp_path, "w", encoding="latin1").write(src)
    out = tmp_path + ".dxbc"
    cmd = [FXC, "/nologo", "/Gec", "/T", PROFILE[fam["stage"]],
           "/E", fam["entry"], "/I", SRC, "/Fo", out, tmp_path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        return None, (r.stdout + r.stderr).strip()
    data = open(out, "rb").read()
    os.remove(out)
    return data, None


def enumerate_perms(fam):
    """Cross-product of the family's axis domains."""
    axes = fam["axes"]
    if not axes:
        yield {}
        return
    names = [a[0] for a in axes]
    for combo in itertools.product(*[a[1] for a in axes]):
        yield dict(zip(names, combo))


# --- Cache-driven permutation source (the engine's REAL retail permutation set) ---
#
# Every pixel shader the engine ships lives in the opengl3 baselinecache as a
# permutation key.  sc2_ps_layout classifies each key into its semantic family by
# schema hash (Model / Particle / Ribbon / Foliage / SplatDirect / SplatDeferred /
# TerrainBlend, cross-confirmed by the per-family b_iShadingMode constant) and
# decodes it into the full b_* feature vector.  This maps our registered family
# names to those cache (family, entry) labels so a folder like Model_DefaultPixelMain
# is filled with Model/DefaultPixelMain's actual retail perms instead of a curated
# cross-product.
# Only the DefaultPixelMain families are cache-driven: the recovered permutation
# schema (sc2_ps_layout) IS the DefaultPixelMain material/shading schema, shared
# verbatim by Model/Particle/Ribbon/Foliage (they differ only on the vertex side).
# SplatDirect/SplatDeferred/TerrainBlend use their OWN pixel roots with family-
# specific axes (e.g. b_iTerrainBlendMode) that this schema does not carry, so their
# real perms are not recoverable here — those keep the curated cross-product (whose
# small, fully-known axis sets already enumerate the retail set as a superset).
CACHE_PS_FAMILIES = {
    "Model_DefaultPixelMain":    ("Model", "DefaultPixelMain"),
    "Particle_DefaultPixelMain": ("Particle", "DefaultPixelMain"),
    "Ribbon_DefaultPixelMain":   ("Ribbon", "DefaultPixelMain"),
    "Foliage_DefaultPixelMain":  ("Foliage", "DefaultPixelMain"),
}

_PS_PAIRS = None   # cached (vec, glsl) walk — the whole-cache scan is expensive


def _ps_pairs():
    global _PS_PAIRS
    if _PS_PAIRS is None:
        import sc2_ps_decode
        _PS_PAIRS = sc2_ps_decode.vec_glsl_pairs()
    return _PS_PAIRS


def bvalues_from_key(key, reliable_only=False):
    """Decode a retail cache key into the {b_*: value} vector the engine compiled
    it with.  Feature axes decode bit-exact; the output/emit axes are engine-forced
    and are better taken from the shader signature (see grouped_cache_perms)."""
    import sc2_ps_layout
    return sc2_ps_layout.decode_key(key, reliable_only=reliable_only)


def decode_perm_bvalues(vec, all_b):
    """The full b_* a single retail cache key compiles with.

    Every named axis comes straight from the key decode (material globals + the 306
    per-layer axes + the FOW / reflection / cloaking / volume / terrain-doodad layer
    groups + the ~0.99-validated MRT emit axes), plus the corrections the key itself
    does not carry:

      * b_emitFinalColor forced on — these are the colour-writing (out_cColor) pass and
        the key stores the default 0;
      * b_blendMRTNormals dropped unless b_emitMRTNormal — blendMRTNormals writes
        result.vNormalDepth (PSMainShading.fx:90), a field that only exists with the
        normal target, so the decode-noise combo the code cannot express is removed;
      * per-layer index axes clamped to their real cardinality (8 UV emitters / 18
        layers) — higher values are decode noise retail never emits;
      * b_iUVEmitterCount sized to the emitters the layers reference — the engine sizes
        the sc2UV[] interpolant array to it, and the schema does not expose it, so a 0
        would overflow the array (the X3504 fxc error).

    `all_b` is the family's #define-token set (scan_b_tokens); axes not decoded default
    to 0.
    """
    import sc2_ps_layout as L
    full = L.decode(vec)
    bvals = {b: 0 for b in all_b}
    for k, v in full.items():
        if k.startswith("b_"):
            bvals[k] = v
    bvals["b_emitFinalColor"] = 1
    if not bvals.get("b_emitMRTNormal"):
        bvals["b_blendMRTNormals"] = 0
    max_emitter = 0
    for k in list(bvals):
        if k.startswith("b_i") and k.endswith("UVEmitter"):
            bvals[k] = min(bvals[k], 7)
            max_emitter = max(max_emitter, bvals[k])
        elif k.endswith("LayerId") or k.endswith("TriPlanarUvId"):
            bvals[k] = min(bvals[k], 17)
    if max_emitter + 1 > bvals.get("b_iUVEmitterCount", 0):
        bvals["b_iUVEmitterCount"] = max_emitter + 1
    return bvals


def grouped_cache_perms(fname):
    """Group a family's REAL retail permutations by compile-equivalence.

    Walks the GL baseline cache, keeps the keys whose schema hash is `fname`'s family,
    and builds each permutation's full b_* via decode_perm_bvalues.

    Grouping is by the FULL named decode (not a minimal referenced-token projection):
    a narrower projection folds keys that differ only in token-pasted section-layer
    axes, which retail compiles to DISTINCT shaders — measured, that under-split the
    Model set to 19.5k vs retail's ~33.9k functional shaders.  The full decode matches
    retail (~32.4k, the residual gap being the few bits decoded only opaquely, e.g.
    alpha-test, which cannot be expressed as an #define at all).  Two keys with the
    same full decode compile — deterministically — to byte-identical DXBC, so they
    fold into one group (fxc DCE then folds further).  Yields (representative_b_values,
    member_key_count), most-common group first.
    """
    import sc2_ps_layout as L
    target = CACHE_PS_FAMILIES[fname]
    entry_file = os.path.join(SRC, FAMILIES[fname]["file"])
    all_b, arrays = scan_b_tokens(entry_file)

    groups = {}   # define-block -> [rep_b_values, count]
    for vec, _glsl in _ps_pairs():
        fam = L.family_of(vec)
        if fam is None or (fam[0], fam[1]) != target:
            continue
        bvals = decode_perm_bvalues(vec, all_b)
        gk = tuple(sorted((k, v) for k, v in bvals.items() if k not in arrays))
        g = groups.get(gk)
        if g is None:
            groups[gk] = [bvals, 1]
        else:
            g[1] += 1
    for _gk, (bvals, cnt) in sorted(groups.items(), key=lambda kv: -kv[1][1]):
        yield bvals, cnt


def run_family(fname, jobs, verbose=False, limit=0):
    fam = FAMILIES[fname]
    entry_file = os.path.join(SRC, fam["file"])
    all_b, arrays = scan_b_tokens(entry_file)
    base = {b: 0 for b in all_b}

    perms = list(enumerate_perms(fam))
    if limit:
        perms = perms[:limit]
    out_dir = os.path.join(OUT_ROOT, fname)
    os.makedirs(out_dir, exist_ok=True)
    scratch = os.path.join(out_dir, "_tmp")
    os.makedirs(scratch, exist_ok=True)

    results = {}   # dxbc_sha -> (dxbc bytes, first axis-combo)
    errors = []

    def work(i_perm):
        i, perm = i_perm
        bvals = dict(base)
        bvals.update(perm)
        tmp = os.path.join(scratch, "p%d.fx" % i)
        data, err = compile_one(fam, bvals, arrays, tmp)
        try:
            os.remove(tmp)
        except OSError:
            pass
        return perm, data, err

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for perm, data, err in ex.map(work, enumerate(perms)):
            if data is None:
                errors.append((perm, err))
                if verbose:
                    print("  FAIL", perm, "\n   ", (err or "")[:200])
                continue
            sha = hashlib.sha1(data).hexdigest()
            if sha not in results:
                results[sha] = (data, perm)

    # write unique blobs + index
    index = []
    for n, (sha, (data, perm)) in enumerate(sorted(results.items())):
        bn = "perm_%04d.dxbc" % n
        open(os.path.join(out_dir, bn), "wb").write(data)
        index.append(dict(file=bn, sha1=sha, axes=perm, size=len(data)))
    json.dump(dict(family=fname, entry=fam["entry"], profile=PROFILE[fam["stage"]],
                   enumerated=len(perms), unique=len(results),
                   failed=len(errors), perms=index),
              open(os.path.join(out_dir, "index.json"), "w"), indent=1)
    try:
        os.rmdir(scratch)
    except OSError:
        pass
    return len(perms), len(results), len(errors)


def _compact_axes(bvals):
    """Only the non-zero b_* of a representative (the full decode has ~780 axes;
    keeping just the set ones makes the index legible)."""
    return {k: v for k, v in sorted(bvals.items()) if v}


def run_family_cache(fname, jobs, verbose=False, limit=0):
    """Compile a family's REAL retail permutations (from the cache) into
    sc2_dxbc/<fname>/, deduped by DXBC.  Unlike run_family (curated cross-product)
    this reproduces the engine's actual permutation set, grouped by semantic family.

    Pipeline: retail keys -> per-family classify -> decode -> fold by compile-
    equivalent #define block (grouped_cache_perms) -> fxc -> fold by DXBC sha1.
    The index records, per unique blob, how many retail keys and how many define
    groups map to it.
    """
    fam = FAMILIES[fname]
    entry_file = os.path.join(SRC, fam["file"])
    _all_b, arrays = scan_b_tokens(entry_file)

    groups = list(grouped_cache_perms(fname))   # [(bvals, key_count), ...]
    total_keys = sum(c for _, c in groups)
    if limit:
        groups = groups[:limit]
    out_dir = os.path.join(OUT_ROOT, fname)
    os.makedirs(out_dir, exist_ok=True)
    # drop stale blobs from a previous (curated or shorter) run so the folder is
    # exactly this run's output
    for old in os.listdir(out_dir):
        if old.startswith("perm_") and old.endswith(".dxbc"):
            os.remove(os.path.join(out_dir, old))
    scratch = os.path.join(out_dir, "_tmp")
    os.makedirs(scratch, exist_ok=True)

    results = {}   # dxbc_sha -> [data, rep_bvals, key_count, group_count]
    errors = []

    def work(i_g):
        i, (bvals, cnt) = i_g
        tmp = os.path.join(scratch, "p%d.fx" % i)
        data, err = compile_one(fam, bvals, arrays, tmp)
        try:
            os.remove(tmp)
        except OSError:
            pass
        return bvals, cnt, data, err

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for bvals, cnt, data, err in ex.map(work, enumerate(groups)):
            if data is None:
                errors.append((cnt, err))
                if verbose:
                    print("  FAIL x%d\n    %s" % (cnt, (err or "")[:200]))
                continue
            sha = hashlib.sha1(data).hexdigest()
            r = results.get(sha)
            if r is None:
                results[sha] = [data, bvals, cnt, 1]
            else:
                r[2] += cnt
                r[3] += 1

    # write unique blobs (most-used first) + index
    ordered = sorted(results.items(), key=lambda kv: -kv[1][2])
    index = []
    for n, (sha, (data, bvals, kc, gc)) in enumerate(ordered):
        bn = "perm_%04d.dxbc" % n
        open(os.path.join(out_dir, bn), "wb").write(data)
        index.append(dict(file=bn, sha1=sha, size=len(data),
                          keys=kc, groups=gc, axes=_compact_axes(bvals)))
    json.dump(dict(family=fname, entry=fam["entry"], profile=PROFILE[fam["stage"]],
                   source="baselinecache", retail_keys=total_keys,
                   compiled_groups=len(groups), unique=len(results),
                   failed=len(errors), perms=index),
              open(os.path.join(out_dir, "index.json"), "w"), indent=1)
    try:
        os.rmdir(scratch)
    except OSError:
        pass
    return total_keys, len(groups), len(results), len(errors)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", help="compile one family (default: all registered)")
    ap.add_argument("--list", action="store_true", help="list families and exit")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0, help="cap perms/family (testing)")
    ap.add_argument("--from-cache", action="store_true",
                    help="compile the REAL retail permutation set from the "
                         "baselinecache (grouped by semantic family) instead of "
                         "the curated cross-product; PS uber families only")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if args.list:
        for k, v in FAMILIES.items():
            tag = " [cache]" if k in CACHE_PS_FAMILIES else ""
            print("%-38s %-6s %-28s axes=%d%s" %
                  (k, PROFILE[v["stage"]], v["entry"], len(v["axes"]), tag))
        return

    if args.from_cache:
        fams = [args.family] if args.family else list(CACHE_PS_FAMILIES)
        print("fxc:", FXC, "\ncompiling REAL retail permutations (grouped by family):")
        for f in fams:
            if f not in CACHE_PS_FAMILIES:
                print("%-38s (no cache mapping, skipped)" % f)
                continue
            keys, grp, uniq, fail = run_family_cache(f, args.jobs, args.verbose, args.limit)
            print("%-38s retail_keys=%-6d groups=%-6d unique_dxbc=%-5d failed=%d"
                  % (f, keys, grp, uniq, fail))
        return

    fams = [args.family] if args.family else list(FAMILIES)
    print("fxc:", FXC)
    for f in fams:
        enum, uniq, fail = run_family(f, args.jobs, args.verbose, args.limit)
        print("%-26s enumerated=%-6d unique=%-5d failed=%d" % (f, enum, uniq, fail))


if __name__ == "__main__":
    main()
