"""Translators for the roots ported in workspace particle.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.

Roots: cookie_vs_main / cookie_ps_main (Shadows.fx) and particle_vs_main
(Billboard.fx, SoftBillboard.fx).
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test


# --------------------------------------------------------------------------
# cookie (Shadows.fx)
# --------------------------------------------------------------------------

@translator('Shadows.fx__vs_write_cookie')
def _cookie_vs(defines, measured):
    return 'cookie_vs_main', ['SkinSingleBone' if on(defines, 'SKIN') else 'SkinNone']


def _cookie_alpha(measured):
    """The caster alpha test. An opaque cookie's coverage is the literal 1, so
    retail's compare is against a literal; its spelling still names the test."""
    test = alpha_test(measured)
    if test != 'AlphaTestOff':
        return test
    lits = [c.replace('lit', 'a') for c in measured['alphaCompare'] if 'ref' in c]
    return C._ALPHA[lits[-1]] if lits else 'AlphaTestOff'


@translator('Shadows.fx__ps_write_cookie')
def _cookie_ps(defines, measured):
    key = 'KeyDiffuseAlpha' if on(defines, 'ALPHA_KEY') else 'KeyNone'
    kind = ('CookieColor' if on(defines, 'COLOR_COOKIE') else
            'CookieDepthMoments' if on(defines, 'DEPTH_COOKIE') else 'CookieOpaque')
    return 'cookie_ps_main', [key, kind, _cookie_alpha(measured)]


@translator('Shadows.fx__ps_write_cookie_banner')
def _cookie_banner_ps(defines, measured):
    key = 'KeyBannerPattern' if on(defines, 'BANNER_MAP') else 'KeyNone'
    kind = ('CookieColor' if on(defines, 'COLORED') else
            'CookieDepthMoments' if on(defines, 'BANNER_MAP') else 'CookieOpaque')
    return 'cookie_ps_main', [key, kind, _cookie_alpha(measured)]


# --------------------------------------------------------------------------
# particle billboards (Billboard.fx, SoftBillboard.fx)
# --------------------------------------------------------------------------

def _texcoord_semantics(measured):
    """Semantic indices of the TEXCOORD interpolants, in register order. The
    k-th texture stage of a particle pass writes the k-th of them; retail does
    not number them by stage."""
    return [row[1] for row in measured['transport'] if row[0] == 'TEXCOORD']


def _lit(combine):
    return 'ColorLit<%s>' % combine


@translator('Billboard.fx__vs_legacy')
def _billboard_vs(defines, measured):
    if on(defines, 'LIT'):
        color = _lit(['LitModulate', 'LitReplace', 'LitClutter'][int(defines.get('LIT_COMBINE', 0))])
    elif on(defines, 'EDGE_ALPHA'):
        color = 'ColorEdgeAlpha'
    elif on(defines, 'AMBIENT_BLEND'):
        color = 'ColorAmbientBlend'
    elif on(defines, 'COLOR0_SQUARE'):
        color = 'ColorSquared'
    else:
        color = 'ColorPassthrough'
    count = int(defines.get('NUM_TEXCOORDS', 1))
    sems = _texcoord_semantics(measured)
    assert len(sems) == count, (defines, sems)
    stages = []
    for k in range(4):
        if k >= count:
            stages.append('TexcoordUnused')
            continue
        uv = int(defines.get('TC%d_UV' % k, k))
        if int(defines.get('TC%d_MODE' % k, 0)) == 1:
            stages.append('TexcoordRaw<%d, %d>' % (sems[k], uv))
        else:
            stages.append('TexcoordMatrix<%d, %d, %d>' % (sems[k], uv, int(defines.get('TC%d_MAT' % k, k))))
    return 'particle_vs_main', [color] + stages


@translator('SoftBillboard.fx__vs_legacy')
def _soft_billboard_vs(defines, measured):
    if on(defines, 'LIT'):
        color = _lit('LitModulate' if on(defines, 'LIT_MODULATE_COLOR') else 'LitReplace')
    else:
        color = 'ColorPassthrough'
    sems = _texcoord_semantics(measured)
    assert len(sems) == 3, (defines, sems)
    second = ('TexcoordMatrix<%d, %d, 1>' % (sems[1], 0 if on(defines, 'SECOND_UV_FROM_UV0') else 1)
              if on(defines, 'SECOND_UV') else 'TexcoordUnused')
    return 'particle_vs_main', [color, 'TexcoordMatrix<%d, 0, 0>' % sems[0], second,
                                'TexcoordViewDepth<%d>' % sems[2], 'TexcoordUnused']


# --------------------------------------------------------------------------
# gate D8
# --------------------------------------------------------------------------

def narrow_first_row():
    """A spec edit shrinking the first float4 non-system interpolant to float3.
    The cookie transports are float4 throughout, so widen_first_row has nothing
    to act on there."""
    from dataclasses import replace

    def edit(spec):
        d = list(spec.defines)
        for i, x in enumerate(d):
            if x.startswith('D3_IO_') and x.endswith('_TYPE=float4'):
                sem = [y for y in d if y.startswith(x.split('_TYPE=')[0] + '_SEM=')]
                if sem and not sem[0].split('=')[1].startswith('SV_'):
                    d[i] = x[:-1] + '3'
                    return replace(spec, defines=tuple(d))
        return None
    return edit


_COOKIE = 'roots/utility/cookie.slang'
_PARTICLE = 'roots/legacy/particle_vs.slang'


def _src(name, root, file, old, new, cls=''):
    return dict(name=name, root=root, kind='src', file=file, old=old, new=new, cls=cls)


MUTATIONS = [
    # --- cookie_vs -------------------------------------------------------------
    _src('cookie-bone-index', 'cookie_vs_main', 'interfaces/skinning_single.slang',
         'uint bone = i.blendIndicesBits().x;', 'uint bone = i.blendIndicesBits().y;', cls='bone'),
    _src('cookie-bone-rows', 'cookie_vs_main', 'interfaces/skinning_single.slang',
         'v.position = float4(dot(matBones[bone].row0, position), dot(matBones[bone].row1, position),',
         'v.position = float4(dot(matBones[bone].row1, position), dot(matBones[bone].row0, position),'),
    _src('cookie-projective-bias', 'cookie_vs_main', _COOKIE,
         '(clipPos.xy + clipPos.w) * 0.5', '(clipPos.xy - clipPos.w) * 0.5'),
    _src('cookie-factor-channel', 'cookie_vs_main', _COOKIE, 'Factor.wwww', 'Factor.xxxx'),
    _src('cookie-tex-matrix', 'cookie_vs_main', _COOKIE,
         'd3TextureMatrixTransform(0, ', 'd3TextureMatrixTransform(1, '),
    _src('cookie-tex-matrix-rows', 'cookie_vs_main', 'math/tex_matrix.slang',
         'dot(d3TextureMatrixRow(index, 2).xyw, h), dot(d3TextureMatrixRow(index, 3).xyw, h)',
         'dot(d3TextureMatrixRow(index, 3).xyw, h), dot(d3TextureMatrixRow(index, 2).xyw, h)'),
    dict(name='cookie-vs-transport-narrow', root='cookie_vs_main', kind='cfg',
         spec=narrow_first_row(), cls='transport'),
    # --- cookie_ps -------------------------------------------------------------
    _src('cookie-key-threshold', 'cookie_ps_main', _COOKIE,
         'i.texcoord0().xy).a >= 0.5', 'i.texcoord0().xy).a >= 0.25'),
    _src('cookie-banner-channel', 'cookie_ps_main', _COOKIE,
         'i.texcoord0().xy).b >= 0.5', 'i.texcoord0().xy).g >= 0.5'),
    _src('cookie-vignette-channel', 'cookie_ps_main', _COOKIE,
         'projected.xy / projected.w).w', 'projected.xy / projected.w).x'),
    _src('cookie-moment-constant', 'cookie_ps_main', _COOKIE,
         'float4(depth, depth * depth, 1.0,', 'float4(depth, depth * depth, 0.5,'),
    _src('cookie-ps-nan-injection', 'cookie_ps_main', _COOKIE,
         'float depth = projected.z / projected.w;', 'float depth = sqrt(projected.z) / projected.w;',
         cls='nan'),
    dict(name='cookie-tie-flip', root='cookie_ps_main', kind='cfg',
         spec=C.swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    dict(name='cookie-register-shift', root='cookie_ps_main', kind='cfg',
         spec=C.shift_first_texture(), cls='register'),
    dict(name='cookie-ps-transport-narrow', root='cookie_ps_main', kind='cfg',
         spec=narrow_first_row(), cls='transport'),
    # --- particle_vs -------------------------------------------------------------
    _src('particle-rotate-cross-order', 'particle_vs_main', _PARTICLE,
         '(dot(q.xyz, p) * q.xyz + cross(q.xyz, t))', '(dot(q.xyz, p) * q.xyz + cross(t, q.xyz))'),
    _src('particle-spin-direction', 'particle_vs_main', _PARTICLE,
         'float halfSpin = center.w * -0.5;', 'float halfSpin = center.w * 0.5;'),
    _src('particle-quat-byte-scale', 'particle_vs_main', _PARTICLE,
         'float4(i.texcoord4Bits()) * (2.0 / 255.0) - 1.0', 'float4(i.texcoord4Bits()) * (2.0 / 256.0) - 1.0'),
    _src('particle-orientation-flag', 'particle_vs_main', _PARTICLE,
         'billboardParams.y > 0.0 ? packedRotation', 'billboardParams.x > 0.0 ? packedRotation'),
    _src('particle-fold-sign', 'particle_vs_main', _PARTICLE,
         'abs(corner.y) + corner.y', 'abs(corner.y) - corner.y'),
    _src('particle-normal-unit-form', 'particle_vs_main', _PARTICLE,
         '1.0 - 2.0 * (q.x * q.x + q.y * q.y)', '1.0 - 2.0 * (q.x * q.x + q.z * q.z)'),
    _src('particle-rim-sharpness', 'particle_vs_main', _PARTICLE,
         '2.0 * edgealphaParams.x', 'edgealphaParams.x'),
    _src('particle-clutter-mask', 'particle_vs_main', _PARTICLE,
         'light.diffuse * vertexColor.x * vertexColor.y', 'light.diffuse * vertexColor.x * vertexColor.z'),
    _src('particle-raw-texcoord-w', 'particle_vs_main', _PARTICLE,
         'float4(d3ParticleUv(i, UV), 0.0, 1.0)', 'float4(d3ParticleUv(i, UV), 1.0, 0.0)'),
    _src('particle-view-depth-sign', 'particle_vs_main', _PARTICLE,
         '-dot(matWorldView[2], p.worldPos)', 'dot(matWorldView[2], p.worldPos)'),
    _src('particle-tex-matrix-rows', 'particle_vs_main', 'math/tex_matrix.slang',
         'dot(d3TextureMatrixRow(index, 2).xyw, h), dot(d3TextureMatrixRow(index, 3).xyw, h)',
         'dot(d3TextureMatrixRow(index, 3).xyw, h), dot(d3TextureMatrixRow(index, 2).xyw, h)'),
    _src('particle-vs-nan-injection', 'particle_vs_main', _PARTICLE,
         'pow(saturate(dot(-toVertex, viewNormal)), ', 'pow(dot(-toVertex, viewNormal), ', cls='nan'),
    dict(name='particle-lit-combine', root='particle_vs_main', kind='cfg',
         spec=C.swap_specialize('ColorLit<LitModulate>', 'ColorLit<LitReplace>')),
    dict(name='particle-transport-width', root='particle_vs_main', kind='cfg',
         spec=C.widen_first_row(), cls='transport'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = ['cookie_ps_main']
SKINNED_ROOTS = ['cookie_vs_main']
