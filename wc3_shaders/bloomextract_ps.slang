// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Bloom bright-pass extraction pixel shader (bloomextract.bls).
//
// First stage of the bloom post-process: it isolates the scene's bright
// highlights so the engine's separable blur and the bloomcombine pass can
// add a glow around them. Single full-screen permutation — `svPosition` is
// declared on the (shared) `SpritePSInput` only so the ISGN matches the
// shipped shader; the body consumes just the UV.
//
// Algorithm (luminance-threshold bright-pass):
//   1. Sample the scene colour.
//   2. Compute its Rec.601 perceptual luma.
//   3. Keep the pixel only where the luma exceeds the cutoff; otherwise emit
//      opaque black so it contributes no glow.
//   4. For surviving pixels emit saturate(colour - threshold). The per-
//      channel subtract (alpha included, exactly like the original DXBC) is a
//      soft rolloff so the bloom ramps in smoothly instead of popping on.
//
// Faithful reconstruction of war3.w3mod/shaders/ps/bloomextract.bls — see
// re_shaders/bloomextract/perm_000.{asm,hlsl}.

implementing wc3_shaders;

// Rec.601 luma weights used by both bloom passes. Matches the
// `l(0.300000, 0.590000, 0.110000)` dp3 constant in the shipped DXBC.
public static const float3 BLOOM_LUMA = float3(0.300000012, 0.589999974, 0.109999999);

[shader("fragment")]
public float4 bloom_extract_ps_main(SpritePSInput input) : SV_Target0
{
    float threshold = bloomExtractPsCB1.threshold;

    float4 color = t_bloomSource.Sample(s_bloomSource, input.uv);
    float  luma  = dot(color.xyz, BLOOM_LUMA);

    // Value emitted for surviving (bright) pixels — threshold-subtracted and
    // clamped on every channel, alpha included.
    float4 thresholded = saturate(color - threshold);

    return (threshold < luma) ? thresholded : float4(0.0, 0.0, 0.0, 1.0);
}
