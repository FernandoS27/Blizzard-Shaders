"""Translators for the roots ported in workspace legacy_aux.

Registered with the same decorator as tools/d3_shaders_cfg.py; the helpers
(on, boolean, alpha_test, swap_specialize, widen_first_row, shift_first_texture)
come from there too.

legacy_aux_ps_main: the auxiliary pixel passes that pair with legacy-layout
vertex shaders. Every subfamily is one fixed computation (no pixel-side
feature define; Distortion's SLOWED only adds an interpolant, which the
measured transport already carries), so each translator names one pixel model.
"""

import d3_shaders_cfg as C
from d3_shaders_cfg import translator, on, boolean, alpha_test

_AUX_MODELS = {
    'Legacy.fx__ps_prepass': 'PrepassDepthOnly',
    'Legacy.fx__highlight_ps': 'HighlightSilhouette',
    'Legacy.fx__ps_erase_highlight': 'HighlightErase',
    'Legacy.fx__ps_highlight_text': 'HighlightText',
    'Legacy.fx__ps_projected_layer_pma': 'ProjectedLayerPremultiplied',
    'Distortion.fx__ps_distortion2tex': 'DistortionTwoLayer',
    'Scene.fx__ps_scene_opaque_glow': 'OpaqueGlow',
}


def _aux_translator(model):
    def translate(defines, measured):
        return 'legacy_aux_ps_main', [model, alpha_test(measured)]
    return translate


for _subfamily, _model in _AUX_MODELS.items():
    translator(_subfamily)(_aux_translator(_model))


_AUX = 'legacy_aux_ps_main'
_AUX_FILE = 'roots/legacy/legacy_aux_ps.slang'

#: gate D8 mutations for this workspace's roots, as dicts of d3_mutate.Mutation fields:
#:   dict(name=..., root=..., kind='src', file='roots/...slang', old=..., new=..., cls='nan')
#:   dict(name=..., root=..., kind='cfg', spec=C.widen_first_row(), cls='transport')
MUTATIONS = [
    dict(name='aux-transport-width', root=_AUX, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='aux-register-shift', root=_AUX, kind='cfg', spec=C.shift_first_texture(), cls='register'),
    dict(name='aux-tie-flip', root=_AUX, kind='cfg', spec=C.swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    dict(name='aux-nan-injection', root=_AUX, kind='src', file=_AUX_FILE,
         old='return float4(layer0.rgb + layer1.rgb - 0.5, i.color0().w);',
         new='return float4(layer0.rgb + sqrt(layer1.rgb - 0.5), i.color0().w);', cls='nan'),
    dict(name='aux-erase-cutoff', root=_AUX, kind='src', file=_AUX_FILE,
         old='clip(cutout - 0.5);', new='clip(cutout - 0.25);'),
    dict(name='aux-highlight-intensity', root=_AUX, kind='src', file=_AUX_FILE,
         old='cutout * i.color0().w * Factor.w', new='cutout * i.color0().w * Factor.z'),
    dict(name='aux-pma-fade-width', root=_AUX, kind='src', file=_AUX_FILE,
         old='float2 edge = saturate(box * 10.0);', new='float2 edge = saturate(box * 8.0);'),
    dict(name='aux-pma-mask-uv', root=_AUX, kind='src', file=_AUX_FILE,
         old='pmaMaskTex.Sample(pmaMaskTex_s, i.texcoord2().xy)', new='pmaMaskTex.Sample(pmaMaskTex_s, i.texcoord1().xy)'),
    dict(name='aux-glow-scale-axis', root=_AUX, kind='src', file=_AUX_FILE,
         old='.rgb * appearanceFX.x;', new='.rgb * appearanceFX.y;'),
    dict(name='aux-text-coverage', root=_AUX, kind='src', file=_AUX_FILE,
         old='return float4(tint.rgb, coverage * tint.a);', new='return float4(tint.rgb, coverage);'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = [_AUX]
SKINNED_ROOTS = []
