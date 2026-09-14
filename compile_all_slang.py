"""Compile all permutations of every shader entry point from the unified
wc3_shaders Slang module, to one of several graphics-API targets.

Runs independently of the current working directory — paths resolve
relative to this script's location.

    --target {d3d11,d3d12,vulkan,opengl,metal,webgpu,all}  (default: d3d11)
    --family {hd_vs,hd_ps,crystal_ps,sd_on_hd_vs,sd_on_hd_ps,sd_highspec_vs,
              sd_classic_ps,water_vs,water_ps,tonemap_ps,all}
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
import time
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


def unlink_retry(path: Path, attempts: int = 10) -> None:
    """Delete a file, tolerating Windows' brief post-exec handle hold.

    slangc and dxc have both already exited when we clean up their
    intermediates, but Windows can keep the image handle mapped for a few
    milliseconds afterwards and `unlink` then raises WinError 32. With many
    parallel jobs that is rare per call and near-certain across a 1024-perm
    sweep, and it used to abort the whole run. Retry briefly, then give up
    quietly: a leftover intermediate is harmless, an aborted sweep is not.
    """
    for i in range(attempts):
        try:
            path.unlink(missing_ok=True)
            return
        except PermissionError:
            time.sleep(0.02 * (i + 1))
    try:
        path.unlink(missing_ok=True)
    except PermissionError:
        pass


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
    # WGSL backend uses #ifdef WGSL_TARGET to shrink PS binding offsets,
    # and shares the scalar-split CB layout with Metal — see PSPerDraw
    # in cb_structs.slang. Both targets land at the same byte offsets the
    # host CB writer expects (HLSL register-packing); the alternative
    # `float3` padding would shift everything by 16 bytes under WGSL
    # std140 / Slang's Metal natural-buffer layout.
    effective_defines = list(defines or [])
    if target == "wgsl":
        effective_defines.append("WGSL_TARGET=1")
    if target == "metal":
        effective_defines.append("METAL_TARGET=1")
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
    # DXIL via HLSL: slangc's HLSL/DX backend mis-emits vertex input semantics
    # (ATTR3 → ATTR30 — every numeric suffix gains a trailing 0). Patching the
    # *compiled* DXIL container to fix this corrupts the signed DXIL (its PSV0 /
    # HASH / metadata go stale and D3D12 rejects it). Instead we emit HLSL,
    # text-patch the semantics, and let DXC compile + sign a consistent
    # container. Only the DX12/DXIL path takes this route; SPIR-V / Metal /
    # WGSL go straight from slangc to their target and never see HLSL.
    dxil_via_hlsl = (target == "dxil")
    emit_target = "hlsl" if dxil_via_hlsl else target
    if dxil_via_hlsl:
        slangc_out = out_path.with_suffix(".hlsl")
    elif metal_via_xcrun:
        slangc_out = out_path.with_suffix(".metal")
    else:
        slangc_out = out_path
    args += [
        "-profile", profile,
        "-target", emit_target,
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
        unlink_retry(out_path)
    if metal_via_xcrun and slangc_out.exists():
        unlink_retry(slangc_out)

    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        # On failure we drop a sibling .err file with stderr so the
        # caller (or a curious user) can inspect what went wrong; the
        # sweep summary still surfaces the perm in fail_list.
        err_path = out_path.with_suffix(out_path.suffix + ".err")
        err_path.write_text(proc.stderr or proc.stdout or "(no slangc output)")
        return False
    if dxil_via_hlsl:
        # slangc_out is the emitted HLSL. Fix the ATTRn → ATTRn0 semantic bug
        # in source, then DXC compiles + validates + signs a consistent DXIL.
        if not slangc_out.exists() or slangc_out.stat().st_size == 0:
            return False
        patch_hlsl_attr_semantics(slangc_out)
        dxc = resolve_dxc(slangc_exe)
        dxc_args = [dxc, "-T", profile, "-E", entry,
                    str(slangc_out), "-Fo", str(out_path)]
        if DEBUG_BUILD:
            dxc_args += ["-Zi", "-Qembed_debug", "-Od"]
        # Retry a failed dxc the same way we retry unlink: under parallel
        # jobs Windows occasionally still holds the freshly written .hlsl
        # open, and dxc's loader reports the sharing violation as "cannot
        # find the file specified" even though the file is plainly there
        # (we stat it two lines up). Only that message is retried — a real
        # compile error is returned on the first attempt, unchanged.
        for attempt in range(4):
            dxc_proc = subprocess.run(dxc_args, capture_output=True, text=True)
            if dxc_proc.returncode == 0:
                break
            msg = (dxc_proc.stderr or "") + (dxc_proc.stdout or "")
            if "cannot find the file" not in msg.lower():
                break
            time.sleep(0.05 * (attempt + 1))
        unlink_retry(slangc_out)
        if dxc_proc.returncode != 0:
            err_path = out_path.with_suffix(out_path.suffix + ".err")
            err_path.write_text("dxc failed:\n" +
                                (dxc_proc.stderr or dxc_proc.stdout or ""))
            return False
    elif metal_via_xcrun:
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
            unlink_retry(slangc_out)
            return False
        lib_proc = subprocess.run(
            ["xcrun", "metallib", str(air_path), "-o", str(out_path)],
            capture_output=True, text=True)
        # Intermediates aren't useful to keep around — they confuse the
        # incremental mtime check on the next run and clutter slang_out/.
        unlink_retry(slangc_out)
        unlink_retry(air_path)
        if lib_proc.returncode != 0:
            err_path = out_path.with_suffix(out_path.suffix + ".err")
            err_path.write_text(
                "xcrun metallib failed:\n" +
                (lib_proc.stderr or lib_proc.stdout or ""))
            return False
    elif target == "wgsl" and out_path.exists() and out_path.stat().st_size > 0:
        fix_wgsl_depth_textures(out_path)
        rename_wgsl_entry_to_main(out_path)
    elif target == "glsl" and out_path.exists() and out_path.stat().st_size > 0:
        fix_glsl_shadow_lod_extension(out_path)
    return out_path.exists() and out_path.stat().st_size > 0


# slangc's HLSL/DX backend appends a stray '0' to every numeric vertex-input
# semantic suffix (ATTR0 → ATTR00, ATTR3 → ATTR30, … ATTR8 → ATTR80), so the
# declared input register becomes 0/10/20/… instead of 0/1/2/…. Fix it in the
# emitted HLSL before DXC/FXC compile. Only the input ATTR semantics face the
# host vertex layout; the interpolated VS→PS semantics (COLOR/TEXCOORD) stay
# consistently shifted on both sides, so leaving them alone keeps linkage valid.
_ATTR_SEMANTIC_FIX_RE = re.compile(r'(:\s*ATTR\d)0\b')


def patch_hlsl_attr_semantics(hlsl_path: Path) -> None:
    text = hlsl_path.read_text(encoding="utf-8")
    fixed = _ATTR_SEMANTIC_FIX_RE.sub(r'\1', text)
    if fixed != text:
        hlsl_path.write_text(fixed, encoding="utf-8")


_dxc_path: Optional[str] = None


def resolve_dxc(slangc_exe: str) -> str:
    """Locate dxc.exe — used to compile the patched HLSL to signed DXIL.
    Prefers the dxc sitting next to slangc (same Vulkan SDK Bin)."""
    global _dxc_path
    if _dxc_path is not None:
        return _dxc_path
    exe = "dxc.exe" if os.name == "nt" else "dxc"
    sibling = Path(slangc_exe).parent / exe
    if sibling.is_file():
        _dxc_path = str(sibling)
        return _dxc_path
    found = shutil.which("dxc")
    if found:
        _dxc_path = found
        return _dxc_path
    if os.name == "nt":
        matches = sorted(glob.glob(r"C:\VulkanSDK\*\Bin\dxc.exe"))
        if matches:
            _dxc_path = matches[-1]
            return _dxc_path
    raise RuntimeError(
        "dxc not found (needed to compile patched HLSL to DXIL). Install the "
        "Vulkan SDK or put dxc on PATH.")


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


    # Longest shape first: `texture_2d` is a prefix of `texture_2d_array`,
    # and `texture_cube` of `texture_cube_array`.
    name_alt = "|".join(re.escape(n) for n in sorted(depth_names))
    new_text = text
    for sampled, depth in (("texture_2d_array",   "texture_depth_2d_array"),
                           ("texture_cube_array", "texture_depth_cube_array"),
                           ("texture_2d",         "texture_depth_2d"),
                           ("texture_cube",       "texture_depth_cube")):
        new_text = re.sub(
            rf"\b({name_alt})\b(\s*:\s*){sampled}<\s*f32\s*>",
            rf"\1\2{depth}",
            new_text,
        )
    if new_text != text:
        wgsl_path.write_text(new_text, encoding="utf-8")


# A `textureLod` on a shadow sampler needs GL_EXT_texture_shadow_lod: core GLSL
# has no explicit-LOD overload for the *Shadow sampler types. slangc 2026.x
# requests it when the call is on a `samplerCubeArrayShadow` but NOT when it is
# on a `sampler2DArrayShadow`, so a shader that only samples the main light's
# cascade array (HD 3.0.0 with SHADOW_CASCADE but not POINT_SHADOWS — 64 of the
# 1024 pixel permutations) emits a call it never declares the extension for, and
# glslangValidator rejects it. Adding the line is always safe: it is a no-op on a
# shader that doesn't make the call, and we only add it when one does.
_GLSL_SHADOW_LOD_RE = re.compile(r"\btextureLod\s*\(\s*sampler\w*Shadow\s*\(")
_GLSL_SHADOW_LOD_EXT = "#extension GL_EXT_texture_shadow_lod : require"


def fix_glsl_shadow_lod_extension(glsl_path: Path) -> None:
    text = glsl_path.read_text(encoding="utf-8")
    if _GLSL_SHADOW_LOD_EXT in text or not _GLSL_SHADOW_LOD_RE.search(text):
        return
    lines = text.splitlines(keepends=True)
    # `#extension` must precede every non-preprocessor token, so it goes
    # directly after `#version`, which must itself be the first directive.
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#version"):
            lines.insert(i + 1, _GLSL_SHADOW_LOD_EXT + "\n")
            glsl_path.write_text("".join(lines), encoding="utf-8")
            return


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
    #
    # 3.0.0 ships three more families at SM4 with a Level9 part -- greyscale,
    # movie and sd_lowspec_vs, all drawn by the low-spec / feature-level-9
    # paths -- so they take the same override.
    if family in SM4_FAMILIES and target_key == "d3d11":
        profile = profile.replace("_5_0", "_4_0")

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
    """3.0.0 HD mesh vertex shader — 72 perms on a MIXED-RADIX index.

    Unlike the pixel shader (whose index is a feature bit mask), the engine
    counts the vertex permutations in mixed radix:

        index = BONE_BUFFER * 1 + TANGENT * 2 + WEIGHT_INDEX * 4
              + VERTEX_COLOR * 12 + UV_COUNT * 24        radices 2/2/3/2/3

    Two digits do not mean what they look like. WEIGHT_INDEX 0 and 1 both mean
    "no skinning" and produce identical bytecode (the engine's vertex-format
    table only ever yields a weight count of 0 or 4, so the middle class is
    unreachable), and BONE_BUFFER is only reachable through the skinned policy
    — so the 72 slots collapse to the 36 distinct programs the shipped BLS
    actually carries.

    Confirmed against the engine: GetShaderIndices case 1 in the 3.0.0 binary
    computes this exact expression. BONE_BUFFER is `boneCount > 256`, which is
    the condition XformSetBones uses to bind the palette as a structured buffer
    instead of the 256-bone constant buffer. See docs/WC3_HD_PERMUTATIONS.md.
    """
    bone_buffer  = idx % 2
    tangent      = (idx // 2) % 2
    weight_index = (idx // 4) % 3
    color        = (idx // 12) % 2
    uv_count     = (idx // 24) % 3

    if weight_index == 2:
        palette = "StructuredBonePalette" if bone_buffer else "ConstantBonePalette"
        skin = f"HDFourBoneSkinning<{palette}>"
    else:
        # Both non-skinning weight indices, and with them both palette
        # sources, fold into one program.
        skin = "HDRigid"

    hasT  = "true" if tangent else "false"
    hasC  = "true" if color else "false"
    hasU0 = "true" if uv_count >= 1 else "false"
    hasU1 = "true" if uv_count >= 2 else "false"
    return PermSpec(
        entry="vs_main",
        types=[skin, f"VertexFormat<{hasT},{hasC},{hasU0},{hasU1}>"],
        defines=[],
        label=f"{skin}+T={hasT}+C={hasC}+UV={uv_count}",
    )


def _hd_ps_fold(*, ao, sc2, mrt, dp, dbg, pts, sc, lit, at, ml):
    """The 3.0.0 feature-mask dependency fold, shared by `hd_ps` and `crystal_ps`.

    Several bits only mean anything under another one, and the engine emits
    identical bytecode for the permutations that differ only in a dead bit. The
    folding below reproduces that: a depth prepass ignores every shading axis,
    the four lighting sub-axes need LIGHTING, and the second cascade set needs
    the first.

    Kept as one function because `crystal_ps` is `hd_ps`'s mask with the AO_MAP
    axis deleted (see map_crystal_ps) -- the two families must fold identically
    or one of them stops matching retail, and duplicating the rules is how that
    drifts.
    """
    if dp:
        # A depth prepass does not shade, so the material axis is dead -- but
        # only when there is no alpha test. An alpha-tested prepass still has
        # to sample alpha to decide `discard`, and MULTI_LAYER changes how that
        # alpha is composed, so retail keeps those two apart. Retail therefore
        # ships ONE blob for the plain-prepass perms and TWO for the
        # alpha-tested ones; folding unconditionally gives hd_ps 202 classes,
        # not folding at all gives 204, and this gives retail's 203.
        lit = False
        mrt = False
        if not at:
            ml = False
    if not lit:
        ao = sc = pts = dbg = False
    if not sc:
        sc2 = False
    return dict(ao=ao, sc2=sc2, mrt=mrt, dp=dp, dbg=dbg,
                pts=pts, sc=sc, lit=lit, at=at, ml=ml)


def map_hd_ps(idx: int) -> PermSpec:
    """3.0.0 HD mesh pixel shader — 1024 perms on a 10-bit feature mask.

    Several bits only mean anything under another one, and the engine emits
    identical bytecode for the permutations that differ only in a dead bit. The
    folding below reproduces that: a depth prepass ignores every shading axis,
    the four lighting sub-axes need LIGHTING, and the second cascade set needs
    the first.

    MULTI_TARGET and DEPTH_PREPASS are preprocessor defines rather than slang
    generics because they reshape PSOutput itself — see types/ps_io.slang.

    Confirmed against the engine: GetShaderIndices case 1 in the 3.0.0 binary
    builds this exact mask, bit for bit. See docs/WC3_HD_PERMUTATIONS.md for
    where each bit comes from in the render state.
    """
    f = _hd_ps_fold(
        ao =bool(idx &   1),   # AO_MAP
        sc2=bool(idx &   2),   # SHADOW_CASCADE2
        mrt=bool(idx &   4),   # MULTI_TARGET
        dp =bool(idx &   8),   # DEPTH_PREPASS
        dbg=bool(idx &  16),   # LIGHT_DEBUG
        pts=bool(idx &  32),   # POINT_SHADOWS
        sc =bool(idx &  64),   # SHADOW_CASCADE
        lit=bool(idx & 128),   # LIGHTING
        at =bool(idx & 256),   # ALPHA_TEST
        ml =bool(idx & 512),   # MULTI_LAYER
    )
    ao, sc2, mrt, dp = f["ao"], f["sc2"], f["mrt"], f["dp"]
    dbg, pts, sc, lit = f["dbg"], f["pts"], f["sc"], f["lit"]
    at, ml = f["at"], f["ml"]

    alpha = "AlphaTestOn" if at else "AlphaTestOff"
    mat = "MultiLayerMaterial" if ml else "StandardMaterial"
    s = lambda v: "true" if v else "false"

    defines: List[str] = []
    if dp:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if mrt:
        defines.append("WC3_IS_MRT=1")

    flags = "+".join(n for n, v in (("LIT", lit), ("AO", ao), ("SC", sc),
                                    ("SC2", sc2), ("PS", pts), ("DBG", dbg),
                                    ("DP", dp), ("MRT", mrt)) if v)
    return PermSpec(
        entry="ps_main",
        types=[alpha, mat, s(lit), s(ao), s(sc), s(sc2), s(pts), s(dbg)],
        defines=defines,
        label=f"{alpha}+{mat}" + (f"+{flags}" if flags else ""),
    )


def map_crystal_ps(idx: int) -> PermSpec:
    """3.0.0 crystal pixel shader -- 512 perms: hd_ps's mask with AO_MAP deleted.

    Crystal is not a cousin of the HD mesh shader, it IS the HD mesh shader with
    one axis removed and three pieces of material math swapped in. Its 9-bit
    index is hd_ps's 10-bit index with bit 0 (AO_MAP) struck out and everything
    above it shifted down one, so crystal index `c` denotes exactly the feature
    set of hd index `2 * c`:

        bit 0 (  1)  SHADOW_CASCADE2      bit 5 ( 32)  SHADOW_CASCADE
        bit 1 (  2)  MULTI_TARGET         bit 6 ( 64)  LIGHTING
        bit 2 (  4)  DEPTH_PREPASS        bit 7 (128)  ALPHA_TEST
        bit 3 (  8)  LIGHT_DEBUG          bit 8 (256)  MULTI_LAYER
        bit 4 ( 16)  POINT_SHADOWS

    Three independent confirmations, each actually run against the extraction:
    the two retail class partitions are EQUAL AS INDEX SETS under c -> 2c (107
    classes each, not merely the same count); crystal/perm_004 is byte-identical
    to hd/perm_0008, declarations included; and no crystal permutation samples
    t2 at UV1, which is the single instruction hd's AO axis adds. Crystal's
    declarations and input signature are byte-for-byte hd's on the lit perms
    too -- same cb1[43]/cb2[31], same t0-t3/t6-t8/t11-t13, same t16/t17/t18
    light buffers, same eight interpolants.

    Because the axes are hd's, the FOLD is hd's: `_hd_ps_fold` is shared rather
    than restated, `dp and not at -> keep MULTI_LAYER` included. AO is pinned
    off, which is what takes hd's 203 classes down to crystal's 107.

    What the shader body does differently is three things and no more -- the
    refracted albedo, the raw (unscaled) normal-map decode, and the
    refract-modulated fresnel alpha. See ps/crystal_ps_body.slang.
    """
    f = _hd_ps_fold(
        ao =False,             # crystal has no AO_MAP axis at all
        sc2=bool(idx &   1),   # SHADOW_CASCADE2
        mrt=bool(idx &   2),   # MULTI_TARGET
        dp =bool(idx &   4),   # DEPTH_PREPASS
        dbg=bool(idx &   8),   # LIGHT_DEBUG
        pts=bool(idx &  16),   # POINT_SHADOWS
        sc =bool(idx &  32),   # SHADOW_CASCADE
        lit=bool(idx &  64),   # LIGHTING
        at =bool(idx & 128),   # ALPHA_TEST
        ml =bool(idx & 256),   # MULTI_LAYER
    )
    sc2, mrt, dp, dbg = f["sc2"], f["mrt"], f["dp"], f["dbg"]
    pts, sc, lit, at, ml = f["pts"], f["sc"], f["lit"], f["at"], f["ml"]

    alpha = "AlphaTestOn" if at else "AlphaTestOff"
    mat = "MultiLayerMaterial" if ml else "StandardMaterial"
    s = lambda v: "true" if v else "false"

    # MULTI_TARGET and DEPTH_PREPASS reshape PSOutput itself, so they are
    # preprocessor defines rather than generics -- see types/ps_io.slang.
    defines: List[str] = []
    if dp:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if mrt:
        defines.append("WC3_IS_MRT=1")

    flags = "+".join(n for n, v in (("LIT", lit), ("SC", sc), ("SC2", sc2),
                                    ("PS", pts), ("DBG", dbg), ("DP", dp),
                                    ("MRT", mrt)) if v)
    return PermSpec(
        entry="crystal_ps_main",
        types=[alpha, mat, s(lit), s(sc), s(sc2), s(pts), s(dbg)],
        defines=defines,
        label=f"{alpha}+{mat}" + (f"+{flags}" if flags else ""),
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
    """3.0.0 SD-on-HD pixel shader — 384 perms, 6 outer blocks x 64 bits.

    Same clustered-forward pipeline as `hd_ps`, same HD vertex shader, same
    constant buffers and the same t16/t17/t18 light buffers — the difference is
    the material: SD assets carry albedo only, so t1/t2/t3/t4 (normal, ORM,
    emissive, team) are never sampled and the shading normal is the
    interpolated one.

    Fog is NOT an axis any more. 2.0.0 spent low bits 4 and 5 on FOG_LINEAR /
    FOG_EXPONENTIAL; 3.0.0 evaluates fog from constants at runtime and spends
    those bits on the two shadow axes instead.

    The outer field is `lit + 2 * sub`, where sub picks the output transform:
    0 = plain, 1 = alpha test, 2 = sRGB encode. Under a depth prepass both
    LIGHTING and the sRGB encode are dead (there is no colour target), which is
    what collapses the outer field to 3 distinct programs there; ALPHA_TEST
    stays live because the prepass still has to punch the same holes.

    Derived from the retail partition: this folding reproduces all 80 of the
    distinct programs in ps/sd_on_hd.bls exactly
    (`tools/wc3_perm_partition.py sd_on_hd_ps`).
    """
    sc2 = bool(idx & 1)      # SHADOW_CASCADE2 — needs SHADOW_CASCADE
    mrt = bool(idx & 2)      # MULTI_TARGET
    dp  = bool(idx & 4)      # DEPTH_PREPASS
    dbg = bool(idx & 8)      # LIGHT_DEBUG
    pts = bool(idx & 16)     # POINT_SHADOWS
    sc  = bool(idx & 32)     # SHADOW_CASCADE

    outer = idx // 64
    lit   = bool(outer % 2)
    sub   = outer // 2
    at    = sub == 1
    srgb  = sub == 2

    if dp:
        lit = False
        mrt = False
        srgb = False          # no colour target to encode into
    if not lit:
        sc = pts = dbg = sc2 = False
    if not sc:
        sc2 = False

    alpha = "AlphaTestOn" if at else "AlphaTestOff"
    s = lambda v: "true" if v else "false"

    defines: List[str] = []
    if dp:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if mrt:
        defines.append("WC3_IS_MRT=1")

    flags = "+".join(n for n, v in (("LIT", lit), ("SC", sc), ("SC2", sc2),
                                    ("PS", pts), ("DBG", dbg), ("SRGB", srgb),
                                    ("DP", dp), ("MRT", mrt)) if v)
    return PermSpec(
        entry="sd_on_hd_ps_main",
        types=[alpha, s(lit), s(sc), s(sc2), s(pts), s(dbg), s(srgb)],
        defines=defines,
        label=alpha + (f"+{flags}" if flags else ""),
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
    """3.0.0 water pixel shader -- 128 perms on a 7-bit mask, 49 programs.

        bit 0 SHADOW_CASCADE2   1 DEPTH_PREPASS   2 LIGHT_DEBUG
        bit 3 POINT_SHADOWS     4 SHADOW_CASCADE  5-6 SSR quality

    The SSR bits are one 2-bit axis, not two booleans: 0 = no reflection
    march, 1 / 2 / 3 = 16 / 32 / 64 coarse steps. A depth prepass is an empty
    program whatever else is set; the second cascade set needs the first.
    Water has no LIGHTING, ALPHA_TEST or MULTI_TARGET axis -- it is always lit
    and always writes both targets.
    """
    dp = bool(idx & 2)
    sc = bool(idx & 16) and not dp
    sc2 = bool(idx & 1) and sc
    dbg = bool(idx & 4) and not dp
    pts = bool(idx & 8) and not dp
    ssr = 0 if dp else (idx >> 5) & 3
    steps = (0, 16, 32, 64)[ssr]
    s = lambda v: "true" if v else "false"
    defines: List[str] = ["WC3_IS_DEPTH_PREPASS=1"] if dp else []
    flags = "+".join(n for n, v in (("SC", sc), ("SC2", sc2), ("PS", pts),
                                    ("DBG", dbg), ("DP", dp)) if v)
    return PermSpec(
        entry="water_ps_main",
        types=[s(sc), s(sc2), s(pts), s(dbg), str(steps)],
        defines=defines,
        label=(flags or "base") + f"+SSR{steps}",
    )


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
    # matching the engine's perm_003 == perm_000 collapse. Fold it HERE, not
    # only in the shader body: the body returning the same value is not the
    # same as one specialisation, and G1 (wc3_perm_partition.py) counts
    # specialisations -- retail ships 3 blobs for these 4 perms.
    enc_b, dec_b = bool(idx & 1), bool(idx & 2)
    if enc_b and dec_b:
        enc_b = dec_b = False
    enc = "true" if enc_b else "false"
    dec = "true" if dec_b else "false"
    return PermSpec(
        entry="sprite_ps_main",
        types=[enc, dec],
        label=f"ENC={enc}+DEC={dec}",
    )


def map_sd_lowspec_vs(idx: int) -> PermSpec:
    """3.0.0 low-spec SD vertex shader -- highspec's 162 perms and axes over a
    72-bone palette (see `sd_highspec_vs.slang`); 108 programs, like highspec."""
    spec = map_sd_highspec_vs(idx)
    return PermSpec(entry="sd_lowspec_vs_main", types=spec.types, label=spec.label)


def _single(entry: str) -> Callable[[int], PermSpec]:
    """A one-permutation family."""
    return lambda idx: PermSpec(entry=entry, types=[], label="(only)")


def map_fog_ps(idx: int) -> PermSpec:
    """3.0.0 full-screen fog: one perm per engine fog mode (0..6). Mode 4 is the
    volumetric fog, which ships as its own shader, so this pass folds it onto
    mode 0 -- retail's 7 perms are 6 blobs."""
    return PermSpec(entry="fog_ps_main", types=[FOG30_NAMES[0 if idx == 4 else idx]],
                    label=f"fog{idx}")


def map_movie_ps(idx: int) -> PermSpec:
    """3.0.0 video decode -- 24 perms, 14 programs.

        bit 0  the output is NOT sRGB-decoded
        bit 1  the source is RGB (sprite's program) rather than Y/Cb/Cr planes
        idx >> 2   0..5: colour matrix (idx >> 2) % 3 -- BT.601 / BT.709 / BT.2020 --
                   and full range when (idx >> 2) >= 3, video range below

    An RGB source reads neither the matrix nor the range, so those axes are
    zeroed for it: its 12 perms are 2 programs.
    """
    rgb = bool(idx & 2)
    srgb = not (idx & 1)
    matrix = 0 if rgb else (idx >> 2) % 3
    full = False if rgb else (idx >> 2) >= 3
    s = lambda v: "true" if v else "false"
    return PermSpec(entry="movie_ps_main", types=[s(rgb), s(srgb), str(matrix), s(full)],
                    label=f"RGB={s(rgb)}+SRGB={s(srgb)}+M{matrix}+FULL={s(full)}")


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


def map_cmaa_edge0_ps(idx: int) -> PermSpec:
    # Single permutation — CMAA edge-detection pass has no feature axes.
    return PermSpec(entry="cmaa_edge0_ps_main", types=[], label="(only)")


def map_cmaa_edge1_ps(idx: int) -> PermSpec:
    # Single permutation — CMAA local-contrast pass has no feature axes.
    return PermSpec(entry="cmaa_edge1_ps_main", types=[], label="(only)")


def map_cmaa_edge_combine_ps(idx: int) -> PermSpec:
    # Single permutation — CMAA edge-combine pass has no feature axes.
    return PermSpec(entry="cmaa_edge_combine_ps_main", types=[], label="(only)")


def map_cmaa_process_apply_ps(idx: int) -> PermSpec:
    # Single permutation — CMAA process-and-apply pass has no feature axes.
    return PermSpec(entry="cmaa_process_apply_ps_main", types=[], label="(only)")


def map_bloom_extract_ps(idx: int) -> PermSpec:
    # Single permutation — bloom bright-pass has no feature axes.
    return PermSpec(entry="bloom_extract_ps_main", types=[], label="(only)")


def map_bloom_combine_ps(idx: int) -> PermSpec:
    # 2 perms driven by 1 compile-time bool: CLAMP_OUTPUT. The two shipped
    # variants differ by exactly one instruction (final combine mad vs
    # mad_sat):
    #   perm_000  CLAMP_OUTPUT=false  (mad,     unclamped)
    #   perm_001  CLAMP_OUTPUT=true   (mad_sat, clamped)
    clamp = "true" if (idx & 1) else "false"
    return PermSpec(
        entry="bloom_combine_ps_main",
        types=[clamp],
        label=f"CLAMP={clamp}",
    )


def map_gaussian_blur_ps(idx: int) -> PermSpec:
    # Single permutation — separable Gaussian blur has no feature axes
    # (the kernel lives entirely in the uploaded tap constant buffer).
    return PermSpec(entry="gaussian_blur_ps_main", types=[], label="(only)")


def map_depth_of_field_ps(idx: int) -> PermSpec:
    # Single permutation — bokeh DoF has no feature axes (the golden-angle
    # spiral parameters all live in the uploaded constant buffer; the
    # far-field-only path is a runtime branch on cb1[2].w, not a perm).
    return PermSpec(entry="depth_of_field_ps_main", types=[], label="(only)")


def map_terrain_vs(idx: int) -> PermSpec:
    """3.0.0 terrain vertex shader -- 2 perms, one axis: bit 0 VERTEX_COLOR.

    2.0.0 shipped eight (SHADOW_PASS, RECEIVE_SHADOWS, VERTEX_COLOR); the two
    shadow bits left with the cascade outputs, as they did in foliage_vs.
    """
    vc = "true" if (idx & 1) else "false"
    return PermSpec(entry="terrain_vs_main", types=[vc], label=f"VC={vc}")


def map_foliage_vs(idx: int) -> PermSpec:
    """3.0.0 foliage vertex shader -- 2 perms, one axis: bit 0 WIND.

    2.0.0 shipped eight (SHADOW_PASS, RECEIVE_SHADOWS, WIND). The two shadow
    bits left with the cascade outputs: 3.0.0 passes the world position on every
    permutation and the pixel shader projects it, as the HD mesh VS does.
    """
    wind = "true" if (idx & 1) else "false"
    return PermSpec(entry="foliage_vs_main", types=[wind], label=f"WIND={wind}")


def map_foliage_ps(idx: int) -> PermSpec:
    """3.0.0 foliage pixel shader -- 128 perms: HD's mask, LIGHTING pinned on.

    Foliage moved onto the HD mesh's banks in 3.0.0 and took its permutation
    layout with it: HD's feature bits in HD's order, with AO_MAP and
    MULTI_LAYER struck out and LIGHTING always set, so the seven bits are

        SC2=1 MRT=2 DP=4 DBG=8 PTS=16 SC=32 AT=64

    Folded by `_hd_ps_fold` -- the same rules, not a copy of them -- which
    gives retail's 50 programs: 48 shaded (3 cascade states x MRT x DBG x
    PTS x AT) plus the plain and the alpha-tested prepass.
    """
    f = _hd_ps_fold(
        ao =False,
        sc2=bool(idx &  1),   # SHADOW_CASCADE2
        mrt=bool(idx &  2),   # MULTI_TARGET
        dp =bool(idx &  4),   # DEPTH_PREPASS
        dbg=bool(idx &  8),   # LIGHT_DEBUG
        pts=bool(idx & 16),   # POINT_SHADOWS
        sc =bool(idx & 32),   # SHADOW_CASCADE
        lit=True,
        at =bool(idx & 64),   # ALPHA_TEST
        ml =False,
    )
    alpha = "AlphaTestOn" if f["at"] else "AlphaTestOff"
    s = lambda v: "true" if v else "false"
    defines: List[str] = []
    if f["dp"]:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if f["mrt"]:
        defines.append("WC3_IS_MRT=1")
    flags = "+".join(n for n, v in (("SC", f["sc"]), ("SC2", f["sc2"]),
                                    ("PS", f["pts"]), ("DBG", f["dbg"]),
                                    ("DP", f["dp"]), ("MRT", f["mrt"])) if v)
    return PermSpec(
        entry="foliage_ps_main",
        types=[alpha, s(f["sc"]), s(f["sc2"]), s(f["pts"]), s(f["dbg"])],
        defines=defines,
        label=alpha + (f"+{flags}" if flags else ""),
    )


def map_terrain_ps(idx: int) -> PermSpec:
    """3.0.0 terrain pixel shader -- 128 perms: foliage's mask, bit 6 dead.

        SC2=1 MRT=2 DP=4 DBG=8 PTS=16 SC=32 (64 dead)

    Terrain's coverage cut-out is unconditional, so the bit foliage spends on
    ALPHA_TEST changes nothing here. Folded by `_hd_ps_fold` with LIGHTING
    pinned on: 24 shaded programs plus one depth prepass, retail's 25.
    """
    f = _hd_ps_fold(
        ao =False,
        sc2=bool(idx &  1),   # SHADOW_CASCADE2
        mrt=bool(idx &  2),   # MULTI_TARGET
        dp =bool(idx &  4),   # DEPTH_PREPASS
        dbg=bool(idx &  8),   # LIGHT_DEBUG
        pts=bool(idx & 16),   # POINT_SHADOWS
        sc =bool(idx & 32),   # SHADOW_CASCADE
        lit=True,
        at =False,
        ml =False,
    )
    s = lambda v: "true" if v else "false"
    defines: List[str] = []
    if f["dp"]:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if f["mrt"]:
        defines.append("WC3_IS_MRT=1")
    flags = "+".join(n for n, v in (("SC", f["sc"]), ("SC2", f["sc2"]),
                                    ("PS", f["pts"]), ("DBG", f["dbg"]),
                                    ("DP", f["dp"]), ("MRT", f["mrt"])) if v)
    return PermSpec(
        entry="terrain_ps_main",
        types=[s(f["sc"]), s(f["sc2"]), s(f["pts"]), s(f["dbg"])],
        defines=defines,
        label=flags or "base",
    )


def map_cliff_vs(idx: int) -> PermSpec:
    """3.0.0 cliff / blight / misc-terrain vertex shader -- one permutation."""
    return PermSpec(entry="cliff_vs_main", types=[], label="(only)")


def map_cliff_ps(idx: int) -> PermSpec:
    """3.0.0 cliff / blight / misc-terrain pixel shader -- 256 perms, 50 programs.

        SC2=1 MRT=2 DP=4 DBG=8 PTS=16 SC=32 (64 dead) AT=128

    Terrain's mask with ALPHA_TEST as one extra top bit. Folded by
    `_hd_ps_fold` with LIGHTING pinned on; the alpha-tested prepass stays
    apart from the plain one, as in HD and foliage.
    """
    f = _hd_ps_fold(
        ao =False,
        sc2=bool(idx &   1),   # SHADOW_CASCADE2
        mrt=bool(idx &   2),   # MULTI_TARGET
        dp =bool(idx &   4),   # DEPTH_PREPASS
        dbg=bool(idx &   8),   # LIGHT_DEBUG
        pts=bool(idx &  16),   # POINT_SHADOWS
        sc =bool(idx &  32),   # SHADOW_CASCADE
        lit=True,
        at =bool(idx & 128),   # ALPHA_TEST
        ml =False,
    )
    alpha = "AlphaTestOn" if f["at"] else "AlphaTestOff"
    s = lambda v: "true" if v else "false"
    defines: List[str] = []
    if f["dp"]:
        defines.append("WC3_IS_DEPTH_PREPASS=1")
    if f["mrt"]:
        defines.append("WC3_IS_MRT=1")
    flags = "+".join(n for n, v in (("SC", f["sc"]), ("SC2", f["sc2"]),
                                    ("PS", f["pts"]), ("DBG", f["dbg"]),
                                    ("DP", f["dp"]), ("MRT", f["mrt"])) if v)
    return PermSpec(
        entry="cliff_ps_main",
        types=[alpha, s(f["sc"]), s(f["sc2"]), s(f["pts"]), s(f["dbg"])],
        defines=defines,
        label=alpha + (f"+{flags}" if flags else ""),
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
    # 3.0.0: 288 perms = 9 outer blocks x 32 inner bits. 2.0.0 had 1152 = 9 x
    # 128; the two deleted bits are the fog pair (2.0.0 inner bits 1 and 2),
    # because 3.0.0 selects all seven fog modes from a constant at runtime
    # instead of compiling one arm per blob. The five survivors kept their
    # relative order and compacted DOWNWARD into bits 0..4.
    #
    #   idx = inner | 32 * outer        outer = mode_idx * 3 + uv_var
    #
    #   inner bit 0 (0x01) — HAS_GBUFFER         (COLOR pass only)
    #         bit 1 (0x02) — HAS_SOFT_PARTICLES  (both passes)
    #         bit 2 (0x04) — HAS_ALPHA_LUT       (needs a UV stream)
    #         bit 3 (0x08) — HAS_VC              (both passes)
    #         bit 4 (0x10) — HAS_LIT             (COLOR pass only)
    #
    #   mode_idx 0 = basic, 1 = billboard, 2 = atlas
    #   uv_var   0 = no UV     -> PopcornNoUV       (COLOR pass)
    #            1 = COLOR pass -> PopcornBasicUV / Billboard / Atlas
    #            2 = MOTION pass -> same modes, IS_MOTION_PASS = true
    #
    # Two folds, derived from the retail blobs by asking of each equivalence
    # class which axes vary INSIDE it — an axis that varies within a class is
    # one the engine folded away for that combination:
    #
    #   uv_var == 0  ->  mode_idx and HAS_ALPHA_LUT both fold away
    #   uv_var == 2  ->  HAS_GBUFFER folds away
    #
    # 16 + 96 + 48 = 160 classes, which is what retail ships.
    #
    # Note what does NOT fold in the motion pass: HAS_ALPHA_LUT and HAS_LIT
    # still split it, even though `diff perm_064 perm_068` has zero body lines
    # differing. They are live through the INPUT SIGNATURE alone — the engine
    # keeps the interpolants bound so the pass switch does not have to relink —
    # so the mapper must still specialise on them.
    inner    = idx & 0x1F
    outer    = idx // 32
    mode_idx = outer // 3
    uv_var   = outer %  3

    has_gbuf = bool(inner & 0x01)
    has_sp   = bool(inner & 0x02)
    has_alut = bool(inner & 0x04)
    has_vc   = bool(inner & 0x08)
    has_lit  = bool(inner & 0x10)

    if uv_var == 0:          # no UV stream: nothing to look a LUT up against,
        has_alut = False     # and no per-mode UV to resolve
        mode_idx = 0
    if uv_var == 2:          # the motion pass writes one target, never a g-buffer
        has_gbuf = False

    if uv_var == 0:
        mode = "PopcornNoUV"
    elif mode_idx == 0:
        mode = "PopcornBasicUV"
    elif mode_idx == 1:
        mode = "PopcornBillboard"
    else:
        mode = "PopcornAtlas"

    is_motion = "true" if uv_var == 2 else "false"

    def b(v: bool) -> str:
        return "true" if v else "false"

    # PopcornPSInput is gated by the same POPCORN_HAS_* defines that
    # gate PopcornVSOutput so d3d12 PSO validation (PS ISG1 subset of VS OSG1)
    # accepts the link. The engine is expected to pair PS perms with VS
    # perms that have matching gating:
    #   HAS_LIT (PS)        <-> HAS_NT (VS)
    #   HAS_ALPHA_LUT (PS)  <-> HAS_RANDOM (VS)   when there's a UV stream
    #   HAS_VC, UV, mode    <-> same on both sides
    defines: List[str] = []
    if uv_var != 0:
        defines.append("POPCORN_HAS_UV=1")
        if mode_idx == 1:
            defines.append("POPCORN_BILLBOARD=1")
            defines.append("POPCORN_HAS_BB_OR_ATLAS=1")
        elif mode_idx == 2:
            defines.append("POPCORN_ATLAS=1")
            defines.append("POPCORN_HAS_BB_OR_ATLAS=1")
    if has_vc:
        defines.append("POPCORN_HAS_VC=1")
    if has_lit:
        defines.append("POPCORN_HAS_NT=1")
    if has_alut:
        defines.append("POPCORN_HAS_RANDOM_UV=1")
    # HAS_GBUFFER migrated to the WC3_POPCORN_HAS_GBUFFER preprocessor define so
    # the deferred-targets struct fields can be #if-gated (see popcorn_ps.slang
    # for the WGSL emit rationale).
    if has_gbuf:
        defines.append("WC3_POPCORN_HAS_GBUFFER=1")

    return PermSpec(
        entry="popcorn_ps_main",
        types=[mode, is_motion, b(has_sp), b(has_alut), b(has_vc), b(has_lit)],
        label=(f"{mode}+M={is_motion}+G={b(has_gbuf)}+SP={b(has_sp)}"
               f"+ALUT={b(has_alut)}+VC={b(has_vc)}+LIT={b(has_lit)}"),
        defines=defines,
    )


# The 3.0.0 fog enum, indexed by the engine's own mode number. Mode 4 is
# volumetric and has no entry: the classic pipeline never implemented it, so
# retail emits mode 0's bytecode there (see `map_sd_classic_ps`).
FOG30_NAMES = {
    0: "FogMode0None",
    1: "FogMode1Linear",
    2: "FogMode2Exp",
    3: "FogMode3ExpSq",
    5: "FogMode5ExpBand",
    6: "FogMode6ExpSqBand",
}


def map_sd_classic_ps(idx: int) -> PermSpec:
    # 3.0.0 layout — MIXED RADIX, not a bitmask (2.0.0 packed fog+alpha into
    # the low 3 bits and strode the stages by 8/40):
    #
    #   idx = fog + 7*alpha + 14*t0stage + 70*t1stage
    #         fog in [0,7)   alpha in [0,2)   t0stage, t1stage in [0,5)
    #
    # 7*2*5*5 = 350 slots. The fog radix is what widened (4 -> 7); the stage
    # enum is unchanged, which is why 92 of the 168 2.0.0 classes survive.
    fog     = idx % 7
    alpha   = (idx // 7) % 2
    t0stage = (idx // 14) % 5
    t1stage = (idx // 70) % 5

    # Fold 1 — mode 4 is VOLUMETRIC fog, which needs a world position and a fog
    # volume the classic pipeline does not have. Retail emits mode 0's bytecode
    # for it in all 50 (alpha, t0, t1) combinations, unconditionally; the same
    # missing implementation is why `fog_ps` ships 7 perms but only 6 blobs.
    if fog == 4:
        fog = 0
    # Fold 2 — a disabled stage 0 short-circuits the chain, so stage 1 is
    # unreachable and every retail class with t0 == 0 varies only in t1.
    if t0stage == 0:
        t1stage = 0

    alpha_t = "AlphaTestOn" if alpha else "AlphaTestOff"
    return PermSpec(
        entry="sd_classic_ps_main",
        types=[STAGE_NAMES[t0stage], STAGE_NAMES[t1stage],
               FOG30_NAMES[fog], alpha_t],
        label=f"T0={t0stage}+T1={t1stage}+fog{fog}+{alpha_t}",
    )


# Per-family permutation mappers. These are the only piece of family
# metadata that stays as code — each maps a linear perm index to the
# tuple of slangc -specialize types for that perm (bit-packed feature
# axes, conditional type-name selection). Everything else (stage,
# perm_count, entry point, module) comes from wc3_shaders.json.
MAPPERS: dict[str, Callable[[int], PermSpec]] = {
    "hd_vs":          map_hd_vs,
    "hd_ps":          map_hd_ps,
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
    "cliffblightmiscterrain_vs": map_cliff_vs,
    "cliffblightmiscterrain_ps": map_cliff_ps,
    "distortion_ps":  map_distortion_ps,
    "imgui_vs":       map_imgui_vs,
    "imgui_ps":       map_imgui_ps,
    "ffxcmaaedge0":            map_cmaa_edge0_ps,
    "ffxcmaaedge1":            map_cmaa_edge1_ps,
    "ffxcmaaedgecombine":      map_cmaa_edge_combine_ps,
    "ffxcmaaprocessandapply":  map_cmaa_process_apply_ps,
    "bloomextract":            map_bloom_extract_ps,
    "bloomcombine":            map_bloom_combine_ps,
    "gaussianblur":            map_gaussian_blur_ps,
    "depthoffield":            map_depth_of_field_ps,
    "sd_lowspec_vs":           map_sd_lowspec_vs,
    "greyscale_ps":            _single("greyscale_ps_main"),
    "ssaa_ps":                 _single("ssaa_ps_main"),
    "foliagepush_ps":          _single("foliagepush_ps_main"),
    "debugtexture_ps":         _single("debugtexture_ps_main"),
    "waterreflection_ps":      _single("waterdepthbounds_ps_main"),
    "fog_ps":                  map_fog_ps,
    "volumetricfog_vs":        _single("volumetricfog_vs_main"),
    "volumetricfog_ps":        _single("volumetricfog_ps_main"),
    "cameraocclusion_vs":      _single("cameraocclusion_vs_main"),
    "cameraocclusion_ps":      _single("cameraocclusion_ps_main"),
    "coneindicator_vs":        _single("coneindicator_vs_main"),
    "coneindicator_ps":        _single("coneindicator_ps_main"),
    "movie_ps":                map_movie_ps,
}

# Families whose 3.0.0 retail blobs are shader model 4 (with a Level9 part);
# see run_sweep.
SM4_FAMILIES = {"sd_classic_ps", "sd_lowspec_vs", "greyscale_ps", "movie_ps"}

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

# Which folder of the 3.0.0 retail extraction each family mirrors. Used only by
# the staleness check below — the tree itself is gitignored and often absent.
RETAIL_DIRS: dict[str, str] = {
    "hd_vs": "hd_vs", "hd_ps": "hd", "crystal_ps": "crystal",
    "sd_on_hd_vs": "sd_on_hd_vs", "sd_on_hd_ps": "sd_on_hd",
    "sd_highspec_vs": "sd_highspec_vs", "sd_classic_ps": "sd",
    "water_vs": "water_vs", "water_ps": "water",
    "popcorn_vs": "popcornfx_vs", "popcorn_ps": "popcornfx",
    "tonemap_ps": "tonemap", "sprite_vs": "sprite_vs", "sprite_ps": "sprite",
    "terrain_vs": "terrain_vs", "terrain_ps": "terrain",
    "foliage_vs": "foliage_vs", "foliage_ps": "foliage",
    "cliffblightmiscterrain_vs": "cliffblightmiscterrain_vs",
    "cliffblightmiscterrain_ps": "cliffblightmiscterrain",
    "distortion_ps": "distortion", "imgui_vs": "imgui_vs", "imgui_ps": "imgui",
    "ffxcmaaedge0": "ffxcmaaedge0", "ffxcmaaedge1": "ffxcmaaedge1",
    "ffxcmaaedgecombine": "ffxcmaaedgecombine",
    "ffxcmaaprocessandapply": "ffxcmaaprocessandapply",
    "bloomextract": "bloomextract", "bloomcombine": "bloomcombine",
    "gaussianblur": "gaussianblur", "depthoffield": "depthoffield",
    "sd_lowspec_vs": "sd_lowspec_vs",
    "greyscale_ps": "greyscale",
    "ssaa_ps": "ssaa",
    "foliagepush_ps": "foliagepush",
    "debugtexture_ps": "debugtexture",
    "waterreflection_ps": "waterreflection",
    "fog_ps": "fog",
    "volumetricfog_vs": "volumetricfog_vs",
    "volumetricfog_ps": "volumetricfog",
    "cameraocclusion_vs": "cameraocclusion_vs",
    "cameraocclusion_ps": "cameraocclusion",
    "coneindicator_vs": "coneindicator_vs",
    "coneindicator_ps": "coneindicator",
    "movie_ps": "movie",
}


def warn_stale_perm_counts(retail_root: Path | None = None) -> List[str]:
    """Warn where `perm_count` disagrees with the 3.0.0 retail blob count.

    A family whose count is still the 2.0.0 one builds *quietly* and wrongly:
    too low and the tail of the grid is never compiled, too high and the mapper
    is called with indices outside the domain it was written for, which folds
    back onto low perms instead of raising. Neither shows up as a build failure,
    which is exactly how five families sat on 2.0.0 counts while every gate was
    green.

    A count and its mapper have to move together, so this only *reports* — it is
    the milestone that ports the mapper which also bumps the count. Returns the
    warning lines so callers can assert on them; prints nothing when the retail
    tree is absent (it is gitignored, so most checkouts will not have it).
    """
    root = retail_root or (REPO_ROOT / "wc3_re_shaders")
    if not root.is_dir():
        return []
    lines: List[str] = []
    for name, cfg in FAMILY_CONFIGS.items():
        sub = RETAIL_DIRS.get(name)
        if not sub:
            continue
        d = root / sub
        if not d.is_dir():
            continue
        actual = len(list(d.glob("perm_*.dxbc")))
        if actual and actual != cfg.perm_count:
            lines.append(f"  {name:<24} config={cfg.perm_count:<5} retail={actual:<5} "
                         f"({'under' if cfg.perm_count < actual else 'over'}-building)")
    if lines:
        print("WARNING: perm_count disagrees with the 3.0.0 retail extraction —")
        print("         these families are still on their 2.0.0 grid:")
        for ln in lines:
            print(ln)
        print("         Bump each count in wc3_shaders.json only alongside its mapper.")
    return lines


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
                             "(repeat the flag). Default: core wc3 families "
                             "only — custom variant families (custom_shaders.json) "
                             "build only when named explicitly or via --family all.")
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

    # Loud, non-fatal: a family still on its 2.0.0 grid builds quietly and wrongly.
    warn_stale_perm_counts()

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

    # Family selection:
    #   --family NAME...  → exactly those families (may be custom).
    #   --family all      → every family, core + custom (selected=None).
    #   (flag omitted)    → core wc3 families only; custom variant
    #                       families (module=="custom") are skipped unless
    #                       named explicitly or via `--family all`.
    selected_families = None
    if args.family and "all" not in args.family:
        selected_families = set(args.family)
    elif not args.family:
        selected_families = {name for name, cfg in FAMILY_CONFIGS.items()
                             if cfg.module == "wc3"}

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
