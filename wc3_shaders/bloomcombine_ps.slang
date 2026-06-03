// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Bloom composite pixel shader (bloomcombine.bls).
//
// Final stage of the bloom post-process: it grades and screen-composites the
// blurred bright-pass result (t1) back over the scene (t0). Both layers get
// an independent saturation + intensity grade; the blend attenuates the scene
// where the bloom is already bright so the two add without clipping to flat
// white. Output alpha is taken from the scene.
//
//   bloom  = grade(t1, saturationBloom, intensityBloom)
//   scene  = grade(t0, saturationScene, intensityScene)
//   result = scene * (1 - saturate(bloom)) + bloom     // screen-style over
//   result.a = scene.a
//
// Specialisation space — one compile-time bool matching the two shipped
// perms, which differ by exactly one instruction (the final combine `mad`
// vs `mad_sat`):
//   perm_000  CLAMP_OUTPUT=false   result left unclamped (mad)
//   perm_001  CLAMP_OUTPUT=true    result clamped to [0,1] (mad_sat)
//
// Faithful reconstruction of war3.w3mod/shaders/ps/bloomcombine.bls — see
// re_shaders/bloomcombine/perm_00{0,1}.{asm,hlsl} and the recompile-verified
// ubershader re_shaders/bloomcombine/bloomcombine_ps.hlsl.

implementing wc3_shaders;

// Saturation + intensity grade applied to one bloom-combine layer. The
// saturation step is lerp(luma, colour, saturation) == luma + s*(colour-luma),
// emitted in the same (colour-luma) → mad → mul order as the shipped DXBC.
float3 bloomGradeLayer(float3 color, float saturation, float intensity)
{
    float  luma   = dot(color, BLOOM_LUMA);
    float3 graded = saturation * (color - luma) + luma;
    return intensity * graded;
}

[shader("fragment")]
public float4 bloom_combine_ps_main<let CLAMP_OUTPUT : bool>(SpritePSInput input) : SV_Target0
{
    // Blurred highlight layer (t1), graded then inverted to a screen mask.
    float3 bloom = bloomGradeLayer(
        t_bloomBlur.Sample(s_bloomBlur, input.uv).xyz,
        bloomCombinePsCB1.saturationBloom,
        bloomCombinePsCB1.intensityBloom);
    float3 maskBloom = float3(1.0, 1.0, 1.0) - saturate(bloom);

    // Scene layer (t0) — also supplies the output alpha.
    float4 scene       = t_bloomScene.Sample(s_bloomScene, input.uv);
    float3 sceneGraded = bloomGradeLayer(
        scene.xyz,
        bloomCombinePsCB1.saturationScene,
        bloomCombinePsCB1.intensityScene);

    // Screen-style composite: scene attenuated by the bloom mask, plus bloom.
    float3 combined = sceneGraded * maskBloom + bloom;
    float3 rgb      = CLAMP_OUTPUT ? saturate(combined) : combined;

    return float4(rgb, scene.w);
}
