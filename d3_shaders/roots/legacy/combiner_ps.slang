// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Fixed-function stage-combiner pixel shaders (Legacy.fx, Billboard.fx and
// SoftBillboard.fx `ps_legacy`, and the firewall / particle / legacy / wing /
// blend-add flow variants).
//
// Every one of them is the same machine: a flow front decides the coordinate
// each texture unit is read at, a stage chain folds the units into colour and
// alpha (interfaces/combiner.slang), a resolve applies the pass's fixed tails
// and output form, and the alpha test runs on what is written.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Resolve: the tails after the chain, in the order they apply
// ---------------------------------------------------------------------------

/// alpha = min(1, alpha ^ (10 * COLOR1.a)): the sprite eaten away over its life
public static const uint RESOLVE_EROSION = 1;
/// colour / alpha modulated by the vertex colour after the chain's last clamp
public static const uint RESOLVE_VCOLOR_RGB = 2;
public static const uint RESOLVE_VCOLOR_ALPHA = 4;
/// colour / alpha squared
public static const uint RESOLVE_SQUARE_RGB = 8;
public static const uint RESOLVE_SQUARE_ALPHA = 16;
/// alpha *= saturate(0.025 * near-fade distance), the distance on TEXCOORD6
public static const uint RESOLVE_NEAR_FADE = 32;
/// alpha *= the soft-particle depth fade against the scene depth buffer
public static const uint RESOLVE_SOFT_FADE = 64;
/// colour replaced by black
public static const uint RESOLVE_ZERO_RGB = 128;
/// colour premultiplied by the clamped alpha
public static const uint RESOLVE_PREMULTIPLY = 256;
/// written alpha: the combined alpha, 1 - clamped alpha, 1 or 0
public static const uint RESOLVE_ALPHA_MASK = 1536;
public static const uint RESOLVE_ALPHA_KEEP = 0;
public static const uint RESOLVE_ALPHA_INVERSE = 512;
public static const uint RESOLVE_ALPHA_ONE = 1024;
public static const uint RESOLVE_ALPHA_ZERO = 1536;
/// colour fogged: lerp(fogColor, colour, FOG0)
public static const uint RESOLVE_FOG = 2048;

public interface ICombinerResolve
{
    static float4 resolve(float3 rgb, float alpha, D3Interpolants i);
}

/// Soft particles fade over the last world unit pair before they would clip
/// into the scene behind them.
static const float kSoftFadeRange = 2.0;

/// Scene depth under the fragment turned back into view distance
/// (cameraParams.xy invert the depth write), minus the sprite's own distance
/// on TEXCOORD2, over the fade range.
float d3SoftFade(D3Interpolants i)
{
    float z = texDepth.Sample(texDepth_s, i.position().xy * windowResolution.xy).x;
    float sceneDepth = -cameraParams.x / (z - cameraParams.y);
    return saturate((sceneDepth - i.texcoord2().x) / kSoftFadeRange);
}

/// The fixed tails named by the bits of STEPS.
public struct Resolve<let STEPS : uint> : ICombinerResolve
{
    static bool has(uint step) { return (STEPS & step) != 0; }

    public static float4 resolve(float3 rgb, float alpha, D3Interpolants i)
    {
        if (has(RESOLVE_EROSION))
            alpha = min(1.0, pow(alpha, 10.0 * i.color1().a));
        if (has(RESOLVE_VCOLOR_RGB))
            rgb *= i.color0().rgb;
        if (has(RESOLVE_VCOLOR_ALPHA))
            alpha *= i.color0().a;
        if (has(RESOLVE_SQUARE_RGB))
            rgb *= rgb;
        if (has(RESOLVE_SQUARE_ALPHA))
            alpha *= alpha;
        if (has(RESOLVE_NEAR_FADE))
            alpha *= saturate(0.025 * i.texcoord6().x);
        if (has(RESOLVE_SOFT_FADE))
            alpha *= d3SoftFade(i);
        if (has(RESOLVE_ZERO_RGB))
            rgb = float3(0.0, 0.0, 0.0);
        if (has(RESOLVE_PREMULTIPLY))
            rgb *= saturate(alpha);

        uint form = STEPS & RESOLVE_ALPHA_MASK;
        float written = alpha;
        if (form == RESOLVE_ALPHA_INVERSE)
            written = 1.0 - saturate(alpha);
        else if (form == RESOLVE_ALPHA_ONE)
            written = 1.0;
        else if (form == RESOLVE_ALPHA_ZERO)
            written = 0.0;

        if (has(RESOLVE_FOG))
            rgb = d3ApplyFog(rgb, i.fog().x);
        return float4(rgb, written);
    }
};

[shader("fragment")]
public float4 combiner_ps_main<TFront : IFlowFront, TChain : IStageChain, TResolve : ICombinerResolve,
                               TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    D3StageArgs args = TFront.args(i);
    float3 rgb;
    float alpha;
    TChain.run(rgb, alpha, args);
    float4 color = TResolve.resolve(rgb, alpha, i);
    TAlpha.apply(color.a);
    return color;
}
