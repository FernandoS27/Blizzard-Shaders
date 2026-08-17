// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family MainShading (psmainshading.fx : MainShading) + MaterialColor
// (psmaterial.fx : MaterialColor).
//
// M1 BOOTSTRAP SCOPE: the standard shading mode with NO material layers and no
// lighting — i.e. cResult = ApplyFog(black, AlphaFactor).  This proves the Model
// PS spine (interpolant transport + DefaultPixelMain wrapper + standard arm +
// fog) end-to-end.  The 18-layer material stack, MainLighting, shadows, normal
// decode, POM, FOW and the non-standard shading arms are transcribed in the
// following M1 increments — each guarded by its `b_*` axis so already-green
// perms stay green.

implementing sc2_shaders;

// Shared layer/material enums (slang's __include does NOT propagate #defines across
// files, so each file that references them in #if / runtime code redeclares them;
// values from psmaterialdefines.fx / psmaterial.fx).
#define LAYEROP_MOD                     0
#define LAYEROP_MOD2X                   1
#define LAYEROP_ADD                     2
#define LAYEROP_LERP                    3
#define CHANNELSELECT_RGB              0
#define CHANNELSELECT_RGBA            1
#define SPECULAR_RGB                   0
#define SPECULAR_A_ONLY                1
#define TEAMCOLOR_DIFFUSE              1

// materialdefines.fx shading-mode enum — redeclared here because slang's __include
// does NOT propagate #defines across files, and the dispatch `#if b_iShadingMode ==
// SHADINGMODE_*` must compare against the real values (b_iShadingMode is passed as a
// -D define; an undefined SHADINGMODE_* would read 0 and mis-route every non-standard
// mode).
#define SHADINGMODE_STANDARD          0
#define SHADINGMODE_DISPLACEMENT      1
#define SHADINGMODE_VECTORUI          2
#define SHADINGMODE_TERRAIN           3
#define SHADINGMODE_VOLUME            4
#define SHADINGMODE_MODEL_TRIANGLE_ID 5
#define SHADINGMODE_REFLECTION        6
#define SHADINGMODE_CLOAKING          7
#ifndef b_iShadingMode
#define b_iShadingMode 0
#endif

// ---- axis defaults for the MaterialColor feature axes -----------------------
#ifndef b_iFakeEnergyConservingSpec
#define b_iFakeEnergyConservingSpec 0
#endif
#ifndef b_iLightmapShadow
#define b_iLightmapShadow 0
#endif
#ifndef b_useVertexAlpha
#define b_useVertexAlpha 0
#endif
#ifndef b_splatAttenuationEnabled
#define b_splatAttenuationEnabled 0
#endif
#ifndef b_iModAlpha
#define b_iModAlpha 0
#endif
#ifndef b_iEnvioLayerEnable
#define b_iEnvioLayerEnable 0
#endif
#ifndef b_useDepthBlend
#define b_useDepthBlend 0
#endif
#ifndef b_iClampOutput
#define b_iClampOutput 0
#endif
#ifndef b_iNormalBlending
#define b_iNormalBlending 0
#endif
#ifndef b_useParallaxMapping
#define b_useParallaxMapping 0
#endif
#ifndef b_iNormalUVEmitter
#define b_iNormalUVEmitter 0
#endif
#ifndef b_haloPass
#define b_haloPass 0
#endif
#ifndef b_computeHeight
#define b_computeHeight 0
#endif
#ifndef b_no8BitHDR
#define b_no8BitHDR 0
#endif

// pscommon.fx depth/normal encoding enum + b_iInEncoding default (the depth-blend
// path reads only the depth channel; the normal decode is DCE'd, so DecodeNormal /
// p_mInvViewTransform are omitted).
#define DEPTH_NORMAL_ENCODING_FLOAT   0
#define DEPTH_NORMAL_ENCODING_RGBA    1
#define DEPTH_NORMAL_ENCODING_RGBA16  2
#ifndef b_iInEncoding
#define b_iInEncoding 0
#endif

// pscommon.fx : DecodeDepth — recover the linear depth from the prepass sample.
float decodeDepth(float4 cSample)
{
#if (b_iInEncoding == DEPTH_NORMAL_ENCODING_RGBA)
    float fDepth = dot(cSample.ba, float2(1.0f, 1.0f / 255.0f));
    return psGlobals.fMaxDepthFactor * ((1.0f / (1.0f - fDepth)) - 1.0f);
#elif (b_iInEncoding == DEPTH_NORMAL_ENCODING_RGBA16)
    return psGlobals.fMaxDepthFactor * ((1.0f / (1.0f - cSample.a)) - 1.0f);
#else   // DEPTH_NORMAL_ENCODING_FLOAT (and the else -> 0 case, which fxc folds here)
    return cSample.a;
#endif
}

// psmaterial.fx : MaterialColor — the full standard-path material stack for the
// transcribed layers: Diffuse, Decal, Specular, the fake-energy-conserving specular
// dim, the Lightmap light-replace, the lighting blend, the Emissive/Emissive2
// additive/modulate layers, vertex-colour + material tint, alpha (vertex-alpha +
// alpha factor), the AlphaMask/AlphaMask2 alpha layers, and ModAlpha; it also
// surfaces the g-buffer diffuse/specular.  Envio, normal mapping, depth-blend,
// splat-attenuation, and the debug tail are gated out (their axes stay off in the
// classes routed here) until their increments.
float4 materialColor(ModelPSInput vertOut, float3 vNormal,
                     float3 cLightDiffuse, float3 cLightSpecular,
                     float4 cShadowColor, float fSpecularity,
                     inout DeferredOutputs def, TriPlanarUVs tp)
{
    float3 cDeferredDiffuse = float3(0, 0, 0);
    float3 cDeferredSpecular = float3(0, 0, 0);
    float3 cEmissive = float3(0, 0, 0);
    float  fTeamColorAlpha = 0.0f;    // diffuse layer alpha, fed to team-colour specular

    // ComputeEnvMappings (psmaterial.fx:155) is dead unless an Envio layer samples
    // it, so it is omitted until the Envio increment.

    // ---- Team-coloured diffuse layer (psmaterial.fx:163-171) ----
#if b_iDiffuseLayerEnable
    {
        SLayerConfig cfg = setupDiffuseLayer();
        float4 cColor = getLayerColor2D(vertOut, cfg, p_sDiffuseSampler_t, p_sSamp, 1.0f, vNormal, tp);
        cDeferredDiffuse = combineLayerColor(cColor, cDeferredDiffuse, cfg);
        fTeamColorAlpha = cColor.a;
    }
#endif

    // ---- Decal layer (psmaterial.fx:175-179) ----
#if b_iDecalLayerEnable
    {
        SLayerConfig cfg = setupDecalLayer();
        float4 cColor = getLayerColor2D(vertOut, cfg, p_sDecalSampler_t, p_sSamp, 1.0f, vNormal, tp);
        cDeferredDiffuse = combineLayerColor(cColor, cDeferredDiffuse, cfg);
    }
#endif

    // ---- Specular layer (psmaterial.fx:182-201) ----
#if b_iSpecularLayerEnable
    {
        SLayerConfig cfg = setupSpecularLayer();
        float4 cColor = getLayerColor2D(vertOut, cfg, p_sSpecularSampler_t, p_sSamp, 1.0f, vNormal, tp);
    #if (b_iSpecularType == SPECULAR_A_ONLY)
        #if (b_iDiffuseTeamColorMode == TEAMCOLOR_DIFFUSE) && b_useTeamColorSpecular
        float a = lerp(psGlobals.cDiffuseTeamColor.a, cColor.a, fTeamColorAlpha);
        cColor = float4(a, a, a, a);
        #endif
    #else
        #if (b_iDiffuseTeamColorMode == TEAMCOLOR_DIFFUSE) && b_useTeamColorSpecular
        cColor = float4(lerp(psGlobals.cDiffuseTeamColor.rgb, cColor.rgb, fTeamColorAlpha), 1.0f);
        #endif
    #endif
        cDeferredSpecular = combineLayerColor(cColor, cDeferredSpecular, cfg);
    }
#endif

    // ---- Fake energy-conserving specular dim (psmaterial.fx:203-208) ----
#if b_iFakeEnergyConservingSpec
    {
        float powClamped = clamp(fSpecularity, 1.0f, 512.0f);
        float dim = saturate(-0.000004444f * powClamped * powClamped
                             + 0.004333f * powClamped + 0.0020834f);
        cDeferredSpecular *= dim;
    }
#endif

    // ---- litOnly light-suppression (psmaterial.fx:212-217) ----
#if b_litOnly && (b_useLighting == 0)
    cLightDiffuse = float3(0, 0, 0);
    cLightSpecular = float3(0, 0, 0);
#endif

    // ---- Lightmap layer replaces the diffuse light (psmaterial.fx:221-229) ----
#if b_iLightmapLayerEnable
    {
        SLayerConfig cfg = setupLightmapLayer();
        float4 cColor = getLayerColor2D(vertOut, cfg, p_sLightmapSampler_t, p_sSamp, 1.0f, vNormal, tp) * 2.0f;
        cLightDiffuse = cColor.rgb;
        cLightSpecular = float3(0, 0, 0);
    #if b_iLightmapShadow
        cLightDiffuse *= lerp(psGlobals.cLightmapShadowColor, float3(1, 1, 1), cShadowColor.a);
    #endif
    }
#endif

    // ---- Blend the lighting components (psmaterial.fx:233-238) ----
    float4 cFinal;
    cFinal.rgb = cDeferredDiffuse * cLightDiffuse;
#if b_useLighting && b_useSpecular
    cFinal.rgb += cDeferredSpecular * cLightSpecular;
#else
    cLightSpecular = float3(0, 0, 0);
#endif

    // ---- Emissive layers (psmaterial.fx:240-276), inside if(!b_litOnly) ----
#if !b_litOnly
    bool bAdd = false;
  #if b_iEmissiveLayerEnable
    {
        SLayerConfig cfg = setupEmissiveLayer();
        float4 cColor = getLayerColor2D(vertOut, cfg, p_sEmissiveSampler_t, p_sSamp, 1.0f, vNormal, tp);
    #if (b_iEmissiveOp == LAYEROP_MOD) || (b_iEmissiveOp == LAYEROP_MOD2X) || (b_iEmissiveOp == LAYEROP_LERP)
        cFinal.rgb = combineLayerColor(cColor, cFinal.rgb, cfg);
    #else
        cEmissive = combineLayerColor(cColor, cEmissive, cfg);
        bAdd = true;
    #endif
    }
  #endif
  #if b_iEmissive2LayerEnable
    {
        SLayerConfig cfg = setupEmissive2Layer();
        float4 cColor = getLayerColor2D(vertOut, cfg, p_sEmissive2Sampler_t, p_sSamp, 1.0f, vNormal, tp);
    #if (b_iEmissive2Op == LAYEROP_MOD) || (b_iEmissive2Op == LAYEROP_MOD2X) || (b_iEmissive2Op == LAYEROP_LERP)
        if (!bAdd)
            cFinal.rgb = combineLayerColor(cColor, cFinal.rgb, cfg);
        else { cEmissive = combineLayerColor(cColor, cEmissive, cfg); bAdd = true; }
    #else
        cEmissive = combineLayerColor(cColor, cEmissive, cfg);
        bAdd = true;
    #endif
    }
  #endif
    if (bAdd)
    {
    #if b_iEmissiveLayerEnable || b_iEmissive2LayerEnable
        cEmissive = cEmissive * psGlobals.fEmissiveMultiplier;
    #endif
        cFinal.rgb += cEmissive.rgb;
    }
#endif

    // ---- Environment-map layer (psmaterial.fx:280-338), inside if(!b_litOnly) ----
#if !b_litOnly && b_iEnvioLayerEnable
    {
        SLayerConfig cfgE = setupEnvioLayer();
        // ComputeEnvMappings (psmaterial.fx:155) transforms the normal + eye vector by
        // the env-map matrix; only reached when an Envio layer samples it.
        SEnvMappings envMappings = computeEnvMappings(
            mul(psGlobals.mEnvironmentMapTransform, float4(vNormal, 1.0f)).xyz,
            mul(psGlobals.mEnvironmentMapTransform, float4(vertOut.EyeToVertex(), 1.0f)).xyz);

        float4 cColorE;
    #if b_iBlurEnvironmentMap
        // Mip from the UV / eye-vector deltas (psmaterial.fx:299-313).
        float3 deltaX, deltaY;
        #if b_useNormalMapping && b_iNormalLayerEnable
        {
            SLayerConfig cfgN = setupNormalLayer();
            float4 vUVn = getUVEmitter(vertOut, cfgN.b_iUVEmitter,
                                       cfgN.p_vMultiplyAddAlphaTrans.w, cfgN.p_mUVTransform);
            deltaX = ddx(vUVn.xyz * psGlobals.vEnvioTextureSize.x);
            deltaY = ddy(vUVn.xyz * psGlobals.vEnvioTextureSize.y);
        }
        #else
            deltaX = ddx(vertOut.EyeToVertex().xyz * 0.25f * psGlobals.vEnvioTextureSize.x);
            deltaY = ddy(vertOut.EyeToVertex().xyz * 0.25f * psGlobals.vEnvioTextureSize.y);
        #endif
        float mipLevel = max(dot(deltaX, deltaX), dot(deltaY, deltaY));
        mipLevel = max(0.0f, 0.5f * log2(mipLevel));
        float bias = psGlobals.vEnvioTextureSize.z * (1.0f - def.cGlossiness);
        cColorE = getLayerColorEnvio(vertOut, cfgE, envMappings, mipLevel + bias, vNormal);
    #else
        cColorE = getLayerColorEnvio(vertOut, cfgE, envMappings, -1.0f, vNormal);
    #endif

        // Envio mask (psmaterial.fx:319-326).
        float4 cMaskValue;
    #if b_iEnvioMaskLayerEnable
        {
            SLayerConfig cfgM = setupEnvioMaskLayer();
            cMaskValue = getLayerColorEnvioMask(vertOut, cfgM, envMappings, vNormal);
            if (cfgM.b_iChannelSelect == CHANNELSELECT_RGBA)
                cMaskValue.rgb *= cMaskValue.a;
            cMaskValue *= cColorE.a;
        }
    #else
        cMaskValue = cColorE.a;
    #endif

    #if b_iEnvioMultipliers
        float3 cConstant = cColorE.rgb * psGlobals.vEnvioConstantDiffSpec.x;
        cConstant += cColorE.rgb * cLightDiffuse * psGlobals.vEnvioConstantDiffSpec.y;
        cConstant += cColorE.rgb * cLightSpecular * psGlobals.vEnvioConstantDiffSpec.z;
        cFinal.rgb = applyEnv(cFinal.rgb, cConstant, cMaskValue, cfgE.b_iOp);
        cDeferredDiffuse = applyEnv(cDeferredDiffuse, cColorE.rgb * psGlobals.vEnvioConstantDiffSpec.y, cMaskValue, cfgE.b_iOp);
        cDeferredSpecular = applyEnv(cDeferredSpecular, cColorE.rgb * psGlobals.vEnvioConstantDiffSpec.z, cMaskValue, cfgE.b_iOp);
    #else
        cFinal.rgb = applyEnv(cFinal.rgb, cColorE.rgb, cMaskValue, cfgE.b_iOp);
    #endif
    }
#endif

    // ---- Tinting (psmaterial.fx:342-349), inside if(!b_litOnly) ----
#if !b_litOnly
  #if b_useVertexColors
    {
        float3 cVertex = saturate(vertOut.VertexColor().xyz);
        cFinal.rgb *= cVertex;
        cDeferredDiffuse.rgb *= cVertex;
    }
  #endif
    cFinal.rgb *= psGlobals.fMaterialTint;
    cDeferredDiffuse.rgb *= psGlobals.fMaterialTint;
#endif

    // ---- Alpha (psmaterial.fx:354-361) ----
    cFinal.a = 1.0f;
#if b_useVertexAlpha
    cFinal.a *= saturate(vertOut.VertexColor().a);
#endif
    cFinal.a *= psGlobals.vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor.w;
    // SplatAttenuationProjector (psmaterial.fx:359-361 -> common.fx:81-88).  Splat
    // families (SplatDirect/SplatDeferred) enable this; the VS packs the plane into
    // VectorUI0, worldPos into VectorUI1.xyz, halfHeight into VectorUI1.w and
    // minHeight into Tangent.w (splatdirect.fx:215-218).  PIXEL_SHADER_VERSION >= PS_30
    // is always true for the ps_5_0 target, so only b_splatAttenuationEnabled gates it.
#if b_splatAttenuationEnabled
    {
        float3 saWorldPos = vertOut.VectorUI1().xyz;
        float4 saPlane = vertOut.VectorUI0();
        float saHalfHeight = vertOut.VectorUI1().w;
        float saMinHeight = vertOut.Tangent().w;
        float saD = abs(dot(float4(saWorldPos, 1.0f), saPlane));
        cFinal.a *= saturate((saHalfHeight - saD) / (saHalfHeight - saMinHeight));
    }
#endif

    // Soft/depth blend (psmaterial.fx:365-372): fade the alpha toward 0 as the
    // fragment approaches the prepass depth (a.k.a. soft particles).  PIXEL_SHADER_VERSION
    // >= PS_30 is always true for our ps_5_0 target.  Only the depth channel of the
    // prepass sample is used (DecodeNormal is DCE'd).
#if b_useDepthBlend
    {
        float4 vNormalDepth = p_sNormalDepthMap_t.Sample(p_sSamp, getBackBufferUV(vertOut));
        float fDistToSampledDepth = max(0.0f, decodeDepth(vNormalDepth) - vertOut.ViewPos().y);
        float thr = psGlobals.vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor.y;
        if (fDistToSampledDepth < thr)
            cFinal.a *= (fDistToSampledDepth / thr);
    }
#endif

    // Save off the whole-pixel transparency (psmaterial.fx:376).
    float fade = cFinal.a;

    // ---- Alpha mask layers (psmaterial.fx:380-390) ----
#if b_iAlphaMaskLayerEnable
    {
        SLayerConfig cfg = setupAlphaMaskLayer();
        cFinal.a *= getLayerColor2D(vertOut, cfg, p_sAlphaMaskSampler_t, p_sSamp, 1.0f, vNormal, tp).a;
    }
#endif
#if b_iAlphaMask2LayerEnable
    {
        SLayerConfig cfg = setupAlphaMask2Layer();
        // Epsilon works around a shader-compiler bug (psmaterial.fx:389).
        cFinal.a *= (getLayerColor2D(vertOut, cfg, p_sAlphaMask2Sampler_t, p_sSamp, 1.0f, vNormal, tp).a + 0.00000001f);
    }
#endif

#if !b_useBlendAdd
    fade = cFinal.a;
#endif

    // ---- ModAlpha premultiply (psmaterial.fx:396-397) ----
#if b_iModAlpha
    cFinal.rgb *= fade;
#endif

    // The deferred specular output carries the material specular multiplier (it is
    // pre-baked into the light's specular for the forward blend, so applied here
    // only for the g-buffer) — psmaterial.fx:402.
    cDeferredSpecular *= psGlobals.vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor.x;

    // Surface the g-buffer material colours (psmaterial.fx inout cDeferredDiffuse /
    // cDeferredSpecular).
    def.cDiffuse = cDeferredDiffuse;
    def.cSpecular = cDeferredSpecular;

    // Clamp the final colour to [0,1] (psmaterial.fx:432) — the g-buffer outputs are
    // NOT clamped by this axis (only cFinal).
#if b_iClampOutput
    cFinal = saturate(cFinal);
#endif
    return cFinal;
}

// pshalo.fx : GetHaloColor — the b_haloPass arm (a screen-space strobe falloff).
float4 getHaloColor(float2 vUV, float4 cColor, float fStrobeOffset,
                    float fStrobeSizeRcp, float fStrobeFalloff)
{
    float4 cResult = cColor;
    float Dist = abs(vUV.y - fStrobeOffset) * fStrobeSizeRcp;
    cResult.rgb *= saturate(max(1.0f - pow(Dist, fStrobeFalloff), 0.0f) + cColor.a);
    cResult.a = 1.0f;
    return cResult;
}

// psmainshading.fx : MainShading — dispatch on b_iShadingMode.  Only the standard
// arm is transcribed so far; other modes (terrain/displacement/volume/…) land in
// M2 and leave cResult at its (1,1,1,1) init until then.
float4 mainShading(ModelPSInput vertOut, out DeferredOutputs def)
{
    float4 cResult = float4(1, 1, 1, 1);

    // g-buffer inits.  DefaultPixelMain zeroes them (psmainshading.fx:48-53), then
    // MainShading (114-116) re-inits vDeferredNormal=0, cDeferredAO=1, cDeferredDiffuse=1
    // — so cDiffuse enters the arms as 1 (matters for the non-standard arms that don't
    // set it, e.g. cloaking's MRT-diffuse perms; standard always overwrites it).
    def.vNormal = float3(0, 0, 0);
    def.cDiffuse = float3(1, 1, 1);
    def.cSpecular = float3(0, 0, 0);
    def.cAO = 1.0f;             // DecodeAOValue only overwrites this via the AO layer
    def.cSpecularPower = 0.0f;
    def.cGlossiness = 0.0f;

    // NOTE: ClipPlanes (common.fx) is a no-op unless HPosAsUV is live + clip
    // planes are bound; it never affects the output, so it is omitted until a
    // perm needs it.

#if (b_iShadingMode == SHADINGMODE_STANDARD) && !b_haloPass
    // ---------- standard ----------
    // Precompute the shared triplanar UV table (psmainshading.fx:131-132), threaded
    // through every material-layer sample.
    TriPlanarUVs tp = initTriPlanarUVs(vertOut);

    // Apply parallax (psmainshading.fx:135-136): offset every UV emitter by the height-
    // map parallax before any material sample.  mainShading's `vertOut` is a by-value
    // copy, so the mutation is local to this invocation.  The heightmap UV uses the
    // NORMAL layer's UV emitter with the Heightmap layer's transform (per the .fx).
#if b_useParallaxMapping
    {
        SLayerConfig hmCfg = setupHeightmapLayer();
        float4 hmUV = getUVEmitter(vertOut, b_iNormalUVEmitter,
                                   hmCfg.p_vMultiplyAddAlphaTrans.w, hmCfg.p_mUVTransform);
        applyParallax(vertOut, hmUV);
    }
#endif

    // DecodeNormal once (psmainshading.fx:139), fed to BOTH lighting and material
    // (the fresnel term), matching the reference's single decode.
    float3 vDeferredNormal = decodeNormal(vertOut);
#if b_iNormalBlending
    vDeferredNormal = normalBlending(vertOut, vDeferredNormal, tp);
#endif
    def.vNormal = vDeferredNormal;

    // Decode AO (psmainshading.fx:147): the AO material layer writes def.cAO and the
    // result feeds MainLighting's ambient/secondary terms.
    float fAmbientOcclusion = decodeAOValue(vertOut, vDeferredNormal, def.cAO, tp);

    // MaterialSpecularity (psmainshading.fx:154) feeds the Blinn specular exponent
    // and the deferred glossiness; cDeferredSpecularPower = fSpecularity
    // (psmainshading.fx:155).  Then Lighting (MainLighting) and MaterialColor, which
    // blends the material diffuse/specular by the light diffuse/specular.
    float fSpecularity = materialSpecularity(vertOut, vDeferredNormal, def.cGlossiness, tp);
    def.cSpecularPower = fSpecularity;
    // psmainshading.fx:151 — the standard arm decodes the soft-shadow noise UV and
    // passes it to MainLighting.
    float2 stdSoftShadowUV = decodeSoftShadowUV(vertOut);
    LightResult light = mainLighting(vertOut, vDeferredNormal, fSpecularity,
                                     fAmbientOcclusion, stdSoftShadowUV);
    cResult = materialColor(vertOut, vDeferredNormal,
                            light.cLightDiffuse, light.cLightSpecular,
                            light.cShadowColor, fSpecularity, def, tp);

    // Unlit override (psmainshading.fx:175-179): the deferred outputs collapse when
    // lighting is off.  Folds away for the lit class under test.
#if b_useLighting == 0
    def.cDiffuse = float3(0, 0, 0);
    def.cSpecular = float3(0, 0, 0);
    def.cSpecularPower = 1.0f;
#endif

    // Fog (runs when b_iDebugMode == NO_DEBUG, true on the transcribed perms).  The
    // lighting-region map (cLightingRegionMap) selects the per-region fog colours.
    cResult.rgb = applyFog(vertOut, cResult, 1.0f, light.cLightingRegionMap).rgb;

    // Fog of war (psmainshading.fx:189).  The .fx gate is
    // b_iDebugMode==NO_DEBUG && b_iDebugRenderMode==NO_DEBUG_RENDER_MODE &&
    // b_emitFinalColor; the debug-mode half lands with the debug increment (the
    // transcribed class is always NO_DEBUG), so only the b_emitFinalColor half
    // is gated here.  ApplyFogOfWar internally no-ops unless b_FOWEnabled.
#if b_emitFinalColor
    {
        // cDeferredDiffuse is inout here (psfow.fx:56/60/64 modify it in the FOW
        // branches), so the g-buffer diffuse target reflects the FOW result too.
        float2 fowUV = ndc2Tex(vertOut.FOWUV().xy);
        cResult.rgb = applyFogOfWar(fowUV, cResult, def.cDiffuse).rgb;
    }
#endif

    // 8-bit HDR scaling (psmainshading.fx:192) — always applied when set (not
    // gated on debug, unlike fog/FOW).
#if b_iUse8BitHDR
    cResult.rgb *= psGlobals.vHDRScaling.x;
#endif

    // ---------- halo (psmainshading.fx:199-200) ----------
    // A separate arm that replaces cResult with the screen-space halo strobe.  In the
    // .fx if-ladder this is `else if (b_haloPass)`, reached only when the standard arm's
    // `mode==STANDARD && !halo` guard fails — i.e. exactly when b_haloPass is set.
#elif b_haloPass
    cResult = getHaloColor(getBackBufferUV(vertOut), psGlobals.cHaloColor,
                           psGlobals.fStrobeOffset, psGlobals.fStrobeSizeRcp,
                           psGlobals.fStrobeFalloff);

    // ---------- terrain (psmainshading.fx:204-207) ----------
#elif (b_iShadingMode == SHADINGMODE_TERRAIN)
    cResult = shadeTerrain(vertOut, def);
  #if b_iUse8BitHDR && !b_computeHeight && !b_no8BitHDR
    cResult.rgb *= psGlobals.vHDRScaling.x;
  #endif

    // ---------- displacement (psmainshading.fx:211-213) ----------
#elif (b_iShadingMode == SHADINGMODE_DISPLACEMENT)
    // DecodeNormal(vertOut) is computed into vDeferredNormal in the .fx but is only a
    // g-buffer/fresnel feed; with no MRT on any displacement perm it DCEs, so Displace
    // (which reads INTERPOLANT_Normal directly) needs nothing from it.
    cResult = displace(vertOut);

    // ---------- vector UI (psmainshading.fx:217-220) ----------
#elif (b_iShadingMode == SHADINGMODE_VECTORUI)
    cResult = vectorUI(vertOut);
  #if b_iUse8BitHDR
    cResult.rgb *= psGlobals.vHDRScaling.x;
  #endif

    // ---------- volume (psmainshading.fx:223-224) ----------
#elif (b_iShadingMode == SHADINGMODE_VOLUME)
    cResult = volume(vertOut);

    // ---------- reflection (psmainshading.fx:228-229) ----------
#elif (b_iShadingMode == SHADINGMODE_REFLECTION)
    cResult = reflection(vertOut);

    // ---------- cloaking (psmainshading.fx:230-231) ----------
#elif (b_iShadingMode == SHADINGMODE_CLOAKING)
    cResult = cloaking(vertOut, def);

    // ---------- model triangle id (psmainshading.fx:225-226) ----------
#elif (b_iShadingMode == SHADINGMODE_MODEL_TRIANGLE_ID)
    cResult = vertOut.VertexColor();
#endif
    // Any other b_iShadingMode (incl. the 6 mode-8 fall-through perms) leaves cResult
    // at its (1,1,1,1) init, exactly as the .fx if-ladder does.

    // AlphaTest (common.fx).
#if b_iAlphaTest
    clip(cResult.a - psGlobals.fAlphaThreshold);
#endif

    return cResult;
}
