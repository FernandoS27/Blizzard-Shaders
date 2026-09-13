// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Vertex-shader helpers specific to the 3.0.0 HD mesh pipeline. The generic
// transform helpers it builds on live in vs/vs_body.slang; what is here is the
// handful of steps 3.0.0 does differently from every other vertex stage.

implementing wc3_shaders;

// UV transform for the HD mesh shader.
//
// Differs from `transformUVs` in exactly one place: the one-stream case. 2.0.0
// left `.zw` at zero there, 3.0.0 repeats `.xy` into it, because the pixel
// shader reads UV1 unconditionally — the ambient-occlusion map is sampled at
// `uv.zw` whether or not the mesh actually carries a second stream, and a
// zeroed pair would pin every AO fetch to the texture's corner texel.
public float4 transformMeshUVs<TVF : IVertexFormat>(
    float2 uv0, float2 uv1,
    float4 mtx0Row0, float4 mtx0Row1,
    float4 mtx1Row0, float4 mtx1Row1)
{
    if (!TVF.hasUV0)
        return float4(0, 0, 0, 0);

    float2 t0 = transformUV(uv0, mtx0Row0, mtx0Row1);
    if (TVF.hasUV1)
        return float4(t0, transformUV(uv1, mtx1Row0, mtx1Row1));
    return float4(t0, t0);
}

// Signed height of the vertex above the water clip plane, travelling on
// TEXCOORD1.w. The pixel shader discards on it, so `underWater` flips the sign
// to swap which side of the plane survives; it is zero when the draw is not
// clipped at all, which keeps every fragment on the "visible" side.
//
// Same arithmetic as 2.0.0's `computeFogDepth`, under the name that describes
// what 3.0.0 actually uses it for — the fog depth now rides on TEXCOORD1.z as
// an ordinary view-space Z.
public float computeWaterClipDistance(float worldZ, float clipHeight, float underWater)
{
    return (worldZ - clipHeight) * underWater;
}

// Blight-map lookup: the world XY placed against the blight rect and clamped
// into it. The saturate is the engine's, not a convenience — terrain outside
// the blighted region samples the rect's border and so reads "unblighted".
public float2 blightMapUV(float2 worldXY, float4 rect)
{
    return saturate((worldXY - rect.xy) * rect.zw);
}
