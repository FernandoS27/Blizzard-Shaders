// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// HD pixel shader entry point.
//
// Specialisation space:
//   TFog              — fog-mode policy.
//   TAlpha            — alpha-test policy.
//   TMat              — material policy (standard vs. multi-layer).
//   HAS_IBL           — route to the full IBL / Cook-Torrance body.
//   HAS_EXTRA_VERTS   — VS passed shadowClip0-2 cascade coords; the IBL
//                        body samples the three shadow cascades and
//                        attenuates the main directional light.
//   IS_DEPTH_PREPASS  — depth-only pass (no color).
//   IS_MRT            — also write the deferred-G-buffer targets.
//   HAS_DEBUG_VIS     — debug visualisation enabled.
//
// The body dispatches to one of {psIBLBody, psMultiLayerBody,
// psStandardBody} based on the flags, then performs post-processing
// (alpha test, fog, color matrix, MRT normal pack, debug overlay) in
// the order the original shader used.

implementing wc3_shaders;

// IS_DEPTH_PREPASS / IS_MRT migrated from `let X : bool` template
// params to `WC3_IS_DEPTH_PREPASS` / `WC3_IS_MRT` preprocessor defines
// (see types/ps_io.slang for the reasoning). The struct gates use
// derived flags WC3_HAS_COLOR (= !WC3_IS_DEPTH_PREPASS) and WC3_HAS_MRT
// (= WC3_IS_MRT && !WC3_IS_DEPTH_PREPASS), both set by the script.
[shader("fragment")]
public PSOutput ps_main<
    TFog     : IFogMode,
    TAlpha   : IAlphaTest,
    TMat     : IMaterialLayer,
    let HAS_IBL            : bool,
    let HAS_EXTRA_VERTS    : bool,
    let HAS_DEBUG_VIS      : bool
>(PSInput input, uint frontFace : SV_IsFrontFace)
{
    PSOutput output;
    bool isFrontFace = frontFace != 0;

#if WC3_IS_DEPTH_PREPASS
    {
        // Depth-only path: either run the alpha-tested prepass or the
        // cheap stub. Both branches discard internally; the rasterizer
        // writes depth from SV_Position. No color write — the PSOutput
        // has no fields on this perm.
        if (!TAlpha.enabled)
            depthPrepassStub(input);
        else
            depthPrepassBody<TAlpha, TMat>(input, isFrontFace);
        return output;
    }
#else
    {

    // Non-IBL draws discard fragments flagged by the VS as "behind the
    // fog-clip plane" before doing any further work. The IBL path
    // delays this until after the body (it needs the world-space
    // normal anyway).
    if (!HAS_IBL)
        backfaceDiscard(input.worldPos.w);

    // Dispatch to the appropriate lit body.
    float4 result;
    if (HAS_IBL)
        result = psIBLBody<TMat, HAS_EXTRA_VERTS, HAS_DEBUG_VIS>(input, isFrontFace);
    else if (TMat.hasMultiLayer)
        result = psMultiLayerBody<HAS_DEBUG_VIS>(input, isFrontFace);
    else
        result = psStandardBody<HAS_DEBUG_VIS>(input, isFrontFace);

    // MRT path: alpha test, extra "are we opaque enough for the
    // G-buffer" test, and G-buffer payloads.
    float3 mrtNormal = float3(0, 0, 0);
    float preAlpha = 0;
#if WC3_IS_MRT
    {
        TAlpha.test(result.w, psCB2.alphaRef);

        // Deferred-only alpha gate — avoids writing partial-coverage
        // pixels to the opaque G-buffer.
        float mrtAlpha = t_albedo.Sample(s_albedo, input.uv.xy).w;
        mrtAlphaTest(mrtAlpha, psCB2.inverseSoftness);

        mrtNormal = computeMRTNormal(input, isFrontFace);

        // Store the pre-fog alpha — used by the deferred resolver to
        // reconstruct the surface opacity.
        preAlpha = result.w;
    }
#else
    {
        // Non-MRT path runs the alpha test here since the MRT block
        // would have run it above. Running it before fog avoids paying
        // the fog apply() cost on discarded pixels.
        TAlpha.test(result.w, psCB2.alphaRef);
    }
#endif

    // When fog is active we pre-multiply by inverseSoftness now so the
    // fog apply() doesn't further modulate alpha. The non-fog branch
    // applies this multiply down below after the color matrix.
    if (TFog.hasFog)
        result.w = psCB2.inverseSoftness * result.w;

    result.xyz = TFog.apply(result.xyz, psCB2.fogColor.xyz,
                            input.worldPos.z, psCB2.fogStart, psCB2.fogEnd, psCB2.fogDensity);

    if (!HAS_DEBUG_VIS)
    {
        // Release: apply the post color-matrix grade and finish the
        // alpha scale if fog was off.
        result.xyz = applyColorMatrix(result.xyz);
        if (!TFog.hasFog)
            result.w = psCB2.inverseSoftness * result.w;
    }

    if (HAS_DEBUG_VIS)
    {
        // Debug overlay needs the world-space normal + its pre-
        // normalisation length; recompute from the normal map rather
        // than storing it through the lit bodies.
        float3 nSample = t_normal.Sample(s_normal, input.uv.xy).xyw;
        float3 tsN = decodeNormalMap(nSample);
        float3 wn = tangentToWorld(tsN, input.tangentWS.xyz, input.normalWS.xyz, input.tangentWS.w);
        float normalLen = length(wn);
        wn = normalize(wn);
        wn = orientNormal(wn, isFrontFace);

        // Effective albedo for DEBUG mode 1: the centre sample after
        // the bit-0 override has been applied, matching what the lit
        // body shaded with.
        float3 effectiveAlbedo = t_albedo.Sample(s_albedo, input.uv.xy).xyz;
        if ((asuint(psCB3.enabledShaders) & 1) != 0)
            effectiveAlbedo = psCB3.overrideAlbedo;

        result = debugVisualize(result, input, wn, normalLen, effectiveAlbedo);
        if (!TFog.hasFog)
            result.w = psCB2.inverseSoftness * result.w;
    }

    // The IBL path defers its backface discard to the very end —
    // matches the retail shader, where `discard_nz` is the last
    // instruction before the SV_Target writes.
    if (HAS_IBL)
        backfaceDiscard(input.worldPos.w);

    output.color = result;
#if WC3_IS_MRT
    {
        // specular.x carries view-space Z for SSR / resolve effects;
        // normal.w carries the pre-fog alpha for coverage.
        output.specular = float4(input.worldPos.z, 0, 0, 1);
        output.normal = float4(mrtNormal, preAlpha);
    }
#endif

    return output;

    }
#endif
}
