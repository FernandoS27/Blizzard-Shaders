// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// HD mesh pixel shader entry point — Warcraft III Reforged 3.0.0.
//
// Specialisation space. The engine's 1024 permutations ARE a 10-bit feature
// mask (unlike the vertex shader, whose index is a mixed-radix counter):
//
//   bit 0 (  1)  AO_MAP          -> HAS_AO_MAP
//   bit 1 (  2)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2
//   bit 2 (  4)  MULTI_TARGET    -> WC3_IS_MRT (a define: it reshapes PSOutput)
//   bit 3 (  8)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS (likewise)
//   bit 4 ( 16)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 5 ( 32)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 6 ( 64)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   bit 7 (128)  LIGHTING        -> HAS_LIGHTING
//   bit 8 (256)  ALPHA_TEST      -> TAlpha
//   bit 9 (512)  MULTI_LAYER     -> TMat
//
// Several bits only exist under another: a depth prepass ignores every shading
// axis, the four lighting sub-axes need LIGHTING, and the second cascade set
// needs the first. compile_all_slang.py folds those dependencies before it
// picks the types, so the permutations that differ only in a dead bit compile
// to the same program — exactly as the shipped BLS does.
//
// What 3.0.0 changed against 2.0.0:
//   * Lighting is CLUSTERED FORWARD. The per-draw light array in b2 is gone;
//     lights live in a structured buffer reached through a screen-space
//     cluster grid. See ps/hd_ps_lighting.slang.
//   * Shadows are per-light and per-pixel: a cube-map array for the cluster
//     lights and a 2D array for the main light's cascades, both projected in
//     the pixel shader from the world position the VS now hands over.
//   * Fog is RUNTIME-selected from seven modes instead of two compile-time
//     axes, and how it is applied depends on the material's blend mode. See
//     ps/hd_ps_post.slang.
//   * New blight mask + colour ramp, a manual depth test against the scene
//     depth target, and a per-draw normal-map strength.
//
// The body below is the shipped shader's order of operations: sample, depth
// test, shadow, shade, finish, clip, blight, fog. That order is not arbitrary
// — the discards sit where they do so that a fragment about to be thrown away
// does not pay for the blight and fog work behind them.

implementing wc3_shaders;

[shader("fragment")]
public PSOutput ps_main<
    TAlpha : IAlphaTest,
    TMat   : IMaterialLayer,
    let HAS_LIGHTING        : bool,
    let HAS_AO_MAP          : bool,
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
        // Depth-only: both bodies discard internally and write nothing. On
        // this permutation PSOutput has no fields at all.
        if (!TAlpha.enabled)
            hdDepthPrepassStub(input);
        else
            hdDepthPrepassAlpha<TAlpha, TMat>(input, isFrontFace);
        return output;
    }
#else
    {

    // Step 1: the material set, with the team layer already folded in.
    HDMaterial mat = sampleHDMaterial<TMat, HAS_LIGHTING>(input.uv.xy);
    float2 enc = encodeScaledNormal(
        t_hdNormal.Sample(s_hdNormal, input.uv.xy).xyw, hdPsCB2.normalStrength);

    // Ambient occlusion rides in t2.x at UV1 — the one thing in the material
    // set that is not sampled at UV0.
    float ao = 1;
    if (HAS_AO_MAP)
        ao = t_hdOrm.Sample(s_hdOrm, input.uv.zw).x;

    // Step 2: the engine's software depth test, before any shading work.
    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);

    // Step 3: main-light shadow, projected from the world position.
    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadow<HAS_SHADOW_CASCADE2>(input.worldPos);

    // Step 4: the shading basis.
    float3 N = hdWorldNormal(input, enc, isFrontFace);
    float3 V = normalize(-input.viewPos.xyz);

    float3 shadedRGB;
    float ndv;

    if (!HAS_LIGHTING)
    {
        // Unlit: emissive plus albedo, tinted by the vertex colour. Used for
        // UI props, fully-baked scenery and anything the clustered pass would
        // be pure cost on.
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

        // Authored roughness is remapped away from both extremes: a perfectly
        // smooth surface has no stable specular lobe, and a perfectly rough
        // one loses the highlight entirely.
        float roughness = saturate(mat.roughMetal.x);
        roughness = roughness * HD_ROUGHNESS_SCALE + HD_ROUGHNESS_BIAS;
        // Geometric specular anti-aliasing: sub-pixel normal variance is
        // folded into the roughness so high-frequency normals stop sparkling.
        surf.rough = (asuint(hdPsCB2.useNdf) != 0) ? specularAA(roughness, N)
                                                   : roughness;

        surf.F0 = surf.metal * surf.albedo;
        surf.diffColor = (surf.albedo - surf.metal * surf.albedo) * INV_PI;

        float rr = surf.rough * surf.rough;
        surf.a2 = rr * rr;
        float kSq = (1 + surf.rough) * (1 + surf.rough);
        surf.kDirect = SCHLICK_K_FACTOR * kSq;
        surf.kInv = -kSq * SCHLICK_K_FACTOR + 1;

        // The main directional light carries the IBL probe and the ambient
        // mix with it; the draw can switch it off and keep the cluster lights.
        float3 lit = float3(0, 0, 0);
        if (asint(hdPsCB2.mainLightEnable) != 0)
            lit = hdMainLight(surf, input.viewPos.xyz, mainShadow);

        lit = hdClusterLights<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG>(
            surf, input.viewPos.xyz, input.worldPos.xyz, input.svPosition.xy, lit);

        if (HAS_AO_MAP)
            lit = lit * ao;

        // Undo the 1/PI the Lambertian diffuse carried through the lights.
        shadedRGB = PI * lit;
        shadedRGB = mat.emissive * hdPsCB2.emissiveGain + shadedRGB;
        shadedRGB = srgbToLinear(input.vertColor.xyz) * shadedRGB;
        ndv = saturate(dot(N, V));
    }

    // Step 5: fresnel rim and cloak, which together decide the final alpha.
    float4 shaded = hdFresnelAndCloak<TMat>(shadedRGB, ndv, mat, input.vertColor.w);

    // Step 6: the clips. Water clipping first, then the material's own alpha
    // test — both before the blight and fog work so a doomed fragment pays for
    // neither.
    if (input.viewPos.w < 0)
        discard;
    TAlpha.test(shaded.w, hdPsCB2.alphaRef);

    if (0.5 < hdPsCB2.blightEnable)
        shaded.xyz = hdApplyBlight(shaded.xyz, input.blightUV.xy);

    // Step 7: fog, colour grade and the blend-mode-aware application.
    output.color = hdApplyFog(shaded, hdFogFactor(input.viewPos.z, input.worldPos.xyz));

#if WC3_IS_MRT
    {
        // The G-buffer has a stricter coverage test than the colour buffer.
        hdMRTSoftnessDiscard(mat.albedo.w);
        // specular.x carries view-space Z for the screen-space resolve passes;
        // normal.w carries the pre-fog alpha as the surface's coverage.
        output.specular = float4(input.viewPos.z, 0, 0, 1);
        output.normal = float4(N * HD_NORMAL_PACK + HD_NORMAL_PACK, shaded.w);
    }
#endif

    return output;

    }
#endif
}
