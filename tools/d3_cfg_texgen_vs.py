"""Translators for the legacy texgen vertex root (``texgen_vs_main``).

Seven subfamilies compile to this root: Legacy.fx vs_legacy (the fixed-function
emulation, described by NT + Tn_MODE/MAT/UV/SCALE and the colour flags) and the
single-purpose entries that are the same shader with a fixed recipe
(Distortion/Scene/PostFX vs_legacy, Legacy vs_legacy_weather, vs_prepass,
vs_projected_layer_pma). Every translator builds the one canonical spec

    texgen_vs_main<Pose, UvSource, Rgb, Alpha, TexGenSet<stage0..stage6>>

so a program shared between subfamilies gets one spec whatever its spelling.

Texgen modes 3 (fog), 7 (clip z) and 8 (fog + clip z) are not stages: fog and
near-fade depth are the FOG0 / TEXCOORD6 interpolants, written by the root when
the slot's measured layout declares them. Generator k writes the k-th texture
interpolant of the measured layout (TEXCOORD6 excluded), which is how programs
whose layout skips TEXCOORD indices are reproduced.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean

ROOT = 'texgen_vs_main'
STAGES = 7

#: texgen modes carried by interpolants of their own rather than a stage, with
#: the interpolant each needs the layout to declare
_TRANSPORT_MODES = {3: [('FOG', 0)], 7: [('TEXCOORD', 6)], 8: [('FOG', 0), ('TEXCOORD', 6)]}


def _targets(measured):
    """TEXCOORD indices a generator can feed, in declaration order."""
    return [idx for sem, idx, *_ in measured['transport'] if sem == 'TEXCOORD' and idx != 6]


def _declares(measured, sem, idx):
    return any((s, i) == (sem, idx) for s, i, *_ in measured['transport'])


def _uv_source(defines, measured):
    if on(defines, 'FLOAT_UV'):
        return 'FloatUv'
    if on(defines, 'UV_PLAIN'):
        return 'IntegerUv'
    return 'PackedUv'


def _spec(measured, pose, uv, rgb, alpha, gens):
    targets = _targets(measured)
    if len(targets) != len(gens):
        raise ValueError('%d generators for texture interpolants %s' % (len(gens), targets))
    stages = ['TexStage<%d, %s>' % (tc, g) for tc, g in zip(targets, gens)]
    stages += ['TexStageNone'] * (STAGES - len(stages))
    return ROOT, [pose, uv, rgb, alpha, 'TexGenSet<%s>' % ', '.join(stages)]


def _edge(sat=True, minimum=False, onex=False, expsat=False):
    return 'AlphaEdge<%s, %s, %s, %s>' % tuple(boolean(x) for x in (sat, minimum, onex, expsat))


def _lit(vcadd=False):
    return 'RgbLit<%s>' % boolean(vcadd)


def _matrix(mat, uv=0, scale=0):
    return 'TexGenMatrix<%d, %d, %d>' % (mat, uv, scale)


# --------------------------------------------------------------------------
# Legacy.fx vs_legacy
# --------------------------------------------------------------------------

def _legacy_generator(mode, mat, uv, scale):
    if mode == 0:
        return _matrix(mat, uv, scale)
    if mode == 1:
        return 'TexGenPassthrough<%d, %d>' % (uv, scale)
    if mode == 2:
        return 'TexGenSphereMap'
    if mode == 4:
        return 'TexGenEyeLinear<%d>' % mat
    if mode == 5:
        return 'TexGenCameraPlane<%d>' % mat
    raise ValueError('texgen mode %d' % mode)


@translator('Legacy.fx__vs_legacy')
def _vs_legacy(defines, measured):
    num = lambda name, default=0: int(defines.get(name, default))
    gens = []
    for k in range(num('NT')):
        mode = num('T%d_MODE' % k)
        if mode in _TRANSPORT_MODES:
            missing = [r for r in _TRANSPORT_MODES[mode] if not _declares(measured, *r)]
            if missing:
                raise ValueError('texgen mode %d but the layout lacks %s' % (mode, missing))
            continue
        gens.append(_legacy_generator(mode, num('T%d_MAT' % k), num('T%d_UV' % k), num('T%d_SCALE' % k)))

    if on(defines, 'SKINNED'):
        pose = 'PoseOneBone' if on(defines, 'SKIN_RIGID') else 'PoseThreeBones'
    else:
        pose = 'PoseStatic'
    rgb = _lit(on(defines, 'VCADD')) if on(defines, 'LIT') else 'RgbVertex'
    if on(defines, 'AMBBLEND'):
        rgb = 'RgbAmbientBlend<%s>' % rgb
    if on(defines, 'COLOR0_A'):
        alpha = _edge(num('EDGE_SAT', 1) != 0, on(defines, 'EDGE_MIN'), on(defines, 'EDGE_ONEX'),
                      on(defines, 'EDGE_EXPSAT'))
    else:
        alpha = 'AlphaVertex'
    return _spec(measured, pose, _uv_source(defines, measured), rgb, alpha, gens)


# --------------------------------------------------------------------------
# fixed recipes
# --------------------------------------------------------------------------

@translator('Distortion.fx__vs_legacy')
def _distortion(defines, measured):
    gens = [_matrix(0), _matrix(1)]
    if on(defines, 'SECOND_UV_LAYER'):
        gens.append(_matrix(3, uv=1))
    return _spec(measured, 'PoseStatic', 'PackedUv', _lit(),
                 _edge(onex=on(defines, 'INVERSE_EDGE_ALPHA')), gens)


@translator('Scene.fx__vs_legacy')
def _scene(defines, measured):
    if on(defines, 'LIGHTING'):
        rgb = _lit(on(defines, 'VERTEX_COLOR'))
    elif on(defines, 'VERTEX_COLOR'):
        rgb = 'RgbVertex'
    else:
        raise ValueError('Scene vs_legacy without a colour source')
    gens = [_matrix(0)] + ([_matrix(1)] if on(defines, 'SECOND_UV') else [])
    return _spec(measured, 'PoseStatic', 'PackedUv', rgb, 'AlphaVertex', gens)


@translator('PostFX.fx__vs_legacy')
def _postfx(defines, measured):
    gens = [_matrix(0), _matrix(1), _matrix(2), _matrix(3, uv=1 if on(defines, 'SECOND_UV') else 0)]
    return _spec(measured, 'PoseStatic', 'PackedUv', 'RgbVertex', 'AlphaVertex', gens)


@translator('Legacy.fx__vs_legacy_weather')
def _weather(defines, measured):
    rgb = _lit() if on(defines, 'VERTEX_LIGHTING') else 'RgbVertex'
    alpha = 'AlphaWeather<%s>' % (_edge() if on(defines, 'EDGE_ALPHA') else 'AlphaVertex')
    layout = int(defines.get('UV_LAYOUT', 0))
    gens = [_matrix(0)]
    if layout >= 1:
        flow = 'TexGenPassthrough<1, 1>' if layout == 2 else _matrix(2)
        gens += [_matrix(1), flow, _matrix(3)]
    return _spec(measured, 'PoseStatic', 'PackedUv', rgb, alpha, gens)


@translator('Legacy.fx__vs_prepass')
def _prepass(defines, measured):
    pose = 'PoseThreeBones' if on(defines, 'SKINNED') else 'PoseStatic'
    return _spec(measured, pose, 'PackedUv', 'RgbVertex', 'AlphaVertex', [])


@translator('Legacy.fx__vs_projected_layer_pma')
def _projected_layer(defines, measured):
    pose = 'PoseWeatherSway' if on(defines, 'WEATHER_DEFORM') else 'PoseStatic'
    gens = ['TexGenEyeLinearFog<0>', _matrix(1), _matrix(2)]
    return _spec(measured, pose, 'PackedUv', 'RgbVertex', 'AlphaVertex', gens)


# --------------------------------------------------------------------------
# gate D8
# --------------------------------------------------------------------------

def _swap_first_two_stage_targets():
    """A spec edit exchanging the interpolants the first two generators feed."""
    import re
    from dataclasses import replace

    def edit(spec):
        if spec.entry != ROOT:
            return None
        *head, tex = spec.specialize
        targets = re.findall(r'TexStage<(\d+), ', tex)
        if len(targets) < 2:
            return None
        swapped = iter([targets[1], targets[0]] + targets[2:])
        tex = re.sub(r'TexStage<(\d+), ', lambda m: 'TexStage<%s, ' % next(swapped), tex)
        return replace(spec, specialize=tuple(head) + (tex,))
    return edit


_TG = 'roots/legacy/texgen.slang'
_VS = 'roots/legacy/texgen_vs.slang'


def _src(name, file, old, new, cls=''):
    return dict(name=name, root=ROOT, kind='src', file=file, old=old, new=new, cls=cls)


#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields
MUTATIONS = [
    dict(name='texgen-transport-width', root=ROOT, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='texgen-stage-targets', root=ROOT, kind='cfg', spec=_swap_first_two_stage_targets(),
         cls='transport'),
    _src('texgen-bone-order-swap', _VS,
         'float4 row0 = matBones[bones.x].row0 * weights.x + matBones[bones.y].row0 * weights.y',
         'float4 row0 = matBones[bones.x].row0 * weights.y + matBones[bones.y].row0 * weights.x', cls='bone'),
    _src('texgen-rigid-bone-channel', _VS, 'uint bone = i.blendIndicesBits().x;',
         'uint bone = i.blendIndicesBits().y;', cls='bone'),
    _src('texgen-expsat-nan', _VS, 'edge = d3SaturateExact(edge);',
         'edge = saturate(edge);', cls='nan'),
    _src('texgen-normal-decode', _VS, '* (2.0 / 255.0) - 1.0;', '* (2.0 / 256.0) - 1.0;'),
    _src('texgen-uv-range-select', _TG, 'return d3DecodeUv1(bits);', 'return d3DecodeUv0(bits);'),
    _src('texgen-integer-uv-channel', _TG, 'return float2(float(bits.x), float(bits.y));',
         'return float2(float(bits.x), float(bits.z));'),
    _src('texgen-float-uv-channel', _TG, 'return i.texcoord1().xy;', 'return i.texcoord2().xy;'),
    _src('texgen-passthrough-w', _TG, 'return float4(TUv.uv(i, UV, SCALE), 0.0, 1.0);',
         'return float4(TUv.uv(i, UV, SCALE), 0.0, 0.0);'),
    _src('texgen-spheremap-axis', _TG, 'return float4(0.5 - 0.5 * v.normal.x,',
         'return float4(0.5 - 0.5 * v.normal.z,'),
    _src('texgen-camera-plane-axis', _TG, 'dot(matView[1].xyz, v.world)', 'dot(matView[2].xyz, v.world)'),
    _src('texgen-eye-linear-fog', _TG, 'v.fog, 0.0);', 'v.clip.z, 0.0);'),
    _src('texgen-near-fade-depth', _VS, 'o.setTexcoord6(float4(v.clip.z,', 'o.setTexcoord6(float4(v.clip.w,'),
    _src('texgen-ambient-blend-weight', _VS, 'T.rgb(i, v), i.color0().w);', 'T.rgb(i, v), i.color1().w);'),
    _src('texgen-vcadd-source', _VS, 'rgb = rgb + i.color0().rgb;', 'rgb = rgb + i.color1().rgb;'),
    _src('texgen-edge-min-clamp', _VS, 'edge = min(edge, 1.0);', 'edge = min(edge, 0.75);'),
    _src('texgen-edge-sat-dropped', _VS, 'facing = saturate(facing);', 'facing = abs(facing);'),
    _src('texgen-weather-intensity', _VS, 'return T.alpha(i, v) * weatherIntensity.x;',
         'return T.alpha(i, v) * weatherIntensity.y;'),
    _src('texgen-sway-phase', _VS, 'randFloat.w + randFloat.y', 'randFloat.w + randFloat.x'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = [ROOT]
