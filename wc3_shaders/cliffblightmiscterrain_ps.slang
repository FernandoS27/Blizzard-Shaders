// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Cliff / blight / misc-terrain pixel shader — Warcraft III Reforged 3.0.0.
//
// New coverage: 2.0.0 shipped no such family. It draws the terrain geometry that
// is not splat ground -- cliffs, blight doodads, ramps -- with a single material
// set rather than terrain's four array layers, and it sits squarely between the
// two families ported before it: foliage's material path on HD's banks, plus
// terrain's coverage cut-out and colour grade.
//
// 256 permutations on terrain's mask with one bit on top, folded by HD's rules to
// 50 programs:
//
//   bit 0 (  1)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2
//   bit 1 (  2)  MULTI_TARGET    -> WC3_IS_MRT (a define: it reshapes PSOutput)
//   bit 2 (  4)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS (likewise)
//   bit 3 (  8)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 4 ( 16)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 5 ( 32)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   bit 6 ( 64)  dead
//   bit 7 (128)  ALPHA_TEST      -> TAlpha
//
// Checked in the bytecode against foliage and terrain:
//
//   * HD's t0-t2 material taps, a RAW normal decode, specular AA, the main
//     light with the 0.4 irradiance normalisation, HD's cluster loop, and the
//     blight fade -- all as foliage;
//   * the albedo-alpha 0.8 coverage cut-out and the final colour grade -- as
//     terrain, but over one albedo rather than four layers;
//   * the normal IS flipped for back faces (foliage's is not), there is no
//     vertex tint at all (terrain tints the albedo, foliage the result), and no
//     emissive;
//   * alpha is vertex alpha times albedo alpha (terrain writes 1), and the alpha
//     test discards on it after everything else.

implementing wc3_shaders;

// A texel whose albedo alpha is below this is a hole in the geometry.
static const float CLIFF_COVERAGE_CUTOFF = 0.800000012;
static const float CLIFF_IRRADIANCE_MAX_SCALE = 0.400000006;

[shader("fragment")]
public PSOutput cliff_ps_main<
    TAlpha : IAlphaTest,
    let HAS_SHADOW_CASCADE  : bool,
    let HAS_SHADOW_CASCADE2 : bool,
    let HAS_POINT_SHADOWS   : bool,
    let HAS_LIGHT_DEBUG     : bool
>(FoliagePSInput input, uint frontFace : SV_IsFrontFace)
{
    PSOutput output;

#if WC3_IS_DEPTH_PREPASS
    {
        float albedoA = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy).w;
        TAlpha.test(input.vertColor.w * albedoA, hdPsCB2.alphaRef);
        if (albedoA - CLIFF_COVERAGE_CUTOFF < 0)
            discard;
        return output;
    }
#else
    {

    float4 albedo = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy);
    if (albedo.w - CLIFF_COVERAGE_CUTOFF < 0)
        discard;

    float3 tsN = decodeNormalMap(t_hdNormal.Sample(s_hdNormal, input.uv.xy).xyw);
    float3 N = orientNormal(tangentToWorld(tsN, input.tangentVS.xyz, input.normalVS,
                                           input.tangentVS.w),
                            frontFace != 0);
    float2 roughMetal = t_hdOrm.Sample(s_hdOrm, input.uv.xy).yz;
    float alpha = input.vertColor.w * albedo.w;

    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadow<HAS_SHADOW_CASCADE2>(input.worldPos);

    float3 V = normalize(-input.viewPos.xyz);
    HDSurface surf = hdBuildSurface(N, V, albedo.xyz, roughMetal);

    float3 lit = float3(0, 0, 0);
    if (asint(hdPsCB2.mainLightEnable) != 0)
        lit = hdMainLightIrr(surf, input.viewPos.xyz, mainShadow,
                             CLIFF_IRRADIANCE_MAX_SCALE);
    lit = hdClusterLights<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG>(
        surf, input.viewPos.xyz, input.worldPos.xyz, input.svPosition.xy, lit);

    float3 rgb = hdApplyBlightFade(PI * lit, input.uv.zw);
    output.color = float4(hdTerrainColorGrade(rgb), alpha);
    TAlpha.test(alpha, hdPsCB2.alphaRef);

#if WC3_IS_MRT
    {
        output.specular = float4(input.viewPos.z, 0, 0, 1);
        output.normal = float4(N * HD_NORMAL_PACK + HD_NORMAL_PACK, alpha);
    }
#endif

    return output;

    }
#endif
}
