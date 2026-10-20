// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Further mesh shading models of the surface vertex root
// (roots/surface/surface_vs.slang) for material variants outside the Prop.fx /
// Scene.fx permutation sets.

implementing d3_shaders;

/// No vertex colour terms at all: every colour interpolant stays zero (a
/// gloss-only pass whose pixel shader takes nothing from the vertex).
public struct ShadingNone : IMeshShading
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o) {}
};

/// A deformation test view: the vertex lighting of VertexLit (without spot or
/// gloss lights) in the texture interpolants, while COLOR0 shows the sway
/// vector stream (COLOR1.xyz) under the material alpha and COLOR1 is dark.
public struct VertexLitSwayProbe<TAlpha : IVertexAlpha> : IMeshShading
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        D3SurfaceLighting light = SurfaceLightRig<false, false>.evaluate(v.view.xyz, v.viewNormal);
        float3 color = i.color0().xyz;
        o.setColor0(float4(i.color1().xyz, TAlpha.alpha(i, v)));
        o.setColor1(float4(0.0, 0.0, 0.0, 0.0));
        o.setTexcoord0(float4(color * 2.0 + light.ambient, 0.0));
        o.setTexcoord1(float4(light.sunDiffuse, 0.0));
    }
};
