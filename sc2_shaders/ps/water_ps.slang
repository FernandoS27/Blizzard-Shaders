// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Water pixel shader (water.fx : WaterPixelMain) — an own-root PS family that reuses
// the SHARED DefaultPixelMain interpolant transport (VertexTransportRaw + InitShader)
// and the shared body stack (mainLighting / applyFog / applyFogOfWar / genCubicEnvio /
// tangentToWorld / decodeDepth).  Only the Water-specific helpers (WaterNormal, the
// pow-fresnel, the screen-space reflection/refraction UV) live here.
//
// Three compile-time branches (b_envMapPass / b_iCheapWater / "pretty" default):
//   * b_envMapPass          -> reflect the eye vector off the water normal, cube sample.
//   * b_iCheapWater         -> flat normal, one diffuse sample, lighting modulate, tint.
//   * else (pretty)         -> fresnel reflection/refraction, depth-driven tint,
//                              caustics, per-pixel lighting with a PS-recomputed
//                              (distorted) shadow UV.
//
// Measured over the 66 retail Water perms (sc2_perms/Water_ps.json): b_iDebugMode /
// b_iDebugRenderMode / b_useTransparentShadows / b_iBiasAdjustment / b_useBlendAdd /
// b_fogScaleByAlpha / b_FOWAdditiveScale are all 0, and b_iLightingMode is never
// PIXEL_SINGLEPASS, so the debug branch, point/spot lights and those fog/FOW/shadow
// sub-branches DCE.  b_iVertexLightingMode is NONE (per-pixel) on 64, FULL on 2.
// b_iInEncoding is {0,1,2} for the depth-effects sample (decodeDepth covers all three).

implementing sc2_shaders;

#ifndef b_iCheapWater
#define b_iCheapWater 0
#endif
#ifndef b_useCaustics
#define b_useCaustics 0
#endif
#ifndef b_useWaterDepthEffects
#define b_useWaterDepthEffects 0
#endif
#ifndef b_envMapPass
#define b_envMapPass 0
#endif
#ifndef b_useCubemapReflections
#define b_useCubemapReflections 0
#endif
#ifndef b_iUse8BitHDR
#define b_iUse8BitHDR 0
#endif

// water.fx : ComputeFresnel — the home-made pow fresnel (not physical).
float waterComputeFresnel(float3 vEyeVect, float3 vNormal)
{
    float eyeDotNormal = dot(vEyeVect, vNormal);
    float f = pow(1.0f - eyeDotNormal, psGlobals.vFresnelParams.x) + psGlobals.vFresnelParams.y;
    return saturate(f);
}

// water.fx : WaterNormal — two scrolling normal-map taps (xy and zw of Vector4),
// reconstruct z, sum + smoothing bias + normalize, rotate into world by the
// [tangent, cross(tangent,normal), normal] basis (tangentToWorld, identity-basis off).
float3 waterNormal(ModelPSInput vertOut)
{
    float3 norm0;
    norm0.xy = p_sTexture0_t.Sample(p_sSamp, vertOut.Vector4().xy).xy;
    norm0.xy = 2.0f * norm0.xy - 1.0f;
    norm0.z  = sqrt(1.0f - dot(norm0.xy, norm0.xy));

    float3 norm1;
    norm1.xy = p_sTexture0_t.Sample(p_sSamp, vertOut.Vector4().zw).zw;
    norm1.xy = 2.0f * norm1.xy - 1.0f;
    norm1.z  = sqrt(1.0f - dot(norm1.xy, norm1.xy));

    float3 vNormal = norm0 + norm1;
    vNormal = vNormal + psGlobals.vNormBias;
    vNormal = normalize(vNormal);
    vNormal = tangentToWorld(vNormal, vertOut.Normal().xyz, vertOut.Tangent().xyz,
                             cross(vertOut.Tangent().xyz, vertOut.Normal().xyz));
    return vNormal;
}

// water.fx : HPos2ScreenUv — VPOS_SEMANTIC path (PS_40+ on every Water perm):
// SV_Position.xy / render-target size.  (The non-VPOS INTERPOLANT_HPosAsUV branch is
// unreachable and DCEs — no Water perm has HPosAsUV live.)
float2 waterHPos2ScreenUv(ModelPSInput vertOut)
{
    return vertOut.HPos.xy / psGlobals.vRTSize;
}

float2 waterReflectionUv(ModelPSInput vertOut)
{
    float2 vResult = waterHPos2ScreenUv(vertOut);
    return (vResult + psGlobals.vVPOffset) * psGlobals.vVPScale;
}

float2 waterRefractionUv(ModelPSInput vertOut)
{
    return waterHPos2ScreenUv(vertOut);
}

[shader("fragment")]
public float4 water_ps_main(ModelPSInput vertOut) : SV_Target
{
#if b_envMapPass
    // -------- Water env-map pass -------------------------------------------------
    float3 vNormal = waterNormal(vertOut);
    float3 eyeDir = normalize(vertOut.WorldPos().xyz - psGlobals.vEyePos);
    float3 uv = genCubicEnvio(eyeDir, vNormal, true);
    return p_sEnvMap_t.SampleLevel(p_sSamp, uv.xyz, 0.0f);

#elif b_iCheapWater
    // -------- Cheap water --------------------------------------------------------
    float4 vFinal = float4(1, 1, 1, 1);
    vFinal.xyz = p_sTexture0_t.Sample(p_sSamp, vertOut.Vector4().xy).xyz;

    float3 vNormal = float3(0, 0, 1);
    LightResult lr = mainLighting(vertOut, vNormal, psGlobals.vSpecColorSpecularity.w,
                                  1.0f, vertOut.Vector4().xy * 512.0f, float4(1, 1, 1, 1));

    vFinal.xyz = (vFinal.xyz * lr.cLightDiffuse + vFinal.xyz) + lr.cLightSpecular * vFinal.xyz;
    vFinal.xyz *= (float3(0.1f, 0.1f, 0.1f) + psGlobals.vTint.xyz);
    vFinal.xyz = applyFog(vertOut, vFinal, 1.0f, lr.cLightingRegionMap).xyz;
  #if b_iUse8BitHDR
    vFinal.xyz *= psGlobals.vHDRScaling.x;
  #endif
    {
        float3 stubDiffuse = float3(0, 0, 0);
        vFinal.xyz = applyFogOfWar(ndc2Tex(vertOut.FOWUV().xy), vFinal, stubDiffuse).xyz;
    }
    return float4(vFinal.xyz, max(psGlobals.vTint.w, 0.5f));

#else
    // -------- Pretty water -------------------------------------------------------
    float3 vNormal = waterNormal(vertOut);
    float3 rnd = vNormal;

    float3 worldPos = vertOut.WorldPos().xyz;
    float3 eyeDir = normalize(psGlobals.vEyePos - worldPos);
    float fresnel = waterComputeFresnel(eyeDir, vNormal);

    float2 reflectionUv = waterReflectionUv(vertOut);
    float2 refractionUv = waterRefractionUv(vertOut);

    // tint, a function of depth
    float tintBlend = psGlobals.vTint.w;
    float depth = 0.5f;
    float saturatedDepth = 0.5f;
    float2 refractionUvDistortion = float2(0, 0);
  #if b_useWaterDepthEffects
    {
        // Only PIXEL_DEPTH (== DecodeDepth of the sample) is read; DecodeNormal DCEs.
        float waterPlaneDepth = vertOut.ViewPos().y;
        depth = decodeDepth(p_sDepthMap_t.Sample(p_sSamp, refractionUv)) - waterPlaneDepth;
        depth = max(0.0f, depth);
        saturatedDepth = saturate(depth);

        tintBlend = psGlobals.fTintFallOff * depth;
        tintBlend = clamp(tintBlend, psGlobals.vTint.w, 1.0f);

        // refraction distortion, re-projected through the depth of the distorted tap
        refractionUvDistortion = vNormal.xy * psGlobals.fRefractionDistortion * depth;
        float depth2 = decodeDepth(p_sDepthMap_t.Sample(p_sSamp, refractionUv + refractionUvDistortion))
                     - waterPlaneDepth;
        depth2 = max(0.0f, depth2);
        refractionUvDistortion *= saturate(depth2);
    }
  #endif

    // make normal variation at shore smaller
    vNormal = lerp(float3(0, 0, 1), vNormal, saturatedDepth);

    // reflection
    float4 cReflection;
  #if b_useCubemapReflections
    {
        // eyeDir is world->eye, so negate for the cubemap lookup.
        float3 cubeUV = genCubicEnvio(-eyeDir, vNormal, true);
        cReflection = p_sEnvMap_t.Sample(p_sSamp, cubeUV.xyz);
    }
  #else
    {
        float distortion = psGlobals.fReflectionDistortion * saturatedDepth;
        reflectionUv += vNormal.xy * distortion;
        cReflection = p_sRelectionMap_t.Sample(p_sSamp, reflectionUv);
    }
  #endif

    // lighting — distort the shadow lookup in world space, then per-pixel light.
    float3 vNewPos = vertOut.WorldPos().xyz + psGlobals.fShadowDistortion * rnd;
    float4 vShadowUv = mul(float4(vNewPos, 1.0f), psGlobals.mShadowTransform);
    LightResult lr = mainLighting(vertOut, vNormal, psGlobals.vSpecColorSpecularity.w,
                                  1.0f, vertOut.Vector4().xy * 512.0f, vShadowUv);

    // refraction (+ caustics on the sea floor)
    float4 cRefraction = p_sRefractionMap_t.Sample(p_sSamp, refractionUv + refractionUvDistortion);
  #if b_useCaustics
    {
        float3 bottomPos = worldPos - eyeDir * depth;
        float2 vCausticsUv = psGlobals.vCausticsUvTiling * bottomPos.xy;
        vCausticsUv.y = 1.0f - vCausticsUv.y;
        vCausticsUv = mul(float4(vCausticsUv.xy, 0.0f, 1.0f), psGlobals.mUvMatrixPS).xy;
        float4 vCaustics = p_sTexture1_t.Sample(p_sSamp, vCausticsUv);
        vCaustics.xyz *= lr.cShadowColor.rgb;
        cRefraction += vCaustics * saturate(psGlobals.fCausticsFallOff * depth);
    }
  #endif

    // blend in refraction
    cRefraction = lerp(cRefraction, psGlobals.vTint, tintBlend);
    cRefraction.xyz = lr.cLightDiffuse * cRefraction.xyz;

    // combine reflection and refraction
    float4 final = float4(0, 0, 0, 1);
    final.xyz = lerp(cRefraction.xyz, cReflection.xyz, fresnel)
              + lr.cLightSpecular * psGlobals.fSpecularScaler;

    final.xyz = applyFog(vertOut, final, 1.0f, lr.cLightingRegionMap).xyz;
    {
        float3 stubDiffuse = float3(0, 0, 0);
        final.xyz = applyFogOfWar(ndc2Tex(vertOut.FOWUV().xy), final, stubDiffuse).xyz;
    }
    // (b_iDebugMode == 0 on every Water perm -> the DebugColor branch DCEs.)
    return float4(final.xyz, 1.0f);
#endif
}
