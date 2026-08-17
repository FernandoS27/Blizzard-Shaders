// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family SHADINGMODE_REFLECTION arm (psreflection.fx : Reflection) — a
// screen-space planar reflection: perturb the back-buffer UV by the tangent-space
// normal projected to view space, then sample the reflection source, modulated by a
// strength layer.  ComputeEnvMappings is dead (EyeToVertex never live; the strength /
// blur-mask layers sample with allowEnvio=false), so it is omitted.

implementing sc2_shaders;

#ifndef b_blurPass
#define b_blurPass 0
#endif
#ifndef b_iReflectionBlurMaskLayerEnable
#define b_iReflectionBlurMaskLayerEnable 0
#endif
#ifndef b_iReflectionNormalLayerEnable
#define b_iReflectionNormalLayerEnable 0
#endif
#ifndef b_iReflectionNormalUseConstantColor
#define b_iReflectionNormalUseConstantColor 0
#endif
#ifndef b_iReflectionStrengthLayerEnable
#define b_iReflectionStrengthLayerEnable 0
#endif

// psreflection.fx : Reflection.
float4 reflection(ModelPSInput vertOut)
{
    float3 vDeferredNormal = float3(0, 0, 0);   // MainShading init; fresnel normal (unused here)
#if b_blurPass
    float4 rvalue = float4(0, 0, 0, 0);
  #if b_iReflectionBlurMaskLayerEnable
    {
        TriPlanarUVs tp = initTriPlanarUVs(vertOut);
        SLayerConfig cfg = setupReflectionBlurMaskLayer();
        rvalue.a = getLayerColor2D(vertOut, cfg, p_sReflectionBlurMaskSampler_t, p_sSamp,
                                   1.0f, vDeferredNormal, tp).a;
    }
  #endif
    return rvalue;
#else
    float3 vTextureNormal = float3(0, 0, 0);
    float3 vNormal = float3(0, 0, 0);

    float2 reflectionUV = getBackBufferUV(vertOut);
  #if b_iReflectionNormalLayerEnable
    {
        SLayerConfig cfg = setupReflectionNormalLayer();
    #if b_iReflectionNormalUseConstantColor
        vTextureNormal = cfg.p_cConstantColor.xyz;
    #else
        float fStub;
        float4 vUV = getUVEmitter(vertOut, cfg.b_iUVEmitter,
                                  cfg.p_vMultiplyAddAlphaTrans.w, cfg.p_mUVTransform);
        vTextureNormal = decodeTextureNormal(p_sReflectionNormalSampler_t, p_sSamp, vUV, fStub);
    #endif
        vNormal = tangentToWorld(vTextureNormal, vertOut.Normal().xyz,
                                 vertOut.Tangent().xyz, vertOut.Binormal());

        // Remove the plane normal before projecting to view space, so we keep just the
        // deviation from the plane normal, which maps to a UV offset.
        vNormal -= dot(vNormal, psGlobals.fReflectionNormal) * psGlobals.fReflectionNormal.xyz;
        vNormal = mul((float3x3)psGlobals.mViewTransform, vNormal);

        float2 reflectionDelta = vNormal.xy * psGlobals.fDistortionStrength.xy;
        reflectionUV.xy += reflectionDelta;
    }
  #endif

    float fStrength = psGlobals.fReflectionStrengthMultiplier;
  #if b_iReflectionStrengthLayerEnable
    {
        TriPlanarUVs tp = initTriPlanarUVs(vertOut);
        SLayerConfig cfg = setupReflectionStrengthLayer();
        fStrength *= getLayerColor2D(vertOut, cfg, p_sReflectionStrengthSampler_t, p_sSamp,
                                     1.0f, vDeferredNormal, tp).a;
    }
  #endif

    return fStrength * p_sReflectionSrc_t.Sample(p_sSamp, reflectionUV);
#endif
}
