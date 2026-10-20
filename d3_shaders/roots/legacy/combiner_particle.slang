// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Particle tails of the stage combiner (roots/legacy/combiner_ps.slang) that
// its Resolve steps do not spell, and the texture roles only particle passes
// bind.
//
// * The soft fade of a glow sphere reaches over three times the range of a
//   soft billboard, and a premultiplied soft sprite fades its colour with its
//   alpha rather than its alpha alone.
// * The premultiplied blend-add pass writes the transmittance `1 - alpha`
//   unclamped: its alpha is a product of the vertex and texture alphas, never
//   clamped anywhere.
//
// Each tail wraps another resolve, so it composes with every Resolve<STEPS>.

implementing d3_shaders;

public struct AlphaMap : ITextureRole { public static float4 sample(float2 uv) { return alphaMap.Sample(alphaMap_s, uv); } };

/// The soft-particle depth fade over RANGE world units: the scene depth under
/// the fragment turned back into view distance (cameraParams.xy invert the
/// depth write), minus the sprite's own distance on TEXCOORD2.
float d3SoftFadeOver(D3Interpolants i, int range)
{
    float z = texDepth.Sample(texDepth_s, i.position().xy * windowResolution.xy).x;
    float sceneDepth = -cameraParams.x / (z - cameraParams.y);
    return saturate((sceneDepth - i.texcoord2().x) * (1.0 / float(range)));
}

/// TInner's colour faded against the scene depth over RANGE units: its alpha,
/// and with RGB its colour too.
public struct ResolveSoftFade<TInner : ICombinerResolve, let RANGE : int, let RGB : bool> : ICombinerResolve
{
    public static float4 resolve(float3 rgb, float alpha, D3Interpolants i)
    {
        float4 color = TInner.resolve(rgb, alpha, i);
        float fade = d3SoftFadeOver(i, RANGE);
        if (RGB)
            color.rgb *= fade;
        color.a *= fade;
        return color;
    }
};

/// TInner's colour with its alpha written as the unclamped transmittance.
public struct ResolveTransmittance<TInner : ICombinerResolve> : ICombinerResolve
{
    public static float4 resolve(float3 rgb, float alpha, D3Interpolants i)
    {
        float4 color = TInner.resolve(rgb, alpha, i);
        return float4(color.rgb, 1.0 - color.a);
    }
};
