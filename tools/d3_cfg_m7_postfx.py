"""Translators for the roots ported in workspace m7_postfx.

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
_PS = 'postfx_ps_main'
_VS = 'postfx_vs_main'
_PS_FILE = 'roots/utility/postfx_ps.slang'
_TONEMAP_FILE = 'roots/utility/postfx_tonemap.slang'
_FXAA_FILE = 'roots/utility/postfx_fxaa.slang'
_MINIMAP_FILE = 'roots/utility/postfx_minimap.slang'
_VS_FILE = 'roots/utility/postfx_vs.slang'

MUTATIONS = [
    # postfx_ps_main
    dict(name='postfx-transport-width', root=_PS, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='postfx-register-shift', root=_PS, kind='cfg', spec=C.shift_first_texture(), cls='register'),
    dict(name='postfx-nan-injection', root=_PS, kind='src', file=_PS_FILE,
         old='return float4(bloom.rgb * 4.5 + frame.rgb, 1.0);',
         new='return float4(sqrt(bloom.rgb - 0.5) * 4.5 + frame.rgb, 1.0);', cls='nan'),
    dict(name='postfx-clamp-epsilon', root=_PS, kind='src', file=_PS_FILE,
         old='viewport.xz - 0.00001;', new='viewport.xz - 0.0001;'),
    dict(name='postfx-daltonize-spread', root=_PS, kind='src', file=_PS_FILE,
         old='float3 shift = float3(0.0, lost.r * 0.7 + lost.g, lost.r * 0.7 + lost.b);',
         new='float3 shift = float3(0.0, lost.r * 0.7 + lost.g, lost.r * 0.6 + lost.b);'),
    dict(name='postfx-dof-linearise', root=_PS, kind='src', file=_PS_FILE,
         old='(depth - cameraParams.y)', new='(depth + cameraParams.y)'),
    dict(name='postfx-lut-texel-centre', root=_PS, kind='src', file=_TONEMAP_FILE,
         old='float2 texel = color.rg * 63.0 + 0.5;', new='float2 texel = color.rg * 63.0 + 0.25;'),
    dict(name='postfx-grade-crossfade-axis', root=_PS, kind='src', file=_TONEMAP_FILE,
         old='return lerp(first, second, colorCorrectionBlend.x);',
         new='return lerp(first, second, colorCorrectionBlend.z);'),
    # (the 12-texel search step is not reachable by D4's texture models -- a retail
    # asm edit l(12.0)->l(8.0) stays `exact` against retail; fxaa_texel_check.py covers it)
    dict(name='postfx-fxaa-subpix-lowpass', root=_PS, kind='src', file=_FXAA_FILE,
         old='(subpixA * (1.0 / 12.0))', new='(subpixA * (1.0 / 10.0))'),
    dict(name='postfx-fxaa-early-exit-alpha', root=_PS, kind='src', file=_FXAA_FILE,
         old='        return rgbyM;', new='        return float4(rgbyM.rgb, 1.0);'),
    dict(name='postfx-lut-tile-rows', root=_PS, kind='src', file=_TONEMAP_FILE,
         old='floor(slice / 8.0)) / 8.0;', new='floor(slice / 4.0)) / 8.0;'),
    dict(name='postfx-fxaa-subpix', root=_PS, kind='src', file=_FXAA_FILE,
         old='static const float kFxaaSubpix = 0.75;', new='static const float kFxaaSubpix = 0.5;'),
    dict(name='postfx-minimap-debug-tint', root=_PS, kind='src', file=_MINIMAP_FILE,
         old='float green = map.g * explored.g * 0.3;', new='float green = map.g * explored.g * 0.25;'),
    # postfx_vs_main
    dict(name='postfx-vs-transport-width', root=_VS, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='postfx-vs-nan-injection', root=_VS, kind='src', file=_VS_FILE,
         old='o.setColor0(i.color0());', new='o.setColor0(sqrt(i.color0() - 0.5));', cls='nan'),
    dict(name='postfx-vs-kernel-offset', root=_VS, kind='src', file=_VS_FILE,
         old='base + Constant0.zw', new='base + Constant0.xy'),
    dict(name='postfx-vs-tex-matrix-rows', root=_VS, kind='src', file=_VS_FILE,
         old='d3TexTransform(matTex0[0], matTex0[1], base)', new='d3TexTransform(matTex0[1], matTex0[0], base)'),
    dict(name='postfx-vs-minimap-layer-uv', root=_VS, kind='src', file=_VS_FILE,
         old='mul(matTex1, i.texcoord1())', new='mul(matTex1, i.texcoord2())'),
    dict(name='postfx-vs-clip-space', root=_VS, kind='src', file=_VS_FILE,
         old='d3WriteClipPlanes(clipPos, o);', new='d3WriteClipPlanes(i.position(), o);'),
]

#: roots added by this workspace, and the bundle each belongs to
NEW_ROOTS = {'postfx_ps_main': 'ps_utility', 'postfx_vs_main': 'vs_utility'}

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = []
SKINNED_ROOTS = []
