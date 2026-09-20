"""The Diablo III retail corpus (``$D3_RE``) as the D3 gates see it.

``$D3_RE/<pixel|vertex>/<Fx>__<entry>/`` holds, per retail permutation key,
``perm_<hash>.dxbc`` + ``.asm``, plus ``perms.csv`` (assets, render state,
texture stage types), ``family.json`` (technique pairings) and the RE
reconstruction's ``uber.hlsl`` + ``uber_manifest.json`` (local defines).

The tree is READ-ONLY input. A retail **program** is identified by the bytes of
its ``.dxbc`` -- never by its ``.asm``, which is an extraction artifact
([[project_fold_class_counting]]) -- and a key names one retail permutation.

The grouping of subfamilies into bundles and roots is ``d3_shaders.json``.
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
D3_RE = Path(os.environ.get('D3_RE', r'C:\Projects\WhiteoutFlakes\d3_re_shaders'))
#: the programs $D3_RE leaves out, extracted by tools/d3_residue.py (plan M7)
RESIDUE_DIR = Path(os.environ.get('D3_RE_RESIDUE') or (REPO / 'd3_re_residue'))
CONFIG = REPO / 'd3_shaders.json'
#: residue placements; a workspace points this at its own copy (tools/d3_ws.py)
RESIDUE_CONFIG = Path(os.environ.get('D3_RESIDUE_CONFIG') or (REPO / 'd3_residue.json'))
STAGE_DIR = {'ps': 'pixel', 'vs': 'vertex'}

#: CBMain row of ``alphaTestRef`` (offset 1888), CBLights row of ``numLights``.
ALPHA_REF_ROW = 1888 // 16
NUM_LIGHTS_ROW = 6160 // 16


@dataclass
class Key:
    subfamily: str
    hash: str
    defines: dict
    shaders: list
    stage_types: str
    dxbc: Path

    @property
    def asm(self) -> Path:
        return self.dxbc.with_suffix('.asm')


@dataclass
class Subfamily:
    name: str            # "Prop.fx__ps_prop"
    stage: str           # "ps" | "vs"
    domain: str          # "surface"
    root: str            # "surface_ps_main"
    folder: Path
    profile: str
    uber_entry: str
    pairs: list
    keys: list = field(default_factory=list)


def load_config() -> dict:
    return json.loads(CONFIG.read_text('utf-8'))


def bundles() -> list:
    """``[(domain, stage)]`` in config order."""
    cfg = load_config()
    return [(d, s) for d, v in cfg.items() if not d.startswith('_') for s in v]


def bundle_id(domain: str, stage: str) -> str:
    return '%s_%s' % (stage, domain)


@lru_cache(maxsize=None)
def subfamilies() -> dict:
    """``{name: Subfamily}`` for every subfamily the config places in a root."""
    out = {}
    for domain, stage in bundles():
        for root, names in load_config()[domain][stage]['roots'].items():
            for name in names:
                folder = D3_RE / STAGE_DIR[stage] / name
                man = json.loads((folder / 'uber_manifest.json').read_text('utf-8'))
                fam = json.loads((folder / 'family.json').read_text('utf-8'))
                sf = Subfamily(name, stage, domain, root, folder,
                               man.get('profile') or fam.get('profile'),
                               man.get('entry') or 'main',
                               fam.get('techniques', []))
                rows = {}
                with open(folder / 'perms.csv', newline='', encoding='utf-8') as fh:
                    for r in csv.DictReader(fh):
                        rows[r['hash']] = r
                for h, p in sorted(man['perms'].items()):
                    r = rows.get(h, {})
                    sf.keys.append(Key(name, h, dict(p.get('defines') or {}),
                                       (r.get('shaders') or '').split(),
                                       r.get('textureStageTypes', ''),
                                       folder / ('perm_%s.dxbc' % h)))
                out[name] = sf
    return out


def unplaced() -> list:
    """RE subfamily folders the config does not place in any root."""
    placed = set(subfamilies())
    return sorted(f.name for s in STAGE_DIR.values() for f in (D3_RE / s).iterdir()
                  if f.is_dir() and f.name not in placed)


@lru_cache(maxsize=None)
def program_id(dxbc: Path) -> str:
    return hashlib.sha1(Path(dxbc).read_bytes()).hexdigest()


# --------------------------------------------------------------------------
# residue (plan M7): keys $D3_RE does not hold
# --------------------------------------------------------------------------

def residue_subfamily(stage: str) -> str:
    """The pseudo-subfamily of residue keys that name no entry point."""
    return 'Residue__%s' % stage


@dataclass
class ResidueKey:
    stage: str
    hash: str
    kind: str            # singleton | no_shd | disputed
    subfamily: str       # "<Fx>__<entry>" for a singleton, else Residue__<stage>
    program: str
    shaders: list
    evidence: dict

    @property
    def dxbc(self) -> Path:
        return RESIDUE_DIR / self.stage / ('%s.dxbc' % self.hash)


@lru_cache(maxsize=None)
def residue_keys() -> tuple:
    path = REPO / 'd3_perms' / '_residue_keys.json'
    if not path.exists():
        return ()
    out = []
    for name, r in sorted(json.loads(path.read_text('utf-8')).items()):
        stage, h = name.split('/')
        sub = r['subfamily'] if r['kind'] == 'singleton' else residue_subfamily(stage)
        out.append(ResidueKey(stage, h, r['kind'], sub, r['program'], r['shaders'],
                              {k: r[k] for k in ('fx', 'fxGuess', 'entries')}))
    return tuple(out)


@lru_cache(maxsize=None)
def residue_config() -> dict:
    """``d3_residue.json``: ``{program id: {"root": ..., "specialize": [...]}}`` for
    residue programs no translator names."""
    if not RESIDUE_CONFIG.exists():
        return {}
    return {k: v for k, v in json.loads(RESIDUE_CONFIG.read_text('utf-8')).items()
            if not k.startswith('_')}


def root_bundle(root: str) -> tuple | None:
    """``(domain, stage)`` of the bundle a root belongs to."""
    cfg = load_config()
    for domain, stage in bundles():
        if root in cfg[domain][stage]['roots']:
            return domain, stage
    return None


@lru_cache(maxsize=None)
def _residue_index() -> dict:
    return {(k.subfamily, k.hash): k for k in residue_keys()}


def key_dxbc(row: dict) -> Path:
    """The retail ``.dxbc`` of one manifest ``retail`` row."""
    if row.get('residue'):
        return _residue_index()[(row['subfamily'], row['hash'])].dxbc
    return subfamilies()[row['subfamily']].folder / ('perm_%s.dxbc' % row['hash'])


_CMP = re.compile(r'^(lt|ge|eq|ne)\s+(\S+),\s*(\S+),\s*(\S+)$')


def alpha_compares(asm_text: str) -> list:
    """Every compare against ``alphaTestRef`` (``cb0[118]``), in program order,
    spelled ``op(lhs,rhs)`` with operands reduced to ``ref`` / ``lit`` / ``a``.

    Two programs that differ only in ``lt ref,a`` against ``ge a,ref`` discard
    differently at an exact tie (design section 0.2); nothing else in the bytes
    records it, so it is a measured axis.
    """
    ref = 'cb0[%d]' % ALPHA_REF_ROW
    out = []
    for line in asm_text.splitlines():
        m = _CMP.match(line.strip())
        if not m or ref not in line:
            continue
        def role(tok):
            t = tok.lstrip('-|')
            if t.startswith(ref):
                return 'ref'
            if t.startswith('l('):
                return 'lit'
            return 'a'
        out.append('%s(%s,%s)' % (m.group(1), role(m.group(3)), role(m.group(4))))
    return out
