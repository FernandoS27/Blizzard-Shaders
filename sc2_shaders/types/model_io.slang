// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family (DefaultPixelMain) pixel-shader IO + bindings.
//
// The shared-interpolant families (Model / Particle / Ribbon / Foliage) don't
// carry a fixed VS->PS struct: the engine packs only the *live* interpolants
// (VS-writes ∩ PS-reads) into TEXCOORD slots per permutation.  We reproduce that
// packing with preprocessor gates driven by the validator/compiler (sc2_shaders_cfg
// .interp_defines), which mirrors sc2_interp.gen_preamble EXACTLY:
//   * SC2_HAS_<name>   present  -> that interpolant is live.
//   * SC2_SEM_<name>   = TEXCOORD<i>  -> its exact semantic (i = its rank in the
//                        sorted live-scalar list), passed whole so no token-paste.
// So the slang candidate's PS input signature matches the fxc reference's slot
// for slot, and the behavioral comparator aligns interpolants by (semantic,index).
//
// This transport grows as MainShading's body stack is transcribed; today it
// carries the interpolants the standard-mode minimal path uses (FogColor, Normal).

implementing sc2_shaders;

// materialdefines.fx shading-mode enum (only the ones referenced so far).
#define SHADINGMODE_STANDARD 0

public struct ModelPSInput
{
    float4 HPos : SV_Position;
#if SC2_HAS_FogColor
    float4 m_FogColor : SC2_SEM_FogColor;
#endif
#if SC2_HAS_WorldPos
    // World-space position (INTERPOLANT_WorldPos) — lighting-region UV, point/spot
    // light vectors, and the in-PS FOWUV recompute source.
    float4 m_WorldPos : SC2_SEM_WorldPos;
#endif
#if SC2_HAS_Diffuse
    // Precomputed vertex lighting (VERTEXLIGHTING_FULL/PARTIAL): the diffuse light
    // colour the VS accumulated, read straight through as cLightDiffuse.
    float3 m_Diffuse : SC2_SEM_Diffuse;
#endif
#if SC2_HAS_Specular
    // Precomputed vertex specular (INTERPOLANT_Specular) — the FULL/PARTIAL arms add
    // it to cLightSpecular.
    float3 m_Specular : SC2_SEM_Specular;
#endif
#if SC2_HAS_ShadowDiffuse
    // Precomputed shadowed vertex diffuse/specular (INTERPOLANT_ShadowDiffuse /
    // _ShadowSpecular) — the FULL arm adds them scaled by cShadowColor.rgb.
    float3 m_ShadowDiffuse : SC2_SEM_ShadowDiffuse;
#endif
#if SC2_HAS_ShadowSpecular
    float3 m_ShadowSpecular : SC2_SEM_ShadowSpecular;
#endif
#if SC2_HAS_ShadowMapUV
    // Projective shadow-map coordinate (EmitPSShadowMapUV), consumed by
    // ShadowIntensity's SampleCmp.
    float4 m_ShadowMapUV : SC2_SEM_ShadowMapUV;
#endif
#if SC2_HAS_HalfVec
    // World-space half-vector (EmitPSHalfVec), the Blinn specular term reads it.
    float3 m_HalfVec : SC2_SEM_HalfVec;
#endif
#if SC2_HAS_Normal
    float4 m_Normal : SC2_SEM_Normal;
#endif
#if SC2_HAS_Tangent
    // Tangent basis (.xyz) for normal mapping; .w carries the binormal sign / the
    // splat-attenuation projector param.
    float4 m_Tangent : SC2_SEM_Tangent;
#endif
#if SC2_HAS_Binormal
    float3 m_Binormal : SC2_SEM_Binormal;
#endif
#if SC2_HAS_EyeToVertexFresnel
    float3 m_EyeToVertexFresnel : SC2_SEM_EyeToVertexFresnel;
#endif
#if SC2_HAS_EyeToVertex
    // Normalised eye->vertex direction (INTERPOLANT_EyeToVertex), the environment-map
    // reflection vector source.
    float3 m_EyeToVertex : SC2_SEM_EyeToVertex;
#endif
#if SC2_HAS_FOWUV
    float4 m_FOWUV : SC2_SEM_FOWUV;
#endif
#if SC2_HAS_ViewPos
    // View-space position (EmitPSViewPos = mul(WorldPos, p_mViewTransform)); the
    // deferred depth target reads OutputDepth = INTERPOLANT_ViewPos.y.
    float3 m_ViewPos : SC2_SEM_ViewPos;
#endif
#if SC2_HAS_VertexColor
    // Per-vertex colour/alpha (INTERPOLANT_VertexColor) — the b_useVertexColors /
    // b_useVertexAlpha material modulation.
    float4 m_VertexColor : SC2_SEM_VertexColor;
#endif
#if SC2_HAS_VectorUI0
    // Generic per-vertex vector 0 (INTERPOLANT_VectorUI0) — local-space normal for
    // triplanar (.xyz) and the splat-attenuation projector.
    float4 m_VectorUI0 : SC2_SEM_VectorUI0;
#endif
#if SC2_HAS_VectorUI1
    // Generic per-vertex vector 1 (INTERPOLANT_VectorUI1) — .a carries vertex-based
    // ambient occlusion; .xyz/.w feed the splat-attenuation projector.
    float4 m_VectorUI1 : SC2_SEM_VectorUI1;
#endif
#if SC2_HAS_TriPlanarWeights
    // Local-space triplanar blend weights (INTERPOLANT_TriPlanarWeights.xyz).
    float4 m_TriPlanarWeights : SC2_SEM_TriPlanarWeights;
#endif
#if SC2_HAS_ParallaxVector
    // Tangent-space view vector for parallax/POM (INTERPOLANT_ParallaxVector).
    float3 m_ParallaxVector : SC2_SEM_ParallaxVector;
#endif
#if SC2_HAS_UV
    // The engine's per-emitter UV array (sc2UV[]): SC2_UV_COUNT float4 slots at
    // consecutive TEXCOORDs starting at SC2_SEM_UV (gen_preamble's packing).
    float4 m_UV[SC2_UV_COUNT] : SC2_SEM_UV;
#endif
#if SC2_HAS_FrontFace
    // SV_IsFrontFace — a system-value input, not a TEXCOORD varying (gen_preamble
    // adds it to VertexTransportRaw as `bool FrontFace : SV_IsFrontFace`).
    bool m_FrontFace : SV_IsFrontFace;
#endif

    // INTERPOLANT_* accessors — return the packed field, or 0 when the engine
    // packed that interpolant out (the .fx's gen_preamble safety-net value).
    float4 FogColor()
    {
#if SC2_HAS_FogColor
        return m_FogColor;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 Normal()
    {
#if SC2_HAS_Normal
        return m_Normal;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 Tangent()
    {
#if SC2_HAS_Tangent
        return m_Tangent;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    // INTERPOLANT_Binormal: the packed varying, or (mirroring gen_preamble) the
    // reconstruction cross(Normal.xyz, Tangent.xyz) * Normal.w when the binormal was
    // packed out but Normal + Tangent survive.
    float3 Binormal()
    {
#if SC2_HAS_Binormal
        return m_Binormal;
#elif SC2_HAS_Normal && SC2_HAS_Tangent
        return cross(m_Normal.xyz, m_Tangent.xyz) * m_Normal.w;
#else
        return float3(0, 0, 0);
#endif
    }
    float4 WorldPos()
    {
#if SC2_HAS_WorldPos
        return m_WorldPos;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float3 Diffuse()
    {
#if SC2_HAS_Diffuse
        return m_Diffuse;
#else
        return float3(0, 0, 0);
#endif
    }
    float3 Specular()
    {
#if SC2_HAS_Specular
        return m_Specular;
#else
        return float3(0, 0, 0);
#endif
    }
    float3 ShadowDiffuse()
    {
#if SC2_HAS_ShadowDiffuse
        return m_ShadowDiffuse;
#else
        return float3(0, 0, 0);
#endif
    }
    float3 ShadowSpecular()
    {
#if SC2_HAS_ShadowSpecular
        return m_ShadowSpecular;
#else
        return float3(0, 0, 0);
#endif
    }
    // INTERPOLANT_ShadowMapUV: the packed varying, or (mirroring gen_preamble's
    // EmitPSShadowMapUV recompute) mul(float4(ViewPos,1), p_mViewToShadowTransform) when
    // the varying was packed out but ViewPos survives.
    float4 ShadowMapUV()
    {
#if SC2_HAS_ShadowMapUV
        return m_ShadowMapUV;
#elif SC2_HAS_ViewPos
        return mul(float4(m_ViewPos, 1.0f), psGlobals.mViewToShadowTransform);
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float3 HalfVec()
    {
#if SC2_HAS_HalfVec
        return m_HalfVec;
#else
        return float3(0, 0, 0);
#endif
    }
    float3 EyeToVertexFresnel()
    {
#if SC2_HAS_EyeToVertexFresnel
        return m_EyeToVertexFresnel;
#else
        return float3(0, 0, 0);
#endif
    }
    float3 EyeToVertex()
    {
#if SC2_HAS_EyeToVertex
        return m_EyeToVertex;
#else
        return float3(0, 0, 0);
#endif
    }
    // INTERPOLANT_FOWUV: the packed varying, or (mirroring gen_preamble's EmitPSFOWUV
    // recompute) mul(WorldPos, p_mFOWMatrix) when packed out but WorldPos survives.
    float4 FOWUV()
    {
#if SC2_HAS_FOWUV
        return m_FOWUV;
#elif SC2_HAS_WorldPos
        return mul(m_WorldPos, psGlobals.mFOWMatrix);
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float3 ViewPos()
    {
#if SC2_HAS_ViewPos
        return m_ViewPos;
#else
        return float3(0, 0, 0);
#endif
    }
    float4 VertexColor()
    {
#if SC2_HAS_VertexColor
        return m_VertexColor;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 VectorUI0()
    {
#if SC2_HAS_VectorUI0
        return m_VectorUI0;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 VectorUI1()
    {
#if SC2_HAS_VectorUI1
        return m_VectorUI1;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 TriPlanarWeights()
    {
#if SC2_HAS_TriPlanarWeights
        return m_TriPlanarWeights;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float3 ParallaxVector()
    {
#if SC2_HAS_ParallaxVector
        return m_ParallaxVector;
#else
        return float3(0, 0, 0);
#endif
    }
    // WRITE_INTERPOLANT_UV(i, v) — parallax mutates the per-emitter UV slots in place.
    [mutating] void SetUV(int i, float4 v)
    {
#if SC2_HAS_UV
        m_UV[i] = v;
#endif
    }
    // READ_INTERPOLANT_UV(i): the i-th per-emitter UV slot (0 when no UV live).
    float4 UV(int i)
    {
#if SC2_HAS_UV
        return m_UV[i];
#else
        return float4(0, 0, 0, 0);
#endif
    }
    // INTERPOLANT_FrontFace — vertOut.FrontFace when live, else the safety-net
    // `true` (gen_preamble); consumed only by the b_iTwoSided backface flip.
    bool FrontFace()
    {
#if SC2_HAS_FrontFace
        return m_FrontFace;
#else
        return true;
#endif
    }
}

// pscommon.fx MRT emit axes — the engine passes them only when nonzero, so the
// `#if (... == 1)` gates read an absent axis as 0 (mirrors pscommon.fx:18-29,
// which defaults emitMRTDepth/Normal/Diffuse/Specular; emitMRTAO is an axis with
// no in-source default, absent-as-0 handles it).
#ifndef b_emitMRTDepth
#define b_emitMRTDepth 0
#endif
#ifndef b_emitMRTNormal
#define b_emitMRTNormal 0
#endif
#ifndef b_emitMRTDiffuse
#define b_emitMRTDiffuse 0
#endif
#ifndef b_emitMRTSpecular
#define b_emitMRTSpecular 0
#endif
#ifndef b_emitMRTAO
#define b_emitMRTAO 0
#endif

// SPixelOut (pscommon.fx:122) — the Model MRT output.  The target layout mirrors
// the .fx's nesting EXACTLY: cColor is always COLOR0/SV_Target0; a depth OR normal
// emit inserts vNormalDepth before the diffuse/specular targets (so their indices
// shift by one), and specular only exists when a diffuse/AO target does.  Slang's
// SV_Target<N> maps to the reference's COLOR<N> (the comparator keys on target
// index), so the two shaders agree on which targets exist and in what order.
public struct ModelPSOutput
{
    float4 cColor : SV_Target0;
#if (b_emitMRTDepth == 1 || b_emitMRTNormal == 1)  // depth implies normals too
    float4 vNormalDepth : SV_Target1;
    #if (b_emitMRTDiffuse == 1 || b_emitMRTAO == 1)
    float4 cDiffuse : SV_Target2;
        #if (b_emitMRTSpecular == 1)
    float4 cSpecular : SV_Target3;
        #endif
    #endif
#else
    #if (b_emitMRTDiffuse == 1 || b_emitMRTAO == 1)
    float4 cDiffuse : SV_Target1;
        #if (b_emitMRTSpecular == 1)
    float4 cSpecular : SV_Target2;
        #endif
    #endif
#endif
};

// The inout g-buffer values MainShading/MaterialColor accumulate alongside the
// final colour (psmainshading.fx:48-53).  DefaultPixelMain reads them to fill the
// deferred MRT targets; they are independent of the fog/FOW/HDR applied to cColor.
public struct DeferredOutputs
{
    float3 vNormal;          // world-space normal (DecodeNormal)
    float3 cDiffuse;         // material diffuse colour (pre-lighting-multiply)
    float3 cSpecular;        // material specular colour (× specular multiplier)
    float  cAO;              // ambient-occlusion (1 unless the AO layer wrote it)
    float  cSpecularPower;   // = MaterialSpecularity (fed to the specular target .a)
    float  cGlossiness;      // SpecularExponent layer alpha (1 without that layer)
};

// $Globals — only the constants the transcribed path references so far.  Declared
// as a ConstantBuffer<struct> (the wc3_shaders idiom) so the fields are struct-
// scoped, not module-global symbols: many SC2 families share engine constants
// (p_fAlphaThreshold, p_cFogColor, …) and module-global cbuffer members would
// collide across families.  Field names drop the `p_` prefix but still
// canonicalise to the fxc reference's names (cFogColor, fAlphaThreshold, …), so
// the behavioral comparator aligns them by name; offsets need not match the
// reference's packed $Globals.
// lighting.fx : DirectionalLight — one 32-byte cbuffer element per light (the
// engine keeps MAX_DIRECTIONAL_LIGHTS = 3).
public struct DirectionalLight
{
    float4 vDirection;
    float4 cColor;
};

// lighting.fx : LightSetup — one per lighting region (MAX_LIGHT_SETUPS = 4).  All
// members are HALF3, which D3D cbuffer packing 16-byte-aligns, so each element is
// 96 bytes and cFogColor sits at offset 80 (the comparator fills the whole array as
// one opaque region, so this internal layout must match the fxc reference — it does,
// both compilers apply the same packing to the same struct).
public struct LightSetup
{
    float3 cAmbientIntensity;
    float3 cLight0Specular;
    float3 cLight0Diffuse;
    float3 cLight1Diffuse;
    float3 cLight2Diffuse;
    float3 cFogColor;
};

// lighting.fx : PointLight (MAX_POINT_LIGHTS = 3) — 48 bytes/element.
public struct PointLight
{
    float4 vPositionRecipRadius;      // xyz = position, w = 1/radius
    float4 cSpecular;
    float4 cColorAttenMultiplier;     // rgb = colour, w = attenuation multiplier
};

// lighting.fx : SpotLight (MAX_SPOTLIGHTS = 7) — 80 bytes/element.
public struct SpotLight
{
    float4 vPositionRecipRadius;
    float4 cSpecular;
    float4 cColorAttenMultiplier;
    float4 vDirection;
    float4 vSpotFalloffBiasScaleAndHotSpotMultiplier;
};

public struct ModelPSGlobalsT
{
    float4 cFogColor;
    float4 vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor;
    float  fAlphaThreshold;

    // Team colour + camera (material layer team-colour / fresnel).
    float3 vCameraDirection;
    float4 cEmissiveTeamColor;
    float4 cDiffuseTeamColor;
    float2 fTeamColorIntensity;
    float3 fMaterialTint;

    // Diffuse material layer constants (psmateriallayer.fx DECLARE_LAYER).
    float4            vDiffuseMultiplyAddAlphaTrans;
    float3            vDiffuseFresnelExponentBiasScale;
    float4            cDiffuseConstantColor;
    float4            vDiffuseRTTTextureOffsetScale;
    row_major float3x4 mDiffuseFresnelTransform;
    row_major float2x4 mDiffuseUVTransform;

    // Fog-of-war (psfow.fx).  ApplyFogOfWar reads only these three; p_fFOWWidth /
    // p_fFOWSmoothing are declared in psfow.fx but never referenced, so fxc drops
    // them from the reference $Globals — omitted here so the cbuffer intersection
    // stays exact.
    float4 vFOWLevels;
    float3 cFOWBlackMaskColor;
    float4 cMaterialFOWTint;

    // Lighting (lighting.fx): ambient + the directional light array, plus the
    // point/spot light arrays and the per-region light setups (referenced only by
    // the single-pass point/spot path and the lighting-region blend).  Constants are
    // aligned by name and the comparator only compares the fxc<->slang intersection,
    // so declaring these unconditionally is safe: a perm that doesn't reference one
    // just leaves it out of both compiled cbuffers (or unread on one side).
    float3           cAmbientColor;
    DirectionalLight directionalLights[3];
    PointLight       pointLights[3];
    SpotLight        spotLights[7];
    LightSetup       lightSetups[4];

    // Eye position (common.fx : p_vEyePos) — ComputeHalfVector for point/spot lights.
    float3           vEyePos;

    // Lighting-region UV transform (lighting.fx : p_vWorldToLightingRegionTransform,
    // xy offset / zw scale) mapping world XY to the region-weight texture.
    float4           vWorldToLightingRegionTransform;

    // 8-bit HDR scaling (common.fx : p_vHDRScaling — .x scales the final colour).
    float2           vHDRScaling;

    // Dynamic-AO screen mapping (common.fx : p_vRecipRenderTargetSizeOffset) — .xy
    // scales SV_Position to [0,1] UV, .zw is the half-texel offset.
    float4           vRecipRenderTargetSizeOffset;

    // Deferred-gbuffer encoding (pscommon.fx EncodeDepthNormal): the view transform
    // (RGBA normal packing casts it to float3x3) + the depth-remap factor.  Declared
    // row_major to match shadersystem.fx's #pragma pack_matrix(row_major).
    row_major float3x4 mViewTransform;
    float              fMaxDepthFactor;

    // In-PS interpolant recompute matrices (sc2_interp.gen_preamble): when the engine
    // packs FOWUV / ShadowMapUV out of the interpolants but their source varying (WorldPos
    // / ViewPos) survives, the PS recomputes them — EmitPSFOWUV (mul(WorldPos, p_mFOWMatrix))
    // and EmitPSShadowMapUV (mul(float4(ViewPos,1), p_mViewToShadowTransform)).
    row_major float4x4 mFOWMatrix;
    row_major float4x4 mViewToShadowTransform;

    // Specular lighting colour + exponent (lighting.fx : p_vSpecColorSpecularity —
    // .rgb is the specular light colour, .w the specular power / gloss).
    float4           vSpecColorSpecularity;

    // Specular material layer constants (psmateriallayer.fx DECLARE_LAYER(Specular)).
    float4            vSpecularMultiplyAddAlphaTrans;
    float3            vSpecularFresnelExponentBiasScale;
    float4            cSpecularConstantColor;
    float4            vSpecularRTTTextureOffsetScale;
    row_major float3x4 mSpecularFresnelTransform;
    row_major float2x4 mSpecularUVTransform;

    // Team-colour + emissive-multiplier constants used by the extra material layers.
    float             fEmissiveMultiplier;

    // Diffuse/Specular triplanar atlas params (SETUP_LAYER completeness).
    float4            vDiffuseAtlasParams;
    float4            vSpecularAtlasParams;

    // Decal material layer constants (psmaterial.fx DECLARE_LAYER(Decal)).
    float4             vDecalMultiplyAddAlphaTrans;
    float4             vDecalAtlasParams;
    float3             vDecalFresnelExponentBiasScale;
    float4             cDecalConstantColor;
    float4             vDecalRTTTextureOffsetScale;
    row_major float3x4 mDecalFresnelTransform;
    row_major float2x4 mDecalUVTransform;

    // Emissive material layer constants (psmaterial.fx DECLARE_LAYER(Emissive)).
    float4             vEmissiveMultiplyAddAlphaTrans;
    float4             vEmissiveAtlasParams;
    float3             vEmissiveFresnelExponentBiasScale;
    float4             cEmissiveConstantColor;
    float4             vEmissiveRTTTextureOffsetScale;
    row_major float3x4 mEmissiveFresnelTransform;
    row_major float2x4 mEmissiveUVTransform;

    // Emissive2 material layer constants (psmaterial.fx DECLARE_LAYER(Emissive2)).
    float4             vEmissive2MultiplyAddAlphaTrans;
    float4             vEmissive2AtlasParams;
    float3             vEmissive2FresnelExponentBiasScale;
    float4             cEmissive2ConstantColor;
    float4             vEmissive2RTTTextureOffsetScale;
    row_major float3x4 mEmissive2FresnelTransform;
    row_major float2x4 mEmissive2UVTransform;

    // AlphaMask material layer constants (psmaterial.fx DECLARE_LAYER(AlphaMask)).
    float4             vAlphaMaskMultiplyAddAlphaTrans;
    float4             vAlphaMaskAtlasParams;
    float3             vAlphaMaskFresnelExponentBiasScale;
    float4             cAlphaMaskConstantColor;
    float4             vAlphaMaskRTTTextureOffsetScale;
    row_major float3x4 mAlphaMaskFresnelTransform;
    row_major float2x4 mAlphaMaskUVTransform;

    // AlphaMask2 material layer constants (psmaterial.fx DECLARE_LAYER(AlphaMask2)).
    float4             vAlphaMask2MultiplyAddAlphaTrans;
    float4             vAlphaMask2AtlasParams;
    float3             vAlphaMask2FresnelExponentBiasScale;
    float4             cAlphaMask2ConstantColor;
    float4             vAlphaMask2RTTTextureOffsetScale;
    row_major float3x4 mAlphaMask2FresnelTransform;
    row_major float2x4 mAlphaMask2UVTransform;

    // Lightmap material layer constants (psmaterial.fx DECLARE_LAYER(Lightmap)).
    float4             vLightmapMultiplyAddAlphaTrans;
    float4             vLightmapAtlasParams;
    float3             vLightmapFresnelExponentBiasScale;
    float4             cLightmapConstantColor;
    float4             vLightmapRTTTextureOffsetScale;
    row_major float3x4 mLightmapFresnelTransform;
    row_major float2x4 mLightmapUVTransform;

    // AmbientOcclusion material layer constants (psmaterial.fx DECLARE_LAYER(AmbientOcclusion)).
    float4             vAmbientOcclusionMultiplyAddAlphaTrans;
    float4             vAmbientOcclusionAtlasParams;
    float3             vAmbientOcclusionFresnelExponentBiasScale;
    float4             cAmbientOcclusionConstantColor;
    float4             vAmbientOcclusionRTTTextureOffsetScale;
    row_major float3x4 mAmbientOcclusionFresnelTransform;
    row_major float2x4 mAmbientOcclusionUVTransform;

    // SpecularExponent material layer constants (psmaterial.fx DECLARE_LAYER(SpecularExponent)).
    float4             vSpecularExponentMultiplyAddAlphaTrans;
    float4             vSpecularExponentAtlasParams;
    float3             vSpecularExponentFresnelExponentBiasScale;
    float4             cSpecularExponentConstantColor;
    float4             vSpecularExponentRTTTextureOffsetScale;
    row_major float3x4 mSpecularExponentFresnelTransform;
    row_major float2x4 mSpecularExponentUVTransform;

    // Normal material layer constants (psmaterial.fx DECLARE_LAYER(Normal)).
    float4             vNormalMultiplyAddAlphaTrans;
    float4             vNormalAtlasParams;
    float3             vNormalFresnelExponentBiasScale;
    float4             cNormalConstantColor;
    float4             vNormalRTTTextureOffsetScale;
    row_major float3x4 mNormalFresnelTransform;
    row_major float2x4 mNormalUVTransform;

    // Lightmap-shadow colour (psmaterial.fx : p_cLightmapShadowColor).
    float3            cLightmapShadowColor;

    // Soft-shadow kernel (psshadow.fx): the rotation-texture UV scale + the PCF tap
    // offset table (p_vSoftShadowTapOffsets[6]).
    float2            vRotationTextureUVScale;
    float4            vSoftShadowTapOffsets[6];

    // Environment mapping (psmaterial.fx): the env-map transform, the constant
    // diffuse/specular envio weights, and the envio texture size (mip/blur).
    row_major float3x4 mEnvironmentMapTransform;
    float3            vEnvioConstantDiffSpec;
    float4            vEnvioTextureSize;

    // Envio material layer constants (psmaterial.fx DECLARE_LAYER(Envio)).
    float4             vEnvioMultiplyAddAlphaTrans;
    float4             vEnvioAtlasParams;
    float3             vEnvioFresnelExponentBiasScale;
    float4             cEnvioConstantColor;
    float4             vEnvioRTTTextureOffsetScale;
    row_major float3x4 mEnvioFresnelTransform;
    row_major float2x4 mEnvioUVTransform;

    // EnvioMask material layer constants (psmaterial.fx DECLARE_LAYER(EnvioMask)).
    float4             vEnvioMaskMultiplyAddAlphaTrans;
    float4             vEnvioMaskAtlasParams;
    float3             vEnvioMaskFresnelExponentBiasScale;
    float4             cEnvioMaskConstantColor;
    float4             vEnvioMaskRTTTextureOffsetScale;
    row_major float3x4 mEnvioMaskFresnelTransform;
    row_major float2x4 mEnvioMaskUVTransform;

    // NormalBlend layer constants (psmaterial.fx DECLARE_LAYER(NormalBlend*)) + the
    // two blend-factor vectors (p_vNormalBlendingFactors / _2).
    float4             vNormalBlendMaskMultiplyAddAlphaTrans;
    float4             vNormalBlendMaskAtlasParams;
    float3             vNormalBlendMaskFresnelExponentBiasScale;
    float4             cNormalBlendMaskConstantColor;
    float4             vNormalBlendMaskRTTTextureOffsetScale;
    row_major float3x4 mNormalBlendMaskFresnelTransform;
    row_major float2x4 mNormalBlendMaskUVTransform;
    float4             vNormalBlendMask2MultiplyAddAlphaTrans;
    float4             vNormalBlendMask2AtlasParams;
    float3             vNormalBlendMask2FresnelExponentBiasScale;
    float4             cNormalBlendMask2ConstantColor;
    float4             vNormalBlendMask2RTTTextureOffsetScale;
    row_major float3x4 mNormalBlendMask2FresnelTransform;
    row_major float2x4 mNormalBlendMask2UVTransform;
    float4             vNormalBlendNormalMultiplyAddAlphaTrans;
    float4             vNormalBlendNormalAtlasParams;
    float3             vNormalBlendNormalFresnelExponentBiasScale;
    float4             cNormalBlendNormalConstantColor;
    float4             vNormalBlendNormalRTTTextureOffsetScale;
    row_major float3x4 mNormalBlendNormalFresnelTransform;
    row_major float2x4 mNormalBlendNormalUVTransform;
    float4             vNormalBlendNormal2MultiplyAddAlphaTrans;
    float4             vNormalBlendNormal2AtlasParams;
    float3             vNormalBlendNormal2FresnelExponentBiasScale;
    float4             cNormalBlendNormal2ConstantColor;
    float4             vNormalBlendNormal2RTTTextureOffsetScale;
    row_major float3x4 mNormalBlendNormal2FresnelTransform;
    row_major float2x4 mNormalBlendNormal2UVTransform;
    float4             vNormalBlendingFactors;
    float4             vNormalBlendingFactors2;

    // Halo pass (psmainshading.fx : p_cHaloColor + the strobe params) — GetHaloColor.
    float4             cHaloColor;
    float              fStrobeOffset;
    float              fStrobeSizeRcp;
    float              fStrobeFalloff;

    // Heightmap material layer constants (psmaterial.fx DECLARE_LAYER(Heightmap)) —
    // the parallax/POM height map.
    float4             vHeightmapMultiplyAddAlphaTrans;
    float4             vHeightmapAtlasParams;
    float3             vHeightmapFresnelExponentBiasScale;
    float4             cHeightmapConstantColor;
    float4             vHeightmapRTTTextureOffsetScale;
    row_major float3x4 mHeightmapFresnelTransform;
    row_major float2x4 mHeightmapUVTransform;
};
ConstantBuffer<ModelPSGlobalsT> psGlobals : register(b0);

// Textures are aligned by canon NAME by the comparator (registers are irrelevant to
// it), and D3D11 pixel shaders cap samplers at 16 slots, so every 2D/cube texture
// shares one SamplerState and both comparison (shadow) maps share one
// SamplerComparisonState.  The dxbc_interp TextureModel keys on the texture, not the
// sampler, so sharing changes no sampled value.
SamplerState           p_sSamp;
SamplerComparisonState p_sCmpSamp;

Texture2D<float4>   p_sDiffuseSampler_t;
Texture2D<float4>   p_sFOWSampler_t;
TextureCube<float4> p_sAmbientEnvironmentTexture_t;
Texture2D<float>    p_sShadowMap_t;
Texture2D<float4>   p_sSSAO_t;

// Lighting-region weight map (lighting.fx : texDecl2D(p_sLightingRegions)).
Texture2D<float4>   p_sLightingRegions_t;

// Depth prepass normal/depth map (pscommon.fx : texDecl2D(p_sNormalDepthMap)) — the
// soft-particle depth blend samples it.
Texture2D<float4>   p_sNormalDepthMap_t;

// Specular material layer texture (texDecl2D(p_sSpecularSampler)).
Texture2D<float4> p_sSpecularSampler_t;

// Extra material-layer textures (all texDecl2D).  Register indices are irrelevant
// to the comparator (it maps textures by canon name); distinct slots just avoid
// collisions.
Texture2D<float4> p_sDecalSampler_t;
Texture2D<float4> p_sEmissiveSampler_t;
Texture2D<float4> p_sEmissive2Sampler_t;
Texture2D<float4> p_sAlphaMaskSampler_t;
Texture2D<float4> p_sAlphaMask2Sampler_t;
Texture2D<float4> p_sLightmapSampler_t;
Texture2D<float4> p_sAmbientOcclusionSampler_t;
Texture2D<float4> p_sSpecularExponentSampler_t;
Texture2D<float4> p_sNormalSampler_t;

// NormalBlend layer textures (psmaterial.fx DECLARE_LAYER_2D(NormalBlend*)).
Texture2D<float4> p_sNormalBlendMaskSampler_t;
Texture2D<float4> p_sNormalBlendMask2Sampler_t;
Texture2D<float4> p_sNormalBlendNormalSampler_t;
Texture2D<float4> p_sNormalBlendNormal2Sampler_t;

// Heightmap layer texture (parallax/POM) — psmaterial.fx DECLARE_LAYER_2D(Heightmap).
Texture2D<float4> p_sHeightmapSampler_t;

// Soft-shadow rotation texture (texDecl2D) + transparent-shadow depth (comparison)
// and colour maps (psshadow.fx).
Texture2D<float4>      p_sRotationTexture_t;
Texture2D<float>       p_sTransparentShadowDepthMap_t;
Texture2D<float4>      p_sTransparentShadowColorMap_t;

// Envio / EnvioMask layer textures — 2D or cube per the layer's texture-type axis
// (DECLARE_LAYER_2D / DECLARE_LAYER_CUBE in psmaterial.fx; TEXTURE_TYPE_2D == 0).
#ifndef b_iEnvioTextureType
#define b_iEnvioTextureType 0
#endif
#ifndef b_iEnvioMaskTextureType
#define b_iEnvioMaskTextureType 0
#endif
#if (b_iEnvioTextureType == 0)
Texture2D<float4>   p_sEnvioSampler_t;
#else
TextureCube<float4> p_sEnvioSampler_t;
#endif
#if (b_iEnvioMaskTextureType == 0)
Texture2D<float4>   p_sEnvioMaskSampler_t;
#else
TextureCube<float4> p_sEnvioMaskSampler_t;
#endif
