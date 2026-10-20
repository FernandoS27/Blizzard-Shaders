// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Full-screen post-processing passes (PostFX.fx, FSAA.fx, FSAA_AMD.fx) and the
// minimap composite (Minimap.fx).
//
// Every pass draws one quad and reads the frame it post-processes from
// texture roles; none has an alpha test or a lighting model. What tells them
// apart is the image operation itself, so the root is generic over exactly
// that: the pass. The screen coordinate a pass samples the frame with is a
// second, shared policy -- the render target is either addressed directly or
// through the `viewport` scale/offset of the sub-rectangle being processed,
// optionally clamped just inside it (1e-5) so bilinear taps never
// read a neighbouring rectangle.
//
// The colour grade (roots/utility/postfx_tonemap), FXAA
// (roots/utility/postfx_fxaa) and minimap (roots/utility/postfx_minimap)
// passes live in their own files.

implementing d3_shaders;

public interface IPostFxPass
{
    static float4 shade(D3Interpolants i);
}

[shader("fragment")]
public float4 postfx_ps_main<TPass : IPostFxPass>(D3Interpolants i) : SV_Target
{
    return TPass.shade(i);
}

// ---------------------------------------------------------------------------
// screen coordinates
// ---------------------------------------------------------------------------

/// Where a screen-quad coordinate lands on the texture a pass samples.
public interface IPostFxScreenUv
{
    static float2 map(float2 uv);
}

/// The coordinate addresses the whole texture.
public struct ScreenUvDirect : IPostFxScreenUv
{
    public static float2 map(float2 uv) { return uv; }
};

/// The coordinate addresses the viewport rectangle: scale `.xz`, offset `.yw`.
public struct ScreenUvViewport : IPostFxScreenUv
{
    public static float2 map(float2 uv) { return uv * viewport.xz + viewport.yw; }
};

/// As ScreenUvViewport, then kept inside the rectangle (its far edge pulled in
/// by 1e-5) so a bilinear tap never bleeds into a neighbouring rectangle.
public struct ScreenUvViewportClamped : IPostFxScreenUv
{
    public static float2 map(float2 uv)
    {
        float2 farEdge = viewport.yw + viewport.xz - 0.00001;
        return max(min(farEdge, uv * viewport.xz + viewport.yw), viewport.yw);
    }
};

/// The coordinate addresses a second rectangle carried in `Constant0` (scale
/// `.xz`, offset `.yw`), used for a half-resolution source.
public struct ScreenUvConstantRect : IPostFxScreenUv
{
    public static float2 map(float2 uv) { return uv * Constant0.xz + Constant0.yw; }
};

/// Luminance weights (Rec. 709, rounded) shared by the post passes.
static const float3 kPostFxLuma = float3(0.222, 0.707, 0.071);

// ---------------------------------------------------------------------------
// simple image operations
// ---------------------------------------------------------------------------

/// Soft focus: the blurred bloom buffer added over the frame at 4.5x.
public struct SoftFocus<TFrameUv : IPostFxScreenUv, TBloomUv : IPostFxScreenUv> : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 frame = texOriginal.Sample(texOriginal_s, TFrameUv.map(i.texcoord0().xy));
        float4 bloom = texBloom.Sample(texBloom_s, TBloomUv.map(i.texcoord1().xy));
        return float4(bloom.rgb * 4.5 + frame.rgb, 1.0);
    }
};

/// Grey-scale: the frame's luminance in every colour channel, alpha kept.
public struct Desaturate : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 frame = texOriginal.Sample(texOriginal_s, i.texcoord0().xy);
        float luma = dot(frame.rgb, kPostFxLuma);
        return float4(luma, luma, luma, frame.a);
    }
};

/// Colour-blindness simulation: the frame through `matColorTransform`.
public struct ColorblindSimulate : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 frame = texOriginal.Sample(texOriginal_s, i.texcoord0().xy);
        return mul(matColorTransform, frame);
    }
};

/// RGB -> LMS cone response (Vienot/Brettel/Mollon), and back.
static const float3 kRgbToL = float3(17.8824005, 43.5161018, 4.119349956);
static const float3 kRgbToM = float3(3.455650091, 27.1553993, 3.867140055);
static const float3 kRgbToS = float3(0.0299565997, 0.184309006, 1.467090011);
static const float3 kLmsToR = float3(0.0809444487, -0.130504414, 0.116721064);
static const float3 kLmsToG = float3(-0.0102485335, 0.0540193282, -0.113614708);
static const float3 kLmsToB = float3(-0.000365296932, -0.00412161462, 0.693511426);

/// Daltonization: simulate the deficiency in LMS space (`matColorTransform`),
/// and shift the colour information the viewer loses into the green and blue
/// channels they can still tell apart.
public struct ColorblindDaltonize : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 frame = texOriginal.Sample(texOriginal_s, i.texcoord0().xy);
        float4 lms = float4(dot(kRgbToL, frame.rgb), dot(kRgbToM, frame.rgb), dot(kRgbToS, frame.rgb), frame.a);
        float3 simulatedLms = mul(matColorTransform, lms).xyz;
        float3 simulated = float3(dot(kLmsToR, simulatedLms), dot(kLmsToG, simulatedLms), dot(kLmsToB, simulatedLms));
        float3 lost = frame.rgb - simulated;
        float3 shift = float3(0.0, lost.r * 0.7 + lost.g, lost.r * 0.7 + lost.b);
        return float4(saturate(frame.rgb + shift), 1.0);
    }
};

/// Frame blended towards its blurred copy by a per-pixel blur fraction map.
public struct BlurByFraction : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float fraction = texFrac.Sample(texFrac_s, i.texcoord2().xy).w;
        float4 blurred = texBlurred.Sample(texBlurred_s, i.texcoord1().xy);
        float4 frame = texOriginal.Sample(texOriginal_s, i.texcoord0().xy);
        return lerp(frame, blurred, fraction);
    }
};

/// Depth of field: the hardware depth linearised with `cameraParams`
/// (-x / (depth - y)), mapped between the near and far focus distances
/// `depthOfFieldParams.xy` and scaled by the strength `.z`, blends the frame
/// towards its blurred copy.
public struct DepthOfField : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float depth = texDepth.Sample(texDepth_s, i.texcoord1().xy).x;
        float viewDistance = -cameraParams.x / (depth - cameraParams.y);
        float focusRange = depthOfFieldParams.y - depthOfFieldParams.x;
        float blur = saturate((viewDistance - depthOfFieldParams.x) / focusRange) * depthOfFieldParams.z;
        float4 blurred = texBlurred.Sample(texBlurred_s, i.texcoord1().xy);
        float4 frame = texOriginal.Sample(texOriginal_s, i.texcoord0().xy);
        return lerp(frame, blurred, blur);
    }
};

/// Screen distortion: the frame re-sampled at an offset read from the
/// distortion buffer (mid-grey = none, full range = 3% of the screen).
public struct ScreenDistortion : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float2 bufferUv = ScreenUvViewportClamped.map(i.texcoord1().xy);
        float2 offset = texDistortion.Sample(texDistortion_s, bufferUv).xy * 2.0 - 1.0;
        float2 displaced = offset * 0.03 + i.texcoord0().xy;
        return texOriginal.Sample(texOriginal_s, ScreenUvViewportClamped.map(displaced));
    }
};

/// Stores the frame's luminance in alpha, the input FXAA expects.
public struct LumaToAlpha<TFrameUv : IPostFxScreenUv> : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 frame = texSampler0.Sample(texSampler0_s, TFrameUv.map(i.texcoord0().xy));
        return float4(frame.rgb, dot(frame.rgb, kPostFxLuma));
    }
};
