// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Cliff / blight / misc-terrain vertex shader — Warcraft III Reforged 3.0.0.
//
// One permutation, new coverage. It is terrain's vertex body on foliage's
// vertex stream and payload: HD's vertex banks (hdVsCB1 / hdVsCB2), the eight
// HD attribute slots, and foliage's seven-slot output -- no splat layer indices,
// so no TEXCOORD8 and no cull sentinel. Three details differ from terrain and
// were read off the shipped bytecode:
//
//   * the vertex colour MODULATES the diffuse tint (terrain's replaces it);
//   * the normal bend has no saturate: z' = z * (z^8 - z) + z, so downward
//     faces bend too;
//   * the tangent's w is passed through raw, as terrain's is (foliage takes
//     its sign).

implementing wc3_shaders;

[shader("vertex")]
public FoliageVSOutput cliff_vs_main(FoliageVSInput input)
{
    FoliageVSOutput output;

    output.position = transformClipPos(input.position, hdVsCB2.worldViewProj);
    output.color = input.vertColor * hdVsCB2.diffuseColor;

    float4 worldPos = computeWorldPos4(input.position, hdVsCB2.world);
    output.worldPos = worldPos;
    output.texCoord = float4(input.uv0, blightMapUV(worldPos.xy, hdVsCB1.rect));

    output.viewPos = float4(transformByWorldView(input.position, hdVsCB2.worldView), 0);
    output.tangentVS = float4(transformNormalRaw(input.tangent.xyz, hdVsCB2.worldView),
                              input.tangent.w);
    output.normalVS = transformNormalRaw(bendTerrainNormal<false>(input.normal),
                                         hdVsCB2.worldView);
    return output;
}
