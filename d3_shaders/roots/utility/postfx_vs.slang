// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Vertex stages of the full-screen passes that do not use TextureFilter.fx's
// quad: the FXAA quad (FSAA.fx, FSAA_AMD.fx) and the minimap (Minimap.fx).
// Both project the quad with matWorldViewProj; the policy lays out the
// coordinates their pixel stages read.

implementing d3_shaders;

public interface IPostFxVertex
{
    static void layout(D3VertexIn i, float4 clipPos, inout D3Interpolants o);
}

[shader("vertex")]
public D3Interpolants postfx_vs_main<TLayout : IPostFxVertex>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    float4 clipPos = mul(matWorldViewProj, i.position());
    o.setPosition(clipPos);
    TLayout.layout(i, clipPos, o);
    return o;
}

/// FXAA quad: the packed screen coordinate through matTex0 (TEXCOORD0), and
/// offset by the kernel in Constant0.zw (TEXCOORD1), Constant1.xy
/// (TEXCOORD2) and Constant1.zw (TEXCOORD3).
public struct FsaaQuadTaps : IPostFxVertex
{
    public static void layout(D3VertexIn i, float4 clipPos, inout D3Interpolants o)
    {
        o.setColor0(float4(i.color0().xyz, 0.0));
        float2 base = d3DecodeUv0(i.texcoord0Bits());
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], base), 0.0, 0.0));
        o.setTexcoord1(float4(base + Constant0.zw, 0.0, 0.0));
        float4 taps = base.xyxy + Constant1;
        o.setTexcoord2(float4(taps.xy, 0.0, 0.0));
        o.setTexcoord3(float4(taps.zw, 0.0, 0.0));
    }
};

/// Minimap: vertex colour, the map / frame-mask / explored layers each through
/// its own texture matrix (matTex0..2), and the user clip planes.
public struct MinimapLayers : IPostFxVertex
{
    public static void layout(D3VertexIn i, float4 clipPos, inout D3Interpolants o)
    {
        o.setColor0(i.color0());
        o.setTexcoord0(mul(matTex0, i.texcoord0()));
        o.setTexcoord1(mul(matTex1, i.texcoord1()));
        o.setTexcoord2(mul(matTex2, i.texcoord2()));
        d3WriteClipPlanes(clipPos, o);
    }
};
