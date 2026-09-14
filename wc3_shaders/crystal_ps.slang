// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Crystal pixel shader entry point — Warcraft III Reforged 3.0.0.
//
// Crystal is the HD mesh shader. Not a cousin of it, not a fork of it: the same
// constant buffers (cb1[43] / cb2[31]), the same textures t0-t3 / t6-t8 /
// t11-t13, the same t16/t17/t18 clustered-light buffers, the same eight
// interpolants, the same order of operations — verified by diffing the shipped
// declarations and input signature against `hd`, which come out byte-identical.
//
// Its 512 permutations are hd_ps's 1024 with the AO_MAP axis struck out and
// every higher bit shifted down one, so crystal index `c` is hd index `2 * c`:
//
//   bit 0 (  1)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2
//   bit 1 (  2)  MULTI_TARGET    -> WC3_IS_MRT (a define: it reshapes PSOutput)
//   bit 2 (  4)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS (likewise)
//   bit 3 (  8)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 4 ( 16)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 5 ( 32)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   bit 6 ( 64)  LIGHTING        -> HAS_LIGHTING
//   bit 7 (128)  ALPHA_TEST      -> TAlpha
//   bit 8 (256)  MULTI_LAYER     -> TMat
//
// Crystal has no ambient-occlusion axis at all: HD's AO bit adds one sample of
// t2 at UV1, and no crystal permutation ever samples at `v2.zw`.
//
// EXACTLY THREE things differ from `ps_main`, all of them material:
//
//   1. The albedo is REFRACTED — two taps of t0 lerped by the refract mask in
//      t2.x — and the blended value is what feeds the team-colour layer.
//   2. The normal map is decoded RAW. HD scales its tangent-space XY by
//      `hdPsCB2.normalStrength` through an encode/decode round trip; crystal
//      never reads that lane (cb2[27].x, 0 of 512 permutations).
//   3. The Fresnel rim alpha PARAMETER is remapped by the refract mask, so a
//      fully transparent facet still takes a visible rim. Present in 384 of
//      crystal's permutations and 0 of HD's 1024.
//
// Everything else — the software depth test, the shadow cascades, clustered
// forward lighting with its cube shadows, the cloak, the blight overlay, the
// runtime fog stack and the deferred targets — is HD's, called rather than
// restated. What 2.0.0 crystal had and 3.0.0 does not: the HAS_IBL axis (now
// unconditional in the lit path), both fog axes, EXTRA_VERTS, and `cb3`
// entirely, which retires crystal's own debug-vis modes and its albedo / ORM
// overrides along with it.

implementing wc3_shaders;

[shader("fragment")]
public PSOutput crystal_ps_main<
    TAlpha : IAlphaTest,
    TMat   : IMaterialLayer,
    let HAS_LIGHTING        : bool,
    let HAS_SHADOW_CASCADE  : bool,
    let HAS_SHADOW_CASCADE2 : bool,
    let HAS_POINT_SHADOWS   : bool,
    let HAS_LIGHT_DEBUG     : bool
>(HDPSInput input, uint frontFace : SV_IsFrontFace)
{
    PSOutput output;
    bool isFrontFace = frontFace != 0;

#if WC3_IS_DEPTH_PREPASS
    {
        // Depth-only: both bodies discard internally and write nothing. On this
        // permutation PSOutput has no fields at all. The plain prepass never
        // touches the material, so it is HD's program unchanged.
        if (!TAlpha.enabled)
            hdDepthPrepassStub(input);
        else
            crystalDepthPrepassAlpha<TAlpha, TMat>(input, isFrontFace);
        return output;
    }
#else
    {

    // Step 1: the material set. The refract mask is fetched ONCE and used
    // twice — for the albedo blend here and for the rim alpha at step 5.
    float refractMask = t_hdOrm.Sample(s_hdOrm, input.uv.xy).x;
    float4 albedo = sampleCrystalAlbedo(input.uv.xy, input.normalWS, refractMask);
    HDMaterial mat = sampleHDMaterialFrom<TMat, HAS_LIGHTING>(input.uv.xy, albedo);

    // Step 2: the engine's software depth test, before any shading work.
    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);

    // Step 3: main-light shadow, projected from the world position.
    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadow<HAS_SHADOW_CASCADE2>(input.worldPos);

    // Step 4: the shading basis. Raw normal decode — no per-draw strength.
    float3 N = crystalWorldNormal(input, isFrontFace);
    float3 V = normalize(-input.viewPos.xyz);

    float3 shadedRGB;
    float ndv;

    if (!HAS_LIGHTING)
    {
        shadedRGB = mat.emissive * hdPsCB2.emissiveGain + mat.albedo.xyz;
        shadedRGB = srgbToLinear(input.vertColor.xyz) * shadedRGB;
        ndv = saturate(dot(V, N));
    }
    else
    {
        HDSurface surf;
        surf.N = N;
        surf.V = V;
        surf.albedo = mat.albedo.xyz;
        surf.metal = mat.roughMetal.y;

        float roughness = saturate(mat.roughMetal.x);
        roughness = roughness * HD_ROUGHNESS_SCALE + HD_ROUGHNESS_BIAS;
        surf.rough = (asuint(hdPsCB2.useNdf) != 0) ? specularAA(roughness, N)
                                                   : roughness;

        surf.F0 = surf.metal * surf.albedo;
        surf.diffColor = (surf.albedo - surf.metal * surf.albedo) * INV_PI;

        float rr = surf.rough * surf.rough;
        surf.a2 = rr * rr;
        float kSq = (1 + surf.rough) * (1 + surf.rough);
        surf.kDirect = SCHLICK_K_FACTOR * kSq;
        surf.kInv = -kSq * SCHLICK_K_FACTOR + 1;

        float3 lit = float3(0, 0, 0);
        if (asint(hdPsCB2.mainLightEnable) != 0)
            lit = hdMainLight(surf, input.viewPos.xyz, mainShadow);

        lit = hdClusterLights<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG>(
            surf, input.viewPos.xyz, input.worldPos.xyz, input.svPosition.xy, lit);

        // Undo the 1/PI the Lambertian diffuse carried through the lights.
        shadedRGB = PI * lit;
        shadedRGB = mat.emissive * hdPsCB2.emissiveGain + shadedRGB;
        shadedRGB = srgbToLinear(input.vertColor.xyz) * shadedRGB;
        ndv = saturate(dot(N, V));
    }

    // Step 5: fresnel rim and cloak, over the refract-modulated rim alpha.
    float4 shaded = hdFresnelAndCloakA<TMat>(
        shadedRGB, ndv, mat, input.vertColor.w,
        refractModulatedFresnelAlpha(hdPsCB2.fresnelColor.w, refractMask));

    // Step 6: the clips — water plane, then the material's own alpha test —
    // both before the blight and fog work so a doomed fragment pays for neither.
    if (input.viewPos.w < 0)
        discard;
    TAlpha.test(shaded.w, hdPsCB2.alphaRef);

    if (0.5 < hdPsCB2.blightEnable)
        shaded.xyz = hdApplyBlight(shaded.xyz, input.blightUV.xy);

    // Step 7: fog, colour grade and the blend-mode-aware application.
    output.color = hdApplyFog(shaded, hdFogFactor(input.viewPos.z, input.worldPos.xyz));

#if WC3_IS_MRT
    {
        hdMRTSoftnessDiscard(mat.albedo.w);
        output.specular = float4(input.viewPos.z, 0, 0, 1);
        output.normal = float4(N * HD_NORMAL_PACK + HD_NORMAL_PACK, shaded.w);
    }
#endif

    return output;

    }
#endif
}
