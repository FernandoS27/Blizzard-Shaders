"""Translators for the roots ported in workspace landscape_ps.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.

Two pixel roots of the surface bundle:

* ``landscape_ps_main`` -- Landscape.fx terrain: landscape5, landscape5_sideproj,
  landscape5_sideproj_gloss_c, landscape_webskin, landscape2_emmissive.
* ``water_ps_main`` -- Landscape.fx landscape5_water, Puddle.fx, and the
  Reflection.fx refractive water (largewater, largewater_reflect, river).
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test

# --------------------------------------------------------------------------
# axis readers
# --------------------------------------------------------------------------


def _roles(measured) -> set:
    """Retail sampler roles bound by the program (trailing t/s dropped)."""
    return {r[4][:-1] for r in measured['resources']}


def _occlusion(measured) -> str:
    return 'OcclusionScreenSpace' if 'ssaoSampler' in _roles(measured) else 'OcclusionBaked'


def _gloss(measured) -> str:
    return 'GlossEnvironment' if 'environmentMapSampler' in _roles(measured) else 'GlossNone'


def _frame(measured) -> str:
    """The per-pixel vertex stage writes its geometry into its last five
    TEXCOORDs: position, normal, tangent, binormal, vertex colour."""
    last = max(idx for name, idx, *_ in measured['transport'] if name == 'TEXCOORD')
    return 'PixelFrameAt%d' % (last - 4)


#: the sun shadow filters, by the name each subfamily's defines give them
_SHADOW_MODE = {  # Landscape.fx sideproj_gloss_c SHADOW_MODE
    '0': 'LandscapeShadowNone', '1': 'LandscapeShadowPacked', '2': 'LandscapeShadowSoft',
    '3': 'LandscapeShadowDepth', '4': 'LandscapeShadowCompare', '5': 'LandscapeShadowDepthQuad'}
_EMISSIVE_SHADOW_MODE = {  # Landscape.fx landscape2_emmissive SHADOW_MODE
    '0': 'LandscapeShadowNone', '1': 'LandscapeShadowPacked', '2': 'LandscapeShadowSoft',
    '3': 'LandscapeShadowCompare', '4': 'LandscapeShadowDepth', '5': 'LandscapeShadowDepthQuad'}
_SHADOW_QUALITY = {  # Landscape.fx landscape_webskin SHADOW_QUALITY
    '0': 'LandscapeShadowNone', '1': 'LandscapeShadowPacked', '2': 'LandscapeShadowSoft',
    '3': 'LandscapeShadowDepth', '4': 'LandscapeShadowDepthQuad', '5': 'LandscapeShadowCompare'}


def _shadow_flags(defines, enabled, hardware, pcf, native) -> str:
    """landscape5 / sideproj spell the filter as flags."""
    if not on(defines, enabled):
        return 'LandscapeShadowNone'
    if on(defines, hardware):
        return 'LandscapeShadowCompare'
    if on(defines, native):
        return 'LandscapeShadowDepthQuad' if on(defines, pcf) else 'LandscapeShadowDepth'
    return 'LandscapeShadowSoft' if on(defines, pcf) else 'LandscapeShadowPacked'


def _light(measured, fog: str, spotlights: bool = False) -> str:
    if measured['lights']:
        return 'LandscapePixelLit<%s, %s, %s>' % (fog, _frame(measured), boolean(spotlights))
    return 'LandscapeVertexLit<%s>' % fog


def _landscape(layers, light, shadow, measured):
    return 'landscape_ps_main', [layers, light, shadow, _occlusion(measured), _gloss(measured),
                                 alpha_test(measured)]


# --------------------------------------------------------------------------
# landscape_ps_main
# --------------------------------------------------------------------------

@translator('Landscape.fx__ps_landscape5')
def _landscape5(defines, measured):
    # SPOTLIGHT only reaches the per-pixel rig; the vertex-lit twins are one program
    light = _light(measured, 'FogInterpolant<false>', on(defines, 'SPOTLIGHT'))
    shadow = _shadow_flags(defines, 'SHADOW', 'SHADOW_HW', 'SHADOW_PCF', 'VIGNETTE')
    return _landscape('LayerSplat5', light, shadow, measured)


@translator('Landscape.fx__ps_landscape5_sideproj')
def _sideproj(defines, measured):
    shadow = _shadow_flags(defines, 'SHADOWMAP', 'SHADOW_HW', 'SHADOW_PCF', 'SHADOW_FADE')
    return _landscape('LayerSplat5SideProjected', _light(measured, 'FogTexcoord5'), shadow, measured)


@translator('Landscape.fx__ps_landscape5_sideproj_gloss_c')
def _sideproj_gloss_c(defines, measured):
    fog = 'FogInterpolant<true>' if measured['lights'] else 'FogColor1'
    shadow = _SHADOW_MODE[str(defines.get('SHADOW_MODE', '0'))]
    return _landscape('LayerSplat5SideProjected', _light(measured, fog), shadow, measured)


@translator('Landscape.fx__ps_landscape_webskin')
def _webskin(defines, measured):
    shadow = _SHADOW_QUALITY[str(defines.get('SHADOW_QUALITY', '0'))]
    return _landscape('LayerOver5', _light(measured, 'FogInterpolant<false>'), shadow, measured)


@translator('Landscape.fx__ps_landscape2_emmissive')
def _emissive(defines, measured):
    shadow = _EMISSIVE_SHADOW_MODE[str(defines.get('SHADOW_MODE', '0'))]
    return _landscape('LayerEmissivePair', _light(measured, 'FogInterpolant<false>'), shadow, measured)


# --------------------------------------------------------------------------
# water_ps_main
# --------------------------------------------------------------------------

_WATER_SHADOW = [('SHADOW_PCFSOFT', 'LandscapeShadowSoft'), ('SHADOW_PACKED', 'LandscapeShadowPacked'),
                 ('SHADOW_SIMPLE', 'LandscapeShadowDepth'), ('SHADOW_PCF4', 'LandscapeShadowDepthQuad'),
                 ('SHADOW_HW', 'LandscapeShadowCompare')]

_PUDDLE_SHADOW = {'SHADOW_PACKED': 'LandscapeShadowPacked', 'SHADOW_SOFT': 'LandscapeShadowSoft',
                  'SHADOW_SINGLE': 'LandscapeShadowDepth', 'SHADOW_PCF': 'LandscapeShadowDepthQuad',
                  'SHADOW_HARDWARE': 'LandscapeShadowCompare'}


@translator('Landscape.fx__ps_landscape5_water')
def _landscape5_water(defines, measured):
    shadow = next((kernel for flag, kernel in _WATER_SHADOW if on(defines, flag)), 'LandscapeShadowNone')
    model = 'WaterLayered<%s, %s, %s>' % (_light(measured, 'FogInterpolant<false>'), shadow, _gloss(measured))
    return 'water_ps_main', [model, alpha_test(measured)]


@translator('Puddle.fx__ps_puddle')
def _puddle(defines, measured):
    shadow = _PUDDLE_SHADOW.get(defines.get('SHADOW_FILTER'), 'LandscapeShadowNone')
    return 'water_ps_main', ['PuddleReflective<%s>' % shadow, alpha_test(measured)]


@translator('Reflection.fx__main_ps_largewater')
def _largewater(defines, measured):
    fresnel = 'FresnelSharp' if on(defines, 'SHARP_FRESNEL') else 'FresnelBroad'
    return 'water_ps_main', ['WaterRefractive<WaterReflectEnvironment, %s, false, false>' % fresnel,
                             alpha_test(measured)]


@translator('Reflection.fx__main_ps_largewater_reflect')
def _largewater_reflect(defines, measured):
    fresnel = 'FresnelSchlick' if on(defines, 'LARGE_WATER') else 'FresnelSoft'
    return 'water_ps_main', ['WaterRefractive<WaterReflectPlanar, %s, false, false>' % fresnel,
                             alpha_test(measured)]


@translator('Reflection.fx__main_ps_river')
def _river(defines, measured):
    model = 'WaterRefractive<WaterReflectEnvironment, FresnelSchlick, true, %s>' % boolean(on(defines, 'GLOSS'))
    return 'water_ps_main', [model, alpha_test(measured)]


#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields
_SHADING = 'roots/surface/landscape_shading.slang'
_LANDSCAPE = 'roots/surface/landscape_ps.slang'
_WATER = 'roots/surface/water_ps.slang'

MUTATIONS = [
    # --- landscape_ps ------------------------------------------------------------
    dict(name='landscape-transport-width', root='landscape_ps_main', kind='cfg', spec=C.widen_first_row(),
         cls='transport'),
    dict(name='landscape-register-shift', root='landscape_ps_main', kind='cfg', spec=C.shift_first_texture(),
         cls='register'),
    dict(name='landscape-tie-flip', root='landscape_ps_main', kind='cfg',
         spec=C.swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    dict(name='landscape-cylinder-nan', root='landscape_ps_main', kind='src', file=_SHADING,
         old='float perpendicular = sqrt(max(axis2 - axial * axial, 0.0));',
         new='float perpendicular = sqrt(axis2 - axial * axial);', cls='nan'),
    dict(name='landscape-spot-cone-select', root='landscape_ps_main', kind='src', file=_SHADING,
         old='float cone = (1.0 - inner) * falloff + inner;',
         new='float cone = inner > 0.5 ? 1.0 : falloff;', cls='nan'),
    # (a `moments.y == 0` -> `< 0` guard flip was tried and is a no-op: with zero
    # coverage the unguarded branch multiplies by -0 and still returns exactly 1)
    dict(name='landscape-soft-shadow-rim', root='landscape_ps_main', kind='src', file=_SHADING,
         old='(length(proj.xy - 0.5) - 0.4)', new='(length(proj.xy - 0.5) - 0.45)'),
    # (1/256 -> 1/255 in the packed depth was tried and is unreachable: it moves the
    # depth by ~1.5e-5 * y, and no trial's compare lands that close)
    dict(name='landscape-packed-gate-depth', root='landscape_ps_main', kind='src', file=_SHADING,
         old='return landscapeShadowFloor(texel.w * occluded + 1.0, proj.z);',
         new='return landscapeShadowFloor(texel.w * occluded + 1.0, coord.z);'),
    dict(name='landscape-point-light-clamp', root='landscape_ps_main', kind='src', file=_SHADING,
         old='int count = min(int(numLights.x), 16);', new='int count = min(int(numLights.x), 15);'),
    dict(name='landscape-fog-alpha', root='landscape_ps_main', kind='src', file=_SHADING,
         old='public static float alpha(float alpha, float fog) { return lerp(fogColor.w, alpha, fog); }',
         new='public static float alpha(float alpha, float fog) { return alpha; }'),
    dict(name='landscape-side-slope-start', root='landscape_ps_main', kind='src', file=_LANDSCAPE,
         old='(i.texcoord7().w - 0.57)', new='(i.texcoord7().w - 0.5)'),
    # --- water_ps ----------------------------------------------------------------
    dict(name='water-transport-width', root='water_ps_main', kind='cfg', spec=C.widen_first_row(),
         cls='transport'),
    dict(name='water-register-shift', root='water_ps_main', kind='cfg', spec=C.shift_first_texture(),
         cls='register'),
    dict(name='water-tie-flip', root='water_ps_main', kind='cfg',
         spec=C.swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    dict(name='water-coverage-nan', root='water_ps_main', kind='src', file=_WATER,
         old='float3 surface = over(c0.xyz, c1.xyz, c2.xyz, c3.xyz, w) / coverage;',
         new='float3 surface = over(c0.xyz, c1.xyz, c2.xyz, c3.xyz, w) / sqrt(coverage - 0.5);', cls='nan'),
    dict(name='water-far-plane', root='water_ps_main', kind='src', file=_WATER,
         old='(sceneDepth < 0.984375)', new='(sceneDepth <= 1.0)'),
    dict(name='water-plane-fade', root='water_ps_main', kind='src', file=_WATER,
         old='abs(dot(float4(position, 1.0), plane) * 0.25)', new='abs(dot(float4(position, 1.0), plane) * 0.5)'),
    dict(name='water-puddle-ripple', root='water_ps_main', kind='src', file=_WATER,
         old='ripple.xy * projected.w * 0.08', new='ripple.xy * projected.w * 0.16'),
    dict(name='water-fresnel-soft', root='water_ps_main', kind='src', file=_WATER,
         old='(grazing * grazing) * 0.9 + 0.1', new='(grazing * grazing) * 0.8 + 0.1'),
    dict(name='water-foam-mask-channel', root='water_ps_main', kind='src', file=_WATER,
         old='texWhitewaterMask.Sample(texWhitewaterMask_s, i.texcoord0().xy).x',
         new='texWhitewaterMask.Sample(texWhitewaterMask_s, i.texcoord0().xy).w'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = ['landscape_ps_main', 'water_ps_main']
SKINNED_ROOTS = []
