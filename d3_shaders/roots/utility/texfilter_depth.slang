// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Depth copies (TextureFilter.fx main_ps_copy_depth*, and the MSAA depth
// resolve): the scene depth read back from a texture and written to SV_Depth.
//
// A single-sampled depth target is sampled at the quad coordinate; a
// multisampled one is loaded at the texel under the coordinate (its first
// sample). The resolve variant also clears its colour target to transparent
// black, so what the pass writes is a policy too.

implementing d3_shaders;

/// Where the depth comes from.
public interface IDepthSource
{
    static float depth(float2 uv);
}

/// The single-sampled depth target's red channel.
public struct DepthSampled : IDepthSource
{
    public static float depth(float2 uv) { return texDepth.Sample(texDepth_s, uv).x; }
};

/// Sample 0 of the multisampled texel under a [0, 1] coordinate.
float d3LoadFirstSample<let SAMPLES : int>(Texture2DMS<float4, SAMPLES> tex, float2 uv)
{
    uint width, height, samples;
    tex.GetDimensions(width, height, samples);
    uint2 texel = uint2(floor(float2(width, height) * uv));
    return tex.Load(int2(texel), 0).x;
}

public struct DepthMultisampled1 : IDepthSource
{
    public static float depth(float2 uv) { return d3LoadFirstSample(texDepthMS1, uv); }
};

public struct DepthMultisampled2 : IDepthSource
{
    public static float depth(float2 uv) { return d3LoadFirstSample(texDepthMS2, uv); }
};

public struct DepthMultisampled4 : IDepthSource
{
    public static float depth(float2 uv) { return d3LoadFirstSample(texDepthMS4, uv); }
};

public struct DepthMultisampled8 : IDepthSource
{
    public static float depth(float2 uv) { return d3LoadFirstSample(texDepthMS8, uv); }
};

/// What the pass writes.
public interface IDepthTarget
{
    associatedtype Output;
    static Output write(float depth);
}

public struct DepthOnlyOutput
{
    public float depth : SV_Depth;
};

/// Depth only; no colour target bound.
public struct TargetDepth : IDepthTarget
{
    typealias Output = DepthOnlyOutput;
    public static DepthOnlyOutput write(float depth)
    {
        DepthOnlyOutput o;
        o.depth = depth;
        return o;
    }
};

public struct DepthColorOutput
{
    public float4 color : SV_Target;
    public float depth : SV_Depth;
};

/// Depth, with the colour target cleared to transparent black.
public struct TargetDepthClearColor : IDepthTarget
{
    typealias Output = DepthColorOutput;
    public static DepthColorOutput write(float depth)
    {
        DepthColorOutput o;
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        o.depth = depth;
        return o;
    }
};

[shader("fragment")]
public TTarget.Output texdepth_ps_main<TSource : IDepthSource, TTarget : IDepthTarget>(D3Interpolants i)
{
    return TTarget.write(TSource.depth(i.texcoord0().xy));
}
