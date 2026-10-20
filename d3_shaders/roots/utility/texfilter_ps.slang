// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Screen-space colour passes of TextureFilter.fx (and the engine's untitled
// resolve/blur passes built the same way): one full-screen quad, the frame or
// an intermediate target read back through the taps texfilter_vs / filter_vs
// laid out, one colour written.
//
// The root is generic over the filter -- what the pass computes from its
// inputs -- and the alpha test applied to the result. The filters live by kind:
//   texfilter_copy.slang   copies, resolves, fixed tap mixes and tone curves
//   texfilter_blur.slang   kernels over neighbouring texels
//   texfilter_scene.slang  passes that rebuild view-space geometry from depth
//
// Many passes address the screen through `viewport`: a [0, 1] coordinate is
// mapped into the viewport's rectangle of the (larger) render target, and
// every offset tap is clamped back inside it so a filter never reads past the
// viewport's edge.

implementing d3_shaders;

public interface ITexFilter
{
    static float4 shade(D3Interpolants i);
}

/// A [0, 1] screen coordinate in the viewport's rectangle of its target.
public float2 d3ViewportUv(float2 uv)
{
    return uv * viewport.xz + viewport.yw;
}

/// The last coordinate still inside the viewport (1e-5 short of its far edge).
public float2 d3ViewportLimit()
{
    return viewport.yw + viewport.xz + -0.00001;
}

/// A viewport coordinate clamped into the viewport.
public float2 d3ViewportClamp(float2 uv)
{
    return max(min(d3ViewportLimit(), uv), viewport.yw);
}

[shader("fragment")]
public float4 texfilter_ps_main<TFilter : ITexFilter, TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float4 color = TFilter.shade(i);
    TAlpha.apply(color.w);
    return color;
}
