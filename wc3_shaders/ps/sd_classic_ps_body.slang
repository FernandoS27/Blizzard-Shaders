// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SD classic pixel shader body.
//
// Recreates the D3D9 fixed-function texture-stage chain the classic
// Warcraft III renderer used. Two texture stages are chained through
// the compile-time policies `T0`, `T1`; lighting is already baked into
// `input.vertColor` by the vertex shader, so the body just applies the
// combiner chain to it, runs the alpha test, and applies fog.
//
// 3.0.0 changed exactly one thing here: the fog axis went from three modes
// (`IFogMode`) to the engine-wide seven (`IFogMode30`), whose arms are shared
// with the HD families — see ps/fog_factor.slang. The stage chain, the
// stage ops themselves, and the order (stages, then alpha test, then fog) are
// all unchanged, which is why 92 of the 168 2.0.0 classes survive byte for
// byte into 3.0.0.
//
// The APPLICATION stays local. HD runs an 11-case blend-mode switch so
// additive materials fade to black; the classic pipeline has no blend-mode
// constant and always lerps plainly toward the fog colour, leaving alpha
// alone.

implementing wc3_shaders;

public float4 sdClassicPsBody<
    T0    : ITextureStage,
    T1    : ITextureStage,
    TFog  : IFogMode30,
    TAlpha: IAlphaTest
>(SDPSInput input)
{
    // The "current color" starts as the pre-lit vertex color.
    float4 current = input.vertColor;

    if (T0.isEnabled)
    {
        // Stage 0: sample albedo (t0) at UV0 and combine.
        float4 tex0 = t_albedo.Sample(s_albedo, input.uv.xy);
        current = T0.applyOp(current, tex0);

        if (T1.isEnabled)
        {
            // Stage 1: sample the second texture (bound at t_normal /
            // t1 in the classic pipeline, despite the name — the
            // classic renderer uses t1 as the detail / lightmap slot)
            // at UV1 and combine.
            float4 tex1 = t_normal.Sample(s_normal, input.uv.zw);
            current = T1.applyOp(current, tex1);
        }
    }

    // Alpha test after combining so cut-out materials see the right
    // alpha including any modulation from the texture stages.
    TAlpha.test(current.w, sdClassicPsCB0.alphaRef);

    // Fog is applied on view-space Z (packed in worldPos.z by the VS).
    if (TFog.hasFog)
    {
        float f = TFog.factor(input.worldPos.z,
                              sdClassicPsCB0.fogColorStart.w,
                              sdClassicPsCB0.fogEnd,
                              sdClassicPsCB0.fogDensity);
        float3 fogColor = sdClassicPsCB0.fogColorStart.xyz;
        current.xyz = f * (current.xyz - fogColor) + fogColor;
    }

    return current;
}
