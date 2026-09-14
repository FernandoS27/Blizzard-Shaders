// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Foliage pixel shader entry point — Warcraft III Reforged 3.0.0.
//
// 3.0.0 moved foliage onto the HD mesh's banks. Its declarations are those of
// a lit HD permutation minus the scene-depth texture (t7): the same cb1[43] /
// cb2[31], t0-t3, t6 / t8, the t11 / t12 / t13 IBL set and the t16 / t17 / t18
// clustered-light buffers. And its 128 permutations are HD's feature mask with
// LIGHTING pinned on and AO_MAP and MULTI_LAYER struck out:
//
//   bit 0 (  1)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2
//   bit 1 (  2)  MULTI_TARGET    -> WC3_IS_MRT (a define: it reshapes PSOutput)
//   bit 2 (  4)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS (likewise)
//   bit 3 (  8)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 4 ( 16)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 5 ( 32)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   bit 6 ( 64)  ALPHA_TEST      -> TAlpha
//
// folded by HD's own rules (compile_all_slang._hd_ps_fold), which reproduce
// retail's 50 programs exactly.
//
// So the shading is HD's -- material taps, specular AA, the main light with
// its IBL and ambient mix, the clustered light loop with point shadows and the
// debug overlay -- called rather than restated. What foliage does NOT do is
// just as much a part of it, and all of it was checked in the bytecode:
//
//   * no software depth test (no t7), no water clip, no fog of any kind;
//   * no fresnel rim and no cloak: alpha is vertex alpha times albedo alpha;
//   * the normal map is decoded RAW (no per-draw strength), and never flipped
//     for back faces;
//   * emissive is added without HD's emissive gain;
//   * the main light's probe irradiance is normalised against 0.4 of its
//     maximum (hdMainLightIrr), in every shaded permutation;
//   * the blight is a DARKENING, unconditional, read from row 0.25 of the
//     ramp's alpha (hdApplyBlightFade), rather than HD's gated colour tint
//     from row 0.75;
//   * the deferred targets skip HD's softness discard.

implementing wc3_shaders;

// The probe irradiance is hue-normalised against 0.4 of its largest component
// rather than the component itself -- see hdMainLightIrr.
static const float FOLIAGE_IRRADIANCE_MAX_SCALE = 0.400000006;

// Shading normal: a raw decode of t1 carried through the interpolated frame.
float3 foliageNormal(FoliagePSInput input)
{
    float3 tsN = decodeNormalMap(t_hdNormal.Sample(s_hdNormal, input.uv.xy).xyw);
    return tangentToWorld(tsN, input.tangentVS.xyz, input.normalVS,
                          input.tangentVS.w);
}

[shader("fragment")]
public PSOutput foliage_ps_main<
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
        // Depth-only. The plain prepass is an empty program; the alpha-tested
        // one punches the leaf silhouette and nothing else.
        if (TAlpha.enabled)
        {
            float albedoA = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy).w;
            TAlpha.test(input.vertColor.w * albedoA, hdPsCB2.alphaRef);
        }
        return output;
    }
#else
    {

    HDMaterial mat = sampleHDMaterial<StandardMaterial, true>(input.uv.xy);
    float alpha = input.vertColor.w * mat.albedo.w;

    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadow<HAS_SHADOW_CASCADE2>(input.worldPos);

    float3 N = foliageNormal(input);
    float3 V = normalize(-input.viewPos.xyz);
    HDSurface surf = hdBuildSurface(N, V, mat.albedo.xyz, mat.roughMetal);

    float3 lit = float3(0, 0, 0);
    if (asint(hdPsCB2.mainLightEnable) != 0)
        lit = hdMainLightIrr(surf, input.viewPos.xyz, mainShadow,
                             FOLIAGE_IRRADIANCE_MAX_SCALE);

    lit = hdClusterLights<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG>(
        surf, input.viewPos.xyz, input.worldPos.xyz, input.svPosition.xy, lit);

    // Undo the 1/PI the Lambertian diffuse carried through the lights.
    float3 rgb = PI * lit + mat.emissive;
    rgb = srgbToLinear(input.vertColor.xyz) * rgb;

    output.color = float4(hdApplyBlightFade(rgb, input.uv.zw), alpha);
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
