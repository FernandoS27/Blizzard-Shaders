// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Terrain pixel shader entry point — Warcraft III Reforged 3.0.0.
//
// 3.0.0 moved terrain onto the HD mesh's banks, the same move foliage made:
// cb1[43] / cb2[31], the t6 / t8 blight pair, the t11 / t12 / t13 IBL set and
// the t16 / t17 / t18 clustered-light buffers. What is terrain's own is the
// splat material -- t0 / t1 / t2 as TEXTURE ARRAYS, one slice per ground
// layer, picked per cell by the four flat-interpolated indices the vertex
// shader passes on TEXCOORD8.
//
// Its 128 permutations are foliage's mask with the ALPHA_TEST bit dead (the
// cut-out is unconditional, see below), folded by HD's rules into retail's 25
// programs:
//
//   bit 0 (  1)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2
//   bit 1 (  2)  MULTI_TARGET    -> WC3_IS_MRT (a define: it reshapes PSOutput)
//   bit 2 (  4)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS (likewise)
//   bit 3 (  8)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 4 ( 16)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 5 ( 32)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   bit 6 ( 64)  dead
//
// The shading is HD's main light (with foliage's 0.4 irradiance normalisation)
// and HD's clustered loop, called rather than restated. Checked in the
// bytecode, and just as much a part of it:
//
//   * up to four layers are blended in index order, each weighted by its own
//     albedo alpha times the vertex alpha: albedo and roughness / metal lerp,
//     the tangent-space normal lerps and renormalises from (0, 0, 1);
//   * a cell whose most opaque layer is under 0.8 is DISCARDED -- in every
//     permutation, the depth prepass included, which is why there is no alpha
//     test axis;
//   * the vertex colour tints the ALBEDO, before lighting, not the result;
//   * no specular anti-aliasing, no emissive, no fog, no depth test, no clip;
//   * foliage's blight darkening, then a fixed 3x3 colour grade, alpha 1.

implementing wc3_shaders;

static const uint  TERRAIN_NO_LAYER = 0xFFFF;
static const uint  TERRAIN_LAYERS = 4;
// A cell whose most opaque layer is below this is a hole in the ground.
static const float TERRAIN_COVERAGE_CUTOFF = 0.800000012;
static const float TERRAIN_IRRADIANCE_MAX_SCALE = 0.400000006;

struct TerrainSplat
{
    float3 albedo;
    float3 normalTS;
    float2 roughMetal;
    float  coverage;    // the most opaque layer's albedo alpha
};

// Blend the cell's layers. Each present layer lerps the running result toward
// itself by its own opacity times the vertex alpha, so later layers paint over
// earlier ones; an absent slot (0xFFFF) is skipped, not blended at zero.
//
// Takes the layer indices and UV rather than the TerrainPSInput: passing the
// struct makes slang emit an internal copy of it for WGSL that keeps the
// `@interpolate(flat)` of the uint4 without a `@location`, which naga rejects
// ("input/output binding is not consistent") on every permutation.
TerrainSplat sampleTerrainSplat(uint4 layers, float2 uv, float vertAlpha)
{
    TerrainSplat s;
    s.albedo = float3(0, 0, 0);
    s.normalTS = float3(0, 0, 1);
    s.roughMetal = float2(0, 0);
    s.coverage = 0;

    for (uint k = 0; k < TERRAIN_LAYERS; ++k)
    {
        if (layers[k] == TERRAIN_NO_LAYER)
            continue;
        float3 uvw = float3(uv, (float)layers[k]);
        float4 albedo = t_terrainAlbedo.Sample(s_terrainAlbedo, uvw);
        float3 n = decodeNormalMap(t_terrainNormal.Sample(s_terrainNormal, uvw).xyw);
        float2 rm = t_terrainOrm.Sample(s_terrainOrm, uvw).yz;

        float w = vertAlpha * albedo.w;
        s.albedo = w * (albedo.xyz - s.albedo) + s.albedo;
        s.coverage = max(albedo.w, s.coverage);
        s.normalTS = normalize(w * (n - s.normalTS) + s.normalTS);
        s.roughMetal = w * (rm - s.roughMetal) + s.roughMetal;
    }
    return s;
}

// The same walk for the depth prepass, which needs only the coverage.
float terrainCoverage(uint4 layers, float2 uv)
{
    float coverage = 0;
    for (uint k = 0; k < TERRAIN_LAYERS; ++k)
    {
        if (layers[k] == TERRAIN_NO_LAYER)
            continue;
        float3 uvw = float3(uv, (float)layers[k]);
        coverage = max(t_terrainAlbedo.Sample(s_terrainAlbedo, uvw).w, coverage);
    }
    return coverage;
}

[shader("fragment")]
public PSOutput terrain_ps_main<
    let HAS_SHADOW_CASCADE  : bool,
    let HAS_SHADOW_CASCADE2 : bool,
    let HAS_POINT_SHADOWS   : bool,
    let HAS_LIGHT_DEBUG     : bool
>(TerrainPSInput input, uint frontFace : SV_IsFrontFace)
{
    PSOutput output;

#if WC3_IS_DEPTH_PREPASS
    {
        if (terrainCoverage(input.layers, input.uv.xy) - TERRAIN_COVERAGE_CUTOFF < 0)
            discard;
        return output;
    }
#else
    {

    TerrainSplat splat = sampleTerrainSplat(input.layers, input.uv.xy, input.vertColor.w);
    if (splat.coverage - TERRAIN_COVERAGE_CUTOFF < 0)
        discard;

    float3 N = tangentToWorld(splat.normalTS, input.tangentVS.xyz, input.normalVS,
                              input.tangentVS.w);
    float3 albedo = srgbToLinear(input.vertColor.xyz) * splat.albedo;
    float3 V = normalize(-input.viewPos.xyz);

    float roughness = saturate(splat.roughMetal.x) * HD_ROUGHNESS_SCALE
                    + HD_ROUGHNESS_BIAS;
    HDSurface surf = hdSurfaceFromRough(N, V, albedo, splat.roughMetal.y, roughness);

    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadow<HAS_SHADOW_CASCADE2>(input.worldPos);

    float3 lit = float3(0, 0, 0);
    if (asint(hdPsCB2.mainLightEnable) != 0)
        lit = hdMainLightIrr(surf, input.viewPos.xyz, mainShadow,
                             TERRAIN_IRRADIANCE_MAX_SCALE);

    lit = hdClusterLights<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG>(
        surf, input.viewPos.xyz, input.worldPos.xyz, input.svPosition.xy, lit);

    float3 rgb = hdApplyBlightFade(PI * lit, input.uv.zw);

    output.color = float4(hdTerrainColorGrade(rgb), 1);

#if WC3_IS_MRT
    {
        output.specular = float4(input.viewPos.z, 0, 0, 1);
        output.normal = float4(N * HD_NORMAL_PACK + HD_NORMAL_PACK, 1);
    }
#endif

    return output;

    }
#endif
}
