// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// texfilter_ps filters that copy, resolve or remap a target texel by texel, or
// mix a fixed set of taps: the copies and MSAA resolves, the letterbox bars,
// the gamma-correction lookup, the interlace and quincunx resolves, the
// weighted shadow blur and the bloom shrink with its brightness curve.

implementing d3_shaders;

/// Luminance weights of the bloom brightness curve.
static const float3 kBloomLuma = float3(0.222, 0.707, 0.071);

/// A colour target the copy reads.
public interface ITexSource
{
    static float4 sample(float2 uv);
}

/// The generic first filter input.
public struct SourceSampler0 : ITexSource
{
    public static float4 sample(float2 uv) { return texSampler0.Sample(texSampler0_s, uv); }
};

/// The colour target of the EQAA resolve.
public struct SourceColorMS : ITexSource
{
    public static float4 sample(float2 uv) { return texColorMS.Sample(texColorMS_s, uv); }
};

/// A straight copy of the source at the quad coordinate.
public struct CopyColor<TSource : ITexSource> : ITexFilter
{
    public static float4 shade(D3Interpolants i) { return TSource.sample(i.texcoord0().xy); }
};

/// The source's alpha, copied into every channel.
public struct CopyAlpha : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float alpha = texSampler0.Sample(texSampler0_s, i.texcoord0().xy).w;
        return float4(alpha, alpha, alpha, alpha);
    }
};

/// Opaque black: the letterbox bars.
public struct FillOpaqueBlack : ITexFilter
{
    public static float4 shade(D3Interpolants i) { return float4(0.0, 0.0, 0.0, 1.0); }
};

/// Gamma correction through a lookup strip: each colour channel indexes the
/// strip's v axis and takes its red; alpha passes through.
public struct GammaLookup : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float4 color = texSampler0.Sample(texSampler0_s, i.texcoord0().xy);
        float r = texSampler1.Sample(texSampler1_s, float2(0.0, color.x)).x;
        float g = texSampler1.Sample(texSampler1_s, float2(0.0, color.y)).x;
        float b = texSampler1.Sample(texSampler1_s, float2(0.0, color.z)).x;
        return float4(r, g, b, color.w);
    }
};

/// Interlaced upscale: the line between two neighbours, 70/15/15.
public struct InterlaceResolve : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float4 color = texSampler0.Sample(texSampler0_s, i.texcoord1().xy) * 0.7;
        color = texSampler0.Sample(texSampler0_s, i.texcoord0().xy) * 0.15 + color;
        return texSampler0.Sample(texSampler0_s, i.texcoord2().xy) * 0.15 + color;
    }
};

/// Quincunx resolve: the average of the two half-offset fields, each nudged a
/// hair off the texel centre; the second field is one target row up.
public struct QuincunxResolve : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv0 = i.texcoord0().xy + float2(0.0001, 0.0);
        float2 uv1 = float2(i.texcoord1().x + -0.0001, i.texcoord1().y - targetDimensions.w);
        float4 field0 = texSampler0.Sample(texSampler0_s, uv0);
        float4 field1 = texSampler1.Sample(texSampler1_s, uv1);
        return lerp(field0, field1, 0.5);
    }
};

/// The plain average of the four filter taps.
public struct TapAverage4 : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float4 sum = texSampler0.Sample(texSampler0_s, i.texcoord1().xy) * 0.25;
        sum = texSampler0.Sample(texSampler0_s, i.texcoord0().xy) * 0.25 + sum;
        sum = texSampler0.Sample(texSampler0_s, i.texcoord2().xy) * 0.25 + sum;
        return texSampler0.Sample(texSampler0_s, i.texcoord3().xy) * 0.25 + sum;
    }
};

/// Four inputs, one per tap, weighted by Weights1..4.
public struct TapWeighted4 : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float4 sum = texSampler1.Sample(texSampler1_s, i.texcoord1().xy) * Weights2;
        sum = Weights1 * texSampler0.Sample(texSampler0_s, i.texcoord0().xy) + sum;
        sum = Weights3 * texSampler2.Sample(texSampler2_s, i.texcoord2().xy) + sum;
        return Weights4 * texSampler3.Sample(texSampler3_s, i.texcoord3().xy) + sum;
    }
};

/// How the bloom shrink gathers its colour.
public interface IShrinkGather
{
    static float4 gather(D3Interpolants i);
}

/// One bilinear tap at the quad coordinate.
public struct GatherSingle : IShrinkGather
{
    public static float4 gather(D3Interpolants i) { return texSampler0.Sample(texSampler0_s, i.texcoord0().xy); }
};

/// Four bilinear taps a quarter target texel around the viewport coordinate:
/// a 4x4 box in two bilinear steps.
public struct GatherBox4x4 : IShrinkGather
{
    public static float4 gather(D3Interpolants i)
    {
        float2 base = d3ViewportUv(i.texcoord0().xy);
        float2 step = targetDimensions.zw;
        float4 sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(step * float2(0.25, -0.25) + base)) * 0.25;
        sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(step * float2(-0.25, -0.25) + base)) * 0.25 + sum;
        sum = texSampler0.Sample(texSampler0_s, d3ViewportClamp(step * float2(-0.25, 0.25) + base)) * 0.25 + sum;
        return texSampler0.Sample(texSampler0_s, d3ViewportClamp(step * float2(0.25, 0.25) + base)) * 0.25 + sum;
    }
};

/// Bloom shrink: the gathered colour pushed towards its cube by its luminance
/// (bright texels bloom, dark ones fall away), premultiplied by alpha.
public struct BloomShrink<TGather : IShrinkGather> : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float4 color = TGather.gather(i);
        float3 cubic = color.xyz * (color.xyz * color.xyz) - color.xyz;
        float luma = dot(color.xyz, kBloomLuma);
        float3 rgb = luma * cubic + color.xyz;
        return float4(rgb * color.w, color.w);
    }
};
