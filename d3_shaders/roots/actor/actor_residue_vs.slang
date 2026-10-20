// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Further actor vertex models of actor_vs_main (roots/actor/actor_vs.slang)
// for material variants outside the Actor.fx / ActorIrrad.fx permutation sets.

implementing d3_shaders;

/// The Actor.fx four-layer texture set (matTex0..3 over UV sets 0, 0, 0 and 1)
/// with the irradiance pass's colour: the diffuse light only, scaled by
/// MeshLighting intensity and weight and halved, under the vertex alpha, and
/// the irradiance-volume normal beside it.
public struct IrradianceLayeredVertex : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        D3IrradianceBasis b = d3IrradianceBasis(v.position, v.normal);
        D3ActorLight light = LightDiffuse.evaluate(i, b.viewPos, b.viewNormal);

        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());
        float2 uv1 = d3DecodeUv1(i.texcoord1Bits());

        o.setPosition(b.clipPos);
        o.setColor0(float4(light.diffuse * MeshLighting.x * MeshLighting.w * 0.5, i.color0().w));
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], uv0), 0.0, 0.0));
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], uv0), 0.0, 0.0));
        o.setTexcoord2(float4(d3TexTransform(matTex2[0], matTex2[1], uv0), 0.0, 0.0));
        o.setTexcoord3(float4(d3TexTransform(matTex3[0], matTex3[1], uv1), 0.0, 0.0));
        o.setTexcoord4(b.irradianceNormal);
        o.setFog(float4(b.fog, 0.0, 0.0, 0.0));
        d3WriteClipPlanes(b.clipPos, o);
    }
};
