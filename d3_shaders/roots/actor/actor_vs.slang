// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Actor vertex shaders: characters, monsters, cloth and banners
// (Actor.fx, ActorIrrad.fx, banner.fx).
//
// Every actor vertex program is the same pipeline -- skin, transform, light,
// lay out texture coordinates, fog, clip planes -- and differs in which
// lighting and which interpolants its shading model hands the pixel stage.
// The skinned object frame (IFrameSkin) and the shading model are the two
// policies the root is generic over. Fog is written whenever the slot's
// interpolant layout declares FOG0.

implementing d3_shaders;

public interface IActorVertexModel
{
    static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o);
}

/// Actor.fx: per-vertex lighting from the primary point light, the linear
/// point lights and one cylindrical light, over four texture stages.
///
/// GLOW is the additive glow pass: vertex alpha fades out as the vertex nears
/// the player, and the second stage reads UV set 1 instead of UV set 0.
public struct ActorVertexLit<let GLOW : bool> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        float3 viewPos = mul(matWorldView, v.position).xyz;
        float3 viewNormal = normalize(mul((float3x3)matWorldView, v.normal));

        D3VertexLight light;
        d3AddPrimaryPointLight(viewPos, viewNormal, light);
        d3AddLinearPointLights(viewPos, viewNormal, light);
        d3AddCylindricalLight(viewPos, viewNormal, light);

        float alpha = 1.0;
        if (GLOW)
        {
            float2 toPlayer = mul(matWorld, v.position).xy - wpPlayer.xy;
            alpha = (1.0 - saturate((length(toPlayer) - 10.0) * 0.2)) * wpPlayer.w;
        }

        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());
        float2 uv1 = d3DecodeUv1(i.texcoord1Bits());

        o.setPosition(clipPos);
        o.setColor0(float4(light.ambient + light.diffuse, alpha));
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], uv0), 0.0, 0.0));
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], GLOW ? uv1 : uv0), 0.0, 0.0));
        o.setTexcoord2(float4(d3TexTransform(matTex2[0], matTex2[1], uv0), 0.0, 0.0));
        o.setTexcoord3(float4(d3TexTransform(matTex3[0], matTex3[1], uv1), 0.0, 0.0));
        o.setFog(float4(d3VertexFog(clipPos.z, mul(matWorld, v.position).z), 0.0, 0.0, 0.0));
        d3WriteClipPlanes(clipPos, o);
    }
};

[shader("vertex")]
public D3Interpolants actor_vs_main<TSkin : IFrameSkin, TModel : IActorVertexModel>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    TModel.shade(i, TSkin.apply(i), o);
    return o;
}
