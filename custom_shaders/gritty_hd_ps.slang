// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Gritty-HD pixel shader entry point.
//
// Shares its specialisation space and post-processing (depth prepass,
// alpha test, fog, MRT pack, color matrix, debug visualisation) with the
// HD PBR entry point (hd_ps.slang). The only difference is the lit body:
// this entry dispatches into the psGritty* family in ps_gritty.slang,
// which keeps PBR (Cook-Torrance + IBL) but recolors the look toward
// "dark and gritty" — selective desaturation, lifted roughness, deeper
// ambient shadows, mid-gray contrast.
//
// Specialisation space (identical to hd_ps):
//   TFog              — fog-mode policy.
//   TAlpha            — alpha-test policy.
//   TMat              — material policy (standard vs. multi-layer).
//   HAS_IBL           — route to the full shadow-cascaded / IBL gritty body.
//   HAS_EXTRA_VERTS   — VS passed shadowClip0-2 cascade coords for the IBL body.
//   IS_DEPTH_PREPASS  — depth-only pass (no color).
//   IS_MRT            — also write the deferred-G-buffer targets.
//   HAS_DEBUG_VIS     — debug visualisation enabled.

implementing custom_shaders;

[shader("fragment")]
public PSOutput<IS_MRT && !IS_DEPTH_PREPASS, !IS_DEPTH_PREPASS> gritty_ps_main<
    TFog     : IFogMode,
    TAlpha   : IAlphaTest,
    TMat     : IMaterialLayer,
    let HAS_IBL            : bool,
    let HAS_EXTRA_VERTS    : bool,
    let IS_DEPTH_PREPASS   : bool,
    let IS_MRT             : bool,
    let HAS_DEBUG_VIS      : bool
>(PSInput input, uint frontFace : SV_IsFrontFace)
{
    PSOutput<IS_MRT && !IS_DEPTH_PREPASS, !IS_DEPTH_PREPASS> output;
    bool isFrontFace = frontFace != 0;

    // Non-IBL / non-prepass draws discard fragments flagged by the VS
    // as "behind the fog-clip plane" before doing any further work —
    // mirrors hd_ps.slang line 45-46.
    if (!HAS_IBL && !IS_DEPTH_PREPASS)
        backfaceDiscard(input.worldPos.w);

    if (IS_DEPTH_PREPASS)
    {
        // Same alpha mask as HD — the gritty bodies use HD's fresnel /
        // cloak alpha math, so the prepass body can be reused unchanged.
        if (!TAlpha.enabled)
            depthPrepassStub(input);
        else
            depthPrepassBody<TAlpha, TMat>(input, isFrontFace);
        output.color = float4(0, 0, 0, 0);
        return output;
    }

    // Gritty body dispatch. Three variants paralleling the HD bodies.
    float4 result;
    if (HAS_IBL)
        result = psGrittyIBLBody<TMat, HAS_EXTRA_VERTS, HAS_DEBUG_VIS>(input, isFrontFace);
    else if (TMat.hasMultiLayer)
        result = psGrittyMultiLayerBody<HAS_DEBUG_VIS>(input, isFrontFace);
    else
        result = psGrittyStandardBody<HAS_DEBUG_VIS>(input, isFrontFace);

    // MRT + alpha-test + fog sequencing: byte-identical to hd_ps so the
    // gritty path drops into the same render targets / deferred resolver.
    float3 mrtNormal = float3(0, 0, 0);
    float preAlpha = 0;
    if (IS_MRT)
    {
        TAlpha.test(result.w, psCB2.alphaRef);

        float mrtAlpha = t_albedo.Sample(s_albedo, input.uv.xy).w;
        mrtAlphaTest(mrtAlpha, psCB2.inverseSoftness);

        mrtNormal = computeMRTNormal(input, isFrontFace);
        preAlpha = result.w;
    }

    if (!IS_MRT)
        TAlpha.test(result.w, psCB2.alphaRef);

    if (TFog.hasFog)
        result.w = psCB2.inverseSoftness * result.w;

    result.xyz = TFog.apply(result.xyz, psCB2.fogColor.xyz,
                            input.worldPos.z, psCB2.fogStart, psCB2.fogEnd, psCB2.fogDensity);

    if (!HAS_DEBUG_VIS)
    {
        result.xyz = applyColorMatrix(result.xyz);
        if (!TFog.hasFog)
            result.w = psCB2.inverseSoftness * result.w;
    }

    if (HAS_DEBUG_VIS)
    {
        float3 nSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
        float3 tsN = decodeNormalMap(nSample);
        float3 wn = tangentToWorld(tsN, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
        float normalLen = length(wn);
        wn = normalize(wn);
        wn = orientNormal(wn, isFrontFace);

        float3 effectiveAlbedo = t_albedo.Sample(s_albedo, input.uv.xy).xyz;
        if ((asuint(psCB3.enabledShaders) & 1) != 0)
            effectiveAlbedo = psCB3.overrideAlbedo;

        result = debugVisualize(result, input, wn, normalLen, effectiveAlbedo);
        if (!TFog.hasFog)
            result.w = psCB2.inverseSoftness * result.w;
    }

    if (HAS_IBL)
        backfaceDiscard(input.worldPos.w);

    output.color = result;
    if (IS_MRT)
    {
        output.specular = float4(input.worldPos.z, 0, 0, 1);
        output.normal = float4(mrtNormal, preAlpha);
    }

    return output;
}
