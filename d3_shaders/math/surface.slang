// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Shared geometry of the surface vertex shaders (scenery, terrain, water, fog
// planes): the transformed vertex, texture-coordinate generation and the
// view-space tangent frame deferred passes hand to their pixel shaders.

implementing d3_shaders;

/// A placed surface vertex in every space its shaders read.
public struct D3SurfaceVertex
{
    public float4 clip;
    public float4 world;
    public float4 view;
    /// Normalized view-space normal.
    public float3 viewNormal;
    /// World-space normal, not normalized.
    public float3 worldNormal;
};

public D3SurfaceVertex d3SurfaceVertex(D3SurfaceObject s)
{
    D3SurfaceVertex v;
    v.clip = mul(matWorldViewProj, s.position);
    v.world = mul(matWorld, s.position);
    v.view = mul(matWorldView, s.position);
    v.viewNormal = normalize(mul((float3x3)matWorldView, s.normal));
    v.worldNormal = mul((float3x3)matWorld, s.normal);
    return v;
}

/// A UBYTE direction stream rotated into view space and normalized.
public float3 d3ViewDirection(uint4 packed)
{
    return normalize(mul((float3x3)matWorldView, d3UnpackDirection(packed)));
}

/// A UV through all four rows of a texture matrix, each row's x, y and w
/// columns against (u, v, 1).
public float4 d3TexProject(float4 row0, float4 row1, float4 row2, float4 row3, float2 uv)
{
    float3 h = float3(uv, 1.0);
    return float4(dot(row0.xyw, h), dot(row1.xyw, h), dot(row2.xyw, h), dot(row3.xyw, h));
}

/// Mesh UV set 1 as a homogeneous coordinate (u, v, 0, 1).
public float4 d3DetailUv(D3VertexIn i)
{
    return float4(d3DecodeUv1(i.texcoord1Bits()), 0.0, 1.0);
}

/// The projected screen position nudged along the view normal: the lookup
/// coordinate of a reflection / environment map, before the divide by w.
public float2 d3ScreenReflection(float3 viewNormal, float4 clip)
{
    return (viewNormal.xy * clip.w + clip.xy + clip.w) * 0.5;
}

/// The reflection coordinate shifted by a texture matrix's translation column,
/// scaled by w so the shift survives the projective divide.
public float2 d3ScreenReflection(float3 viewNormal, float4 clip, float4 shiftRow0, float4 shiftRow1)
{
    return d3ScreenReflection(viewNormal, clip) + clip.w * float2(shiftRow0.w, shiftRow1.w);
}

/// Writes TEXCOORD<index>; the index is a specialization constant.
public void d3SetTexcoord(inout D3Interpolants o, int index, float4 value)
{
    switch (index)
    {
    case 0: o.setTexcoord0(value); break;
    case 1: o.setTexcoord1(value); break;
    case 2: o.setTexcoord2(value); break;
    case 3: o.setTexcoord3(value); break;
    case 4: o.setTexcoord4(value); break;
    case 5: o.setTexcoord5(value); break;
    case 6: o.setTexcoord6(value); break;
    case 7: o.setTexcoord7(value); break;
    case 8: o.setTexcoord8(value); break;
    case 9: o.setTexcoord9(value); break;
    case 10: o.setTexcoord10(value); break;
    case 11: o.setTexcoord11(value); break;
    case 12: o.setTexcoord12(value); break;
    case 13: o.setTexcoord13(value); break;
    default: break;
    }
}

/// The deferred-lighting tangent frame, in five consecutive texture
/// coordinates starting at `first`: view position, view normal, tangent,
/// binormal, and the vertex colour with the given alpha.
public void d3WriteTangentFrame(inout D3Interpolants o, int first, D3VertexIn i, D3SurfaceVertex v, float alpha)
{
    d3SetTexcoord(o, first, v.view);
    d3SetTexcoord(o, first + 1, float4(v.viewNormal, 0.0));
    d3SetTexcoord(o, first + 2, float4(d3ViewDirection(i.tangentBits()), 0.0));
    d3SetTexcoord(o, first + 3, float4(d3ViewDirection(i.binormalBits()), 0.0));
    d3SetTexcoord(o, first + 4, float4(i.color0().xyz, alpha));
}
