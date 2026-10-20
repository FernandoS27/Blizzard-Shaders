"""Gate data for the roots ported in workspace m7_filter.

The residue programs placed here (TextureFilter.fx passes, the untitled
resolve/blur passes and Shadows.fx vs_write_cookie_vertalpha) have no
translators: each is placed by program in d3_residue.json (written by place.py
beside this file). This file declares the new roots and their D8 mutations.
"""

import d3_shaders_cfg as C

#: residue roots introduced in this workspace, by bundle
NEW_ROOTS = {
    'texfilter_vs_main': 'vs_utility',
    'cookie_tint_vs_main': 'vs_utility',
    'texfilter_ps_main': 'ps_utility',
    'texdepth_ps_main': 'ps_utility',
}


# --------------------------------------------------------------------------
# gate D8
# --------------------------------------------------------------------------

def _narrow_first_row():
    """A spec edit shrinking the first float4 non-system interpolant to float3
    (the cookie caster's transport is float4 throughout, so widen_first_row has
    nothing to act on)."""
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


def _src(name, root, file, old, new, cls=''):
    return dict(name=name, root=root, kind='src', file=file, old=old, new=new, cls=cls)


def _cfg(name, root, spec, cls=''):
    return dict(name=name, root=root, kind='cfg', spec=spec, cls=cls)


_PS = 'roots/utility/texfilter_ps.slang'
_COPY = 'roots/utility/texfilter_copy.slang'
_BLUR = 'roots/utility/texfilter_blur.slang'
_SCENE = 'roots/utility/texfilter_scene.slang'
_DEPTH = 'roots/utility/texfilter_depth.slang'
_VS = 'roots/utility/texfilter_vs.slang'
_TINT = 'roots/utility/cookie_tint.slang'

MUTATIONS = [
    # --- texfilter_ps ------------------------------------------------------------
    _src('texfilter-viewport-edge', 'texfilter_ps_main', _PS,
         'return viewport.yw + viewport.xz + -0.00001;', 'return viewport.yw + viewport.xz + -0.001;'),
    _src('texfilter-gaussian-weights', 'texfilter_ps_main', _BLUR,
         '{ 0.0481169038, 0.0599573553,', '{ 0.0599573553, 0.0481169038,'),
    _src('texfilter-glow-center-weight', 'texfilter_ps_main', _BLUR,
         'kGlowCenterWeight = 0.380853;', 'kGlowCenterWeight = 0.38;'),
    _src('texfilter-highlight-threshold', 'texfilter_ps_main', _BLUR,
         'kHighlightSolid = 0.125;', 'kHighlightSolid = 0.25;'),
    _src('texfilter-bloom-luma', 'texfilter_ps_main', _COPY,
         'float3(0.222, 0.707, 0.071)', 'float3(0.707, 0.222, 0.071)'),
    _src('texfilter-copy-alpha-channel', 'texfilter_ps_main', _COPY,
         'float alpha = texSampler0.Sample(texSampler0_s, i.texcoord0().xy).w;',
         'float alpha = texSampler0.Sample(texSampler0_s, i.texcoord0().xy).x;'),
    _src('texfilter-ssao-reflect-order', 'texfilter_ps_main', _SCENE,
         'reflect(kSsaoKernel[k].yzw, random)', 'reflect(random, kSsaoKernel[k].yzw)'),
    _src('texfilter-retro-dither-cell', 'texfilter_ps_main', _SCENE,
         'cell.x * 9 + cell.y * 3 + cell.z', 'cell.y * 9 + cell.x * 3 + cell.z'),
    _src('texfilter-normal-nan-injection', 'texfilter_ps_main', _SCENE,
         'return float3(xy, 1.0 - sqrt(dot(xy, xy)));', 'return float3(xy, 1.0 - sqrt(dot(xy, xy) - 0.5));',
         cls='nan'),
    _cfg('texfilter-tie-flip', 'texfilter_ps_main', C.swap_specialize('DiscardLE', 'DiscardLT'), cls='tie'),
    _cfg('texfilter-register-shift', 'texfilter_ps_main', C.shift_first_texture(), cls='register'),
    _cfg('texfilter-transport-width', 'texfilter_ps_main', C.widen_first_row(), cls='transport'),
    # --- texdepth_ps -------------------------------------------------------------
    # D4 does not compare SV_Depth and D2 does not see a multisampled texture's
    # sample count (see depth_check.py), so what these gates can catch in this
    # root is its declarations and the resolve's colour; the depth itself is
    # guarded by DEPTH_MUTATIONS below.
    _src('texdepth-clear-alpha', 'texdepth_ps_main', _DEPTH,
         'o.color = float4(0.0, 0.0, 0.0, 0.0);', 'o.color = float4(0.0, 0.0, 0.0, 1.0);'),
    _src('texdepth-clear-nan-injection', 'texdepth_ps_main', _DEPTH,
         'o.color = float4(0.0, 0.0, 0.0, 0.0);', 'o.color = float4(0.0, 0.0, 0.0, sqrt(depth - 0.5));',
         cls='nan'),
    _src('texdepth-sampled-as-load', 'texdepth_ps_main', _DEPTH,
         'return texDepth.Sample(texDepth_s, uv).x; }', 'return texDepth.Load(int3(uv, 0)).x; }'),
    _cfg('texdepth-target-kind', 'texdepth_ps_main', C.swap_specialize('TargetDepthClearColor', 'TargetDepth')),
    _cfg('texdepth-register-shift', 'texdepth_ps_main', C.shift_first_texture(), cls='register'),
    _cfg('texdepth-transport-width', 'texdepth_ps_main', C.widen_first_row(), cls='transport'),
    # --- texfilter_vs ------------------------------------------------------------
    _src('texfilter-vs-far-plane', 'texfilter_vs_main', _VS,
         'return float4(projected.xy, 1.0, 1.0);', 'return float4(projected.xy, 0.0, 1.0);'),
    _src('texfilter-vs-homogeneous-w', 'texfilter_vs_main', _VS,
         'o.setTexcoord0(float4(base, 0.0, 1.0));', 'o.setTexcoord0(float4(base, 0.0, 0.0));'),
    _src('texfilter-vs-clip-space-z', 'texfilter_vs_main', _VS,
         'return float4(i.position().xy, 0.0, 1.0); }', 'return float4(i.position().xy, 1.0, 1.0); }'),
    _src('texfilter-vs-color-alpha-leak', 'texfilter_vs_main', _VS,
         'o.setColor0(float4(i.color0().xyz, 0.0));', 'o.setColor0(float4(i.color0().xyw, 0.0));'),
    _src('texfilter-vs-tap-order', 'texfilter_vs_main', _VS,
         'o.setTexcoord2(float4(taps23.xy, 0.0, 0.0));', 'o.setTexcoord2(float4(taps23.yx, 0.0, 0.0));'),
    _src('texfilter-vs-projection-matrix', 'texfilter_vs_main', _VS,
         '{ return mul(matWorldViewProj, i.position()); }', '{ return mul(matWorldView, i.position()); }'),
    _cfg('texfilter-vs-transport-width', 'texfilter_vs_main', C.widen_first_row(), cls='transport'),
    # --- cookie_tint_vs ----------------------------------------------------------
    _src('cookie-tint-vertex-channel', 'cookie_tint_vs_main', _TINT,
         'return i.color0().wwww * Factor.wwww;', 'return i.color0().xxxx * Factor.wwww;'),
    _src('cookie-tint-projective-bias', 'cookie_tint_vs_main', _TINT,
         '(clipPos.xy + clipPos.w) * 0.5', '(clipPos.xy - clipPos.w) * 0.5'),
    _src('cookie-tint-tex-matrix', 'cookie_tint_vs_main', _TINT,
         'd3TextureMatrixTransform(0, ', 'd3TextureMatrixTransform(1, '),
    _src('cookie-tint-clip-planes', 'cookie_tint_vs_main', _TINT,
         'd3WriteClipPlanes(clipPos, o);', 'd3WriteClipPlanes(clipPos * 0.5, o);'),
    _cfg('cookie-tint-policy', 'cookie_tint_vs_main', C.swap_specialize('TintVertexAlpha', 'TintFactor')),
    _cfg('cookie-tint-transport-narrow', 'cookie_tint_vs_main', _narrow_first_row(), cls='transport'),
]

#: depth-output mutations of texdepth_ps_main, each caught by depth_check.py --mutations
#: (the depth written, bit for bit, and the multisampled declarations). Not gate D8:
#: D4 skips SV_Depth, so these would read MISSED there.
DEPTH_MUTATIONS = [
    _src('texdepth-sampled-channel', 'texdepth_ps_main', _DEPTH,
         'return texDepth.Sample(texDepth_s, uv).x; }', 'return texDepth.Sample(texDepth_s, uv).y; }'),
    _src('texdepth-loaded-channel', 'texdepth_ps_main', _DEPTH,
         'return tex.Load(int2(texel), 0).x;', 'return tex.Load(int2(texel), 0).y;'),
    _src('texdepth-depth-nan-injection', 'texdepth_ps_main', _DEPTH,
         'return tex.Load(int2(texel), 0).x;', 'return sqrt(tex.Load(int2(texel), 0).x - 0.5);', cls='nan'),
    _src('texdepth-sample-count', 'texdepth_ps_main', 'types/texfilter_textures.slang',
         'Texture2DMS<float4, 4> texDepthMS4', 'Texture2DMS<float4, 2> texDepthMS4'),
    _src('texdepth-resolve-depth-scale', 'texdepth_ps_main', _DEPTH,
         'return TTarget.write(TSource.depth(i.texcoord0().xy));',
         'return TTarget.write(TSource.depth(i.texcoord0().xy) * 0.5);'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = ['texfilter_ps_main']
SKINNED_ROOTS = []
