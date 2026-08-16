// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family shadowing (psshadow.fx : ShadowIntensity / SampleShadowMap /
// DecodeSoftShadowUV), the cShadowColor MainLighting scales the key light by.
//
// Covers the hard-shadow arm (one comparison sample), the SOFT-shadow arm (the
// rotation-texture PCF kernel over p_vSoftShadowTapOffsets, with the optional
// depth-bias adjustment), and TRANSPARENT shadows (a second depth map + colour
// map).  The commented-out parallax-shadow block in the .fx is a no-op and omitted.

implementing sc2_shaders;

#ifndef b_useShadows
#define b_useShadows 0
#endif
#ifndef b_iUseSoftShadows
#define b_iUseSoftShadows 0
#endif
#ifndef b_useTransparentShadows
#define b_useTransparentShadows 0
#endif
#ifndef b_iUseExplicitShadowTest
#define b_iUseExplicitShadowTest 0
#endif
#ifndef b_iBiasAdjustment
#define b_iBiasAdjustment 0
#endif
#ifndef b_iSoftShadowTaps
#define b_iSoftShadowTaps 0
#endif
#ifndef b_iUVEmitterCount
#define b_iUVEmitterCount 0
#endif

// psshadow.fx : SampleShadowMap — one comparison sample (sampleTexShadow =
// SampleCmpLevelZero(sampler, uv.xy/uv.w, uv.z)); the caller has already divided by
// w, so uv.w==1 and the /w is a no-op.
float sampleShadowMapTex(Texture2D<float> tShadow, SamplerComparisonState sShadow, float4 shadowMapUV)
{
    float s = tShadow.SampleCmpLevelZero(sShadow, shadowMapUV.xy / shadowMapUV.w, shadowMapUV.z);
#if b_iUseExplicitShadowTest
    return (s > shadowMapUV.z) ? 1.0f : 0.0f;
#else
    return s;
#endif
}

// The key shadow map, bound.
float sampleShadowMap(float4 shadowMapUV)
{
    return sampleShadowMapTex(p_sShadowMap_t, p_sCmpSamp, shadowMapUV);
}

// psmaterial.fx : DecodeSoftShadowUV — the noise-rotation UV for the soft-shadow
// kernel.  VPOS_SEMANTIC (PS_40+) uses ScreenPos; with UV emitters it uses UV0*256.
float2 decodeSoftShadowUV(ModelPSInput vertOut)
{
#if b_useShadows && b_iUseSoftShadows
  #if (b_iUVEmitterCount > 0)
    return vertOut.UV(0).xy * 256.0f;
  #else
    return vertOut.HPos.xy / psGlobals.vRotationTextureUVScale;
  #endif
#else
    return float2(0, 0);
#endif
}

// psshadow.fx : ShadowIntensity — 1 = fully lit.  (The heightmap/parallax-shadow
// args are only used by the commented-out parallax block, so they are dropped.)
float4 shadowIntensity(ModelPSInput vertOut, float4 shadowMapUV, float2 softShadowUV)
{
#if b_useShadows
    float4 cShadowColor;
  #if b_iUseSoftShadows
    shadowMapUV = shadowMapUV / shadowMapUV.w;
    cShadowColor = float4(0, 0, 0, 0);

    float2 ddist_duv = float2(0, 0);
    #if b_iBiasAdjustment
    {
        float4 duvdist_dx = ddx(shadowMapUV);
        float4 duvdist_dy = ddy(shadowMapUV);
        float temp = (duvdist_dx.x * duvdist_dy.y) - (duvdist_dx.y * duvdist_dy.x);
        if (temp != 0.0f)
        {
            float invDet = 1.0f / temp;
            ddist_duv.x = duvdist_dy.y * duvdist_dx.z - duvdist_dx.y * duvdist_dy.z;
            ddist_duv.y = duvdist_dx.x * duvdist_dy.z - duvdist_dy.x * duvdist_dx.z;
            ddist_duv *= invDet;
        }
        else ddist_duv = float2(0, 0);
    }
    #endif

    // Random rotation vector from the noise texture.
    float3 rotation;
    rotation.xy = normalize(p_sRotationTexture_t.Sample(p_sSamp, softShadowUV).ra);
    rotation.z = -rotation.y;

    // Two taps per iteration.
    for (int i = 0; i < b_iSoftShadowTaps / 2; i++)
    {
        float4 rotOffset = rotation.xzxz * psGlobals.vSoftShadowTapOffsets[i].xxzz
                         + rotation.yxyx * psGlobals.vSoftShadowTapOffsets[i].yyww;

        float4 sampleUV = shadowMapUV;
        #if b_iBiasAdjustment
        sampleUV.z += ddist_duv.x * rotOffset.x + ddist_duv.y * rotOffset.y;
        #endif
        cShadowColor += sampleShadowMap(sampleUV + rotOffset.xyxx * float4(1.0f, 1.0f, 0.0f, 0.0f));

        sampleUV = shadowMapUV;
        #if b_iBiasAdjustment
        sampleUV.z += ddist_duv.x * rotOffset.z + ddist_duv.y * rotOffset.w;
        #endif
        cShadowColor += sampleShadowMap(sampleUV + rotOffset.zwxx * float4(1.0f, 1.0f, 0.0f, 0.0f));
    }

    #if (b_iSoftShadowTaps > 0)
    cShadowColor = cShadowColor / b_iSoftShadowTaps;
    #endif
  #else
    shadowMapUV = shadowMapUV / shadowMapUV.w;
    cShadowColor = sampleShadowMap(shadowMapUV);
  #endif

  #if b_useTransparentShadows
    {
        float fTransparentOcclusion = sampleShadowMapTex(
            p_sTransparentShadowDepthMap_t, p_sCmpSamp, shadowMapUV);
        if (fTransparentOcclusion < 1.0f)
            cShadowColor.rgb = cShadowColor.rgb
                * p_sTransparentShadowColorMap_t.Sample(p_sSamp, shadowMapUV.xy).rgb;
    }
  #endif

    return cShadowColor;
#else
    return float4(1, 1, 1, 1);
#endif
}
