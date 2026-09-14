// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Terrain vertex shader body — Warcraft III Reforged 3.0.0.
//
// 3.0.0 moved terrain onto the HD mesh's vertex banks, as it did foliage:
// `hdVsCB1` (the blight rect) and `hdVsCB2` (world / worldView /
// worldViewProj and the diffuse tint) at HD's offsets. The cascade outputs are
// gone -- the pixel shader reprojects the world position -- and with them the
// SHADOW_PASS and RECEIVE_SHADOWS bits, leaving one axis: VERTEX_COLOR.
//
// Two things terrain does that no other stage does:
//
//   * a cell whose four splat layer slots are ALL empty (0xFFFF) is culled by
//     parking its vertex at clip z = -2, behind the near plane, rather than by
//     any index-buffer work;
//   * the object normal is BENT toward +Z before it is transformed:
//     z' = saturate(z) * (z^8 - z) + z, then renormalised. Upward-facing ground
//     keeps its slope shading while steep faces flatten less. The result is
//     not renormalised again after the worldView rotation.

implementing wc3_shaders;

static const uint TERRAIN_NO_LAYER_VS = 0xFFFF;

// Where an all-empty cell's vertices go: behind the near plane.
static const float4 TERRAIN_CULLED_POSITION = float4(0, 0, -2, 1);

// The terrain normal bend. Zero at z == 0 and z == 1, so flat ground and
// vertical cliffs are untouched and only the slopes between them tilt.
// `cliffblightmiscterrain_vs` bends without the saturate, so downward-facing
// geometry bends too.
public float3 bendTerrainNormal<let CLAMP_Z : bool>(float3 n)
{
    float z2 = n.z * n.z;
    float z4 = z2 * z2;
    float weight = CLAMP_Z ? saturate(n.z) : n.z;
    float bentZ = weight * (z4 * z4 - n.z) + n.z;
    return normalize(float3(n.xy, bentZ));
}

public TerrainVSOutput terrainVSBody<let HAS_VERTEX_COLOR : bool>(TerrainVSInput input)
{
    TerrainVSOutput output;

    output.layers = input.layers;

    float4 clip = transformClipPos(input.position, hdVsCB2.worldViewProj);
    bool empty = all(input.layers == uint4(TERRAIN_NO_LAYER_VS, TERRAIN_NO_LAYER_VS,
                                           TERRAIN_NO_LAYER_VS, TERRAIN_NO_LAYER_VS));
    output.position = empty ? TERRAIN_CULLED_POSITION : clip;

    // The vertex colour REPLACES the tint rather than modulating it.
    output.color = HAS_VERTEX_COLOR ? input.vertColor : hdVsCB2.diffuseColor;

    float4 worldPos = computeWorldPos4(input.position, hdVsCB2.world);
    output.worldPos = worldPos;
    output.texCoord = float4(input.uv0, blightMapUV(worldPos.xy, hdVsCB1.rect));

    output.viewPos = float4(transformByWorldView(input.position, hdVsCB2.worldView), 0);
    output.tangentVS = float4(transformNormalRaw(input.tangent.xyz, hdVsCB2.worldView),
                              input.tangent.w);
    output.normalVS = transformNormalRaw(bendTerrainNormal<true>(input.normal),
                                         hdVsCB2.worldView);
    return output;
}
