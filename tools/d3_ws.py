#!/usr/bin/env python3
"""Isolated workspaces for porting d3_shaders roots in parallel.

d3_shaders is ONE translation unit: a root under construction that does not
compile breaks every other root's build. A workspace is a private copy of the
module plus a private build tree and translator plugin:

    d3_work/<name>/d3_shaders/     copy of d3_shaders/ to edit freely
    d3_work/<name>/cfg.py          translators + MUTATIONS for the roots ported here
    d3_work/<name>/d3_residue.json residue program placements made here (plan M7)
    d3_work/<name>/out/            compile / validation output

and every D3 tool runs against it through this launcher:

    python tools/d3_ws.py init <name>
    python tools/d3_ws.py <name> compile   --bundle ps_actor [--root actor_ps_main]
    python tools/d3_ws.py <name> validate  --bundle ps_actor --root actor_ps_main --fold
    python tools/d3_ws.py <name> partition --bundle ps_actor
    python tools/d3_ws.py <name> mutate    --root actor_ps_main
    python tools/d3_ws.py <name> lint
    python tools/d3_ws.py <name> build     --bundle ps_actor --verify
    python tools/d3_ws.py land <name> [--dry-run]

Landing is a three-way merge against ``d3_work/_baseline`` (the module every
workspace was copied from): files only the workspace changed are copied, the
module root's include list is merged, anything changed on both sides is
reported as a conflict, and ``cfg.py`` becomes ``tools/d3_cfg_<name>.py``.
Residue placements (``d3_residue.json``) are merged by program: a placement
only the workspace made is added, one both sides made differently is a
conflict. The full gate set then runs in the main tree.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORK = REPO / 'd3_work'

TOOLS = {
    'compile': REPO / 'compile_all_d3.py',
    'validate': REPO / 'tools' / 'd3_validate_all.py',
    'partition': REPO / 'tools' / 'd3_perm_manifest.py',
    'mutate': REPO / 'tools' / 'd3_mutate.py',
    'lint': REPO / 'tools' / 'd3_style_lint.py',
    'build': REPO / 'build_d3_bls.py',
    'diff': REPO / 'tools' / 'd3_diff.py',
}

PLUGIN_TEMPLATE = '''"""Translators for the roots ported in workspace {name}.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test

# @translator('Fx.fx__entry')
# def _entry(defines, measured):
#     return 'root_main', ['Policy<true>', alpha_test(measured)]

#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields:
#:   dict(name=..., root=..., kind='src', file='roots/...slang', old=..., new=..., cls='nan')
#:   dict(name=..., root=..., kind='cfg', spec=C.widen_first_row(), cls='transport')
MUTATIONS = []

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = []
'''


def env_for(name: str) -> dict:
    ws = WORK / name
    env = dict(os.environ)
    env['D3_SHADERS_DIR'] = str(ws / 'd3_shaders')
    env['D3_SLANG_OUT'] = str(ws / 'out')
    env['D3_CFG_PLUGINS'] = str(ws / 'cfg.py')
    env['D3_RESIDUE_CONFIG'] = str(ws / 'd3_residue.json')
    return env


def init(name: str) -> int:
    ws = WORK / name
    if ws.exists():
        print('%s already exists' % ws)
        return 1
    ws.mkdir(parents=True)
    shutil.copytree(REPO / 'd3_shaders', ws / 'd3_shaders')
    (ws / 'cfg.py').write_text(PLUGIN_TEMPLATE.format(name=name), 'utf-8')
    residue = REPO / 'd3_residue.json'
    (ws / 'd3_residue.json').write_text(residue.read_text('utf-8') if residue.exists() else '{}\n', 'utf-8')
    (ws / 'out').mkdir()
    print('workspace %s ready: edit %s and %s' % (name, ws / 'd3_shaders', ws / 'cfg.py'))
    return 0


def _merge_includes(base: str, ours: str, theirs: str) -> str:
    """The module root is an include list: keep main's file and add the
    workspace's new `__include` lines after the last include of their group."""
    have = set(ours.splitlines())
    lines = ours.splitlines()
    for line in theirs.splitlines():
        if line.startswith('__include') and line not in have:
            directory = line.split('"')[1].split('/')[0]
            at = max((i for i, l in enumerate(lines)
                      if l.startswith('__include') and l.split('"')[1].split('/')[0] == directory),
                     default=max(i for i, l in enumerate(lines) if l.startswith('__include')))
            lines.insert(at + 1, line)
            have.add(line)
    return '\n'.join(lines) + '\n'


def land(name: str, dry_run: bool) -> int:
    """Three-way land of a workspace into the main tree (baseline = d3_work/_baseline)."""
    ws = WORK / name / 'd3_shaders'
    base = WORK / '_baseline' / 'd3_shaders'
    main = REPO / 'd3_shaders'
    actions, conflicts = [], []
    for src in sorted(ws.rglob('*')):
        if src.is_dir() or src.suffix in ('.dxbc', '.asm', '.err'):
            continue
        rel = src.relative_to(ws)
        b, m = base / rel, main / rel
        theirs = src.read_bytes()
        ours = m.read_bytes() if m.exists() else None
        old = b.read_bytes() if b.exists() else None
        if theirs == old or theirs == ours:
            continue
        if ours == old:
            actions.append((rel, theirs, 'copy'))
        elif rel.as_posix() == 'd3_shaders.slang':
            merged = _merge_includes(old.decode(), ours.decode(), theirs.decode())
            actions.append((rel, merged.encode(), 'merge includes'))
        else:
            conflicts.append(rel)
    plugin = WORK / name / 'cfg.py'
    target = REPO / 'tools' / ('d3_cfg_%s.py' % name)
    for rel, data, how in actions:
        print('  %-14s %s' % (how, rel.as_posix()))
        if not dry_run:
            (main / rel).parent.mkdir(parents=True, exist_ok=True)
            (main / rel).write_bytes(data)
    print('  %-14s %s -> %s' % ('plugin', plugin.name, target.relative_to(REPO)))
    if not dry_run:
        shutil.copyfile(plugin, target)
    for rel in conflicts:
        print('  CONFLICT       %s changed in main and in the workspace -- merge by hand' % rel.as_posix())
    return max(1 if conflicts else 0, _land_residue(name, dry_run), _land_roots(plugin, dry_run))


def _land_roots(plugin: Path, dry_run: bool) -> int:
    """A workspace's ``NEW_ROOTS = {root: bundle id}`` become roots (with no RE subfamilies)
    in d3_shaders.json, so the manifest can place residue programs into them."""
    import importlib.util
    import json
    spec = importlib.util.spec_from_file_location('d3_ws_plugin', plugin)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(REPO / 'tools'))
    spec.loader.exec_module(mod)
    roots = getattr(mod, 'NEW_ROOTS', {})
    if not roots:
        return 0
    path = REPO / 'd3_shaders.json'
    cfg = json.loads(path.read_text('utf-8'))
    bad = 0
    for root, bid in sorted(roots.items()):
        stage, domain = bid.split('_', 1)
        have = [(d, s) for d in cfg if not d.startswith('_') for s in cfg[d] if root in cfg[d][s]['roots']]
        if have and have != [(domain, stage)]:
            print('  CONFLICT       root %s already in %s' % (root, have))
            bad += 1
            continue
        if not have:
            cfg[domain][stage]['roots'][root] = []
            print('  %-14s %s -> %s' % ('new root', root, bid))
    if not dry_run:
        text = json.dumps(cfg, indent=2) + '\n'
        path.write_text(text, 'utf-8')
    return 1 if bad else 0


def _land_residue(name: str, dry_run: bool) -> int:
    import json
    src = WORK / name / 'd3_residue.json'
    dst = REPO / 'd3_residue.json'
    if not src.exists():
        return 0
    theirs = json.loads(src.read_text('utf-8'))
    ours = json.loads(dst.read_text('utf-8')) if dst.exists() else {}
    added, bad = 0, 0
    for pid, spec in theirs.items():
        if pid not in ours:
            ours[pid] = spec
            added += 1
        elif ours[pid] != spec:
            print('  CONFLICT       d3_residue.json program %s placed differently in main' % pid[:12])
            bad += 1
    print('  %-14s d3_residue.json: %d placement(s)' % ('merge', added))
    if not dry_run:
        dst.write_text(json.dumps(ours, indent=1, sort_keys=True) + '\n', 'utf-8')
    return 1 if bad else 0


def main(argv) -> int:
    if len(argv) >= 2 and argv[0] == 'init':
        return init(argv[1])
    if len(argv) >= 2 and argv[0] == 'land':
        return land(argv[1], '--dry-run' in argv)
    if len(argv) < 2 or argv[1] not in TOOLS:
        print(__doc__)
        return 2
    name, tool, rest = argv[0], argv[1], argv[2:]
    if not (WORK / name).exists():
        print('no workspace %s (python tools/d3_ws.py init %s)' % (name, name))
        return 2
    extra = ['--partition'] if tool == 'partition' else []
    return subprocess.call([sys.executable, str(TOOLS[tool])] + extra + rest, env=env_for(name))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
