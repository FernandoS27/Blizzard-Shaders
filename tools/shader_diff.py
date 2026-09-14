"""Differential tester for two disassembled shaders that should agree.

Given two shader disassemblies (a slang-compiled reimplementation and the
retail bytecode it mirrors), feed both the *same* random inputs and constant
buffers over many trials and report the worst output divergence. Built on
:mod:`dxbc_interp`.

The non-obvious part is **input mapping**. The two shaders rarely share an
input-register layout even when they're semantically identical:

  * slang names varyings with a x10 semantic index (``TEXCOORD10`` == retail's
    ``TEXCOORD1``, ``TEXCOORD70`` == ``TEXCOORD7``); retail uses the raw index.
  * retail PACKS several semantics into one register by write-mask
    (``TEXCOORD1.x`` + ``TEXCOORD7.yzw`` -> register 2); slang usually gives
    each its own register.

So inputs are generated **per semantic** (``{(name, index): [4 lanes]}``) and
:func:`map_inputs` places each semantic's components into the right register
*channels* for whichever shader it's feeding. Get this wrong and you get huge
phantom divergences that look like shader bugs but aren't.

CLI::

    python tools/shader_diff.py SLANG.asm RETAIL.asm [--trials N] [--tol T]
    python tools/shader_diff.py a.dxbc b.dxbc --decompiler C:/path/cmd_Decompiler.exe

For non-trivial shaders (driven constant-buffer discriminants, structured
inputs) import :func:`compare` and pass your own ``inputs_fn`` / ``cbufs_fn``
generators — see ``tools/shader_diff_popcorn.py`` for a worked example.
"""

import argparse
import math
import random
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, execute, TextureModel, f2b, b2f  # noqa: E402

_CH = {'x': 0, 'y': 1, 'z': 2, 'w': 3}


# --------------------------------------------------------------------------
# loading (optionally disassembling .dxbc on the way in)
# --------------------------------------------------------------------------

def decompile(dxbc_path, decompiler):
    """Disassemble a ``.dxbc`` to ``.asm`` next to it via 3Dmigoto. Returns the path."""
    dxbc_path = Path(dxbc_path)
    asm = dxbc_path.with_suffix('.asm')
    subprocess.run([str(decompiler), '-d', str(dxbc_path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not asm.exists():
        raise RuntimeError(f"decompiler produced no .asm for {dxbc_path}")
    return asm

def load(path, decompiler=None):
    """Load a :class:`Program` from ``.asm`` (or ``.dxbc`` if ``decompiler`` given)."""
    path = Path(path)
    if path.suffix == '.dxbc':
        if not decompiler:
            raise ValueError("a .dxbc needs --decompiler to disassemble first")
        path = decompile(path, decompiler)
    return Program.from_file(path)


def perm_path(directory, idx, ext):
    """Resolve ``<directory>/perm_<idx>.<ext>``, whatever the zero-padding is.

    ``tools/extract_wc3_bls.py`` pads the perm number to the width of the
    family's perm count, so the SAME family can be 3 digits in one retail tree
    and 4 in another: 2.0.0 popcornfx shipped 1152 perms (``perm_0000``) and
    3.0.0 ships 288 (``perm_000``). Hardcoding either width silently turns a
    real comparison into ``FileNotFoundError`` -- which is how the 3.0.0
    popcornfx blobs looked missing when they were sitting right there.

    Widest first, so a directory that somehow holds both naming schemes
    resolves the way the extractor most recently wrote it.
    """
    directory = Path(directory)
    for width in (5, 4, 3):
        cand = directory / f"perm_{idx:0{width}d}.{ext}"
        if cand.exists():
            return cand
    # Nothing matched: hand back the conventional name so the caller raises a
    # FileNotFoundError naming a path a human can go look for.
    return directory / f"perm_{idx:03d}.{ext}"


# --------------------------------------------------------------------------
# input mapping — semantic values -> per-shader input registers
# --------------------------------------------------------------------------

def is_x10_inflated(signature):
    """Is this signature's semantic numbering slang's x10 form?

    Slang's HLSL emit concatenates a field's semantic index onto the name it
    was written with, so a source ``TEXCOORD1`` reaches fxc as ``TEXCOORD10``
    and is stored with ``sem_idx = 10``. EVERY index in such a signature is
    therefore a multiple of ten; a retail signature is not.

    Deciding this per program rather than per entry matters, because the two
    numberings genuinely collide. The 3.0.0 HD pixel shader carries a real
    ``TEXCOORD10`` (the world position) alongside ``TEXCOORD1`` (the view
    position) -- and slang compiles those to indices 100 and 10. Looking each
    index up as-is first would hand slang's TEXCOORD1 the world position that
    belongs to TEXCOORD10, and both legs of the comparison would silently
    disagree about which varying is which.

    The rule needs at least one index of ten or more to fire: a signature whose
    indices are all zero is ambiguous, and deflating zero is the identity
    anyway. This is the same recovery ``build_bls.fix_dxbc_signatures`` applies
    when it packs slang output into a BLS, and the two must agree.
    """
    indices = [idx for _, idx, _, _ in signature]
    return bool(indices) and max(indices) >= 10 and all(i % 10 == 0 for i in indices)


def map_inputs(program, semantic_values, sysvals=None):
    """Build ``{register: [4 lanes]}`` for ``program`` from per-semantic values.

    Args:
        program:         the :class:`Program` being fed.
        semantic_values: a mapping with ``.get((name, index))`` -> 4 lanes
                         (raw index; the x10 slang naming is handled here).
        sysvals:         ``{sysval_name: bits}`` e.g. ``{"is_front_face": 0xFFFFFFFF}``.
    """
    inflated = is_x10_inflated(program.input_sig)
    inp = {}
    for name, idx, mask, reg in program.input_sig:
        if inflated:
            idx //= 10
        v = semantic_values.get((name, idx))
        if v is None and idx >= 10 and idx % 10 == 0:
            # A mixed signature (some entries inflated, some not) should not
            # happen, but falling back costs nothing and keeps older callers
            # that relied on this rule working.
            v = semantic_values.get((name, idx // 10))
        if v is None:
            v = [0, 0, 0, 0]
        inp.setdefault(reg, [0, 0, 0, 0])
        # place this semantic's components at its masked channels, in order
        # (retail packs multiple semantics per register -> merge, don't overwrite)
        for di, c in enumerate(ch for ch in mask if ch in _CH):
            inp[reg][_CH[c]] = v[di]
    for name, bits in (sysvals or {}).items():
        if name in program.sysval_regs:
            inp[program.sysval_regs[name]] = [bits, bits, bits, bits]
    return inp


# --------------------------------------------------------------------------
# default random generators (work out of the box; override for real coverage)
# --------------------------------------------------------------------------

class RandomSemantics:
    """Lazily returns a deterministic random 4-vec for any ``(name, index)``.

    Same key -> same value within a trial, so both shaders are fed identically.
    Normals/tangents (TEXCOORD4/5 by Wc3 convention) come out unit-length.
    """

    def __init__(self, seed):
        self.seed = seed

    def get(self, key):
        name, idx = key
        rng = random.Random(f"{self.seed}:{name}:{idx}")   # str seed (tuples unhashable as seeds in 3.14)
        if name == 'TEXCOORD' and idx in (4, 5):      # normal / tangent
            v = [rng.uniform(-1, 1) for _ in range(3)]
            m = math.sqrt(sum(c * c for c in v)) or 1.0
            lanes = [f2b(c / m) for c in v]
            lanes.append(f2b(rng.choice([-1.0, 1.0])))  # handedness in .w
            return lanes
        return [f2b(rng.uniform(-2, 2)) for _ in range(4)]


class _RandomRows:
    def __init__(self, seed, slot):
        self.seed, self.slot = seed, slot

    def __len__(self):
        # D3D11 SM5 constant buffer maximum is 4096 float4 rows (256 typical).
        # Returning a large constant satisfies dxbc_interp's bounds check so
        # dynamically-indexed cbuffers do not raise instead of comparing.
        return 4096

    def __getitem__(self, index):
        rng = random.Random(f"{self.seed}:{self.slot}:{index}")
        return [f2b(rng.uniform(-1, 1)) for _ in range(4)]

class RandomCBufs:
    """``cb[slot][row]`` -> deterministic random 4-vec (read-only, lazy)."""

    def __init__(self, seed):
        self.seed = seed

    def __getitem__(self, slot):
        return _RandomRows(self.seed, slot)


def default_sysvals(seed):
    """Random front-face for PS (other sysvals default to 0)."""
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --------------------------------------------------------------------------
# output comparison
# --------------------------------------------------------------------------

def output_diff(out_a, out_b, regs, rel_scale=0.0):
    """Worst per-channel difference over the given output registers.

    NaN==NaN and same-signed inf==inf are treated as equal (they signal the
    same degenerate input, not a divergence). NaN on ONE side is a divergence
    and scores +inf: ``abs(nan - x)`` is NaN and ``nan > worst`` is False, so
    without this it would score zero and a shader that turned a finite result
    into NaN would pass. Returns ``(worst, (reg, ch, a, b))``.

    ``rel_scale`` puts a floor under the divisor: the score becomes
    ``|a-b| / max(rel_scale, |a|, |b|)``, which is plain absolute error while
    the values stay below the floor and relative error above it. Left at its
    default of 0 the score is exactly ``|a-b|`` and nothing changes.

    It exists because a fixed absolute threshold tests large outputs far more
    strictly than small ones, which silently makes a gate's strictness depend on
    how bright the pixel is. `hd_ps`'s light-complexity overlay ADDS a light
    count to the output, so its debug permutations carry values around 13 where
    the shaded ones sit near 3; at 128 trials all 64 LIGHT_DEBUG permutations
    crossed 1e-3 absolute while their non-debug siblings passed, on the same
    seed, at the same output lane, with the SAME relative error (1.45e-04 vs
    1.27e-04). Nothing was wrong with the overlay. Pass ``rel_scale=1.0`` for
    any family whose outputs are not confined to roughly [0,1].
    """
    worst = 0.0; where = None
    for reg in regs:
        for k in range(4):
            a = out_a.f(reg, k); b = out_b.f(reg, k)
            na, nb = math.isnan(a), math.isnan(b)
            if na and nb:
                continue
            d = math.inf if (na or nb) else abs(a - b)
            if math.isinf(a) and math.isinf(b) and (a > 0) == (b > 0):
                continue
            if rel_scale > 0 and not math.isinf(d):
                d = d / max(rel_scale, abs(a), abs(b))
            if d > worst:
                worst = d; where = (reg, k, a, b)
    return worst, where


class CompareResult:
    def __init__(self):
        self.trials = 0
        self.worst = 0.0
        self.worst_where = None       # (reg, ch, a_val, b_val)
        self.worst_seed = None
        self.discard_mismatches = 0

    def __repr__(self):
        return (f"CompareResult(trials={self.trials}, worst={self.worst:.3e}, "
                f"discard_mismatches={self.discard_mismatches})")


def compare(prog_a, prog_b, *, trials=200, output_regs=(0,), tol=1e-3,
            inputs_fn=None, cbufs_fn=None, sysvals_fn=None,
            texture=None, structured=None, deriv_scale=0.0, seed0=0,
            rel_scale=0.0):
    """Run both programs over ``trials`` random draws and collect the worst diff.

    Args:
        prog_a, prog_b: the two :class:`Program` s (order is irrelevant).
        output_regs:    output registers to compare (``0`` == SV_Target0).
        tol:            informational threshold (does not stop the run).
        inputs_fn:      ``seed -> semantic_values`` (default: :class:`RandomSemantics`).
        cbufs_fn:       ``seed -> cbufs`` (default: :class:`RandomCBufs`).
        sysvals_fn:     ``seed -> {name: bits}`` (default: random front-face).
        texture:        a :class:`TextureModel` shared by both shaders.
        structured:     a :class:`dxbc_interp.StructuredModel` shared by both
                        shaders, for ``ld_structured`` reads (clustered light
                        lists and the like). Defaults to the smooth stand-in,
                        whose garbage-as-int values overrun data-driven loops.
        deriv_scale:    synthetic-derivative magnitude (keep 0 unless testing
                        specular-AA-style paths, which can't be matched exactly).
        rel_scale:      magnitude floor for the diff score; see
                        :func:`output_diff`. 0 (the default) keeps the score a
                        plain absolute difference.
    """
    inputs_fn = inputs_fn or (lambda s: RandomSemantics(s))
    cbufs_fn = cbufs_fn or (lambda s: RandomCBufs(s))
    sysvals_fn = sysvals_fn or default_sysvals
    tex = texture or TextureModel()

    res = CompareResult()
    for t in range(trials):
        seed = seed0 + t
        sv = inputs_fn(seed)
        cb = cbufs_fn(seed)
        sysv = sysvals_fn(seed)
        ia = map_inputs(prog_a, sv, sysv)
        ib = map_inputs(prog_b, sv, sysv)
        sb = structured(seed) if callable(structured) else structured
        oa = execute(prog_a, ia, cb, texture=tex, structured=sb,
                     deriv_scale=deriv_scale)
        ob = execute(prog_b, ib, cb, texture=tex, structured=sb,
                     deriv_scale=deriv_scale)
        res.trials += 1
        if oa.discarded != ob.discarded:
            res.discard_mismatches += 1
        w, where = output_diff(oa, ob, output_regs, rel_scale=rel_scale)
        if w > res.worst:
            res.worst = w; res.worst_where = where; res.worst_seed = seed
    return res


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('a', help='first shader (.asm, or .dxbc with --decompiler)')
    ap.add_argument('b', help='second shader')
    ap.add_argument('--trials', type=int, default=200)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--outputs', default='0',
                    help='comma-separated output registers to compare (default 0)')
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--deriv-scale', type=float, default=0.0)
    ap.add_argument('--decompiler', default=None,
                    help='path to 3Dmigoto cmd_Decompiler.exe (needed for .dxbc inputs)')
    args = ap.parse_args(argv)

    prog_a = load(args.a, args.decompiler)
    prog_b = load(args.b, args.decompiler)
    regs = tuple(int(x) for x in args.outputs.split(','))

    try:
        res = compare(prog_a, prog_b, trials=args.trials, output_regs=regs,
                      tol=args.tol, seed0=args.seed, deriv_scale=args.deriv_scale)
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        print("hint: the default random generators don't drive data-dependent loop\n"
              "      counts (e.g. light count). Write a driver with a cbufs_fn that\n"
              "      sets them -- see tools/shader_diff_popcorn.py.", file=sys.stderr)
        return 2

    print(f"models      : {prog_a.model} vs {prog_b.model}")
    print(f"trials      : {res.trials}")
    print(f"outputs     : {list(regs)}")
    print(f"worst diff  : {res.worst:.3e}" + (f"  (seed {res.worst_seed})" if res.worst_where else ""))
    if res.worst_where:
        reg, ch, av, bv = res.worst_where
        print(f"  at o{reg}.{'xyzw'[ch]}: a={av:.5g} b={bv:.5g}")
    print(f"discard mism: {res.discard_mismatches}")
    ok = res.worst <= args.tol and res.discard_mismatches == 0
    print("RESULT      :", "MATCH" if ok else "DIVERGE")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(_main())
