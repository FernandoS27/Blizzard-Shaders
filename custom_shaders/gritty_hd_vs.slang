// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Gritty-HD vertex shader entry point.
//
// Produces the same VSOutput as hd_vs.slang — view-space position /
// normal / tangent, shadow cascade clip coords, UV transforms — so the
// gritty pixel shader (gritty_hd_ps) can consume identical interpolants.
// The body is a passthrough of the HD VS math; a dedicated entry point
// is kept so the BLS bundle can ship VS+PS together as `gritty_hd.bls`
// and so future gritty-only VS work (e.g. distance-based dust falloff)
// has a place to live.
//
// Specialisation space is identical to hd_vs:
//   TSkin         — ISkinning policy (rigid or four-bone).
//   TVF           — IVertexFormat (which optional attribs are live).
//   HAS_SHADOWS   — whether the three cascade clip coords need computing.

implementing custom_shaders;

[shader("vertex")]
public VSOutput<HAS_SHADOWS> gritty_vs_main<
    TSkin : ISkinning,
    TVF   : IVertexFormat,
    let HAS_SHADOWS : bool
>(VSInput<TVF> input)
{
    VSOutput<HAS_SHADOWS> output;

    float3 skinnedPos, skinnedNormal, skinnedTangent;
    TSkin.transform(
        input.position, input.normal, input.tangent,
        input.weights, input.boneIndices, vsCB3,
        skinnedPos, skinnedNormal, skinnedTangent);

    output.worldPos.xyz = transformByWorldView(skinnedPos, vsCB2.worldView);
    output.position     = transformClipPos(skinnedPos, vsCB2.worldViewProj);

    output.normalWS = transformNormal(skinnedNormal, vsCB2.worldView);

    if (TVF.hasTangent)
    {
        output.tangentWS.xyz = transformNormal(skinnedTangent, vsCB2.worldView);
        output.tangentWS.w = input.tangent.w;
    }
    else
    {
        output.tangentWS = float4(0, 0, 0, 0);
    }

    if (HAS_SHADOWS)
    {
        float4 worldPos4 = computeWorldPos4(skinnedPos, vsCB2.world);
        output.worldPos.w = computeFogDepth(worldPos4.z, vsCB2.clipHeight, vsCB2.underWater);

        float4 sc0, sc1, sc2;
        computeShadowCascades(worldPos4, vsCB1, sc0, sc1, sc2);
        output.shadowClip0 = sc0;
        output.shadowClip1 = sc1;
        output.shadowClip2 = sc2;
    }
    else
    {
        float worldZ = computeScalarWorldZ(skinnedPos, vsCB2.world);
        output.worldPos.w = computeFogDepth(worldZ, vsCB2.clipHeight, vsCB2.underWater);

        output.shadowClip0 = float4(0, 0, 0, 0);
        output.shadowClip1 = float4(0, 0, 0, 0);
        output.shadowClip2 = float4(0, 0, 0, 0);
    }

    if (TVF.hasVertexColor)
        output.color = vsCB2.diffuseColor * input.vertColor;
    else
        output.color = vsCB2.diffuseColor;

    output.texCoord = transformUVs<TVF>(
        input.uv0, input.uv1,
        vsCB2.texMtx0Row0, vsCB2.texMtx0Row1,
        vsCB2.texMtx1Row0, vsCB2.texMtx1Row1);

    return output;
}
