#!/usr/bin/env python3
"""Gate D6 -- do the non-D3D11 outputs of d3_shaders validate?

``compile_all_d3.py --target ...`` proves slangc accepts each slot for a
backend; this runs each backend's own validator over what it wrote, because a
backend can accept code its consumer rejects (the Wc3 HD 3.0.0 port had a green
D3D gate while four of six backends were broken):

* vulkan  ``.spv``  -> ``spirv-val``
* opengl  ``.glsl`` -> ``glslangValidator -V`` (stage from the bundle)
* webgpu  ``.wgsl`` -> ``naga``
* d3d12   ``.dxil`` -- validated and signed by dxc during the compile
* metal   ``.metal`` -- no validator on this host; compile-only

    python compile_all_d3.py --all --target d3d12,vulkan,opengl,metal,webgpu --sample 12
    python tools/d3_backends.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import compile_all_d3 as CA               # noqa: E402

VALIDATORS = {
    'vulkan': ('spv', lambda p, stage: ['spirv-val', str(p)]),
    # slang's GLSL uses separate texture/sampler objects (GL_KHR_vulkan_glsl), so it is
    # checked with Vulkan semantics, as the Wc3 G5 gate did
    'opengl': ('glsl', lambda p, stage: ['glslangValidator', '-V', '-S', 'frag' if stage == 'ps' else 'vert',
                                         '-o', os.devnull, str(p)]),
    'webgpu': ('wgsl', lambda p, stage: ['naga', str(p)]),
}


def main() -> int:
    bad = total = 0
    for target, (ext, cmd) in VALIDATORS.items():
        tool = cmd(Path('x'), 'ps')[0]
        if not shutil.which(tool):
            print('%-7s %s not found -- skipped' % (target, tool))
            continue
        files = sorted((CA.OUT_ROOT / target).glob('*/slot_*.%s' % ext))

        def run(p):
            stage = p.parent.name.split('_', 1)[0]
            r = subprocess.run(cmd(p, stage), capture_output=True, text=True)
            return p, r.returncode, (r.stdout + r.stderr).strip()

        with ThreadPoolExecutor(8) as ex:
            res = list(ex.map(run, files))
        fails = [(p, out) for p, rc, out in res if rc != 0]
        total += len(res)
        bad += len(fails)
        print('%-7s %4d/%-4d validate' % (target, len(res) - len(fails), len(res)))
        for p, out in fails[:8]:
            print('   %s: %s' % (p.relative_to(CA.OUT_ROOT), out.splitlines()[-1] if out else ''))
    print('D6: %d file(s), %s' % (total, 'clean' if not bad else '%d failed' % bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
