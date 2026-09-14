// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Small full-screen passes — Warcraft III Reforged 3.0.0.
//
// New coverage (P13): five single-permutation pixel shaders that 3.0.0 ships
// and 2.0.0 did not, each a handful of instructions over a full-screen
// triangle (SV_Position + TEXCOORD0, the sprite payload):
//
//   greyscale_ps        desaturate by a quarter, then darken to a quarter
//   ssaa_ps             four-tap supersample resolve
//   foliagepush_ps      the radial falloff splat that stamps the foliage
//                       push field `foliage_vs` bends grass by
//   debugtexture_ps     one slice of a texture array, inverted, for debugging
//   waterdepthbounds_ps the min / max depth over each output texel's source
//                       rectangle -- the tile bounds `water_ps`'s screen-space
//                       reflection march walks (shipped as waterreflection.bls)

implementing wc3_shaders;

// ---------------------------------------------------------------------------
// greyscale.bls
// ---------------------------------------------------------------------------

static const float3 GREYSCALE_LUMA = float3(0.298999995, 0.587000012, 0.114);

[shader("fragment")]
public float4 greyscale_ps_main(SpritePSInput input) : SV_Target0
{
    float4 c = t_screenSource.Sample(s_screenSource, input.uv);
    float luma = dot(c.xyz, GREYSCALE_LUMA);
    float3 grey = (luma - c.xyz) * 0.25 + c.xyz;
    return float4(grey * 0.25, c.w);
}

// ---------------------------------------------------------------------------
// ssaa.bls
// ---------------------------------------------------------------------------

[shader("fragment")]
public float4 ssaa_ps_main(SpritePSInput input) : SV_Target0
{
    // A quarter of the source texel step, scaled by the supersample factor.
    float2 step = screenPassPsCB2.params.xy * screenPassPsCB2.params.z;
    float2 q = step * 0.25;
    float4 a = t_screenSource.Sample(s_screenSource, float2(q.x, -q.y) + input.uv);
    float4 b = t_screenSource.Sample(s_screenSource, float2(-q.x, q.y) + input.uv);
    float4 c = t_screenSource.Sample(s_screenSource, step * 0.25 + input.uv);
    float4 d = t_screenSource.Sample(s_screenSource, -step * 0.25 + input.uv);
    return (c + (b + (a + d))) * 0.25;
}

// ---------------------------------------------------------------------------
// foliagepush.bls
// ---------------------------------------------------------------------------

[shader("fragment")]
public float4 foliagepush_ps_main(SpritePSInput input) : SV_Target0
{
    float2 d = input.uv + float2(-0.5, -0.5);
    float falloff = max(-sqrt(dot(d, d)) * 2.0 + 1.0, 0.0);
    return float4((falloff * falloff) * screenPassPsCB2.params.xxx, 1.0);
}

// ---------------------------------------------------------------------------
// debugtexture.bls
// ---------------------------------------------------------------------------

[shader("fragment")]
public float4 debugtexture_ps_main(SpritePSInput input) : SV_Target0
{
    float v = t_screenSourceArray.Sample(s_screenSource,
                                         float3(input.uv, screenPassPsCB2.params.x)).x;
    return float4(float3(1, 1, 1) - v, 1.0);
}

// ---------------------------------------------------------------------------
// waterreflection.bls -- the depth bounds of each tile
// ---------------------------------------------------------------------------

// For the output texel at `svPosition`, the source rectangle is
// [floor(p * scale * dims), ceil((p + 1) * scale * dims)), where `scale` is the
// output-to-source texel ratio in cb3[0].zw. The bounds start inverted
// (1e6, 0) so an empty rectangle writes them unchanged.
[shader("fragment")]
public float2 waterdepthbounds_ps_main(SpritePSInput input) : SV_Target0
{
    uint w, h, mips;
    t_screenSource.GetDimensions(0, w, h, mips);
    float2 p = floor(input.svPosition.xy);
    float2 dims = (float2)uint2(w, h);
    int2 lo = int2(floor(dims * (screenPassPsCB3.scale.zw * p)));
    int2 hi = int2(ceil(dims * (screenPassPsCB3.scale.zw * (p + 1.0))));
    int2 maxTexel = int2(w, h) - int2(1, 1);

    float2 bounds = float2(1000000.0, 0.0);
    for (int y = lo.y; y < hi.y; y++)
    {
        for (int x = lo.x; x < hi.x; x++)
        {
            int2 texel = min(maxTexel, max(int2(x, y), int2(0, 0)));
            float d = t_screenSource.Load(int3(texel, 0)).x;
            bounds = float2(min(d, bounds.x), max(d, bounds.y));
        }
    }
    return bounds;
}
