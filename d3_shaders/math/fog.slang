// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Fog and user clip planes -- the per-vertex tail every Diablo III mesh vertex
// shader shares.
//
// The fog factor is written to the FOG0 interpolant: 1 is unfogged, 0 fully
// fogged. It is the smaller of a view-depth term and a height term measured
// from the player: `fogParams` holds (depth scale, depth bias, height scale,
// height bias).

implementing d3_shaders;

/// Combined depth + height fog factor for one vertex.
public float d3VertexFog(float clipZ, float worldZ)
{
    float depthFog = saturate(clipZ * fogParams.x + fogParams.y);
    float heightFog = 1.0 - saturate((worldZ - wpPlayer.z) * fogParams.z + fogParams.w);
    return min(heightFog, depthFog);
}

/// The fogged colour: `lerp(fogColor, color, fog)`.
public float3 d3ApplyFog(float3 color, float fog)
{
    return lerp(fogColor.rgb, color, fog);
}

/// Distances to the six user clip planes: planes 0-3 in SV_ClipDistance0,
/// planes 4-5 in SV_ClipDistance1.xy with .zw zero.
public void d3WriteClipPlanes(float4 clipPos, inout D3Interpolants o)
{
    o.setClip0(float4(dot(clipPos, vecClipPlane[0]), dot(clipPos, vecClipPlane[1]),
                      dot(clipPos, vecClipPlane[2]), dot(clipPos, vecClipPlane[3])));
    o.setClip1(float4(dot(clipPos, vecClipPlane[4]), dot(clipPos, vecClipPlane[5]), 0.0, 0.0));
}
