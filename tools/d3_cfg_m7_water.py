"""Translators for the roots ported in workspace m7_water.

Plan M7 residue: the Reflection.fx / Puddle.fx / InteractiveFog.fx singletons,
the Landscape.fx two-layer floors and the Scene.fx / Prop.fx residue vertex
programs. Every program here is placed as data (d3_residue.json); this file
only carries the D8 mutations of the code those placements added to
water_ps_main, landscape_ps_main and surface_vs_main (the roots' required
transport / register / nan / tie / bone classes are covered by their landed
translator files).

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test  # noqa: F401

_WATER = 'roots/surface/water_ps.slang'
_LANDSCAPE = 'roots/surface/landscape_ps.slang'
_SURFACE_VS = 'roots/surface/surface_vs.slang'
_PLACE = 'interfaces/surface_placement.slang'

#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields:
#:   dict(name=..., root=..., kind='src', file='roots/...slang', old=..., new=..., cls='nan')
#:   dict(name=..., root=..., kind='cfg', spec=C.widen_first_row(), cls='transport')
MUTATIONS = [
    # --- water_ps: composed refractive / opaque surfaces --------------------------
    dict(name='water-fresnel-flat-exponent', root='water_ps_main', kind='src', file=_WATER,
         old='pow(grazing, 0.4) * 0.6 + 0.4', new='pow(grazing, 0.5) * 0.6 + 0.4'),
    dict(name='water-murk-ripple-channel', root='water_ps_main', kind='src', file=_WATER,
         old='texRipple.Sample(texRipple_s, i.texcoord0().zw).y) * murkAlpha',
         new='texRipple.Sample(texRipple_s, i.texcoord0().zw).x) * murkAlpha'),
    dict(name='water-projected-env-unscaled', root='water_ps_main', kind='src', file=_WATER,
         old='(s.normal.xy * 0.12 * projected.w + projected.xy) / projected.w',
         new='(s.normal.xy * 0.12 + projected.xy) / projected.w'),
    dict(name='water-normal-scale-component', root='water_ps_main', kind='src', file=_WATER,
         old='n.xy = n.xy * normalMapScale.x;', new='n.xy = n.xy * normalMapScale.y;'),
    dict(name='water-coverage-highlights-unfogged', root='water_ps_main', kind='src', file=_WATER,
         old='float3 highlights = waterHighlights(i, s) * s.fog;', new='float3 highlights = waterHighlights(i, s);'),
    dict(name='water-gloss-mask-channel', root='water_ps_main', kind='src', file=_WATER,
         old='return fresnel * texAlpha.Sample(texAlpha_s, i.texcoord0().xy).w;',
         new='return fresnel * texAlpha.Sample(texAlpha_s, i.texcoord0().xy).x;'),
    dict(name='water-ripple-normal-unnormalized', root='water_ps_main', kind='src', file=_WATER,
         old='return normalize(waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw));',
         new='return waterRippleGradient(texRipple, texRipple_s, i.texcoord0().zw);'),
    dict(name='water-opaque-murk-nan', root='water_ps_main', kind='src', file=_WATER,
         old='float3 color = d3ApplyFog(s.tint * murk.xyz, s.fog);',
         new='float3 color = d3ApplyFog(s.tint * murk.xyz, s.fog) / (murk.w - murk.w);', cls='nan'),
    # --- landscape_ps: two-layer splat ---------------------------------------------
    dict(name='landscape-splat2-weight-channel', root='landscape_ps_main', kind='src', file=_LANDSCAPE,
         old='a.color = lerp(c, texLayer1.Sample(texLayer1_s, i.texcoord1().zw), a.weights.x);',
         new='a.color = lerp(c, texLayer1.Sample(texLayer1_s, i.texcoord1().zw), a.weights.y);'),
    dict(name='landscape-splat2-normal-channel', root='landscape_ps_main', kind='src', file=_LANDSCAPE,
         old='return lerp(n, landscapeDecodeNormal(texNormal1.Sample(texNormal1_s, i.texcoord1().zw)), a.weights.x);',
         new='return lerp(n, landscapeDecodeNormal(texNormal1.Sample(texNormal1_s, i.texcoord1().zw)), a.weights.z);'),
    # --- surface_vs: puddles, prepasses, water frames, sway, fog planes -------------
    dict(name='surface-puddle-specular-halved', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='o.setTexcoord0(float4(light.specular, 0.0));', new='o.setTexcoord0(float4(light.specular * 0.5, 0.0));'),
    dict(name='surface-puddle-view-projection', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='o.setTexcoord7(mul(matTex6, v.view));', new='o.setTexcoord7(mul(matTex6, v.world));'),
    dict(name='surface-skinned-sway-strength', root='surface_vs_main', kind='src', file=_PLACE,
         old='s.position = float4(d3WindSwayOffset<WEATHER>(i) + s.position.xyz, 1.0);',
         new='s.position = float4(d3WindSwayOffset<WEATHER>(i) * 0.5 + s.position.xyz, 1.0);'),
    dict(name='surface-prepass-uv-slot', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='d3SetTexcoord(o, UV, d3TexProject(', new='d3SetTexcoord(o, UV + 1, d3TexProject('),
    dict(name='surface-view-rows-normalized', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='float3 normal = mul((float3x3)matWorldView, d3UnpackDirection(i.normalBits()));',
         new='float3 normal = v.viewNormal;'),
    dict(name='surface-water-screen-shift-rows', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='return float4(d3ScreenReflection(v.viewNormal, v.clip, matTex0[0], matTex0[1]), v.clip.zw);',
         new='return float4(d3ScreenReflection(v.viewNormal, v.clip, matTex0[1], matTex0[0]), v.clip.zw);'),
    dict(name='surface-glow-unmapped-zw', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='o.setTexcoord3(float4(uv, 0.0, 1.0));', new='o.setTexcoord3(float4(uv, 1.0, 0.0));'),
    dict(name='surface-fog-plane-layer-matrix', root='surface_vs_main', kind='src', file=_SURFACE_VS,
         old='o.setTexcoord5(d3TexProject(matTex4[0], matTex4[1], matTex4[2], matTex4[3], d3MeshUv(i)));',
         new='o.setTexcoord5(d3TexProject(matTex5[0], matTex5[1], matTex5[2], matTex5[3], d3MeshUv(i)));'),
    dict(name='surface-water-normal-maps-on', root='surface_vs_main', kind='cfg',
         spec=C.swap_specialize('ReflectiveWaterFrames<true, false, WaterEnvironmentUv, false>',
                                'ReflectiveWaterFrames<true, false, WaterEnvironmentUv, true>')),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = []
