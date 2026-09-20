// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Screen-space filter passes (TextureFilter.fx).
//
// Every filter draws one quad whose vertices carry a packed screen coordinate.
// The vertex stage lays that coordinate out as four taps; the pixel stages of
// the individual filters read the taps they need. Retail ships three filter
// vertex programs (two of them identical) and, in this corpus, one filter
// pixel program: the selection-highlight outline.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// filter_vs
// ---------------------------------------------------------------------------

/// Where the four taps sit relative to the quad's screen coordinate.
public interface IFilterTaps
{
    static float4 taps01(float2 base);
    static float4 taps23(float2 base);
}

/// Taps offset by the pass's kernel: Constant0.xy/.zw and Constant1.xy/.zw.
public struct FilterTapsOffset : IFilterTaps
{
    public static float4 taps01(float2 base) { return base.xyxy + Constant0; }
    public static float4 taps23(float2 base) { return base.xyxy + Constant1; }
};

/// All four taps on the coordinate itself; the pixel stage spreads them.
public struct FilterTapsCentered : IFilterTaps
{
    public static float4 taps01(float2 base) { return base.xyxy; }
    public static float4 taps23(float2 base) { return base.xyxy; }
};

[shader("vertex")]
public D3Interpolants filter_vs_main<TTaps : IFilterTaps>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    o.setPosition(mul(matWorldViewProj, i.position()));
    o.setColor0(float4(i.color0().xyz, 0.0));
    float2 base = d3DecodeUv0(i.texcoord0Bits());
    float4 taps01 = TTaps.taps01(base);
    float4 taps23 = TTaps.taps23(base);
    o.setTexcoord0(float4(taps01.xy, 0.0, 0.0));
    o.setTexcoord1(float4(taps01.zw, 0.0, 0.0));
    o.setTexcoord2(float4(taps23.xy, 0.0, 0.0));
    o.setTexcoord3(float4(taps23.zw, 0.0, 0.0));
    return o;
}

// ---------------------------------------------------------------------------
// blur_ps: the selection-highlight outline
// ---------------------------------------------------------------------------

/// Luminance weights the outline's contrast curve preserves hue with.
static const float3 kHighlightLuma = float3(0.222, 0.707, 0.071);

/// The blurred highlight mask kept only outside the solid silhouette, alpha
/// and colour both pushed through a ^0.25 contrast curve.
[shader("fragment")]
public float4 blur_ps_main<TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float2 uv = i.texcoord0().xy * viewport.xz + viewport.yw;
    float4 original = texOriginalHighlight.Sample(texOriginalHighlight_s, uv);
    float4 blurred = texBlurredHighlight.Sample(texBlurredHighlight_s, uv);

    float alpha = pow(blurred.w, 0.25);
    if (original.w > 0.125)
        alpha = 0.0;
    TAlpha.apply(alpha);

    float luma = dot(blurred.xyz, kHighlightLuma);
    float3 rgb = blurred.xyz / luma * pow(luma, 0.25);
    return float4(rgb, alpha);
}
