#!/usr/bin/env python3
"""Gate D9 -- is d3_shaders still an idiomatic slang module?

Behavioural gates cannot tell a shader that recovers features from one that
pastes per-program bodies behind a switch; this checks the shape:

* roots/ and interfaces/ use no preprocessor conditional -- algorithms are
  interfaces and value generics; only types/ turns measured data (layouts,
  registers) into declarations;
* no identifier or define names a retail hash, slot number or permutation;
* no decompiler-style register temporaries (``r0``, ``r12xyzw``) as names;
* no type, and no function signature, declared in two files: the module is one
  translation unit, so two roots written apart that each define ``IVertexAlpha``
  compile alone and break together.

    python tools/d3_style_lint.py
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get('D3_SHADERS_DIR') or (Path(__file__).resolve().parent.parent / 'd3_shaders'))

_COND = re.compile(r'^\s*#\s*(if|ifdef|ifndef|elif)\b(.*)$')
_ALLOWED_COND = re.compile(r'\bD3_(HAS|TARGET)_\w+')
_HASHY = re.compile(r'\b\w*(?:perm|slot|hash)_?[0-9a-f]{4,}\w*\b', re.I)
_HEX8 = re.compile(r'\b[0-9a-f]{8}\b')
_REGISTER_NAME = re.compile(r'\b(?:float|int|uint|bool)[234]?\s+(r\d+[xyzw]*)\s*[=;]')


_TYPE_DECL = re.compile(r'^\s*(?:public\s+)?(?:struct|interface|enum|typealias)\s+(\w+)')
_FUNC_DECL = re.compile(r'^(?:public\s+)?(?:static\s+)?[\w<>, ]+?\s+(\w+)\s*\(([^)]*)\)\s*$')


def duplicates() -> list:
    seen = {}
    problems = []
    for path in sorted(ROOT.rglob('*.slang')):
        rel = path.relative_to(ROOT).as_posix()
        depth = 0
        for n, line in enumerate(path.read_text('utf-8').splitlines(), 1):
            code = line.split('//', 1)[0]
            if depth == 0:
                m = _TYPE_DECL.match(code)
                key = None
                if m:
                    key = ('type', m.group(1))
                else:
                    f = _FUNC_DECL.match(code.strip())
                    if f and not code.startswith((' ', '	')) and f.group(1) not in ('if', 'for', 'while', 'switch'):
                        params = tuple(p.strip().rsplit(' ', 1)[0] for p in f.group(2).split(',') if p.strip())
                        key = ('function', f.group(1), params)
                if key:
                    if key in seen and seen[key][0] != rel:
                        problems.append('%s:%d: %s %s also declared at %s:%d'
                                        % (rel, n, key[0], key[1], seen[key][0], seen[key][1]))
                    seen.setdefault(key, (rel, n))
            depth += code.count('{') - code.count('}')
    return problems


def lint() -> list:
    problems = duplicates()
    for path in sorted(ROOT.rglob('*.slang')):
        rel = path.relative_to(ROOT)
        top = rel.parts[0]
        for n, line in enumerate(path.read_text('utf-8').splitlines(), 1):
            code = line.split('//', 1)[0]
            m = _COND.match(code)
            if m and top in ('roots', 'interfaces') and not _ALLOWED_COND.search(m.group(2)):
                problems.append('%s:%d: preprocessor conditional in %s/: %s' % (rel, n, top, line.strip()))
            if _HASHY.search(code) or _HEX8.search(code):
                problems.append('%s:%d: identifier names a hash/slot: %s' % (rel, n, line.strip()))
            if _REGISTER_NAME.search(code):
                problems.append('%s:%d: register-named temporary: %s' % (rel, n, line.strip()))
    return problems


def main() -> int:
    problems = lint()
    for p in problems:
        print(p)
    print('D9: %d file(s) checked, %s' % (len(list(ROOT.rglob('*.slang'))),
                                         'clean' if not problems else '%d problem(s)' % len(problems)))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
