"""Diablo III slot -> slang compile spec (the ``map_d3`` mapper).

A slot's compile spec has two halves, and they come from different places:

* **What the program computes** -- the root entry point and its ``-specialize``
  arguments -- comes from a per-subfamily *translator*: a small function that
  reads the retail key's local defines (``uber_manifest.json``) and measured
  axes and names the slang policies that reproduce it.
* **What the program declares** -- interpolant and vertex-stream layouts and
  texture registers -- is the measured retail signature and resource table,
  turned into ``-D D3_*`` defines the same way for every subfamily
  (types/transport.slang, types/streams.slang, types/textures.slang).

The spec IS the slot's canonical key: gate D1 (``d3_perm_manifest.py
--partition``) checks that specs split retail keys exactly as their program
bytes do -- two programs never share a spec, and every key of one program
(including keys from other subfamilies) gets the same one.

Translators for landed roots live in ``tools/d3_cfg_<domain>.py`` files, loaded
at the bottom of this module. A workspace (``tools/d3_ws.py``) points the whole
toolchain at a private copy of the module (``D3_SHADERS_DIR``) and adds its own
translator files (``D3_CFG_PLUGINS``, ``os.pathsep``-separated), so a root under
construction never breaks the one-translation-unit build of the others.
"""

from __future__ import annotations

import importlib.util
import os
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INCLUDE = Path(os.environ.get('D3_SHADERS_DIR') or (REPO / 'd3_shaders'))
MODULE = INCLUDE / 'd3_shaders.slang'

#: retail signature spelling of the system values (D2 upper-cases both legs)
_SV = {'SV_POSITION': 'SV_Position', 'SV_CLIPDISTANCE': 'SV_ClipDistance'}


@dataclass(frozen=True)
class Spec:
    entry: str
    specialize: tuple
    defines: tuple

    def key(self) -> tuple:
        return (self.entry, self.specialize, self.defines)


# --------------------------------------------------------------------------
# declarations: layouts and registers, identical for every subfamily
# --------------------------------------------------------------------------

def _vec(comp: str, width: int) -> str:
    base = {'float': 'float', 'uint': 'uint', 'int': 'int'}[comp]
    return base if width == 1 else '%s%d' % (base, width)


def _layout(rows: list, prefix: str, member: str) -> list:
    out = []
    for n, (name, idx, _reg, mask, _sysval, comp) in enumerate(rows):
        sem = '%s%d' % (_SV.get(name, name), idx)
        out += ['%s_%d=1' % (prefix, n),
                '%s_%d_TYPE=%s' % (prefix, n, _vec(comp, len(mask))),
                '%s_%d_SEM=%s' % (prefix, n, sem),
                '%s_AT_%s%d=%s%d' % (prefix, name, idx, member, n)]
    return out


def declaration_defines(measured: dict) -> list:
    d = _layout(measured['transport'], 'D3_IO', 'io')
    d += _layout(measured.get('streams') or [], 'D3_IN', 'in')
    for reg, kind, _dim, _cmp, name in measured['resources']:
        d.append('D3_%s_%s=%s' % ('T' if kind == 'texture' else 'S', role(name), reg))
    return d


def role(name: str) -> str:
    """The texture role a retail resource name binds: Effects splits a sampler into
    ``<role>t`` / ``<role>s``; a resource declared without that mangling (a
    ``Texture2DMS texDepth`` read only by ``ldms``) keeps its whole name."""
    return name[:-1] if name[-1:] in ('t', 's') else name



def for_target(spec: Spec, target: str, stage: str) -> Spec:
    """The spec a non-D3D11 target compiles; the spec's identity (what D1 checks)
    and the D3D11 build are untouched.

    * One binding space: every texture/sampler register N gets an explicit
      binding (pixel textures 16+N / samplers 64+N, vertex 80+N / 112+N).
    * WGSL has no clip distances, so under webgpu the SV_ClipDistance
      interpolant positions are left undeclared (their setters become no-ops and
      a pixel shader simply does not receive them)."""
    if target == 'd3d11':
        return spec
    # textures t0-t47 and samplers s0-s15 per stage, one binding space
    tex_base, samp_base = (16, 64) if stage == 'ps' else (80, 112)
    extra = []
    for x in spec.defines:
        if x.startswith('D3_T_') or x.startswith('D3_S_'):
            name, reg = x.split('=')
            kind, role = name[3], name[5:]
            extra.append('D3_VK_%s_%s=%d' % (kind, role, (tex_base if kind == 'T' else samp_base) + int(reg[1:])))
    spec = Spec(spec.entry, spec.specialize, spec.defines + tuple(extra))
    if target != 'webgpu':
        return spec
    drop = {x.split('_SEM=')[0] for x in spec.defines if '_SEM=SV_ClipDistance' in x}
    kept = tuple(x for x in spec.defines
                 if not any(x == d + '=1' or x.startswith(d + '_') for d in drop)
                 and not (x.startswith('D3_IO_AT_SV_CLIPDISTANCE')))
    return Spec(spec.entry, spec.specialize, kept)

# --------------------------------------------------------------------------
# shared axis readers
# --------------------------------------------------------------------------

_ALPHA = {'lt(ref,a)': 'DiscardLE', 'ge(a,ref)': 'DiscardLT',
          'lt(a,ref)': 'DiscardGE', 'ge(ref,a)': 'DiscardGT',
          'eq(a,ref)': 'DiscardNE', 'eq(ref,a)': 'DiscardNE'}


def alpha_test(measured: dict) -> str:
    """The IAlphaTest implementer the retail compare spelling names."""
    tests = [c for c in measured['alphaCompare'] if 'lit' not in c]
    if not tests:
        return 'AlphaTestOff'
    return _ALPHA[tests[-1]]


def on(defines: dict, name: str) -> bool:
    return str(defines.get(name, '0')) not in ('0', '')


def boolean(v: bool) -> str:
    return 'true' if v else 'false'


# --------------------------------------------------------------------------
# translators
# --------------------------------------------------------------------------

TRANSLATORS = {}


def translator(*subfamilies):
    def register(fn):
        for s in subfamilies:
            TRANSLATORS[s] = fn
        return fn
    return register


def is_ported(subfamily: str) -> bool:
    return subfamily in TRANSLATORS


def map_d3(subfamily: str, defines: dict, measured: dict) -> Spec:
    entry, specialize = TRANSLATORS[subfamily](defines, measured)
    return Spec(entry, tuple(specialize), tuple(sorted(declaration_defines(measured))))


def row_spec(row: dict, measured: dict, program: str) -> Spec | None:
    """The spec of one manifest ``retail`` row, None when nothing names it yet.

    A ``$D3_RE`` row goes through its subfamily's translator. A residue row (plan
    M7) has no local defines: a translator registered for its subfamily still wins
    (a singleton family ported the usual way), otherwise its program's placement in
    ``d3_residue.json`` is the spec. A residue row whose program only joins a v1
    slot has neither and simply takes that slot's spec."""
    sub = row['subfamily']
    if sub in TRANSLATORS:
        return map_d3(sub, row['defines'], measured)
    if row.get('residue'):
        import d3_retail as R
        placed = R.residue_config().get(program)
        if placed:
            return Spec(placed['root'], tuple(placed['specialize']),
                        tuple(sorted(declaration_defines(measured))))
    return None


@translator('TextureFilter.fx__main_vs')
def _filter_vs(defines, measured):
    return 'filter_vs_main', ['FilterTapsOffset']


@translator('TextureFilter.fx__main_vs_highlight', 'TextureFilter.fx__main_vs_ssao')
def _filter_vs_centered(defines, measured):
    return 'filter_vs_main', ['FilterTapsCentered']


@translator('TextureFilter.fx__main_ps_highlight_blur_con_ppc')
def _blur_ps(defines, measured):
    return 'blur_ps_main', [alpha_test(measured)]


# Actor.fx main_vs / main_ps_alphacomp are translated in tools/d3_cfg_actor.py with the
# rest of the actor domain.


# --------------------------------------------------------------------------
# spec mutations (gate D8): used by tools/d3_mutate.py and translator plugins
# --------------------------------------------------------------------------

def swap_specialize(old: str, new: str):
    """A spec edit replacing one specialization argument (e.g. a tie flip)."""
    from dataclasses import replace
    def edit(spec):
        if old not in spec.specialize:
            return None
        return replace(spec, specialize=tuple(new if s == old else s for s in spec.specialize))
    return edit


def widen_first_row():
    """A spec edit growing the first narrower-than-float4 interpolant by one component."""
    from dataclasses import replace
    def edit(spec):
        d = list(spec.defines)
        for i, x in enumerate(d):
            if x.startswith('D3_IO_') and '_TYPE=float' in x and not x.endswith('float4'):
                name, ty = x.split('=')
                width = 1 if ty == 'float' else int(ty[-1])
                d[i] = '%s=float%d' % (name, width + 1)
                return replace(spec, defines=tuple(d))
        return None
    return edit


def shift_first_texture():
    """A spec edit moving the first bound texture up one register."""
    from dataclasses import replace
    def edit(spec):
        d = list(spec.defines)
        for i, x in enumerate(d):
            if x.startswith('D3_T_'):
                name, reg = x.split('=')
                d[i] = '%s=t%d' % (name, int(reg[1:]) + 1)
                return replace(spec, defines=tuple(d))
        return None
    return edit


# --------------------------------------------------------------------------
# translator files: landed domains, then workspace plugins
# --------------------------------------------------------------------------

#: loaded plugin modules; a plugin may also define ``MUTATIONS`` for d3_mutate
PLUGINS = []


def _load(path: Path):
    spec = importlib.util.spec_from_file_location('d3_cfg_plugin_%d' % len(PLUGINS), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    PLUGINS.append(mod)


for _path in sorted(Path(__file__).resolve().parent.glob('d3_cfg_*.py')):
    _load(_path)
for _path in filter(None, os.environ.get('D3_CFG_PLUGINS', '').split(os.pathsep)):
    _load(Path(_path))
