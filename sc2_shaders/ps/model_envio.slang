// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family environment mapping (psuvmapping.fx : ComputeEnvMappings /
// GenEnvioUV / GenSphericalEnvio / GenCubicEnvio; psmaterial.fx : ApplyEnv + the
// Envio material block).  Covers the Envio + EnvioMask layers (2D or cube), the
// constant-diffuse/spec multipliers, and the blur-mip path.

implementing sc2_shaders;

// Shared layer enums (slang's __include does NOT propagate #defines across files,
// so every file that uses these at runtime redeclares them; values from
// psmaterialdefines.fx).
#define LAYEROP_MOD                     0
#define LAYEROP_ADD                     2
#define LAYEROP_LERP                    3
#define CHANNELSELECT_RGBA             1

// materialdefines.fx envio UV selectors.
#define UVMAP_REFLECT_CUBICENVIO     2
#define UVMAP_REFLECT_SPHERICALENVIO 3
#define UVMAP_CUBICENVIO             7
#define UVMAP_SPHERICALENVIO         8

#ifndef b_iEnvioLayerEnable
#define b_iEnvioLayerEnable 0
#endif
#ifndef b_iEnvioMultipliers
#define b_iEnvioMultipliers 0
#endif
#ifndef b_iBlurEnvironmentMap
#define b_iBlurEnvironmentMap 0
#endif

// psuvmapping.fx : SEnvMappings — the four precomputed envio lookup coordinates.
struct SEnvMappings
{
    float2 vReflectSphericalEnvioUV;
    float3 vReflectCubicEnvioUV;
    float2 vSphericalEnvioUV;
    float3 vCubicEnvioUV;
};

// GenSphericalEnvio / GenCubicEnvio (PS_40+ always takes the reflect branch when
// bReflect is set — the PS_14 guard is unreachable here).
float2 genSphericalEnvio(float3 vPosition, float3 vNormal, bool bReflect)
{
    float3 vLookup = bReflect
        ? normalize(vPosition - 2.0f * dot(vPosition, vNormal) * vNormal)
        : vNormal;
    return vLookup.xz * float2(0.5f, -0.5f) + 0.5f;
}

float3 genCubicEnvio(float3 vPosition, float3 vNormal, bool bReflect)
{
    return bReflect
        ? normalize(vPosition - 2.0f * dot(vPosition, vNormal) * vNormal)
        : vNormal;
}

SEnvMappings computeEnvMappings(float3 vNormal, float3 vPosition)
{
    SEnvMappings e;
    e.vReflectSphericalEnvioUV = genSphericalEnvio(vPosition, vNormal, true);
    e.vReflectCubicEnvioUV     = genCubicEnvio(vPosition, vNormal, true);
    e.vSphericalEnvioUV        = genSphericalEnvio(vPosition, vNormal, false);
    e.vCubicEnvioUV            = genCubicEnvio(vPosition, vNormal, false);
    return e;
}

// psuvmapping.fx : GenEnvioUV.
float4 genEnvioUV(SEnvMappings e, int iMapping)
{
    float3 vResult;
    if (iMapping == UVMAP_REFLECT_CUBICENVIO)
        vResult = e.vReflectCubicEnvioUV;
    else if (iMapping == UVMAP_REFLECT_SPHERICALENVIO)
    {
        vResult.xy = e.vReflectSphericalEnvioUV;
        vResult.z = 0;
    }
    else if (iMapping == UVMAP_CUBICENVIO)
        vResult = e.vCubicEnvioUV;
    else if (iMapping == UVMAP_SPHERICALENVIO)
    {
        vResult.xy = e.vSphericalEnvioUV;
        vResult.z = 0;
    }
    else
        vResult = float3(0, 0, 0);
    return float4(vResult, 1);
}

// psmaterial.fx : ApplyEnv.
float3 applyEnv(float3 cColor, float3 cEnv, float4 cMaskValue, int iOp)
{
    if (iOp == LAYEROP_MOD)       return cColor * cEnv * cMaskValue.rgb;
    else if (iOp == LAYEROP_ADD)  return cColor + cEnv * cMaskValue.rgb;
    else if (iOp == LAYEROP_LERP) return lerp(cColor, cEnv, cMaskValue.a);
    return cColor;
}

// psmateriallayercolor.fx SampleLayer, envio arm — the layer's envio UV + the
// 2D/cube sample (texture type is a compile-time axis).  `lod<0` means "no explicit
// mip" (Sample); lod>=0 uses SampleLevel (the blur-mip path).
float4 sampleEnvio(ModelPSInput vertOut, SLayerConfig cfg, SEnvMappings e, float lod)
{
    if (cfg.b_iUseConstantColor)
        return cfg.p_cConstantColor;
    float4 vUV = getUVEmitter(vertOut, cfg.b_iUVEmitter,
                              cfg.p_vMultiplyAddAlphaTrans.w, cfg.p_mUVTransform);
    if (cfg.b_iUVMapping == UVMAP_REFLECT_CUBICENVIO || cfg.b_iUVMapping == UVMAP_CUBICENVIO
        || cfg.b_iUVMapping == UVMAP_REFLECT_SPHERICALENVIO || cfg.b_iUVMapping == UVMAP_SPHERICALENVIO)
        vUV = genEnvioUV(e, cfg.b_iUVMapping);
    if (cfg.b_iIsRTTTexture)
        vUV.xy = vUV.xy * cfg.p_vRTTTextureOffsetScale.zw + cfg.p_vRTTTextureOffsetScale.xy;
#if (b_iEnvioTextureType == 0)
    return (lod < 0.0f) ? p_sEnvioSampler_t.Sample(p_sSamp, vUV.xy)
                        : p_sEnvioSampler_t.SampleLevel(p_sSamp, vUV.xy, lod);
#else
    return (lod < 0.0f) ? p_sEnvioSampler_t.Sample(p_sSamp, vUV.xyz)
                        : p_sEnvioSampler_t.SampleLevel(p_sSamp, vUV.xyz, lod);
#endif
}

float4 sampleEnvioMask(ModelPSInput vertOut, SLayerConfig cfg, SEnvMappings e)
{
    if (cfg.b_iUseConstantColor)
        return cfg.p_cConstantColor;
    float4 vUV = getUVEmitter(vertOut, cfg.b_iUVEmitter,
                              cfg.p_vMultiplyAddAlphaTrans.w, cfg.p_mUVTransform);
    if (cfg.b_iUVMapping == UVMAP_REFLECT_CUBICENVIO || cfg.b_iUVMapping == UVMAP_CUBICENVIO
        || cfg.b_iUVMapping == UVMAP_REFLECT_SPHERICALENVIO || cfg.b_iUVMapping == UVMAP_SPHERICALENVIO)
        vUV = genEnvioUV(e, cfg.b_iUVMapping);
    if (cfg.b_iIsRTTTexture)
        vUV.xy = vUV.xy * cfg.p_vRTTTextureOffsetScale.zw + cfg.p_vRTTTextureOffsetScale.xy;
#if (b_iEnvioMaskTextureType == 0)
    return p_sEnvioMaskSampler_t.Sample(p_sSamp, vUV.xy);
#else
    return p_sEnvioMaskSampler_t.Sample(p_sSamp, vUV.xyz);
#endif
}

// GetLayerColor(Envio) = SampleLayer(envio) + ComputeLayerColorInternal.
float4 getLayerColorEnvio(ModelPSInput vertOut, SLayerConfig cfg, SEnvMappings e,
                          float lod, float3 vNormal)
{
    return computeLayerColorInternal(vertOut, cfg, 1.0f, sampleEnvio(vertOut, cfg, e, lod), vNormal);
}
float4 getLayerColorEnvioMask(ModelPSInput vertOut, SLayerConfig cfg, SEnvMappings e, float3 vNormal)
{
    return computeLayerColorInternal(vertOut, cfg, 1.0f, sampleEnvioMask(vertOut, cfg, e), vNormal);
}
