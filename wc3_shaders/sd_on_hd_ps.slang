// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SD-on-HD pixel shader entry point — Warcraft III Reforged 3.0.0.
//
// Specialisation space. The engine's 384 permutations are a 6-bit feature mask
// under a 6-way outer block, not a flat bitmask:
//
//   idx = bits | 64 * outer,   outer = LIGHTING + 2 * sub,   sub in {0, 1, 2}
//
//   bit 0 (  1)  SHADOW_CASCADE2 -> HAS_SHADOW_CASCADE2
//   bit 1 (  2)  MULTI_TARGET    -> WC3_IS_MRT (a define: it reshapes PSOutput)
//   bit 2 (  4)  DEPTH_PREPASS   -> WC3_IS_DEPTH_PREPASS (likewise)
//   bit 3 (  8)  LIGHT_DEBUG     -> HAS_LIGHT_DEBUG
//   bit 4 ( 16)  POINT_SHADOWS   -> HAS_POINT_SHADOWS
//   bit 5 ( 32)  SHADOW_CASCADE  -> HAS_SHADOW_CASCADE
//   sub    0/1/2  plain / ALPHA_TEST / SRGB_OUTPUT
//
// `sub` is a three-way choice rather than two more bits because the engine
// never ships an alpha-tested sRGB slot. Under a depth prepass LIGHTING and
// the sRGB encode are both dead — there is no colour target — but ALPHA_TEST
// stays live, because the prepass still has to punch the same holes the colour
// pass will. That is what collapses 384 permutations to the 80 distinct
// programs in ps/sd_on_hd.bls.
//
// What 3.0.0 changed against 2.0.0:
//   * SD assets now go through the HD pipeline end to end — the HD vertex
//     shader, HD constant buffers, HD textures, clustered-forward lighting,
//     per-pixel cascade and cube shadows. 2.0.0's separate SD IBL / standard
//     bodies are gone.
//   * Fog stopped being a permutation axis. 2.0.0 spent low bits 4 and 5 on
//     FOG_LINEAR / FOG_EXPONENTIAL; 3.0.0 selects one of seven modes from a
//     constant at runtime and spends those two bits on the shadow axes.
//   * The old debug-visualisation axis is gone; the surviving debug bit is
//     HD's light-complexity overlay.
//
// The shape below is `hd_ps.slang` with an albedo-only material. See
// ps/sd_on_hd_ps_body.slang for why that makes `metal` and `rough` constants
// and why the fresnel rim disappears.

implementing wc3_shaders;

[shader("fragment")]
public PSOutput sd_on_hd_ps_main<
    TAlpha : IAlphaTest,
    let HAS_LIGHTING        : bool,
    let HAS_SHADOW_CASCADE  : bool,
    let HAS_SHADOW_CASCADE2 : bool,
    let HAS_POINT_SHADOWS   : bool,
    let HAS_LIGHT_DEBUG     : bool,
    let HAS_SRGB_OUTPUT     : bool
>(HDPSInput input, uint frontFace : SV_IsFrontFace)
{
    PSOutput output;
    bool isFrontFace = frontFace != 0;

#if WC3_IS_DEPTH_PREPASS
    {
        // Depth-only: both bodies discard internally and write nothing. On
        // this permutation PSOutput has no fields at all.
        if (!TAlpha.enabled)
            sdOnHdPrepassStub(input);
        else
            sdOnHdPrepassAlpha<TAlpha>(input, isFrontFace);
        return output;
    }
#else
    {

    // Step 1: the engine's software depth test, before any texture work. HD
    // samples its material set first; SD tests first. Both are the shipped
    // order for their own family.
    hdDepthTestDiscard(input.svPosition.xy, input.viewPos.z);

    // Step 2: the material — one map.
    float4 albedo = t_hdAlbedo.Sample(s_hdAlbedo, input.uv.xy);

    // Step 3: main-light shadow, projected from the world position.
    float mainShadow = 1;
    if (HAS_SHADOW_CASCADE)
        mainShadow = hdMainLightShadow<HAS_SHADOW_CASCADE2>(input.worldPos);

    // Step 4: the shading basis. No normal map, so the interpolated geometric
    // normal is the shading normal; TEXCOORD3 carries a tangent this family
    // has no use for.
    float3 N = orientNormal(normalize(input.normalWS), isFrontFace);
    float3 V = normalize(-input.viewPos.xyz);

    float3 shadedRGB;
    float ndv;

    if (!HAS_LIGHTING)
    {
        // Unlit: albedo tinted by the vertex colour, and nothing else. Used
        // for UI props and anything already baked.
        shadedRGB = srgbToLinear(input.vertColor.xyz) * albedo.xyz;
        ndv = saturate(dot(V, N));
    }
    else
    {
        HDSurface surf = sdOnHdSurface(albedo.xyz, N, V);

        // The main directional light carries the IBL probe and the ambient
        // mix with it; the draw can switch it off and keep the cluster lights.
        float3 lit = float3(0, 0, 0);
        if (asint(hdPsCB2.mainLightEnable) != 0)
            lit = hdMainLight(surf, input.viewPos.xyz, mainShadow);

        lit = hdClusterLights<HAS_POINT_SHADOWS, HAS_LIGHT_DEBUG>(
            surf, input.viewPos.xyz, input.worldPos.xyz, input.svPosition.xy, lit);

        // Undo the 1/PI the Lambertian diffuse carried through the lights.
        shadedRGB = srgbToLinear(input.vertColor.xyz) * (PI * lit);
        ndv = saturate(dot(N, V));
    }

    // Step 5: the cloak, which decides the final alpha. HD's fresnel rim has
    // no counterpart here.
    float4 shaded = sdOnHdCloak(shadedRGB, ndv, albedo.w, input.vertColor.w);

    // Step 6: the clips. Water clipping first, then the material's own alpha
    // test — both before the blight and fog work so a doomed fragment pays for
    // neither.
    if (input.viewPos.w < 0)
        discard;
    TAlpha.test(shaded.w, hdPsCB2.alphaRef);

    if (0.5 < hdPsCB2.blightEnable)
        shaded.xyz = hdApplyBlight(shaded.xyz, input.blightUV.xy);

    // Step 7: fog and the blend-mode-aware application — HD's block without
    // the colour grade.
    float4 result = hdApplyFogGraded<false>(
        shaded, hdFogFactor(input.viewPos.z, input.worldPos.xyz));

    // Step 8: sRGB encoding for a _UNORM render target, faded in by the
    // surface's own alpha so a transparent fragment is left in linear space
    // for the blend. Applied after the fog, and NOT suppressed by the debug
    // overlay — 2.0.0 suppressed it under its (since removed) debug axis.
    if (HAS_SRGB_OUTPUT)
        result.xyz = lerp(result.xyz, linearToSrgb(result.xyz), result.w);

    output.color = result;

#if WC3_IS_MRT
    {
        // The G-buffer has a stricter coverage test than the colour buffer.
        hdMRTSoftnessDiscard(albedo.w);
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
