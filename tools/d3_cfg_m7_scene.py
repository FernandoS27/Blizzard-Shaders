"""Translators for the roots ported in workspace m7_scene.

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
_SCENE, _WATER, _ACTOR = 'scene_ps_main', 'water_ps_main', 'actor_ps_main'
_SURFACE = 'roots/surface/'
MUTATIONS = [
    # --- scene_ps: the residue models ---
    dict(name='foliage-opaque-level', root=_SCENE, kind='src', file=_SURFACE + 'scene_coverage.slang',
         old='float(LEVEL) / 255.0', new='float(LEVEL) / 256.0'),
    dict(name='corruption-grows-not-erodes', root=_SCENE, kind='src', file=_SURFACE + 'scene_fog_planes.slang',
         old='float growth = fogSampler.Sample(fogSampler_s, i.texcoord4().xy).r;',
         new='float growth = 1.0 - fogSampler.Sample(fogSampler_s, i.texcoord4().xy).r;'),
    dict(name='scum-channel', root=_SCENE, kind='src', file=_SURFACE + 'scene_fog_planes.slang',
         old='scumSampler.Sample(scumSampler_s, i.texcoord5().xy).r', new='scumSampler.Sample(scumSampler_s, i.texcoord5().xy).g'),
    dict(name='crack-exposure', root=_SCENE, kind='src', file=_SURFACE + 'scene_cracked_ground.slang',
         old='(exposed * crack.a)', new='crack.a'),
    dict(name='crack-normal-blend-order', root=_SCENE, kind='src', file=_SURFACE + 'scene_cracked_ground.slang',
         old='lerp(lower, upper, cover)', new='lerp(upper, lower, cover)'),
    dict(name='sphere-gloss-renormalized', root=_SCENE, kind='src', file=_SURFACE + 'scene_sphere_gloss.slang',
         old='float3 normal = float3(dot(row0.xyz, tangent), dot(row1.xyz, tangent), dot(row2.xyz, tangent));',
         new='float3 normal = normalize(float3(dot(row0.xyz, tangent), dot(row1.xyz, tangent), dot(row2.xyz, tangent)));'),
    dict(name='glow-night-time-axis', root=_SCENE, kind='src', file=_SURFACE + 'scene_unlit.slang',
         old='float night = 1.0 - Time.z;', new='float night = 1.0 - Time.y;'),
    dict(name='unlit-gloss-coverage-channel', root=_SCENE, kind='src', file=_SURFACE + 'scene_unlit.slang',
         old='diffuse.a, i.fog().x), diffuse.g);', new='diffuse.a, i.fog().x), diffuse.a);'),
    dict(name='cloud-unsaturated', root=_SCENE, kind='src', file=_SURFACE + 'scene_unlit.slang',
         old='(saturate(upper * 2.0) - saturate(lower * 2.0))', new='(upper * 2.0 - saturate(lower * 2.0))'),
    dict(name='debug-band-weight', root=_SCENE, kind='src', file=_SURFACE + 'scene_unlit.slang',
         old='.w, ShadowColor.z);', new='.w, ShadowColor.w);'),
    dict(name='residue-nan-injection', root=_SCENE, kind='src', file=_SURFACE + 'scene_unlit.slang',
         old='float3 color = (i.color0().rgb * 2.0) * diffuse.rgb + glow;',
         new='float3 color = sqrt(i.color0().rgb - 0.5) * diffuse.rgb + glow;', cls='nan'),
    # --- water_ps: the scene-material variants ---
    dict(name='water-mild-fresnel', root=_WATER, kind='src', file=_SURFACE + 'water_scene_variants.slang',
         old='grazing * 0.7 + 0.3;', new='grazing * 0.75 + 0.25;'),
    dict(name='water-ripple-unnormalized', root=_WATER, kind='src', file=_SURFACE + 'water_scene_variants.slang',
         old='return normalize(waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw));',
         new='return waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw);'),
    dict(name='water-planar-strength', root=_WATER, kind='src', file=_SURFACE + 'water_scene_variants.slang',
         old='return planar * 0.6 + WaterReflectEnvironmentUnfogged', new='return planar * 0.5 + WaterReflectEnvironmentUnfogged'),
    dict(name='water-projected-perturbation', root=_WATER, kind='src', file=_SURFACE + 'water_scene_variants.slang',
         old='(s.normal.xy * 0.12 * projected.w + projected.xy)', new='(s.normal.xy * 0.12 + projected.xy)'),
    # --- actor_ps: the glossy trees ---
    dict(name='tree-gloss-bias', root=_ACTOR, kind='src', file='roots/actor/irradiance_gloss.slang',
         old='(i.color1().xyz + 0.5)', new='(i.color1().xyz + 0.25)'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = []
