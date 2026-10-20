"""Translators for the roots ported in workspace m7_actor.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.

Plan M7 residue (actor): the 55 programs of this workspace are placed as data
in d3_residue.json -- no translator is needed. They land in existing roots
(actor_ps_main, actor_vs_main, combiner_ps_main, texgen_vs_main) through new
implementers in roots/actor/effects_ps.slang, roots/actor/effects_vs.slang and
interfaces/combiner_actor_roles.slang, with their texture roles declared in
types/textures_actor.slang. The mutations below exercise that new code.
"""

from dataclasses import replace

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test  # noqa: F401

_VS = 'actor_vs_main'
_PS = 'actor_ps_main'
_COMBINER = 'combiner_ps_main'
_EPS = 'roots/actor/effects_ps.slang'
_EVS = 'roots/actor/effects_vs.slang'
_ROLES = 'interfaces/combiner_actor_roles.slang'


def _src(name, root, file, old, new, cls=''):
    return dict(name=name, root=root, kind='src', file=file, old=old, new=new, cls=cls)


def _swap_inner(old: str, new: str):
    """A spec edit replacing text inside one specialization argument (a policy
    nested in a model, e.g. the ghost's own alpha test)."""
    def edit(spec):
        if not any(old in s for s in spec.specialize):
            return None
        return replace(spec, specialize=tuple(s.replace(old, new) for s in spec.specialize))
    return edit


#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields:
#:   dict(name=..., root=..., kind='src', file='roots/...slang', old=..., new=..., cls='nan')
#:   dict(name=..., root=..., kind='cfg', spec=C.widen_first_row(), cls='transport')
MUTATIONS = [
    # --- actor_ps_main: the one-off effect models --------------------------------
    _src('banner-highlight-coverage', _PS, _EPS,
         'return float4(Factor.xyz, background.z * i.color0().w);',
         'return float4(Factor.xyz, background.y * i.color0().w);'),
    _src('glow-pass-clamp', _PS, _EPS,
         'saturate(i.color0().xyz * diffuse.xyz + glow)', '(i.color0().xyz * diffuse.xyz + glow)'),
    _src('cloak-grey-bias', _PS, _EPS,
         '(packed * appearanceFX.x - 0.5) * coverage + 0.5', '(packed * appearanceFX.x - 0.25) * coverage + 0.5'),
    _src('ghost-dissipation-channel', _PS, _EPS,
         'dissipationMap.Sample(dissipationMap_s, d3UnitTexcoord(i, UNIT)).w',
         'dissipationMap.Sample(dissipationMap_s, d3UnitTexcoord(i, UNIT)).x'),
    _src('ghost-mask-uv', _PS, _EPS,
         'alpha2Map.Sample(alpha2Map_s, i.texcoord2().xy).w', 'alpha2Map.Sample(alpha2Map_s, i.texcoord1().xy).w'),
    _src('ghost-shell-discard', _PS, _EPS,
         'if (diffuse.w * appearanceFX.x == 0.0)', 'if (diffuse.w * appearanceFX.x < 0.0)'),
    _src('ghost-test-after-fade', _PS, _EPS, 'TTest.apply(coverage);', 'TTest.apply(coverage * appearanceFX.x);'),
    _src('charred-burn-mean', _PS, _EPS, 'burn * 0.5, diffuse.w', 'burn * 0.25, diffuse.w'),
    _src('animated-mask-channel', _PS, _EPS,
         'animatedMap.Sample(animatedMap_s, i.texcoord1().xy).w', 'animatedMap.Sample(animatedMap_s, i.texcoord1().xy).x'),
    _src('elemental-layer-gain', _PS, _EPS,
         'LAYER_2X ? layer.xyz * 2.0 : layer.xyz', 'LAYER_2X ? layer.xyz * 4.0 : layer.xyz'),
    _src('tornado-swirl-boost', _PS, _EPS, 'saturate(swirl * Factor.w * 4.0)', 'saturate(swirl * Factor.w * 2.0)'),
    _src('revive-ramp-row', _PS, _EPS,
         'float2(rampU, i.texcoord2().y)', 'float2(rampU, i.texcoord2().x)'),
    _src('health-orb-rim-lane', _PS, _EPS,
         'hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().z) + color',
         'hitFlashColorAdd.xyz * d3HitFlashRim(i.texcoord4().y) + color'),
    _src('glow-overlay-fog-lane', _PS, _EPS,
         'd3ApplyFog(color, i.texcoord7().z), coverage)', 'd3ApplyFog(color, i.texcoord7().y), coverage)'),
    _src('stone-facing-abs', _PS, _EPS, 'lerp(lit * 2.0, stone, abs(facing))', 'lerp(lit * 2.0, stone, facing)'),
    _src('crystal-viewport-clamp', _PS, _EPS,
         'float2 limit = (viewport.yw + viewport.xz) - 0.00001;', 'float2 limit = (viewport.yw + viewport.xz) - 0.001;'),
    _src('crystal-refraction-nan', _PS, _EPS,
         'float2 screen = (clip.xy / clip.z) * float2(0.5, -0.5)',
         'float2 screen = (clip.xy / sqrt(clip.z - 0.5)) * float2(0.5, -0.5)', cls='nan'),
    dict(name='ghost-inner-tie-flip', root=_PS, kind='cfg',
         spec=_swap_inner('GhostIrradiancePixel<DiscardLE', 'GhostIrradiancePixel<DiscardLT'), cls='tie'),

    # --- actor_vs_main: the one-off effect policies and models --------------------
    _src('uv-layer-matrix-row', _VS, _EVS,
         'd3TextureMatrixRow(index, 0), d3TextureMatrixRow(index, 1), uv',
         'd3TextureMatrixRow(index, 0), d3TextureMatrixRow(index, 2), uv'),
    _src('uv-layer-pair-rows', _VS, _EVS,
         'd3TextureMatrixTransform(MAT2, uv0).xyz', 'd3TextureMatrixTransform(MAT2, uv0).xyw'),
    _src('rest-projection-mirror', _VS, _EVS, 'float4 mirrored = float4(-rest, 1.0);', 'float4 mirrored = float4(rest, 1.0);'),
    _src('revive-gate-lift', _VS, _EVS, 'gate + float2(0.0, 0.8)', 'gate + float2(0.0, 0.6)'),
    _src('revive-ramp-translation', _VS, _EVS, 'matTex3[0].w, matTex3[1].w, gate', 'matTex3[0].w, matTex3[0].w, gate'),
    _src('vertex-tint-above-ambient', _VS, _EVS,
         '* i.color0().xyz - l.ambient;', '* i.color0().xyz;'),
    _src('glow-overlay-normal-frame', _VS, _EVS,
         'o.setTexcoord3(normalize(mul(matWorld, float4(v.normal, 0.0))));',
         'o.setTexcoord3(normalize(mul(matWorldIrrad, float4(v.normal, 0.0))));'),
    _src('swirl-uv1-set', _VS, _EVS,
         'o.setTexcoord3(float4(d3TexTransform(matTex3[0], matTex3[1], uv1), 0.0, 0.0));',
         'o.setTexcoord3(float4(d3TexTransform(matTex3[0], matTex3[1], uv0), 0.0, 0.0));'),
    _src('unlit-split-alpha-scale', _VS, _EVS,
         'o.setColor0(color * float4(0.5, 0.5, 0.5, 1.0));', 'o.setColor0(color * 0.5);'),
    _src('normal-frame-w-lane', _VS, _EVS,
         'o.setTexcoord2(float4(0.0, 0.0, worldNormal.x, worldNormal.x));',
         'o.setTexcoord2(float4(0.0, 0.0, worldNormal.x, 0.0));'),
    _src('swirl-irradiance-nan', _VS, _EVS,
         'o.setTexcoord4(normalize(mul(matWorldIrrad, float4(v.normal, 0.0))));',
         'o.setTexcoord4(normalize(mul(matWorldIrrad, float4(v.normal, 0.0)) * 0.0));', cls='nan'),

    # --- combiner_ps_main: the actor texture roles --------------------------------
    _src('actor-role-gloss-glow', _COMBINER, 'interfaces/combiner_roles.slang',
         'return texGloss.Sample(texGloss_s, uv);', 'return texGlow.Sample(texGlow_s, uv);'),
    _src('actor-role-flow0-uv', _COMBINER, _ROLES,
         'return flowSampler0.Sample(flowSampler0_s, uv);', 'return flowSampler0.Sample(flowSampler0_s, uv.yx);'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = []
