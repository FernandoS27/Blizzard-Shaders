"""Translators for the roots ported in workspace scene_ps.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test


def _texcoords(measured):
    return sorted(idx for name, idx, *_ in measured['transport'] if name == 'TEXCOORD')


# ---------------------------------------------------------------------------
# prepasses and fog planes
# ---------------------------------------------------------------------------

@translator('Scene.fx__ps_scene_prepass', 'Prop.fx__ps_prop_prepass')
def _prepass(defines, measured):
    shape = 'AlphaQuarterStepsHard' if on(defines, 'ALPHAMASK') else 'AlphaUnshaped'
    uv = _texcoords(measured)[0]
    return 'scene_ps_main', ['CoveragePrepass<%s, %d>' % (shape, uv), alpha_test(measured)]


@translator('InteractiveFog.fx__ps_fog')
def _fog_plane(defines, measured):
    return 'scene_ps_main', ['FogPlaneMasks<false>', alpha_test(measured)]


@translator('InteractiveFog.fx__ps_fog_vert_alpha')
def _fog_plane_vertex_alpha(defines, measured):
    return 'scene_ps_main', ['FogPlaneMasks<true>', alpha_test(measured)]


# ---------------------------------------------------------------------------
# lightmapped surfaces
# ---------------------------------------------------------------------------

#: the five sun shadow kernels (roots/surface/landscape_shading.slang), by what each computes
PACKED, MOMENTS, DEPTH, PCF, COMPARE = ('LandscapeShadowPacked', 'LandscapeShadowSoft',
                                        'LandscapeShadowDepth', 'LandscapeShadowDepthQuad',
                                        'LandscapeShadowCompare')


def _shadow(kernel):
    return 'LandscapeShadowNone' if kernel is None else kernel


def _mode(defines, name, kernels):
    """A subfamily's numbered shadow-mode define -> kernel (mode 0: none)."""
    return kernels[int(defines.get(name, '0'))]


def _frame(measured):
    """First TEXCOORD of the per-pixel frame: the vertex stage packs the view
    position, three axes and the emissive colour last."""
    return _texcoords(measured)[-1] - 4


def _pixel_lighting(normal, measured, spot, gloss):
    return 'PixelLighting<%s, %d, %s, %s>' % (normal, _frame(measured), boolean(spot), boolean(gloss))


def _composite(lighting, shadow, shape, ssao, gloss, fog, measured):
    occlusion = 'OcclusionScreenSpace' if ssao else 'OcclusionBaked'
    return 'scene_ps_main', ['LightmapComposite<%s, %s, %s, %s, %s, %s>'
                             % (lighting, shadow, occlusion, shape, boolean(gloss), boolean(fog)),
                             alpha_test(measured)]


@translator('Scene.fx__ps_scene')
def _scene(defines, measured):
    gloss = on(defines, 'GLOSS')
    if on(defines, 'PER_PIXEL'):
        lighting = _pixel_lighting('NormalFromNormalMap', measured, on(defines, 'SPOTLIGHT'), gloss)
    else:
        lighting = 'VertexLighting'
    kernel = None
    if on(defines, 'SHADOW'):
        kernel = _mode(defines, 'SHADOW_FILTER', (PACKED, DEPTH, PCF, COMPARE, MOMENTS))
    shape = 'AlphaQuarterStepsSoft' if on(defines, 'ALPHAMASK') else 'AlphaUnshaped'
    return _composite(lighting, _shadow(kernel), shape, on(defines, 'SSAO'), gloss,
                      on(defines, 'FOG'), measured)


@translator('Scene.fx__ps_scene_aux')
def _scene_aux(defines, measured):
    kernel = _mode(defines, 'SHADOW_MODE', (None, PACKED, COMPARE, DEPTH, MOMENTS, PCF))
    return _composite('VertexLighting', _shadow(kernel), 'AlphaUnshaped', False, False, True, measured)


@translator('Prop.fx__ps_prop')
def _prop(defines, measured):
    kernel = None
    if on(defines, 'SHADOW'):
        if on(defines, 'VIGNETTE'):
            kernel = COMPARE if on(defines, 'SHADOW_CMP') else PCF if on(defines, 'SHADOW_SOFT') else DEPTH
        else:
            kernel = MOMENTS if on(defines, 'SHADOW_SOFT') else PACKED
    shape = 'AlphaUnshaped'
    if on(defines, 'ALPHAMASK'):
        shape = 'AlphaQuarterStepsHard' if on(defines, 'ALPHAMASK_B') else 'AlphaQuarterStepsSoft'
    return 'scene_ps_main', ['PropComposite<%s, %s, %s, %s>'
                             % (_shadow(kernel), shape, boolean(on(defines, 'GLOSS')),
                                boolean(on(defines, 'USE_FOG'))),
                             alpha_test(measured)]


@translator('Scene.fx__ps_scene_battlenet')
def _battlenet(defines, measured):
    kernel = _mode(defines, 'SHADOW_MODE', (None, COMPARE, DEPTH, PACKED, PCF, MOMENTS))
    return 'scene_ps_main', ['LightmapGlowComposite<%s, %s>'
                             % (_shadow(kernel), boolean(on(defines, 'PP'))),
                             alpha_test(measured)]


@translator('Scene.fx__ps_scene_glow_2tex')
def _two_layer(defines, measured):
    kernel = _mode(defines, 'SHADOWMODE', (None, PACKED, MOMENTS, DEPTH, PCF, COMPARE))
    lighting = 'VertexLighting'
    if on(defines, 'PER_PIXEL'):
        lighting = _pixel_lighting('NormalFromLayers', measured, False, False)
    return 'scene_ps_main', ['TwoLayerComposite<%s, %s>' % (lighting, _shadow(kernel)),
                             alpha_test(measured)]


@translator('Scene.fx__ps_scene_overlay')
def _overlay(defines, measured):
    kernel = _mode(defines, 'SHADOW_MODE', (None, PACKED, MOMENTS, COMPARE, DEPTH, PCF))
    lighting = 'VertexLighting'
    if on(defines, 'PER_PIXEL'):
        lighting = _pixel_lighting('NormalFromOverlay', measured, False, True)
    return 'scene_ps_main', ['OverlayComposite<%s, %s>' % (lighting, _shadow(kernel)),
                             alpha_test(measured)]


@translator('Scene.fx__ps_scene_act4_floor')
def _heaven_floor(defines, measured):
    kernel = _mode(defines, 'SHADOW_MODE', (None, PACKED, MOMENTS, DEPTH, PCF, COMPARE))
    lighting = 'VertexLighting'
    if on(defines, 'PER_PIXEL_LIGHTING'):
        lighting = _pixel_lighting('NormalFromFloorMap', measured, False, True)
    return 'scene_ps_main', ['FloorReflectionComposite<%s, %s>' % (lighting, _shadow(kernel)),
                             alpha_test(measured)]


#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields:
#:   dict(name=..., root=..., kind='src', file='roots/...slang', old=..., new=..., cls='nan')
#:   dict(name=..., root=..., kind='cfg', spec=C.widen_first_row(), cls='transport')
_ROOT = 'scene_ps_main'
_MODELS = 'roots/surface/scene_models.slang'
_KERNELS = 'roots/surface/landscape_shading.slang'
MUTATIONS = [
    dict(name='scene-transport-width', root=_ROOT, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='scene-register-shift', root=_ROOT, kind='cfg', spec=C.shift_first_texture(), cls='register'),
    dict(name='scene-tie-flip', root=_ROOT, kind='cfg', spec=C.swap_specialize('DiscardLE', 'DiscardLT'),
         cls='tie'),
    dict(name='scene-nan-injection', root=_ROOT, kind='src', file=_MODELS,
         old='return occlusion * (light.dark', new='return sqrt(occlusion - 0.5) * (light.dark', cls='nan'),
    # (a first candidate, 'texel.z * (1/65536) -> (1/65535)', was MISSED and is a no-op on the
    # domain: it moves the packed depth by z * 2.3e-10, below float32 resolution for any depth
    # the compare can see)
    dict(name='packed-depth-byte-order', root=_ROOT, kind='src', file=_KERNELS,
         old='float depth = texel.x + texel.y * (1.0 / 256.0)', new='float depth = texel.y + texel.x * (1.0 / 256.0)'),
    dict(name='packed-receiver-undivided', root=_ROOT, kind='src', file=_KERNELS,
         old='return landscapeShadowFloor(texel.w * occluded + 1.0, proj.z);',
         new='return landscapeShadowFloor(texel.w * occluded + 1.0, coord.z);'),
    # (a first candidate, dropping 'moments.y == 0.0', was MISSED and is a no-op: with
    # moments.y == 0 the other arm is -0 and min(fade, moments.z) * -0 + 1 == 1)
    dict(name='moments-test-channels', root=_ROOT, kind='src', file=_KERNELS,
         old='biased * (1.0 - moments.y) + moments.x', new='biased * (1.0 - moments.x) + moments.y'),
    dict(name='pcf-weight-order', root=_ROOT, kind='src', file=_KERNELS,
         old='float4 weights = float4((1.0 - f.y) * f.x, (1.0 - f.x) * f.y,',
         new='float4 weights = float4((1.0 - f.x) * f.y, (1.0 - f.y) * f.x,'),
    dict(name='pixel-light-clamp', root=_ROOT, kind='src', file='math/surface_lights.slang',
         old='int count = min(int(numLights.x), 16);', new='int count = min(int(numLights.x), 15);'),
    dict(name='half-shadow-strength', root=_ROOT, kind='src', file=_MODELS,
         old='float sun = TShadow.visibility(i.texcoord4()) * 0.5 + 0.5;',
         new='float sun = TShadow.visibility(i.texcoord4()) * 0.5 + 0.25;'),
    dict(name='foliage-mask-threshold', root=_ROOT, kind='src', file='roots/surface/scene_ps.slang',
         old='(alpha - 0.34375) * 9.1428575', new='(alpha - 0.375) * 9.1428575'),
    dict(name='overlay-amount-strength', root=_ROOT, kind='src', file=_MODELS,
         old='float amount = overlay.w * i.texcoord4().z;', new='float amount = overlay.w;'),
    dict(name='frame-axis-order', root=_ROOT, kind='src', file='roots/surface/scene_lighting.slang',
         old='float3 normal = normalize(t.x * axisX + t.y * axisY + t.z * axisZ);',
         new='float3 normal = normalize(t.x * axisY + t.y * axisX + t.z * axisZ);'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = ['scene_ps_main']
SKINNED_ROOTS = []
