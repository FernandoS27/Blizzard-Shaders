"""Residue particle programs placed in workspace m7_particle (plan M7).

No translators and no new roots: the 19 programs are residue placements in
d3_residue.json (written by place.py) into combiner_ps_main and texgen_vs_main,
through implementers this workspace added in new files:

* roots/legacy/combiner_particle.slang -- the TexDiffuse0 / DiffuseMap / AlphaMap
  roles, ResolveSoftFade (range, colour fade) and ResolveTransmittance;
* roots/legacy/texgen_soft.slang       -- TexGenViewDepth;
* types/textures_particle.slang        -- the alphaMap and texDiffuse0 globals.
"""

import d3_shaders_cfg as C  # noqa: F401  (the plugin contract)

_PART = 'roots/legacy/combiner_particle.slang'
_SOFT = 'roots/legacy/texgen_soft.slang'


def _src(name, root, file, old, new, cls=''):
    return dict(name=name, root=root, kind='src', file=file, old=old, new=new, cls=cls)


#: gate D8 mutations for the implementers added here; the roots' required classes
#: are covered by tools/d3_cfg_combiner.py and tools/d3_cfg_texgen_vs.py
MUTATIONS = [
    _src('particle-soft-fade-range', 'combiner_ps_main', _PART,
         '(1.0 / float(range))', '(1.0 / float(range + 1))'),
    _src('particle-soft-fade-rgb-dropped', 'combiner_ps_main', _PART,
         'color.rgb *= fade;', 'color.rgb *= 1.0;'),
    _src('particle-soft-fade-inversion', 'combiner_ps_main', _PART,
         'float sceneDepth = -cameraParams.x / (z - cameraParams.y);',
         'float sceneDepth = -cameraParams.y / (z - cameraParams.x);'),
    _src('particle-transmittance-clamped', 'combiner_ps_main', _PART,
         'return float4(color.rgb, 1.0 - color.a);', 'return float4(color.rgb, 1.0 - saturate(color.a));'),
    _src('particle-alpha-map-role', 'combiner_ps_main', _PART,
         'return alphaMap.Sample(alphaMap_s, uv);', 'return diffuseMap.Sample(diffuseMap_s, uv);'),
    _src('soft-view-depth-sign', 'texgen_vs_main', _SOFT,
         'return float4(-v.view.z, 0.0, 0.0, 0.0);', 'return float4(v.view.z, 0.0, 0.0, 0.0);'),
    _src('soft-view-depth-axis', 'texgen_vs_main', _SOFT,
         'return float4(-v.view.z, 0.0, 0.0, 0.0);', 'return float4(-v.clip.w, 0.0, 0.0, 0.0);'),
]

ALPHA_ROOTS = []
SKINNED_ROOTS = []
