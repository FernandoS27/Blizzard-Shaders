// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// texfilter_ps filters that blur: kernels over neighbouring texels of one
// target. The separable kernels (bloom Gaussian, VSM box, highlight glow) take
// their axis as a policy and step in target texels (`targetDimensions.zw`);
// the rest (the three-tap bloom/VSM combiner, the highlight masks, sharpen,
// motion blur, the bilateral SSAO blur) are fixed kernels.

implementing d3_shaders;

/// The axis a separable kernel steps along, in target texels.
public interface IBlurAxis
{
    static float2 offset(float texels);
}

public struct AxisHorizontal : IBlurAxis
{
    public static float2 offset(float texels) { return float2(texels * targetDimensions.z, 0.0); }
};

public struct AxisVertical : IBlurAxis
{
    public static float2 offset(float texels) { return float2(0.0, texels * targetDimensions.w); }
};

/// How a kernel addresses the target: straight at the quad coordinate, or
/// through the viewport rectangle with every offset tap clamped inside it.
public interface IKernelSpace
{
    static float2 base(float2 uv);
    static float2 tap(float2 uv);
}

public struct SpaceTarget : IKernelSpace
{
    public static float2 base(float2 uv) { return uv; }
    public static float2 tap(float2 uv) { return uv; }
};

public struct SpaceViewport : IKernelSpace
{
    public static float2 base(float2 uv) { return d3ViewportUv(uv); }
    public static float2 tap(float2 uv) { return d3ViewportClamp(uv); }
};

/// Weights of the 13-tap Gaussian, outermost pair first; the last is the centre.
static const float kGaussian13[7] = { 0.0481169038, 0.0599573553, 0.0717819855, 0.0825689360,
                                      0.0912527889, 0.0968955457, 0.0988529697 };

/// Bloom blur: a 13-tap Gaussian along one axis.
public struct GaussianBlur13<TAxis : IBlurAxis> : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 sum = float4(0.0, 0.0, 0.0, 0.0);
        for (float texels = -6.0; texels < 0.0; texels += 1.0)
        {
            float2 offset = TAxis.offset(texels);
            float4 ahead = texSampler0.Sample(texSampler0_s, offset + uv);
            float4 behind = texSampler0.Sample(texSampler0_s, -offset + uv);
            float weight = kGaussian13[uint(texels + 6.0)];
            sum = ahead * weight + sum;
            sum = behind * weight + sum;
        }
        return texSampler0.Sample(texSampler0_s, uv) * kGaussian13[6] + sum;
    }
};

/// VSM filter: a 7-tap box along one axis.
public struct BoxBlur7<TAxis : IBlurAxis> : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 sum = float4(0.0, 0.0, 0.0, 0.0);
        for (int texels = 1; texels <= 3; texels++)
        {
            float2 offset = TAxis.offset(float(texels));
            sum = sum + texSampler0.Sample(texSampler0_s, offset + uv);
            sum = texSampler0.Sample(texSampler0_s, -offset + uv) + sum;
        }
        return (texSampler0.Sample(texSampler0_s, uv) + sum) * (1.0 / 7.0);
    }
};

/// Tap distances and weights of the highlight glow kernel, innermost first.
static const float kGlowDistance[5] = { 1.5, 3.5, 5.5, 7.5, 9.5 };
static const float kGlowWeight[5] = { 0.336101592, 0.192839444, 0.0709416643, 0.0167335141, 0.00253077247 };
static const float kGlowCenterWeight = 0.380853;

/// Highlight glow along one axis: colour dilates (the brightest tap wins) while
/// coverage is blurred by a Gaussian over PAIRS bilinear tap pairs.
public struct HighlightGlow<TAxis : IBlurAxis, TSpace : IKernelSpace, let PAIRS : int> : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 base = TSpace.base(i.texcoord0().xy);
        float4 center = texSampler0.Sample(texSampler0_s, base);
        float3 rgb = center.xyz;
        float alpha = center.w * kGlowCenterWeight;
        for (int k = 0; k < PAIRS; k++)
        {
            float2 offset = TAxis.offset(kGlowDistance[k]);
            float4 behind = texSampler0.Sample(texSampler0_s, TSpace.tap(-offset + base));
            float4 ahead = texSampler0.Sample(texSampler0_s, TSpace.tap(offset + base));
            rgb = max(max(behind.xyz, ahead.xyz), rgb);
            alpha = (behind.w + ahead.w) * kGlowWeight[k] + alpha;
        }
        return float4(rgb, alpha);
    }
};

/// The pass-supplied three-tap kernel (bloom / highlight / VSM `_con`): two
/// taps weighted by Weights1.x and .z, faded towards a third by Weights1.y.
public struct KernelTaps3 : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 base = d3ViewportUv(i.texcoord0().xy);
        float4 sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(base + Constant1.xy)) * Weights1.z;
        sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(base + Constant0.xy)) * Weights1.x + sum;
        sum = sum * (1.0 - Weights1.y);
        return texSampler0.Sample(texSampler0_s, d3ViewportClamp(base + Constant0.zw)) * Weights1.y + sum;
    }
};

/// Silhouette threshold of the highlight masks: the original highlight counts
/// as covered above this alpha.
static const float kHighlightSolid = 0.125;

/// Highlight composite: the blurred highlight, kept only outside the solid
/// silhouette.
public struct HighlightMask : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = d3ViewportUv(i.texcoord0().xy);
        float4 original = texOriginalHighlight.Sample(texOriginalHighlight_s, uv);
        float4 blurred = texBlurredHighlight.Sample(texBlurredHighlight_s, uv);
        float alpha = kHighlightSolid < original.w ? 0.0 : blurred.w;
        return float4(blurred.xyz, alpha);
    }
};

/// 1 where the original highlight is empty at a clamped viewport tap.
float d3HighlightEmpty(float2 uv)
{
    float4 original = texOriginalHighlight.Sample(texOriginalHighlight_s, d3ViewportClamp(uv));
    return kHighlightSolid >= original.w ? 1.0 : 0.0;
}

/// Highlight composite with a feathered inner edge: outside the silhouette the
/// blurred highlight's coverage, inside it the fraction of the four
/// pass-supplied neighbour taps that fall outside.
public struct HighlightMaskFeathered : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 base = d3ViewportUv(i.texcoord0().xy);
        float empty = d3HighlightEmpty(base + Constant0.zw) + d3HighlightEmpty(base + Constant0.xy);
        empty = d3HighlightEmpty(base + Constant1.xy) + empty;
        empty = d3HighlightEmpty(base + Constant1.zw) + empty;
        float edge = empty * 0.25;
        float4 original = texOriginalHighlight.Sample(texOriginalHighlight_s, base);
        float4 blurred = texBlurredHighlight.Sample(texBlurredHighlight_s, base);
        bool outside = kHighlightSolid >= original.w;
        float inner = outside ? 0.0 : edge;
        return float4(blurred.xyz, blurred.w * float(outside) + inner);
    }
};

/// Upscale sharpen: the centre boosted against its four diagonal neighbours.
public struct SharpenDiagonal : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 base = d3ViewportUv(i.texcoord0().xy);
        float2 texel = targetDimensions.zw;
        float4 sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(base - texel));
        sum = sum + texSampler0.Sample(texSampler0_s, d3ViewportClamp(texel * float2(-1.0, 1.0) + base));
        sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(texel * float2(1.0, -1.0) + base)) + sum;
        float4 center = texSampler0.Sample(texSampler0_s, base);
        sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(base + texel)) + sum;
        return center * 1.3 + sum * -0.075;
    }
};

/// Motion blur: where the velocity target (0.5-biased) moves, 13 unfiltered
/// taps along the velocity; elsewhere the original colour.
public struct MotionBlur13 : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 base = d3ViewportUv(i.texcoord0().xy);
        float2 uv = d3ViewportClamp(base);
        float2 velocity = texVelocity.Sample(texVelocity_s, uv).xy + -0.5;
        float4 original = texOriginal.Sample(texOriginal_s, uv);
        if (0.001 < dot(velocity, velocity))
        {
            float2 stride = velocity * 4.0;
            float3 sum = float3(0.0, 0.0, 0.0);
            for (int k = 0; k < 13; k++)
            {
                float2 tap = stride * (float(k) * targetDimensions.zw) * 4.0 + base;
                sum = sum + texOriginal.SampleLevel(texOriginal_s, d3ViewportClamp(tap), 0.0).xyz;
            }
            return float4(sum * (1.0 / 13.0), 1.0);
        }
        return original;
    }
};

/// Weights of the bilateral SSAO blur by tap distance (the centre first).
static const float kSsaoBlurWeight[9] = { 0.07582, 0.07493, 0.07232, 0.06816, 0.06274,
                                          0.0564, 0.04952, 0.04246, 0.03555 };

/// Accumulated occlusion and weight of a bilateral blur.
struct SsaoBlurSum
{
    float occlusion;
    float weight;
};

/// One tap of the bilateral SSAO blur: kept when its depth is within 4 units of
/// the centre and its normal within ~73 degrees.
void d3SsaoBlurTap(inout SsaoBlurSum sum, float2 uv, float3 normal, float depth, int k, float direction)
{
    float2 tap = d3ViewportClamp(direction * float(k) * Constant0.xy + uv);
    float4 texel = texNormal.Sample(texNormal_s, tap);
    float3 tapNormal = d3DecodeScreenNormal(texel);
    float depthDelta = d3DecodeScreenDepth(texel) + -depth;
    float occlusion = texSSAOBuffer.Sample(texSSAOBuffer_s, tap).w;
    float near = 4.0 >= abs(depthDelta) ? 1.0 : 0.0;
    float facing = dot(tapNormal, normal) >= 0.3 ? 1.0 : 0.0;
    float weight = near * kSsaoBlurWeight[k];
    sum.occlusion = facing * weight * occlusion + sum.occlusion;
    sum.weight = weight * facing + sum.weight;
}

/// SSAO blur: a 15-tap bilateral kernel along the pass-supplied axis
/// (Constant0.xy), normalised by the weight it kept.
public struct SsaoBilateralBlur : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = d3ViewportUv(i.texcoord0().xy);
        float4 texel = texNormal.Sample(texNormal_s, uv);
        float3 normal = d3DecodeScreenNormal(texel);
        float depth = d3DecodeScreenDepth(texel);
        SsaoBlurSum sum;
        sum.occlusion = texSSAOBuffer.Sample(texSSAOBuffer_s, uv).w * kSsaoBlurWeight[0];
        sum.weight = kSsaoBlurWeight[0];
        for (int k = 1; k < 8; k++)
            d3SsaoBlurTap(sum, uv, normal, depth, k, -1.0);
        for (int k = 1; k < 8; k++)
            d3SsaoBlurTap(sum, uv, normal, depth, k, 1.0);
        float ao = sum.occlusion / sum.weight;
        return float4(ao, ao, ao, ao);
    }
};
