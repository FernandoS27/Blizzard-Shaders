"""Compile all permutations of every shader entry point from the unified
wc3_shaders Slang module, to one of several graphics-API targets.

Runs independently of the current working directory — paths resolve
relative to this script's location.

    --target {d3d11,d3d12,vulkan,opengl,metal,webgpu,all}  (default: d3d11)
    --family {hd_vs,hd_ps,toon_hd_vs,toon_hd_ps,gritty_hd_vs,gritty_hd_ps,
              crystal_ps,sd_on_hd_vs,sd_on_hd_ps,sd_highspec_vs,sd_classic_ps,
              water_vs,water_ps,tonemap_ps,all}
    --slangc PATH   explicit slangc.exe override
"""

import argparse
import concurrent.futures
import glob
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional

from shader_config import load_families

REPO_ROOT = Path(__file__).resolve().parent
SHADER = REPO_ROOT / "wc3_shaders" / "wc3_shaders.slang"
CUSTOM_SHADER = REPO_ROOT / "custom_shaders" / "custom_shaders.slang"
WC3_INCLUDE_DIR = REPO_ROOT / "wc3_shaders"
CUSTOM_SHADER_DIR = REPO_ROOT / "custom_shaders"
OUT_BASE = REPO_ROOT / "slang_out"

# When --debug is passed, main() flips these: OUT_BASE moves to a sibling
# `slang_out_debug` tree (so debug and release bytecode never collide and
# each gets its own incremental-mtime state) and DEBUG_BUILD makes
# invoke_slangc emit full debug symbols + no optimisation. build_bls.py is
# then pointed at slang_out_debug via its existing --slang-out override.
OUT_BASE_DEBUG = REPO_ROOT / "slang_out_debug"
DEBUG_BUILD = False

# When the --metallib path is active, slangc emits .metal source (target=metal)
# and we drive Apple's `xcrun metal` + `xcrun metallib` ourselves to compile
# it. We do this instead of letting slangc invoke its own metal downstream
# because slangc (as of 2026.9) ignores `-Xmetal -mmacosx-version-min=...`
# and always produces metallib container version 1.2.7 — driving xcrun
# directly lets us pin -mmacosx-version-min and emit older metallib versions
# (e.g. min=11 → metallib 1.2.5, which matches the lowest container slang's
# Metal-2.3 emit syntax is compatible with; the Wc3-shipped 1.2.2 isn't
# reachable because slangc has no pre-2.3 Metal output).
METALLIB_MAC_MIN: Optional[str] = None

_source_mtime_cache: Optional[float] = None


def shader_source_mtime(slangc_exe: str) -> float:
    """Newest mtime across every input that can change a slang output.

    Returned mtime gates the incremental skip in run_sweep: if a perm's
    output file exists and is newer than this number, slangc would emit
    byte-identical bytecode (modulo nondeterminism in slangc itself) so
    we skip the invocation. Inputs that count:
      • every .slang under wc3_shaders/ and custom_shaders/ (slang's
        preprocessor and module import semantics mean any one of them
        can affect any entry point)
      • the slangc binary itself (different versions produce different
        bytecode — see the popcorn_vs 2026.1 vs 2026.8 saga)
      • this script + shader_config.py + wc3_shaders.json (the perm
        mapping or per-perm defines table can change)
    """
    global _source_mtime_cache
    if _source_mtime_cache is not None:
        return _source_mtime_cache
    candidates: List[Path] = [
        Path(slangc_exe),
        Path(__file__),
        REPO_ROOT / "shader_config.py",
        REPO_ROOT / "wc3_shaders.json",
        REPO_ROOT / "custom_shaders.json",
    ]
    for root in (WC3_INCLUDE_DIR, CUSTOM_SHADER_DIR):
        if root.exists():
            candidates.extend(root.rglob("*.slang"))
    newest = 0.0
    for p in candidates:
        try:
            newest = max(newest, p.stat().st_mtime)
        except OSError:
            pass
    _source_mtime_cache = newest
    return newest

# Family metadata — stage, entry point, perm_count, which source module
# hosts the entry point — comes from wc3_shaders.json via shader_config. The
# module="custom" families compile from CUSTOM_SHADER with WC3_INCLUDE_DIR
# on the include path so `import wc3_shaders;` resolves.
FAMILY_CONFIGS = load_families()
FAMILIES = tuple(FAMILY_CONFIGS.keys())

# Stage → profile per target + output file extension and optional extra
# slangc args. The metal entry can be switched to metallib (compiled Metal
# bytecode) by `--metallib VERSION`; see main(). metallib generation
# requires Apple's `metal` downstream compiler (Xcode toolchain) and will
# only succeed on macOS.
#
# - d3d11 / d3d12 use the native HLSL profile strings.
# - vulkan (SPIR-V) / opengl (GLSL) use glsl_450.
# - metal and webgpu accept the Slang-universal sm_6_0 profile.
TARGETS = {
    "d3d11":  {"target": "dxbc",  "ext": "dxbc",  "vs": "vs_5_0",   "ps": "ps_5_0",   "extra": []},
    "d3d12":  {"target": "dxil",  "ext": "dxil",  "vs": "vs_6_0",   "ps": "ps_6_0",   "extra": []},
    "vulkan": {"target": "spirv", "ext": "spv",   "vs": "glsl_450", "ps": "glsl_450", "extra": ["-fvk-use-dx-layout"]},
    "opengl": {"target": "glsl",  "ext": "glsl",  "vs": "glsl_450", "ps": "glsl_450", "extra": []},
    "metal":  {"target": "metal", "ext": "metal", "vs": "sm_6_0",   "ps": "sm_6_0",   "extra": []},
    "webgpu": {"target": "wgsl",  "ext": "wgsl",  "vs": "sm_6_0",   "ps": "sm_6_0",   "extra": []},
}

_slangc_path: Optional[str] = None


def resolve_slangc(override: Optional[str] = None) -> str:
    """Locate slangc.exe. Caches the result after the first successful call."""
    global _slangc_path
    if _slangc_path is not None:
        return _slangc_path

    exe = "slangc.exe" if os.name == "nt" else "slangc"

    # Explicit override (CLI flag or SLANGC env var) wins.
    for cand in (override, os.environ.get("SLANGC")):
        if cand and Path(cand).is_file():
            _slangc_path = cand
            return _slangc_path

    # Standard PATH lookup.
    found = shutil.which("slangc")
    if found:
        _slangc_path = found
        return _slangc_path

    # Vulkan SDK installer sets VULKAN_SDK to the active install.
    vulkan_sdk = os.environ.get("VULKAN_SDK")
    if vulkan_sdk:
        candidate = Path(vulkan_sdk) / "Bin" / exe
        if candidate.is_file():
            _slangc_path = str(candidate)
            return _slangc_path

    # Fallback: scan the default Windows install root for the newest SDK.
    if os.name == "nt":
        matches = sorted(glob.glob(r"C:\VulkanSDK\*\Bin\slangc.exe"))
        if matches:
            _slangc_path = matches[-1]
            return _slangc_path

    raise SystemExit(
        "slangc not found. Install the Vulkan SDK, put slangc on PATH, "
        "or pass --slangc / set SLANGC to its full path."
    )


@dataclass
class PermSpec:
    entry: str
    types: List[str]
    label: str
    # Per-perm preprocessor defines (e.g. ["POPCORN_HAS_VC=1"]). Used by
    # families that gate VS input / output struct fields with `#if`
    # rather than `Conditional<>` because slangc miscompiles compound
    # bool gates in the latter (see PopcornVSInput in vs_io.slang).
    defines: List[str] = field(default_factory=list)


@dataclass
class SweepResult:
    family: str
    count: int
    ok: int = 0
    fail: int = 0
    fail_list: List[str] = field(default_factory=list)


def invoke_slangc(entry: str, target: str, profile: str,
                  specialize: List[str], out_path: Path,
                  shader_path: Path,
                  extra: Optional[List[str]] = None,
                  include_dirs: Optional[List[Path]] = None,
                  slangc_override: Optional[str] = None,
                  defines: Optional[List[str]] = None) -> bool:
    slangc_exe = slangc_override if slangc_override else resolve_slangc()
    args = [slangc_exe, "-entry", entry]
    for t in specialize:
        args += ["-specialize", t]
    # WGSL backend uses #ifdef WGSL_TARGET to shrink PS binding offsets.
    effective_defines = list(defines or [])
    if target == "wgsl":
        effective_defines.append("WGSL_TARGET=1")
    for d in effective_defines:
        # slangc 2026.x rejects `-D NAME=val` (space-separated) when
        # followed by `-specialize`; use the concatenated form.
        args += [f"-D{d}"]
    for inc in include_dirs or []:
        args += ["-I", str(inc)]
    # Metallib via xcrun: slangc emits .metal source to a sibling temp
    # path; the .air → .metallib step runs after slangc returns. See
    # METALLIB_MAC_MIN docstring for why we don't let slangc do it itself.
    metal_via_xcrun = (target == "metal" and METALLIB_MAC_MIN is not None
                       and str(out_path).endswith(".metallib"))
    slangc_out = out_path.with_suffix(".metal") if metal_via_xcrun else out_path
    args += [
        "-profile", profile,
        "-target", target,
        "-o", str(slangc_out),
        "-warnings-disable", "39001",
    ]
    # Debug builds: full debug symbols (-g2) and no optimisation (-O0) so
    # the bytecode maps cleanly back to slang source in RenderDoc / PIX /
    # the Vulkan validation layers. SPIR-V additionally needs
    # -emit-spirv-directly: the default SPIRV-via-GLSL path drops slang's
    # debug info, the direct backend preserves it.
    if DEBUG_BUILD:
        args += ["-g2", "-O0"]
        if target == "spirv":
            args.append("-emit-spirv-directly")
    if extra:
        args += extra
    args.append(str(shader_path))

    # Delete any stale output up front so a failed compile can't
    # masquerade as success via a leftover .dxbc from a prior run.
    if out_path.exists():
        out_path.unlink()
    if metal_via_xcrun and slangc_out.exists():
        slangc_out.unlink()

    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        # On failure we drop a sibling .err file with stderr so the
        # caller (or a curious user) can inspect what went wrong; the
        # sweep summary still surfaces the perm in fail_list.
        err_path = out_path.with_suffix(out_path.suffix + ".err")
        err_path.write_text(proc.stderr or proc.stdout or "(no slangc output)")
        return False
    if metal_via_xcrun:
        if not slangc_out.exists() or slangc_out.stat().st_size == 0:
            return False
        air_path = out_path.with_suffix(".air")
        metal_proc = subprocess.run(
            ["xcrun", "metal", "-c",
             f"-mmacosx-version-min={METALLIB_MAC_MIN}",
             str(slangc_out), "-o", str(air_path)],
            capture_output=True, text=True)
        if metal_proc.returncode != 0:
            err_path = out_path.with_suffix(out_path.suffix + ".err")
            err_path.write_text(
                "xcrun metal failed:\n" +
                (metal_proc.stderr or metal_proc.stdout or ""))
            slangc_out.unlink(missing_ok=True)
            return False
        lib_proc = subprocess.run(
            ["xcrun", "metallib", str(air_path), "-o", str(out_path)],
            capture_output=True, text=True)
        # Intermediates aren't useful to keep around — they confuse the
        # incremental mtime check on the next run and clutter slang_out/.
        slangc_out.unlink(missing_ok=True)
        air_path.unlink(missing_ok=True)
        if lib_proc.returncode != 0:
            err_path = out_path.with_suffix(out_path.suffix + ".err")
            err_path.write_text(
                "xcrun metallib failed:\n" +
                (lib_proc.stderr or lib_proc.stdout or ""))
            return False
    elif target == "wgsl" and out_path.exists() and out_path.stat().st_size > 0:
        fix_wgsl_depth_textures(out_path)
        rename_wgsl_entry_to_main(out_path)
    return out_path.exists() and out_path.stat().st_size > 0


def rename_wgsl_entry_to_main(wgsl_path: Path) -> None:
    """Rename the entry function to `main` — the WebGPU backend uses
    a fixed "main" entryPoint."""
    text = wgsl_path.read_text(encoding="utf-8")
    new_text = re.sub(
        r"(@(vertex|fragment|compute)[ \t\r\n]+fn[ \t]+)[A-Za-z_]\w*",
        r"\1main",
        text,
    )
    if new_text != text:
        wgsl_path.write_text(new_text, encoding="utf-8")


def fix_wgsl_depth_textures(wgsl_path: Path) -> None:
    """Propagate `texture_depth_2d` typing from textureSampleCompareLevel
    use sites back through the call chain. Works around slangc 2026.x
    emitting comparison-sampled textures as texture_2d<f32>."""
    text = wgsl_path.read_text(encoding="utf-8")

    # Seed: every NAME that's the texture argument to textureSampleCompareLevel.
    depth_names = set(re.findall(r"textureSampleCompareLevel\s*\(\s*\(?\s*([A-Za-z_]\w*)",
                                  text))
    if not depth_names:
        return

    fn_sig_re = re.compile(r"\bfn\s+([A-Za-z_]\w*)\s*\(([^)]*)\)")
    fn_params: Dict[str, List[str]] = {}
    for m in fn_sig_re.finditer(text):
        fname = m.group(1)
        names = []
        for piece in m.group(2).split(","):
            pm = re.match(r"([A-Za-z_]\w*)\s*:", piece.strip())
            if pm:
                names.append(pm.group(1))
        fn_params[fname] = names

    for _ in range(8):
        grew = False
        for fname, params in fn_params.items():
            depth_param_positions = [i for i, p in enumerate(params) if p in depth_names]
            if not depth_param_positions:
                continue
            for call_m in re.finditer(rf"\b{re.escape(fname)}\s*\(([^)]*)\)", text):
                args = [a.strip() for a in call_m.group(1).split(",")]
                for pos in depth_param_positions:
                    if pos < len(args):
                        arg = args[pos].lstrip("(").rstrip(")").strip()
                        if re.fullmatch(r"[A-Za-z_]\w*", arg) and arg not in depth_names:
                            depth_names.add(arg)
                            grew = True
        if not grew:
            break


    name_alt = "|".join(re.escape(n) for n in sorted(depth_names))
    new_text = re.sub(
        rf"\b({name_alt})\b(\s*:\s*)texture_2d<\s*f32\s*>",
        r"\1\2texture_depth_2d",
        text,
    )
    if new_text != text:
        wgsl_path.write_text(new_text, encoding="utf-8")


def run_sweep(family: str, count: int, mapper: Callable[[int], PermSpec],
              stage: str, target_key: str, jobs: int = 1,
              slangc_override: Optional[str] = None) -> SweepResult:
    cfg = TARGETS[target_key]
    print()
    print(f"========== [{target_key}] {family} ({count} perms, jobs={jobs}) ==========")
    out_dir = OUT_BASE / target_key / family
    out_dir.mkdir(parents=True, exist_ok=True)
    # Incremental: only the perms whose output is older than any input
    # (slang sources, slangc binary, script/json) are re-compiled. The
    # rest are kept as-is so a no-op rebuild does no slangc work. The
    # source_mtime is captured up front; per-perm we still wipe stale
    # .err files from a failed previous run.
    src_mtime = shader_source_mtime(slangc_override or resolve_slangc())

    result = SweepResult(family=family, count=count)
    ext = cfg["ext"]
    target = cfg["target"]
    profile = cfg[stage]
    extra = cfg.get("extra", [])

    # The shipped SD classic pixel shader is compiled to SM4 / SM2 (SHDR
    # + Aon9 chunks) for D3D9 compatibility — every other shipped shader
    # uses SM5 (SHEX). The Wc3 engine binds the SD classic perm via its
    # legacy pipeline and rejects (or mis-binds) SM5 bytecode there, so
    # we override the D3D11 PS profile to ps_4_0 for this family. SM4 is
    # a strict subset of SM5 for the operations the SD classic PS uses
    # (one or two `Sample`s, fixed-function blend, optional fog +
    # `discard`), so the only behaviour change is the chunk type.
    if family == "sd_classic_ps" and target_key == "d3d11":
        profile = "ps_4_0"

    # Custom-shader families compile from their own module file with
    # wc3_shaders on the include path so `import wc3_shaders;` resolves.
    # The explicit -stage flag keeps slangc from trying to validate
    # wc3_shaders' own entry points (vs_main, ps_main, …) against the
    # current profile while it's being imported — without it the
    # import pipeline emits all entry points in the module.
    if FAMILY_CONFIGS[family].module == "custom":
        shader_path = CUSTOM_SHADER
        include_dirs = [WC3_INCLUDE_DIR]
        custom_extra = extra + [
            "-stage", "fragment" if stage == "ps" else "vertex",
            # Suppress slangc's attempt to validate wc3_shaders' own
            # entry points (hd_vs, hd_ps, …) against our profile while
            # it's being imported — they're re-scanned for capability
            # checks by default and error because the profile only
            # matches one stage.
            "-ignore-capabilities",
        ]
    else:
        shader_path = SHADER
        include_dirs = None
        custom_extra = extra

    # Build the per-perm work list once so the executor only has to dispatch.
    perm_specs = [(i, mapper(i), out_dir / f"perm_{i:03d}.{ext}")
                  for i in range(count)]

    def compile_one(item):
        i, spec, out_path = item
        # Skip when the previous output is newer than every input that
        # could change its contents. `>=` rather than `>` because a
        # source edited within the same filesystem-mtime tick as the
        # output should re-compile to be safe (catches "edit-then-build
        # twice in a second" loops).
        if out_path.exists() and out_path.stat().st_mtime > src_mtime:
            # Drop any stale .err from a previous failed run so the
            # next failure isn't masked by an old error message.
            err_path = out_path.with_suffix(out_path.suffix + ".err")
            if err_path.exists():
                err_path.unlink()
            return i, spec, True, True  # ok=True, skipped=True
        ok = invoke_slangc(spec.entry, target, profile, spec.types, out_path,
                           shader_path, custom_extra, include_dirs,
                           slangc_override, spec.defines)
        return i, spec, ok, False

    # Each slangc invocation is a long-running subprocess, so a thread
    # pool parallelises well — the GIL is released while we wait on the
    # child process. Use sequential dispatch when jobs<=1 to keep stack
    # traces tidy on single-thread runs.
    if jobs <= 1:
        outcomes = [compile_one(item) for item in perm_specs]
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            outcomes = list(pool.map(compile_one, perm_specs))

    skipped = 0
    for i, spec, ok, was_skipped in outcomes:
        if was_skipped:
            skipped += 1
        if ok:
            result.ok += 1
        else:
            result.fail += 1
            result.fail_list.append(f"perm_{i} ({spec.label})")

    # Keep the fail list in perm-index order so it's stable across runs.
    result.fail_list.sort()

    print()
    print(f"Compile: {result.ok} OK / {result.fail} fail "
          f"({skipped} up-to-date)")
    if result.fail_list:
        print("--- First 5 compile failures ---")
        for entry in result.fail_list[:5]:
            print(f"  {entry}")
    return result


def map_hd_vs(idx: int) -> PermSpec:
    tang     = idx % 2
    weight   = (idx // 2) % 3
    color    = (idx // 6) % 2
    texcoord = (idx // 12) % 3
    prepass  = (idx // 36) % 2
    shadows  = (idx // 72) % 2

    skin  = "FourBoneSkinning" if weight == 2 else "Rigid"
    hasT  = "true" if tang == 1 else "false"
    hasC  = "true" if color == 1 else "false"
    hasU0 = "true" if texcoord >= 1 else "false"
    hasU1 = "true" if texcoord >= 2 else "false"
    shad  = "true" if (shadows == 1 and prepass == 0) else "false"

    # HAS_SHADOWS is no longer a slang `let HAS_SHADOWS : bool` template
    # parameter — VSOutput dropped the template so its WGSL emit doesn't
    # tunnel `Conditional<float4, HAS_SHADOWS>` through `array<float4, 1>`
    # (rejected on @location varyings). We pass it as a preprocessor `-D`
    # define instead; types/vs_io.slang gates the shadowClip fields on
    # `#if HAS_SHADOWS`, and hd_vs.slang's body switches between the
    # shadow and non-shadow paths with the same #if.
    # Match popcorn's pattern: only emit -D when the flag is true (slangc
    # rejects `-D NAME=0` in this build); the #if HAS_SHADOWS gate evaluates
    # to 0 when the define is absent (slangc warns 15205 but still compiles).
    defines: List[str] = []
    if shad == "true":
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="vs_main",
        types=[skin, f"VertexFormat<{hasT},{hasC},{hasU0},{hasU1}>"],
        defines=defines,
        label=f"{skin}+T={hasT}+C={hasC}+UV={texcoord}+SH={shad}",
    )


def _hd_ps_bits(idx: int):
    """Shared 9-bit feature encoding for hd_ps and crystal_ps. Bit 2 /
    EXTRA_VERTS toggles the shadow cascade inputs the VS writes on
    TEXCOORD4-6; the HD IBL PS consumes them for the 3-cascade PCF
    shadow lookup."""
    return {
        "mrt":  bool(idx & 1),
        "dp":   bool(idx & 2),
        "ev":   bool(idx & 4),
        "ibl":  bool(idx & 8),
        "fogL": bool(idx & 16),
        "fogE": bool(idx & 32),
        "at":   bool(idx & 64),
        "ml":   bool(idx & 128),
        "dbg":  bool(idx & 256),
    }


def _hd_ps_types(b):
    if b["fogL"] and b["fogE"]:
        fog = "FogExp2"
    elif b["fogL"]:
        fog = "FogLinear"
    elif b["fogE"]:
        fog = "FogExponential"
    else:
        fog = "FogNone"
    alpha = "AlphaTestOn" if b["at"] else "AlphaTestOff"
    mat   = "MultiLayerMaterial" if b["ml"] else "StandardMaterial"
    iblS  = "true" if b["ibl"] else "false"
    evS   = "true" if b["ev"] else "false"
    dpS   = "true" if b["dp"] else "false"
    mrtS  = "true" if b["mrt"] else "false"
    dbgS  = "true" if b["dbg"] else "false"
    return fog, alpha, mat, iblS, evS, dpS, mrtS, dbgS


def map_hd_ps(idx: int) -> PermSpec:
    b = _hd_ps_bits(idx)
    fog, alpha, mat, iblS, evS, dpS, mrtS, dbgS = _hd_ps_types(b)
    defines: List[str] = []
    if b["dp"]:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if b["mrt"]:
        defines.append("WC3_IS_MRT=1")
    # `ev` (HAS_EXTRA_VERTS) gates the shadowClip0..2 fields in PSInput.
    # Must mirror the VS-side WC3_HAS_SHADOWS so the @location indices
    # align across VS-output / PS-input on WGSL (the renderer pairs the
    # VS perm with shadows=true to the PS perm with ev=true).
    if b["ev"]:
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="ps_main",
        types=[fog, alpha, mat, iblS, evS, dbgS],
        defines=defines,
        label=f"{fog}+{alpha}+{mat}+IBL={iblS}+EV={evS}+DP={dpS}+MRT={mrtS}+DBG={dbgS}",
    )


def map_toon_hd_vs(idx: int) -> PermSpec:
    # Toon-HD shares the HD vertex-format encoding 1:1 — same 144 perms,
    # same specialisation types + defines, different entry point.
    spec = map_hd_vs(idx)
    return PermSpec(entry="toon_vs_main", types=spec.types, defines=spec.defines,
                    label=spec.label)


def map_toon_hd_ps(idx: int) -> PermSpec:
    # Toon-HD shares the HD pixel-shader 9-bit feature encoding 1:1 —
    # same 512 perms, same specialisation types, different entry point.
    spec = map_hd_ps(idx)
    return PermSpec(entry="toon_ps_main", types=spec.types, defines=spec.defines,
                    label=spec.label)


def map_gritty_hd_vs(idx: int) -> PermSpec:
    # Gritty-HD shares the HD vertex-format encoding 1:1 — same 144
    # perms, same specialisation types + defines, different entry point.
    spec = map_hd_vs(idx)
    return PermSpec(entry="gritty_vs_main", types=spec.types, defines=spec.defines,
                    label=spec.label)


def map_gritty_hd_ps(idx: int) -> PermSpec:
    # Gritty-HD shares the HD pixel-shader 9-bit feature encoding 1:1 —
    # same 512 perms, same specialisation types, different entry point.
    spec = map_hd_ps(idx)
    return PermSpec(entry="gritty_ps_main", types=spec.types, defines=spec.defines,
                    label=spec.label)


def map_crystal_ps(idx: int) -> PermSpec:
    # Crystal shares hd_ps's 9-bit encoding for most features. Bit 2 /
    # EXTRA_VERTS is unused on crystal's PS signature (crystal doesn't
    # expose a shadow-cascade path yet), so we drop it from the
    # specialisation tuple. IS_DEPTH_PREPASS / IS_MRT migrated to
    # preprocessor defines (see map_hd_ps).
    b = _hd_ps_bits(idx)
    fog, alpha, mat, iblS, _evS, dpS, mrtS, dbgS = _hd_ps_types(b)
    defines: List[str] = []
    if b["dp"]:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if b["mrt"]:
        defines.append("WC3_IS_MRT=1")
    return PermSpec(
        entry="crystal_ps_main",
        types=[fog, alpha, mat, iblS, dbgS],
        defines=defines,
        label=f"{fog}+{alpha}+{mat}+IBL={iblS}+DP={dpS}+MRT={mrtS}+DBG={dbgS}",
    )


def map_sd_on_hd_vs(idx: int) -> PermSpec:
    tang     = idx % 2
    weight   = (idx // 2) % 3
    color    = (idx // 6) % 2
    texcoord = (idx // 12) % 3
    prepass  = (idx // 36) % 2
    shadows  = (idx // 72) % 2

    skin  = "SDFourBoneSkinning" if weight == 2 else "Rigid"
    hasT  = "true" if tang == 1 else "false"
    hasC  = "true" if color == 1 else "false"
    hasU0 = "true" if texcoord >= 1 else "false"
    hasU1 = "true" if texcoord >= 2 else "false"
    shad  = "true" if (shadows == 1 and prepass == 0) else "false"

    # Same HAS_SHADOWS-as-define migration as map_hd_vs — see the comment
    # there. The slang entry no longer takes a `let HAS_SHADOWS : bool`,
    # and the cascade fields are gated by `#if HAS_SHADOWS` in vs_io.slang.
    defines: List[str] = []
    if shad == "true":
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="sd_on_hd_vs_main",
        types=[skin, f"VertexFormat<{hasT},{hasC},{hasU0},{hasU1}>"],
        defines=defines,
        label=f"{skin}+T={hasT}+C={hasC}+UV={texcoord}+SH={shad}",
    )


def map_sd_on_hd_ps(idx: int) -> PermSpec:
    base       = idx & 0x3F
    high_field = idx // 64

    mrt  = bool(base & 1)
    dp   = bool(base & 2)
    ev   = bool(base & 4)
    ibl  = bool(base & 8)
    fogL = bool(base & 16)
    fogE = bool(base & 32)

    if fogL and fogE:
        fog = "FogExp2"
    elif fogL:
        fog = "FogLinear"
    elif fogE:
        fog = "FogExponential"
    else:
        fog = "FogNone"

    at   = high_field in (1, 4)
    srgb = high_field in (2, 5)
    dbg  = high_field in (3, 4, 5)

    alpha = "AlphaTestOn" if at else "AlphaTestOff"
    iblS  = "true" if ibl else "false"
    evS   = "true" if ev else "false"
    dpS   = "true" if dp else "false"
    mrtS  = "true" if mrt else "false"
    srgbS = "true" if srgb else "false"
    dbgS  = "true" if dbg else "false"

    defines: List[str] = []
    if dp:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if mrt:
        defines.append("WC3_IS_MRT=1")
    if ev:
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="sd_on_hd_ps_main",
        types=[fog, alpha, iblS, evS, srgbS, dbgS],
        defines=defines,
        label=(f"{fog}+{alpha}+IBL={iblS}+EV={evS}+DP={dpS}"
               f"+MRT={mrtS}+SRGB={srgbS}+DBG={dbgS}"),
    )


def map_sd_highspec_vs(idx: int) -> PermSpec:
    weight = idx % 3
    color  = (idx // 3) % 2
    uv     = (idx // 6) % 3
    lights = (idx // 18) % 9

    skin  = "SDFourBoneSkinning" if weight == 2 else "Rigid"
    hasC  = "true" if color == 1 else "false"
    hasU0 = "true" if uv >= 1 else "false"
    hasU1 = "true" if uv >= 2 else "false"

    return PermSpec(
        entry="sd_highspec_vs_main",
        types=[skin, f"VertexFormat<false,{hasC},{hasU0},{hasU1}>", str(lights)],
        label=f"{skin}+C={hasC}+UV={uv}+NL={lights}",
    )


STAGE_NAMES = [
    "StageDisabled", "StageModulate", "StageLerp",
    "StageModulateRGB", "StageModulate2X",
]


def map_water_vs(idx: int) -> PermSpec:
    # Single permutation — no feature specialisation.
    return PermSpec(entry="water_vs_main", types=[], label="(only)")


def map_water_ps(idx: int) -> PermSpec:
    # 4 permutations: FogNone / FogLinear / FogExponential / FogExp2.
    fogL = bool(idx & 1)
    fogE = bool(idx & 2)
    if fogL and fogE:
        fog = "FogExp2"
    elif fogL:
        fog = "FogLinear"
    elif fogE:
        fog = "FogExponential"
    else:
        fog = "FogNone"
    return PermSpec(entry="water_ps_main", types=[fog], label=fog)


def map_tonemap_ps(idx: int) -> PermSpec:
    # Single permutation — HDR→LDR resolve has no feature axes.
    return PermSpec(entry="tonemap_ps_main", types=[], label="(only)")


def map_sprite_vs(idx: int) -> PermSpec:
    # Single permutation — pre-projected sprite VS has no feature axes.
    return PermSpec(entry="sprite_vs_main", types=[], label="(only)")


def map_sprite_ps(idx: int) -> PermSpec:
    # 4 permutations driven by 2 independent bools:
    #   bit 0 — HAS_SRGB_ENCODE (linear → sRGB write)
    #   bit 1 — HAS_SRGB_DECODE (sRGB    → linear read)
    # Both bits set is a passthrough (the encode/decode pair cancels),
    # matching the engine's perm_003 == perm_000 collapse.
    enc = "true" if (idx & 1) else "false"
    dec = "true" if (idx & 2) else "false"
    return PermSpec(
        entry="sprite_ps_main",
        types=[enc, dec],
        label=f"ENC={enc}+DEC={dec}",
    )


def map_distortion_ps(idx: int) -> PermSpec:
    # Single permutation — full-screen chromatic-aberration pass has no
    # feature axes.
    return PermSpec(entry="distortion_ps_main", types=[], label="(only)")


def map_imgui_vs(idx: int) -> PermSpec:
    # Single permutation — ImGui VS has a fixed 2D projection layout
    # and no feature axes.
    return PermSpec(entry="imgui_vs_main", types=[], label="(only)")


def map_imgui_ps(idx: int) -> PermSpec:
    # 2 permutations driven by 1 bool: HAS_SRGB_DECODE.
    #
    # The engine indexes the shipped imgui.bls perms in the inverse
    # order: perm_000 carries the sRGB-decoded variant (used when
    # ImGui draws are routed to a linear-storage render target), and
    # perm_001 is the passthrough modulate (used with an sRGB-format
    # target where the hardware does the decode on write).
    has_decode = (idx == 0)
    dec = "true" if has_decode else "false"
    return PermSpec(
        entry="imgui_ps_main",
        types=[dec],
        label=f"DEC={dec}",
    )


def map_terrain_vs(idx: int) -> PermSpec:
    # 8 perms = 3 raw bits, but only 4 functionally distinct outputs:
    #   bit 0 — SHADOW_PASS      (caster pass; suppresses cascade output)
    #   bit 1 — RECEIVE_SHADOWS  (emit cascade UVs)
    #   bit 2 — VERTEX_COLOR     (per-vertex RGBA from ATTR2)
    # Effective HAS_SHADOWS = (RECEIVE_SHADOWS && !SHADOW_PASS) — a draw
    # rendering its own caster pass never emits cascade UVs even when
    # the receive flag is also set. perm_001/003/005/007 collapse onto
    # perm_000/000/004/004 respectively.
    shadow_pass = bool(idx & 1)
    receive     = bool(idx & 2)
    vert_color  = bool(idx & 4)
    has_shadows = receive and not shadow_pass

    vc = "true" if vert_color else "false"
    # HAS_SHADOWS migrated to WC3_HAS_SHADOWS preprocessor define (see
    # map_hd_vs). HAS_VERTEX_COLOR stays as a slang template param.
    defines: List[str] = []
    if has_shadows:
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="terrain_vs_main",
        types=[vc],
        defines=defines,
        label=f"VC={vc}+SH={'true' if has_shadows else 'false'}",
    )


def map_foliage_vs(idx: int) -> PermSpec:
    # 8 perms = 3 raw bits, but only 4 functionally distinct outputs:
    #   bit 0 — SHADOW_PASS    (caster pass; suppresses cascade output)
    #   bit 1 — RECEIVE_SHADOWS
    #   bit 2 — WIND_ANIMATION
    # Effective HAS_SHADOWS = (RECEIVE_SHADOWS && !SHADOW_PASS) — same
    # collapse rule as terrain_vs.
    shadow_pass = bool(idx & 1)
    receive     = bool(idx & 2)
    wind        = bool(idx & 4)
    has_shadows = receive and not shadow_pass

    wd = "true" if wind else "false"
    # HAS_SHADOWS migrated to WC3_HAS_SHADOWS preprocessor define (see
    # map_hd_vs). HAS_WIND stays as a slang template param.
    defines: List[str] = []
    if has_shadows:
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="foliage_vs_main",
        types=[wd],
        defines=defines,
        label=f"SH={'true' if has_shadows else 'false'}+WIND={wd}",
    )


def map_foliage_ps(idx: int) -> PermSpec:
    # 128 perms (7 raw bits) — every bit is functionally distinct:
    #   bit 0 (1)   — MRT_OUTPUTS
    #   bit 1 (2)   — NULL_PASS    (overrides everything; 64/128 collapse)
    #   bit 2 (4)   — RECEIVE_SHADOWS
    #   bit 3 (8)   — FOG_LINEAR
    #   bit 4 (16)  — FOG_EXPONENTIAL  (with bit 3 → FogExp2)
    #   bit 5 (32)  — ALPHA_TEST
    #   bit 6 (64)  — TINT_OVERRIDE
    null_pass = bool(idx & 2)
    mrt       = bool(idx & 1)
    shadows   = bool(idx & 4)
    fogL      = bool(idx & 8)
    fogE      = bool(idx & 16)
    at        = bool(idx & 32)
    tint      = bool(idx & 64)

    if fogL and fogE:
        fog = "FogExp2"
    elif fogL:
        fog = "FogLinear"
    elif fogE:
        fog = "FogExponential"
    else:
        fog = "FogNone"

    npS  = "true" if null_pass else "false"
    mrtS = "true" if mrt       else "false"
    shS  = "true" if shadows   else "false"
    atS  = "true" if at        else "false"
    tnS  = "true" if tint      else "false"
    # HAS_NULL_PASS / HAS_MRT migrated to preprocessor defines so
    # FoliagePSOutput can use #if instead of `Conditional<>` (see
    # foliage_ps.slang). WC3_HAS_MRT factors in NULL_PASS already; the
    # script sets it explicitly rather than relying on derivation.
    defines: List[str] = []
    if null_pass:
        defines.append("WC3_TERRAIN_NULL_PASS=1")
    elif mrt:
        defines.append("WC3_HAS_MRT=1")
    if shadows:
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="foliage_ps_main",
        types=[shS, fog, atS, tnS],
        defines=defines,
        label=f"NULL={npS}+MRT={mrtS}+SH={shS}+{fog}+AT={atS}+TINT={tnS}",
    )


def map_terrain_ps(idx: int) -> PermSpec:
    # 128 perms (7 raw bits) but only 4 functionally distinct axes:
    #   bit 0 (1)   — MRT_OUTPUTS
    #   bit 1 (2)   — NULL_PASS    (overrides everything; 64/128 collapse)
    #   bit 2 (4)   — RECEIVE_SHADOWS
    #   bit 3 (8)   — unused (reserved)
    #   bit 4 (16)  — unused (reserved)
    #   bit 5 (32)  — unused (reserved)
    #   bit 6 (64)  — TINT_OVERRIDE
    # The reserved bits collapse to identical bytecode under the same
    # functional axes, so the mapper just ignores them — slangc gets the
    # same -specialize tuple for every collapse-equivalent index.
    null_pass = bool(idx & 2)
    mrt       = bool(idx & 1)
    shadows   = bool(idx & 4)
    tint      = bool(idx & 64)

    npS = "true" if null_pass else "false"
    mrtS = "true" if mrt      else "false"
    shS  = "true" if shadows  else "false"
    tnS  = "true" if tint     else "false"
    # HAS_NULL_PASS / HAS_MRT migrated to preprocessor defines (see
    # terrain_ps.slang and ps_io.slang for the rationale).
    defines: List[str] = []
    if null_pass:
        defines.append("WC3_TERRAIN_NULL_PASS=1")
    elif mrt:
        defines.append("WC3_HAS_MRT=1")
    if shadows:
        defines.append("WC3_HAS_SHADOWS=1")
    return PermSpec(
        entry="terrain_ps_main",
        types=[shS, tnS],
        defines=defines,
        label=f"NULL={npS}+MRT={mrtS}+SH={shS}+TINT={tnS}",
    )


def map_popcorn_vs(idx: int) -> PermSpec:
    # 72 perms = 9 outer blocks × 8 inner bits.
    #   inner bits (0..7):
    #     bit 0 — HAS_RANDOM
    #     bit 1 — HAS_VC
    #     bit 2 — HAS_NT
    #   outer = mode_idx * 3 + uv_variant   (mode 0..2, variant 0..2):
    #     mode 0 = basic, 1 = billboard, 2 = atlas
    #     variant 0 = no UV (collapses any mode to PopcornNoUV)
    #     variant 1/2 = UV stream bound (the engine compiles two
    #                   redundant variants per mode — they map to the
    #                   same set of POPCORN_* defines here).
    #
    # popcorn_vs uses preprocessor defines (POPCORN_HAS_*) to gate
    # which fields are declared on PopcornVSInput / PopcornVSOutput,
    # rather than slang `Conditional<>` (which slangc miscompiles on
    # entry-point IO with compound bool gates — see vs_io.slang). The
    # entry has no slang generics, so `types` is empty.
    inner    = idx & 7
    outer    = idx // 8
    mode_idx = outer // 3
    uv_var   = outer %  3

    has_rand = bool(inner & 1)
    has_vc   = bool(inner & 2)
    has_nt   = bool(inner & 4)

    if uv_var == 0:
        mode_label = "NoUV"
        has_uv      = False
        is_billboard = False
        is_atlas     = False
    elif mode_idx == 0:
        mode_label = "BasicUV"
        has_uv      = True
        is_billboard = False
        is_atlas     = False
    elif mode_idx == 1:
        mode_label = "Billboard"
        has_uv      = True
        is_billboard = True
        is_atlas     = False
    else:
        mode_label = "Atlas"
        has_uv      = True
        is_billboard = False
        is_atlas     = True

    defines: List[str] = []
    if has_uv:
        defines.append("POPCORN_HAS_UV=1")
    if is_billboard:
        defines.append("POPCORN_BILLBOARD=1")
    if is_atlas:
        defines.append("POPCORN_ATLAS=1")
    if is_billboard or is_atlas:
        defines.append("POPCORN_HAS_BB_OR_ATLAS=1")
    if has_rand and has_uv:
        defines.append("POPCORN_HAS_RANDOM_UV=1")
    if has_vc:
        defines.append("POPCORN_HAS_VC=1")
    if has_nt:
        defines.append("POPCORN_HAS_NT=1")

    return PermSpec(
        entry="popcorn_vs_main",
        types=[],
        label=f"{mode_label}+R={int(has_rand)}+VC={int(has_vc)}+NT={int(has_nt)}",
        defines=defines,
    )


def map_popcorn_ps(idx: int) -> PermSpec:
    # 1152 perms = 9 outer blocks × 128 inner bits.
    #   inner bits (0..127):
    #     bit 0 (0x01) — HAS_GBUFFER         (COLOR pass only)
    #     bit 1 (0x02) — FOG_LINEAR          (COLOR pass only)
    #     bit 2 (0x04) — FOG_EXP             (COLOR pass only;
    #                                         set with bit 1 → FogExp2)
    #     bit 3 (0x08) — HAS_SOFT_PARTICLES  (both passes)
    #     bit 4 (0x10) — HAS_ALPHA_LUT       (COLOR pass only)
    #     bit 5 (0x20) — HAS_VC              (both passes)
    #     bit 6 (0x40) — HAS_LIT             (COLOR pass only)
    #
    #   outer (0..8) = mode_idx * 3 + uv_variant:
    #     mode 0 = basic, 1 = billboard, 2 = atlas
    #     variant 0 = no UV         → PopcornNoUV       (COLOR pass)
    #     variant 1 = COLOR pass    → PopcornBasicUV / Billboard / Atlas
    #     variant 2 = MOTION pass   → same modes, IS_MOTION_PASS = true
    #
    # Note: many bit combinations collapse semantically (e.g. all the
    # COLOR-pass-only bits are no-ops in MOTION_PASS) but the engine
    # still compiles every variant so its perm-table stays a fixed grid.
    # We mirror that 1:1 here so the Slang specialisations line up
    # perm-for-perm with the original BLS bundle.
    inner    = idx & 0x7F
    outer    = idx // 128
    mode_idx = outer // 3
    uv_var   = outer %  3

    if uv_var == 0:
        mode = "PopcornNoUV"
    elif mode_idx == 0:
        mode = "PopcornBasicUV"
    elif mode_idx == 1:
        mode = "PopcornBillboard"
    else:
        mode = "PopcornAtlas"

    is_motion = "true" if uv_var == 2 else "false"

    fogL = bool(inner & 0x02)
    fogE = bool(inner & 0x04)
    if fogL and fogE:
        fog = "FogExp2"
    elif fogL:
        fog = "FogLinear"
    elif fogE:
        fog = "FogExponential"
    else:
        fog = "FogNone"

    has_gbuf = "true" if (inner & 0x01) else "false"
    has_sp   = "true" if (inner & 0x08) else "false"
    has_alut = "true" if (inner & 0x10) else "false"
    has_vc   = "true" if (inner & 0x20) else "false"
    has_lit  = "true" if (inner & 0x40) else "false"

    # PopcornPSInput is gated by the same POPCORN_HAS_* defines that
    # gate PopcornVSOutput so d3d12 PSO validation (PS ISG1 ⊆ VS OSG1)
    # accepts the link. The engine is expected to pair PS perms with VS
    # perms that have matching gating:
    #   HAS_LIT (PS)        ↔ HAS_NT (VS)
    #   HAS_ALPHA_LUT (PS)  ↔ HAS_RANDOM (VS)   when there's a UV stream
    #   HAS_VC, UV, mode    ↔ same on both sides
    defines: List[str] = []
    if uv_var != 0:
        defines.append("POPCORN_HAS_UV=1")
        if mode_idx == 1:
            defines.append("POPCORN_BILLBOARD=1")
            defines.append("POPCORN_HAS_BB_OR_ATLAS=1")
        elif mode_idx == 2:
            defines.append("POPCORN_ATLAS=1")
            defines.append("POPCORN_HAS_BB_OR_ATLAS=1")
    if inner & 0x20:
        defines.append("POPCORN_HAS_VC=1")
    if inner & 0x40:
        defines.append("POPCORN_HAS_NT=1")
    if (inner & 0x10) and uv_var != 0:
        defines.append("POPCORN_HAS_RANDOM_UV=1")
    # HAS_GBUFFER && !IS_MOTION_PASS migrated to WC3_POPCORN_HAS_GBUFFER
    # preprocessor define so the deferred-targets struct fields can be
    # #if-gated (see popcorn_ps.slang for the WGSL emit rationale).
    if (inner & 0x01) and uv_var != 2:
        defines.append("WC3_POPCORN_HAS_GBUFFER=1")

    return PermSpec(
        entry="popcorn_ps_main",
        types=[mode, fog, is_motion, has_sp, has_alut, has_vc, has_lit],
        label=(f"{mode}+M={is_motion}+{fog}+G={has_gbuf}+SP={has_sp}"
               f"+ALUT={has_alut}+VC={has_vc}+LIT={has_lit}"),
        defines=defines,
    )


def map_sd_classic_ps(idx: int) -> PermSpec:
    low     = idx & 7
    t0stage = (idx // 8) % 5
    t1stage = (idx // 40) % 5

    fogL = bool(low & 1)
    fogE = bool(low & 2)
    at   = bool(low & 4)

    if fogL and fogE:
        fog = "FogExp2"
    elif fogL:
        fog = "FogLinear"
    elif fogE:
        fog = "FogExponential"
    else:
        fog = "FogNone"
    alpha = "AlphaTestOn" if at else "AlphaTestOff"

    return PermSpec(
        entry="sd_classic_ps_main",
        types=[STAGE_NAMES[t0stage], STAGE_NAMES[t1stage], fog, alpha],
        label=f"T0={t0stage}+T1={t1stage}+{fog}+{alpha}",
    )


# Per-family permutation mappers. These are the only piece of family
# metadata that stays as code — each maps a linear perm index to the
# tuple of slangc -specialize types for that perm (bit-packed feature
# axes, conditional type-name selection). Everything else (stage,
# perm_count, entry point, module) comes from wc3_shaders.json.
MAPPERS: dict[str, Callable[[int], PermSpec]] = {
    "hd_vs":          map_hd_vs,
    "hd_ps":          map_hd_ps,
    "toon_hd_vs":     map_toon_hd_vs,
    "toon_hd_ps":     map_toon_hd_ps,
    "gritty_hd_vs":   map_gritty_hd_vs,
    "gritty_hd_ps":   map_gritty_hd_ps,
    "crystal_ps":     map_crystal_ps,
    "sd_on_hd_vs":    map_sd_on_hd_vs,
    "sd_on_hd_ps":    map_sd_on_hd_ps,
    "sd_highspec_vs": map_sd_highspec_vs,
    "sd_classic_ps":  map_sd_classic_ps,
    "water_vs":       map_water_vs,
    "water_ps":       map_water_ps,
    "popcorn_vs":     map_popcorn_vs,
    "popcorn_ps":     map_popcorn_ps,
    "tonemap_ps":     map_tonemap_ps,
    "sprite_vs":      map_sprite_vs,
    "sprite_ps":      map_sprite_ps,
    "terrain_vs":     map_terrain_vs,
    "terrain_ps":     map_terrain_ps,
    "foliage_vs":     map_foliage_vs,
    "foliage_ps":     map_foliage_ps,
    "distortion_ps":  map_distortion_ps,
    "imgui_vs":       map_imgui_vs,
    "imgui_ps":       map_imgui_ps,
}

# Fail fast if the config and the mapper set drift — every family listed
# in wc3_shaders.json must have a mapper implementation here, and vice versa.
_missing_mappers = set(FAMILY_CONFIGS) - set(MAPPERS)
_orphan_mappers  = set(MAPPERS)        - set(FAMILY_CONFIGS)
if _missing_mappers or _orphan_mappers:
    raise SystemExit(
        f"wc3_shaders.json / MAPPERS mismatch — "
        f"missing mappers for {sorted(_missing_mappers)}, "
        f"orphan mappers for {sorted(_orphan_mappers)}"
    )

# Iteration order matches wc3_shaders.json (i.e. FAMILY_CONFIGS insertion order).
SWEEPS = [
    (name, cfg.perm_count, MAPPERS[name], cfg.stage)
    for name, cfg in FAMILY_CONFIGS.items()
]


def main() -> int:
    global OUT_BASE, DEBUG_BUILD

    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--family", action="append",
                        choices=(*FAMILIES, "all"),
                        help="Limit compilation to one or more families "
                             "(repeat the flag). Default: every family.")
    parser.add_argument("--target", choices=(*TARGETS.keys(), "all"),
                        default="d3d11",
                        help="Graphics API target (default: d3d11).")
    parser.add_argument("--debug", action="store_true",
                        help="Emit debug shaders: full debug symbols (-g2), "
                             "no optimisation (-O0), and -emit-spirv-directly "
                             "for the vulkan target. Output goes to a separate "
                             "slang_out_debug/ tree so it never collides with "
                             "the optimised slang_out/.")
    parser.add_argument("--metallib", metavar="MACOS_MIN",
                        help="Emit compiled Metal bytecode (.metallib) with the given "
                             "macOS deployment target (e.g. `11` or `11.0`). Requires "
                             "Apple's Metal compiler (Xcode) — macOS only. On macOS "
                             "the metal target is auto-included with macOS min 11 "
                             "unless this flag overrides it.")
    parser.add_argument("--slangc", help="Path to slangc executable "
                                         "(overrides PATH / VULKAN_SDK lookup).")
    parser.add_argument("--slangc-for", action="append", default=[],
                        metavar="FAMILY=PATH",
                        help="Per-family slangc override. Repeatable. "
                             "Example: --slangc-for popcorn_vs=C:/slang/slangc.exe. "
                             "Workaround for families that need a newer compiler "
                             "(slangc 2026.1 miscompiles compound bool gates in "
                             "Conditional fields used by popcorn_vs).")
    parser.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 1,
                        help="Number of parallel slangc processes to run "
                             "(default: %(default)s = os.cpu_count()). "
                             "Each permutation is an independent slangc "
                             "invocation, so this scales near-linearly until "
                             "you saturate the CPU. Use --jobs 1 for "
                             "deterministic single-thread output.")
    args = parser.parse_args()
    if args.jobs < 1:
        args.jobs = 1

    # --debug retargets the whole run: bytecode goes to slang_out_debug/
    # and invoke_slangc switches on the -g2 / -O0 / -emit-spirv-directly
    # path. Done before any path is touched so OUT_BASE is consistent.
    if args.debug:
        OUT_BASE = OUT_BASE_DEBUG
        DEBUG_BUILD = True

    # On macOS we can drive Apple's metal compiler to emit real .metallib
    # bytecode (not just .metal source), which build_bls.py can then pack
    # into mtlfs/mtlvs BLS files. On other platforms this step is skipped
    # — Apple's toolchain is not available.
    mac_min = args.metallib or ("11" if sys.platform == "darwin" else None)
    if mac_min:
        # Emit .metal source via slangc, then drive xcrun metal + metallib
        # ourselves so we control the deployment target. slangc's built-in
        # metallib backend ignores -Xmetal -mmacosx-version-min and pins
        # the container at 1.2.7 (Metal 4.x), whereas xcrun-driven we get
        # 1.2.5 at mac-min=11 (Metal 2.3, the lowest slangc syntax permits).
        TARGETS["metal"] = {
            "target": "metal",
            "ext":    "metallib",
            "vs":     "sm_6_0",
            "ps":     "sm_6_0",
            "extra":  [],
        }
        global METALLIB_MAC_MIN
        METALLIB_MAC_MIN = mac_min

    slangc = resolve_slangc(args.slangc)
    print(f"Using slangc: {slangc}")
    print(f"Shader module: {SHADER}")
    print(f"Parallel jobs: {args.jobs}")
    print(f"Output base:   {OUT_BASE}")
    if DEBUG_BUILD:
        print("Build mode:    DEBUG (-g2 -O0, +emit-spirv-directly)")
    if mac_min:
        print(f"Metal output: metallib (macOS min={mac_min})")

    OUT_BASE.mkdir(exist_ok=True)

    active_targets = list(TARGETS.keys()) if args.target == "all" else [args.target]
    # macOS bonus: always emit metallibs alongside the primary target so
    # build_bls.py can repackage the mtlfs/mtlvs BLS files.
    if sys.platform == "darwin" and "metal" not in active_targets:
        active_targets.append("metal")

    # `args.family` is None when the flag isn't passed (→ every family),
    # a list of names when passed one or more times, or `["all"]` for
    # the explicit catch-all keyword.
    selected_families = None
    if args.family and "all" not in args.family:
        selected_families = set(args.family)

    # Parse `--slangc-for FAMILY=PATH` repeatables into a {family: path} map.
    # Used to override the default slangc on a per-family basis (e.g. when
    # the default slangc miscompiles a specific family — see the flag help).
    family_slangc: Dict[str, str] = {}
    for entry in args.slangc_for:
        if "=" not in entry:
            raise SystemExit(
                f"--slangc-for expects FAMILY=PATH (got '{entry}')")
        fam, _, path = entry.partition("=")
        if fam not in FAMILIES:
            raise SystemExit(
                f"--slangc-for: unknown family '{fam}' "
                f"(known: {', '.join(FAMILIES)})")
        if not Path(path).is_file():
            raise SystemExit(
                f"--slangc-for {fam}: slangc not found at '{path}'")
        family_slangc[fam] = path

    all_results: List[tuple] = []  # (target_key, SweepResult)
    for target_key in active_targets:
        for name, count, mapper, stage in SWEEPS:
            if selected_families is not None and name not in selected_families:
                continue
            result = run_sweep(name, count, mapper, stage, target_key,
                               args.jobs, family_slangc.get(name))
            all_results.append((target_key, result))

    print()
    print("=" * 72)
    print("SUMMARY")
    print("=" * 72)
    total = SweepResult(family="TOTAL", count=0)
    for target_key, r in all_results:
        total.count += r.count
        total.ok    += r.ok
        total.fail  += r.fail
        label = f"[{target_key}] {r.family}"
        print(f"{label:<28}  total={r.count:>4}  "
              f"compile={r.ok:>4}ok/{r.fail:>4}fail")
    print()
    print(f"{'TOTAL':<28}  total={total.count:>4}  "
          f"compile={total.ok:>4}ok/{total.fail:>4}fail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
