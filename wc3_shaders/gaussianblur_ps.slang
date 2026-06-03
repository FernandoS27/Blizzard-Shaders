// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Separable Gaussian blur pixel shader (gaussianblur.bls).
//
// One full-screen permutation used for both axes of the engine's separable
// blur — it bridges the bloom bright-pass (bloomextract) and the composite
// (bloomcombine). Each invocation walks a uniform-supplied tap list, sampling
// the source at `uv + tap.offset` and accumulating `sample * tap.weight`. The
// horizontal and vertical passes run the same shader with a different tap set
// (offsets along X vs Y), so the blur kernel lives entirely in the constant
// buffer the engine uploads — the shader itself is axis-agnostic.
//
// Algorithm (weighted tap accumulation):
//   count = (int)taps[0].w                       // active tap count
//   acc   = 0
//   for i in [0, count):
//       acc += source.Sample(uv + taps[i].xy) * taps[i].z
//   return acc
//
// Faithful reconstruction of war3.w3mod/shaders/ps/gaussianblur.bls — see
// re_shaders/gaussianblur/perm_000.{asm,hlsl}. The signed-int loop counter,
// the (int) truncation of the tap count, and the multiply-add accumulation
// order all mirror the shipped DXBC (ftoi / ige / mad), as does `SpritePSInput`
// supplying SV_Position + the TEXCOORD0 UV the body consumes.

implementing wc3_shaders;

[shader("fragment")]
public float4 gaussian_blur_ps_main(SpritePSInput input) : SV_Target0
{
    // Active tap count from cb1[0].w, truncated to a signed int (DXBC `ftoi`).
    int tapCount = (int)gaussianBlurPsCB1.taps[0].w;

    float4 accum = float4(0.0, 0.0, 0.0, 0.0);
    for (int i = 0; i < tapCount; ++i)
    {
        float4 tap      = gaussianBlurPsCB1.taps[i];
        float2 sampleUv = tap.xy + input.uv;
        float4 texel    = t_gaussianSource.Sample(s_gaussianSource, sampleUv);
        accum = texel * tap.z + accum;   // mad: sample * weight + acc
    }

    return accum;
}
