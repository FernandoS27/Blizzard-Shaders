"""Gate data for workspace m7_combiner (plan M7 residue, bundle ps_legacy).

The 158 residue programs placed here have no translators: each is placed by
program in d3_residue.json. Most are Legacy.fx ps_legacy stage-combiner
programs (combiner_ps_main), decoded from their retail instruction streams;
the combiner gained blend / signed-add / hit-flash op bits and an extra-first
layer sum for the stage combinations no v1 key used. Three projected-layer
variants join legacy_aux_ps_main, and two new roots take the rest:
legacy_fixed_ps_main (the `_v11` surface fallbacks, UI / cutscene utilities
and debug views) and depth_clear_ps_main (the SV_Depth clear pass).

This file declares the new roots and the D8 mutations of every root touched.
"""

import d3_shaders_cfg as C

#: residue roots introduced in this workspace, by bundle
NEW_ROOTS = {
    'legacy_fixed_ps_main': 'ps_legacy',
    'depth_clear_ps_main': 'ps_legacy',
}


# --------------------------------------------------------------------------
# gate D8
# --------------------------------------------------------------------------

def _narrow_texcoord0():
    """A spec edit shrinking TEXCOORD0 from float4 to float3 (the depth clear's
    only non-system interpolant is float4, so widen_first_row has nothing to act on)."""
    from dataclasses import replace

    def edit(spec):
        d = list(spec.defines)
        for i, x in enumerate(d):
            if x.startswith('D3_IO_') and x.endswith('_TYPE=float4'):
                sem = [y for y in d if y.startswith(x.split('_TYPE=')[0] + '_SEM=')]
                if sem and sem[0].split('=')[1] == 'TEXCOORD0':
                    d[i] = x[:-1] + '3'
                    return replace(spec, defines=tuple(d))
        return None
    return edit


_FIXED = 'legacy_fixed_ps_main'
_FIXED_FILE = 'roots/legacy/legacy_fixed_ps.slang'
_DEPTH = 'depth_clear_ps_main'
_DEPTH_FILE = 'roots/legacy/depth_clear_ps.slang'
_COMBINER = 'combiner_ps_main'
_COMBINER_FILE = 'interfaces/combiner.slang'
_AUX = 'legacy_aux_ps_main'
_AUX_FILE = 'roots/legacy/legacy_aux_projected.slang'

MUTATIONS = [
    # --- legacy_fixed_ps: required classes ------------------------------------
    dict(name='fixed-transport-width', root=_FIXED, kind='cfg', spec=C.widen_first_row(), cls='transport'),
    dict(name='fixed-register-shift', root=_FIXED, kind='cfg', spec=C.shift_first_texture(), cls='register'),
    dict(name='fixed-tie-flip', root=_FIXED, kind='cfg', spec=C.swap_specialize('DiscardLE', 'DiscardLT'),
         cls='tie'),
    dict(name='fixed-nan-injection', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='float3 light = saturate(colLight.xyz * nl + ambient);',
         new='float3 light = saturate(colLight.xyz * sqrt(nl - 0.5) + ambient);', cls='nan'),
    # --- legacy_fixed_ps: formulas --------------------------------------------
    dict(name='fixed-inactive-dim', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='(DIMMED ? 0.2 : 0.7)', new='(DIMMED ? 0.2 : 0.75)'),
    dict(name='fixed-luma-weights', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='float3(0.222, 0.707, 0.071)', new='float3(0.299, 0.587, 0.114)'),
    dict(name='fixed-outline-tap', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='sum = sum + tap(uv, float2(1.0, 0.0));', new='sum = sum + tap(uv, float2(1.0, 1.0));'),
    dict(name='fixed-cutscene-chroma', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='rgb.b = luma + 2.017232180 * cb;', new='rgb.b = luma + 2.017232180 * cr;'),
    dict(name='fixed-specular-facing', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='(nl >= 0.0 && nh >= 0.0) ? nh8 : 0.0', new='(nh >= 0.0) ? nh8 : 0.0'),
    dict(name='fixed-irradiance-flash-order', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='lit = lit * 2.0 + hitFlashColorAdd.xyz;', new='lit = lit * 2.0 + hitFlashColorMul.xyz;'),
    dict(name='fixed-noise-lookup', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='float2(Time.y, ambient.y)', new='float2(Time.x, ambient.y)'),
    dict(name='fixed-fresnel-opacity', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='lerp(diffuse.a, 1.0, fresnel)', new='diffuse.a'),
    dict(name='fixed-batch-ramp', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='numBatches.x * 0.0625 + 0.03125', new='numBatches.x * 0.0625'),
    dict(name='fixed-icon-mask-channel', root=_FIXED, kind='src', file=_FIXED_FILE,
         old='float mask = texMask.Sample(texMask_s, i.texcoord1().xy).x;',
         new='float mask = texMask.Sample(texMask_s, i.texcoord1().xy).w;'),
    # --- depth_clear_ps ---------------------------------------------------------
    dict(name='depth-transport-width', root=_DEPTH, kind='cfg', spec=_narrow_texcoord0(), cls='transport'),
    dict(name='depth-binds-texture', root=_DEPTH, kind='src', file=_DEPTH_FILE,
         old='o.depth = i.texcoord0().x;',
         new='o.depth = i.texcoord0().x + sampler0.Sample(sampler0_s, i.texcoord0().xy).x;', cls='register'),
    dict(name='depth-nan-injection', root=_DEPTH, kind='src', file=_DEPTH_FILE,
         old='o.depth = i.texcoord0().x;', new='o.depth = sqrt(i.texcoord0().x - 0.5);', cls='nan'),
    dict(name='depth-component', root=_DEPTH, kind='src', file=_DEPTH_FILE,
         old='o.depth = i.texcoord0().x;', new='o.depth = i.texcoord0().y;'),
    dict(name='depth-colour-alpha', root=_DEPTH, kind='src', file=_DEPTH_FILE,
         old='o.color = float4(0.0, 0.0, 0.0, 0.0);', new='o.color = float4(0.0, 0.0, 0.0, 1.0);'),
    dict(name='depth-position-z', root=_DEPTH, kind='src', file=_DEPTH_FILE,
         old='o.depth = i.texcoord0().x;', new='o.depth = i.position().z;'),
    # --- combiner_ps: the op bits and layer sum added here ----------------------
    dict(name='combiner-blend-weight-vertex', root=_COMBINER, kind='src', file=_COMBINER_FILE,
         old='float weight = d3OpHas(op, BLEND_VCOLOR_A) ? color0.a : tex.a;',
         new='float weight = d3OpHas(op, BLEND_VCOLOR_A) ? tex.a : color0.a;'),
    dict(name='combiner-blend-overlay-axis', root=_COMBINER, kind='src', file=_COMBINER_FILE,
         old='if (d3OpHas(op, OVERLAY)) weight *= diffuseOverlay.x;',
         new='if (d3OpHas(op, OVERLAY)) weight *= diffuseOverlay.y;'),
    dict(name='combiner-signed-bias', root=_COMBINER, kind='src', file=_COMBINER_FILE,
         old='v = d3Gain(d3ModifyRgb((v + src) - 0.5, op, color0), op);',
         new='v = d3Gain(d3ModifyRgb((v + src) - 0.25, op, color0), op);'),
    dict(name='combiner-hitflash-swap', root=_COMBINER, kind='src', file=_COMBINER_FILE,
         old='v = v * hitFlashColorMul.rgb + hitFlashColorAdd.rgb;',
         new='v = v * hitFlashColorAdd.rgb + hitFlashColorMul.rgb;'),
    # (swapping the two products of LayerSumExtraFirst's sum is no mutation: float
    # addition commutes, so only D5 -- a distinct blob -- tells it from LayerSum)
    dict(name='combiner-extra-first-premultiply', root=_COMBINER, kind='src', file=_COMBINER_FILE,
         old='rgb = xrgb * xalpha + rgb * alpha;', new='rgb = xrgb + rgb * alpha;'),
    # --- legacy_aux_ps: the projected-layer variants added here -----------------
    # (a 1/128 -> 1/64 shift is below the schedule: every trial whose gate falls
    # between the two is outside the projected box, which clips it)
    dict(name='aux-projected-threshold', root=_AUX, kind='src', file=_AUX_FILE,
         old='return (0.0078125 >= gate) ? kNoProjectedLayer : layer;',
         new='return (0.125 >= gate) ? kNoProjectedLayer : layer;'),
    dict(name='aux-projected-ungated-alpha', root=_AUX, kind='src', file=_AUX_FILE,
         old='return float4(d3ProjectedLayerFog(covered, i.texcoord0().z), covered.a);',
         new='return float4(d3ProjectedLayerFog(covered, i.texcoord0().z), 1.0 - covered.a);'),
    dict(name='aux-projected-debug-tint', root=_AUX, kind='src', file=_AUX_FILE,
         old='return float4(0.25, 0.0, 0.25, alpha);', new='return float4(0.25, 0.25, 0.25, alpha);'),
]

#: roots that must include a tie-flip / bone-order mutation
ALPHA_ROOTS = [_FIXED]
SKINNED_ROOTS = []
