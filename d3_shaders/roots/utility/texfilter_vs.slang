// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Full-screen quads of the TextureFilter.fx passes that filter_vs does not
// cover: the depth copies and MSAA resolves, the letterbox bars and the gamma
// correction pass.
//
// Every quad vertex carries the packed screen coordinate of mesh UV set 0.
// The passes differ in where the quad is placed (projected by the pass's
// matrix, projected but pinned to the far plane, or already in clip space) and
// in how the coordinate is handed on (the four filter taps, or one coordinate,
// homogeneous or plain).

implementing d3_shaders;

/// Where the quad lands in clip space.
public interface IQuadPlacement
{
    static float4 place(D3VertexIn i);
}

/// Projected by the pass's world-view-projection.
public struct QuadProjected : IQuadPlacement
{
    public static float4 place(D3VertexIn i) { return mul(matWorldViewProj, i.position()); }
};

/// Projected in x and y only; z and w pinned to 1 so the quad sits on the far
/// plane whatever the matrix says.
public struct QuadFarPlane : IQuadPlacement
{
    public static float4 place(D3VertexIn i)
    {
        float4 projected = mul(matWorldViewProj, i.position());
        return float4(projected.xy, 1.0, 1.0);
    }
};

/// The stream position is already the clip-space corner (z 0, w 1).
public struct QuadClipSpace : IQuadPlacement
{
    public static float4 place(D3VertexIn i) { return float4(i.position().xy, 0.0, 1.0); }
};

/// How the screen coordinate reaches the pixel stage.
public interface IQuadCoords
{
    static void write(float2 base, inout D3Interpolants o);
}

/// The four filter taps, laid out as filter_vs lays them.
public struct CoordsTaps<TTaps : IFilterTaps> : IQuadCoords
{
    public static void write(float2 base, inout D3Interpolants o)
    {
        float4 taps01 = TTaps.taps01(base);
        float4 taps23 = TTaps.taps23(base);
        o.setTexcoord0(float4(taps01.xy, 0.0, 0.0));
        o.setTexcoord1(float4(taps01.zw, 0.0, 0.0));
        o.setTexcoord2(float4(taps23.xy, 0.0, 0.0));
        o.setTexcoord3(float4(taps23.zw, 0.0, 0.0));
    }
};

/// One coordinate as a homogeneous point (w = 1).
public struct CoordsHomogeneous : IQuadCoords
{
    public static void write(float2 base, inout D3Interpolants o)
    {
        o.setTexcoord0(float4(base, 0.0, 1.0));
    }
};

[shader("vertex")]
public D3Interpolants texfilter_vs_main<TPlacement : IQuadPlacement, TCoords : IQuadCoords>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    o.setPosition(TPlacement.place(i));
    o.setColor0(float4(i.color0().xyz, 0.0));
    TCoords.write(d3DecodeUv0(i.texcoord0Bits()), o);
    return o;
}
