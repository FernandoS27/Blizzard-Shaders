"""Translators for the actor domain: every slot of vs_actor and ps_actor.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.

The Actor.fx translators are re-registered here (this plugin loads after
tools/d3_shaders_cfg.py, so these win): the actor vertex root now takes an
IFrameSkin, and Actor.fx's ISkin reaches it through ``FrameByteNormal<...>``.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test


# --------------------------------------------------------------------------
# vertex
# --------------------------------------------------------------------------

@translator('Actor.fx__main_vs')
def _actor_main_vs(defines, measured):
    skin = 'SkinBlend3' if on(defines, 'SKIN') else 'SkinNone'
    return 'actor_vs_main', ['FrameByteNormal<%s>' % skin, 'ActorVertexLit<%s>' % boolean(on(defines, 'GLOW'))]


def _frame(skinned):
    return 'FrameBlend3' if skinned else 'FrameRigid'


@translator('ActorIrrad.fx__vs_irrad_pvdo')
def _vs_pvdo(defines, measured):
    if on(defines, 'UNLIT'):
        light = 'LightVertexColor'
    else:
        light = 'LightSpecular' if on(defines, 'GLOSS') else 'LightDiffuse'
    facing = ('FacingReversed' if on(defines, 'BACKFACE') else
              'FacingViewer' if on(defines, 'TWOSIDED') else 'FacingAuthored')
    source = 'RestFromStream' if on(defines, 'CLOTH') else 'RestFromPosition'
    alpha = 'AlphaEdgeFresnel' if on(defines, 'EDGEALPHA') else 'AlphaFromVertex'
    return 'actor_vs_main', [_frame(on(defines, 'SKINNED')),
                             'IrradianceSplitVertex<%s, SplitDiffuseAmbient, %s, TexgenProjection<%s>, %s>'
                             % (light, facing, source, alpha)]


@translator('ActorIrrad.fx__vs_irrad_pvdo_necro_pet')
def _vs_necro_pet(defines, measured):
    return 'actor_vs_main', [_frame(on(defines, 'SKINNED')),
                             'IrradianceSplitVertex<LightSpecular, SplitAmbientFloor, FacingAuthored, '
                             'TexgenProjection<RestFromPosition>, AlphaFromVertex>']


@translator('ActorIrrad.fx__vs_irrad_pvdo_necro_bloodgolem')
def _vs_bloodgolem(defines, measured):
    return 'actor_vs_main', ['FrameBlend3',
                             'IrradianceSplitVertex<LightSpecular, SplitDiffuseAmbient, FacingAuthored, '
                             'TexgenSecondUv, AlphaFromVertex>']


def _combined(frame, light, texgen, alpha='AlphaFromVertex', scale='MeshLightingIntensity'):
    return 'actor_vs_main', [frame, 'IrradianceCombinedVertex<%s, %s, %s, %s>' % (light, scale, texgen, alpha)]


@translator('ActorIrrad.fx__vs_irrad_pv')
def _vs_pv(defines, measured):
    frame = ('FrameBlend3' if on(defines, 'SKIN') else
             'FrameWindSway' if on(defines, 'DEFORM') else 'FrameRigid')
    light = 'LightDiffuse' if on(defines, 'LIGHTING') else 'LightVertexColor'
    return _combined(frame, light, 'TexgenNone')


@translator('ActorIrrad.fx__vs_animated_pv')
def _vs_animated(defines, measured):
    return _combined(_frame(on(defines, 'SKINNED')), 'LightSpecular', 'TexgenAnimatedLayer')


@translator('ActorIrrad.fx__vs_crystal')
def _vs_crystal(defines, measured):
    light = 'LightSpecular' if on(defines, 'SPECULAR') else 'LightDiffuse'
    return _combined('FrameBlend3', light, 'TexgenCrystal', scale='MeshLightingColor')


def _rest(defines):
    return 'RestFromPosition' if on(defines, 'SKINNED') else 'RestFromStream'


@translator('ActorIrrad.fx__vs_disintegrate_death_pv')
def _vs_disintegrate(defines, measured):
    return _combined(_frame(on(defines, 'SKINNED')), 'LightDiffuse', 'TexgenDisintegrate<%s>' % _rest(defines))


@translator('ActorIrrad.fx__vs_pulverize_death_pv')
def _vs_pulverize(defines, measured):
    return _combined(_frame(on(defines, 'SKINNED')), 'LightDiffuse', 'TexgenPulverize<%s>' % _rest(defines))


@translator('ActorIrrad.fx__vs_elemental_wipe_death_pv')
def _vs_wipe(defines, measured):
    return _combined(_frame(on(defines, 'SKINNED')), 'LightDiffuse', 'TexgenWipe<%s>' % _rest(defines))


@translator('ActorIrrad.fx__vs_elemental_death_pv')
def _vs_elemental(defines, measured):
    source = 'RestFromStream' if on(defines, 'UV2_FROM_INPUT') else 'RestFromPosition'
    alpha = 'AlphaEdgeFresnel' if on(defines, 'EDGE_FRESNEL_ALPHA') else 'AlphaFromVertex'
    return _combined(_frame(on(defines, 'SKINNED')), 'LightDiffuse', 'TexgenProjection<%s>' % source, alpha)


@translator('ActorIrrad.fx__vs_irrad_prepass')
def _vs_prepass(defines, measured):
    return 'actor_vs_main', [_frame(on(defines, 'SKINNED')), 'IrradiancePrepassVertex']


@translator('ActorIrrad.fx__vs_bump_pp')
def _vs_bump(defines, measured):
    light = 'LightSpecular' if on(defines, 'SPECULAR') else 'LightDiffuse'
    alpha = 'AlphaEdgeFresnel' if on(defines, 'RIM_ALPHA') else 'AlphaFromVertex'
    extra = 'BumpExtraFade' if on(defines, 'FADE') else 'BumpExtraNone'
    return 'actor_vs_main', [_frame(on(defines, 'SKIN')), 'IrradianceBumpVertex<%s, %s, %s, %s>'
                             % (light, alpha, extra, boolean(on(defines, 'TANGENT_FRAME')))]


@translator('ActorIrrad.fx__vs_bump2_pp')
def _vs_bump2(defines, measured):
    return 'actor_vs_main', [_frame(on(defines, 'SKINNED')),
                             'IrradianceBumpVertex<LightSpecular, AlphaFromVertex, BumpExtraDetailUv, true>']


@translator('banner.fx__vs_banner')
def _vs_banner(defines, measured):
    light = 'LightDiffuse' if on(defines, 'LIT') else 'LightVertexColor'
    return 'actor_vs_main', ['FrameStream', 'BannerVertex<%s>' % light]


# --------------------------------------------------------------------------
# pixel
# --------------------------------------------------------------------------

@translator('Actor.fx__main_ps_alphacomp')
def _actor_alphacomp(defines, measured):
    return 'actor_ps_main', ['ActorAlphaComposite', alpha_test(measured)]


def _ps(model, measured):
    return 'actor_ps_main', [model, alpha_test(measured)]


def _coverage(defines):
    return 'CoverageBanded' if on(defines, 'ALPHAMASK') else 'CoverageAsIs'


@translator('ActorIrrad.fx__ps_irrad_pvdo')
def _ps_pvdo(defines, measured):
    albedo = 'AlbedoHeroTint' if on(defines, 'HEROTINT') else 'AlbedoOverlay'
    factor = 'FactorAlphaMasked' if on(defines, 'TINT') else 'FactorUniform'
    coverage = 'CoveragePremultiplied' if on(defines, 'PMA') else _coverage(defines)
    return _ps('IrradianceSplitPixel<%s, %s, %s, %s, %s, %s>'
               % (albedo, factor, coverage, boolean(on(defines, 'GLOW')), boolean(on(defines, 'GLOSS')),
                  boolean(on(defines, 'FOG'))), measured)


@translator('ActorIrrad.fx__ps_irrad_pvdo_highlight')
def _ps_highlight(defines, measured):
    return _ps('HighlightPixel<%s>' % _coverage(defines), measured)


@translator('ActorIrrad.fx__ps_irrad_prepass')
def _ps_prepass(defines, measured):
    return _ps('IrradiancePrepassPixel<%s>' % _coverage(defines), measured)


@translator('ActorIrrad.fx__ps_ghost_pv_zpass')
def _ps_ghost(defines, measured):
    return _ps('GhostPrepassPixel', measured)


@translator('ActorIrrad.fx__ps_irrad_pv')
def _ps_pv(defines, measured):
    return _ps('IrradianceTintedPixel', measured)


@translator('ActorIrrad.fx__ps_animated_pv')
def _ps_animated(defines, measured):
    return _ps('AnimatedLayerPixel', measured)


@translator('ActorIrrad.fx__ps_disintegrate_death_pv')
def _ps_disintegrate(defines, measured):
    return _ps('DisintegratePixel', measured)


@translator('ActorIrrad.fx__ps_pulverize_death_pv')
def _ps_pulverize(defines, measured):
    return _ps('PulverizePixel<%s>' % boolean(on(defines, 'FOG')), measured)


@translator('ActorIrrad.fx__ps_elemental_death_pv')
def _ps_elemental(defines, measured):
    return _ps('ElementalPixel', measured)


@translator('ActorIrrad.fx__ps_elemental_wipe_death_pv')
def _ps_wipe(defines, measured):
    return _ps('WipePixel<%s, %s>' % (boolean(on(defines, 'GLOW')), boolean(on(defines, 'FOG'))), measured)


@translator('ActorIrrad.fx__ps_irrad_pvdo_necro_bloodgolem')
def _ps_bloodgolem(defines, measured):
    return _ps('BloodGolemPixel<%s>' % boolean(on(defines, 'FOG')), measured)


_SHADOWS = {'0': 'ShadowNone', '1': 'ShadowPackedDepth', '2': 'ShadowSoftPcf', '3': 'ShadowBilinearCompare',
            '4': 'ShadowSingleCompare', '5': 'ShadowHardwareCompare'}


@translator('ActorIrrad.fx__ps_bump_pp')
def _ps_bump(defines, measured):
    shadow = _SHADOWS[str(defines.get('SHADOW', '0'))]
    return _ps('IrradianceBumpPixel<%s, %s, %s>' % (shadow, boolean(on(defines, 'GLOSS')), boolean(on(defines, 'GLOW'))),
               measured)


@translator('ActorIrrad.fx__ps_bump_pp_edgeglow')
def _ps_edgeglow(defines, measured):
    return _ps('EdgeGlowPixel<NormalSingleMap, EdgeGlowIrradiance>', measured)


@translator('ActorIrrad.fx__ps_bump_pp_edgeglow_noirrad')
def _ps_edgeglow_noirrad(defines, measured):
    return _ps('EdgeGlowPixel<NormalSingleMap, EdgeGlowReflectionOnly>', measured)


@translator('ActorIrrad.fx__ps_bump2_pp_edgeglow')
def _ps_edgeglow2(defines, measured):
    return _ps('EdgeGlowPixel<NormalDetailPair, EdgeGlowIrradiance>', measured)


@translator('banner.fx__ps_banner')
def _ps_banner(defines, measured):
    return _ps('BannerPixel', measured)


# --------------------------------------------------------------------------
# gate D8
# --------------------------------------------------------------------------

#: mutations for the actor roots; tools/d3_mutate.py adds its Actor.fx ones for the
#: same roots (bone-order-swap, transport / register / tie classes, NaN injections)
_VS = 'actor_vs_main'
_PS = 'actor_ps_main'


def _src(name, root, file, old, new, cls=''):
    return dict(name=name, root=root, kind='src', file=file, old=old, new=new, cls=cls)


_IVS = 'roots/actor/irradiance_vs.slang'
_IPS = 'roots/actor/irradiance_ps.slang'

MUTATIONS = [
    # --- actor_vs_main: ActorIrrad / banner --------------------------------------
    _src('frame-bone-order-swap', _VS, 'interfaces/frame_skinning.slang',
         'float4 blend0 = matBones[bones.x].row0 * weights.x + matBones[bones.y].row0 * weights.y',
         'float4 blend0 = matBones[bones.x].row0 * weights.y + matBones[bones.y].row0 * weights.x', cls='bone'),
    _src('frame-normal-decode-bias', _VS, 'interfaces/frame_skinning.slang',
         'return float3(packed.xyz) * (2.0 / 255.0) - 1.0;', 'return float3(packed.xyz) * (2.0 / 255.0) - 0.5;'),
    _src('wind-sway-phase', _VS, 'interfaces/frame_skinning.slang',
         '(i.color1().w + randFloat.w) + randFloat.y', '(i.color1().w + randFloat.w) + randFloat.x'),
    _src('specular-primary-color', _VS, 'math/lights_specular.slang',
         'acc.specular = (highlight * lightPoints[0].colSpecular.xyz) * atten;',
         'acc.specular = (highlight * lightPoints[0].colDiffuse.xyz) * atten;'),
    _src('specular-linear-clamp', _VS, 'math/lights_specular.slang',
         'int count = min(int(numLights.x), 16);', 'int count = min(int(numLights.x), 15);'),
    _src('ambient-floor-slope', _VS, _IVS,
         'ambient = appearanceFX.y * (l.ambient - floored) + floored;',
         'ambient = appearanceFX.x * (l.ambient - floored) + floored;'),
    _src('facing-viewer-row', _VS, _IVS,
         'dot(matWorldView[2].xyz, normal) < 0.0', 'dot(matWorldView[1].xyz, normal) < 0.0'),
    _src('edge-fresnel-exponent', _VS, _IVS,
         'pow(facing, edgealphaParams.x + edgealphaParams.x)', 'pow(facing, edgealphaParams.x)'),
    _src('mesh-lighting-color', _VS, _IVS,
         'return diffuse * MeshLighting.xyz;', 'return diffuse * MeshLighting.xxx;'),
    _src('second-uv-matrix', _VS, _IVS,
         'd3TexTransform(matTex4[0], matTex4[1], uv1)', 'd3TexTransform(matTex3[0], matTex3[1], uv1)'),
    _src('animated-layer-matrix', _VS, _IVS,
         'd3TexTransform(matTex4[0], matTex4[1], uv0)', 'd3TexTransform(matTex5[0], matTex5[1], uv0)'),
    _src('disintegrate-front', _VS, _IVS,
         'dot(matTex2[1], rest4), matTex2[0].w, 0.0)', 'dot(matTex2[1], rest4), matTex2[1].w, 0.0)'),
    _src('pulverize-front', _VS, _IVS,
         '(matTex2[0].w * 16.0 - 8.0) - rest.x', '(matTex2[0].w * 16.0 - 8.0) + rest.x'),
    _src('wipe-translation-twice', _VS, _IVS,
         'dot(matTex2[1], rest) + matTex2[1].w,', 'dot(matTex2[1], rest),'),
    _src('bump-fog-lane', _VS, _IVS,
         'float4(worldTangent.x, worldBinormal.x, worldNormal.x, fog)',
         'float4(worldTangent.x, worldBinormal.x, worldNormal.x, worldNormal.x)'),
    _src('bump-fade-matrix', _VS, _IVS,
         'o.setTexcoord5(mul(matTex6, worldPos));', 'o.setTexcoord5(mul(matTex7, worldPos));'),
    _src('banner-uv1-range', _VS, _IVS,
         'o.setTexcoord1(float4(d3DecodeUv1(i.texcoord1Bits()), 0.0, 0.0));',
         'o.setTexcoord1(float4(d3DecodeUv0(i.texcoord1Bits()), 0.0, 0.0));'),
    _src('irradiance-normal-nan', _VS, _IVS,
         'b.irradianceNormal = normalize(mul(matWorldIrrad, float4(normal, 0.0)));',
         'b.irradianceNormal = normalize(mul(matWorldIrrad, float4(normal, 0.0)) * 0.0);', cls='nan'),
    dict(name='irradiance-vs-transport-width', root=_VS, kind='cfg', spec=C.widen_first_row(), cls='transport'),

    # --- actor_ps_main: ActorIrrad / banner --------------------------------------
    _src('alpha-test-nan-kept', _PS, 'interfaces/alpha_test.slang',
         'if ((alphaTestRef.w < alpha) == false) discard;', 'if (alpha <= alphaTestRef.w) discard;', cls='nan'),
    _src('irradiance-diffuse-nan', _PS, _IPS,
         'return diffuse.xyz * irradianceMap.Sample(irradianceMap_s, i.texcoord3().xyz).xyz * 2.0;',
         'return sqrt(diffuse.xyz - 0.5) * irradianceMap.Sample(irradianceMap_s, i.texcoord3().xyz).xyz * 2.0;',
         cls='nan'),
    _src('hero-tint-ramp-row', _PS, _IPS, 'float2(dye.x, tintRampUV.x)', 'float2(dye.x, tintRampUV.y)'),
    _src('coverage-band-bias', _PS, _IPS, 'ceil((coverage - 0.5) * 12.0)', 'ceil((coverage - 0.25) * 12.0)'),
    _src('premultiply-invert', _PS, _IPS, 'float4(color * opacity, 1.0 - opacity)', 'float4(color * opacity, opacity)'),
    _src('tint-mask-coverage', _PS, _IPS, 'return vertexAlpha * Factor.w;', 'return diffuse.w * vertexAlpha * Factor.w;'),
    _src('shadow-packed-depth-z', _PS, _IPS,
         'return d3ShadowTail(shadow, ndc.z) * i.color0().xyz;', 'return d3ShadowTail(shadow, proj.z) * i.color0().xyz;'),
    _src('shadow-soft-edge-fade', _PS, _IPS,
         'saturate((length(ndc.xy - 0.5) - 0.4) * 10.0)', 'saturate((length(ndc.xy - 0.5) - 0.3) * 10.0)'),
    _src('shadow-bilinear-weights', _PS, _IPS,
         'float4((1.0 - f.y) * f.x, (1.0 - f.x) * f.y,', 'float4((1.0 - f.x) * f.y, (1.0 - f.y) * f.x,'),
    _src('shadow-floor', _PS, _IPS, 'shadow = max(shadow, ShadowColor.x);', 'shadow = max(shadow, ShadowColor.y);'),
    _src('shadow-hardware-reference', _PS, _IPS,
         'shadowMap.SampleCmpLevelZero(shadowMap_cmp, proj.xy, proj.z)',
         'shadowMap.SampleCmpLevelZero(shadowMap_cmp, proj.xy, proj.z / proj.w)'),
    _src('edge-glow-alpha-scale', _PS, _IPS, 'edge * edgealphaParams.y', 'edge * edgealphaParams.x'),
    _src('detail-normal-uv', _PS, _IPS,
         'normalMap2.Sample(normalMap2_s, i.color1().xy)', 'normalMap2.Sample(normalMap2_s, i.texcoord5().xy)'),
    _src('dissolve-front-center', _PS, _IPS, 'dissolve.y - 1.0', 'dissolve.y - 0.5'),
    _src('pulverize-bias', _PS, _IPS, 'saturate(i.texcoord2().z + 0.5)', 'saturate(i.texcoord2().z + 0.25)'),
    _src('wipe-gate-uv', _PS, _IPS,
         'float4 gate = layer2DiffuseMap.Sample(layer2DiffuseMap_s, i.texcoord2().xy);',
         'float4 gate = layer2DiffuseMap.Sample(layer2DiffuseMap_s, i.texcoord1().xy);'),
    _src('elemental-rim-lane', _PS, _IPS,
         'color += hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().z);',
         'color += hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().y);'),
    _src('bloodgolem-overlay-threshold', _PS, _IPS,
         'select(tinted > 0.5, screen, multiply)', 'select(tinted > 0.4, screen, multiply)'),
    _src('animated-layer-scale', _PS, _IPS, 'color += layer * 2.0;', 'color += layer * 4.0;'),
    _src('banner-ramp-row', _PS, _IPS, 'float2(patternU, bannerTintRampUV.y)', 'float2(patternU, bannerTintRampUV.z)'),
    dict(name='irradiance-ps-tie-flip-lt', root=_PS, kind='cfg', spec=C.swap_specialize('DiscardLT', 'DiscardLE'),
         cls='tie'),
    dict(name='irradiance-ps-tie-flip-gt', root=_PS, kind='cfg', spec=C.swap_specialize('DiscardGT', 'DiscardGE'),
         cls='tie'),
    dict(name='irradiance-ps-register-shift', root=_PS, kind='cfg', spec=C.shift_first_texture(), cls='register'),
    dict(name='irradiance-ps-transport-width', root=_PS, kind='cfg', spec=C.widen_first_row(), cls='transport'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = [_PS]
SKINNED_ROOTS = [_VS]
