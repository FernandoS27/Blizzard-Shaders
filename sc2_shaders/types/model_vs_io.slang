// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Model-family vertex-shader IO + bindings (model.fx : ModelVertexMain).
//
// Two permuted structs bracket the vertex stage:
//
//   * `ModelVSStreamIn` — vsmodelvertexformat.fx's `VertDecl`, the D3D vertex
//     declaration.  Which attributes exist is a compile-time layout decision
//     (`b_iUVCoordCount`, `b_iLayoutHasColor`, `b_iLayoutHasCustomUB4N1`,
//     `b_iLayoutHasNoVertexBlend{Weights,Indices}`, `b_iUseSignedIntUVs`), so the
//     fields are `#if`-gated exactly as the `HasXxx_()` macros gate them there.
//
//   * `DefaultVSOutput` — the engine-injected `VertexTransport`.  It carries only the
//     *live* interpolants (VS-writes ∩ PS-reads) and is packed identically to the
//     pixel stage's `ModelPSInput`: the live scalars sorted by name at TEXCOORD0,1,2…
//     then the per-emitter UV array.  Both structs are driven by the SAME
//     `SC2_HAS_<name>` / `SC2_SEM_<name>` defines (sc2_shaders_cfg.interp_defines),
//     which mirror sc2_interp.gen_preamble — so the slang VS output signature matches
//     the fxc reference's slot for slot and `compare_vs` aligns them by semantic.
//
// The `INTERPOLANT_<name>` *readers* are accessors here too, because ModelVertexMain
// reads back what it just wrote (EmitParallaxVector consumes INTERPOLANT_Normal /
// _Tangent / _Binormal, EmitDiffuse consumes INTERPOLANT_VectorUI1) — including
// gen_preamble's Binormal reconstruction when that varying was packed out.

implementing sc2_shaders;

// vspostprocess.fx sizes p_vBlurOffsets as `[b_iSampleCount + 1]`; vsGlobals must
// match so both legs give the array the same byte span.  Slang gives each
// `__include`d file its own preprocessor state, hence the local default.
#ifndef b_iSampleCount
#define b_iSampleCount 0
#endif

// The compile-time axis defaults + the .fx enums live in a preprocessor header:
// `__include` merges declarations but NOT #defines, so every VS translation unit
// includes the same block (see vs/model_vs_defines.slangh).
#include "vs/model_vs_defines.slangh"

// vsuvmapping.fx:13 — the Planar-Local tiling constant.  A declaration, not a
// define, so `__include` DOES carry it to the other VS translation units.
static const float c_planarLocalUVMapping = 0.09375f;

// ---------------------------------------------------------------------------
// Vertex stream declaration (vsmodelvertexformat.fx : VertDecl).
// Legacy semantics resolve through shadersystem.fx's `*_` aliases; the D3D path
// maps POSITION_ -> POSITION, COLOR0_ -> COLOR0, … verbatim.
// ---------------------------------------------------------------------------
public struct ModelVSStreamIn
{
    float4 vPosition : POSITION;
#if !b_iLayoutHasNoVertexBlendWeights
    float4 vBlendWeights : BLENDWEIGHT;
#endif
#if !b_iLayoutHasNoVertexBlendIndices
    float4 vBlendIndices : BLENDINDICES;
#endif
    float4 vNormal : NORMAL;
#if b_iLayoutHasColor
    float4 cColor : COLOR0;
#endif
    // TexCoordType is `int2` under b_iUseSignedIntUVs, else HALF2 (= float2 at
    // PIXEL_SHADER_VERSION >= PS_30, which the engine always sets for SM4+).
#if (b_iUVCoordCount >= 1)
  #if b_iUseSignedIntUVs
    int2 vUV0 : TEXCOORD0;
  #else
    float2 vUV0 : TEXCOORD0;
  #endif
#endif
#if (b_iUVCoordCount >= 2)
  #if b_iUseSignedIntUVs
    int2 vUV1 : TEXCOORD1;
  #else
    float2 vUV1 : TEXCOORD1;
  #endif
#endif
#if (b_iUVCoordCount >= 3)
  #if b_iUseSignedIntUVs
    int2 vUV2 : TEXCOORD2;
  #else
    float2 vUV2 : TEXCOORD2;
  #endif
#endif
#if (b_iUVCoordCount >= 4)
  #if b_iUseSignedIntUVs
    int2 vUV3 : TEXCOORD3;
  #else
    float2 vUV3 : TEXCOORD3;
  #endif
#endif
    float3 vTangent : TANGENT;
#if b_iLayoutHasCustomUB4N1
    float4 cCustomUB4N1 : COLOR1;
#endif
};

// ---------------------------------------------------------------------------
// Internal vertex-shader vertex format (vsmodelvertexformat.fx : Input).
// Same gating as VertDecl, plus the derived binormal; no semantics (it never
// crosses a stage boundary), so it is a plain struct.
// ---------------------------------------------------------------------------
public struct ModelVSVertex
{
    float4 vPosition;
#if !b_iLayoutHasNoVertexBlendWeights
    float4 vBlendWeights;
#endif
#if !b_iLayoutHasNoVertexBlendIndices
    float4 vBlendIndices;
#endif
    float4 vNormal;
#if b_iLayoutHasColor
    float4 cColor;
#endif
#if (b_iUVCoordCount >= 1)
    float2 vUV0;
#endif
#if (b_iUVCoordCount >= 2)
    float2 vUV1;
#endif
#if (b_iUVCoordCount >= 3)
    float2 vUV2;
#endif
#if (b_iUVCoordCount >= 4)
    float2 vUV3;
#endif
    float3 vTangent;
    float3 vBinormal;
#if b_iLayoutHasCustomUB4N1
    float4 cCustomUB4N1;
#endif

    // The `HasUVCoordN_()`-gated reads in EmitModelUV: absent coordinate sets
    // contribute 0 (model.fx:140-147 initialises UV0..UV3 to 0 first).
    float2 UVCoord0() { return (b_iUVCoordCount >= 1) ? _uv0() : float2(0, 0); }
    float2 UVCoord1() { return (b_iUVCoordCount >= 2) ? _uv1() : float2(0, 0); }
    float2 UVCoord2() { return (b_iUVCoordCount >= 3) ? _uv2() : float2(0, 0); }
    float2 UVCoord3() { return (b_iUVCoordCount >= 4) ? _uv3() : float2(0, 0); }

    float2 _uv0() {
#if (b_iUVCoordCount >= 1)
        return vUV0;
#else
        return float2(0, 0);
#endif
    }
    float2 _uv1() {
#if (b_iUVCoordCount >= 2)
        return vUV1;
#else
        return float2(0, 0);
#endif
    }
    float2 _uv2() {
#if (b_iUVCoordCount >= 3)
        return vUV2;
#else
        return float2(0, 0);
#endif
    }
    float2 _uv3() {
#if (b_iUVCoordCount >= 4)
        return vUV3;
#else
        return float2(0, 0);
#endif
    }

    // model.fx passes literal 0s to Skin() when the layout has no blend weights;
    // these accessors make the *indices* side equally safe when only that half of
    // the layout is absent (the raw field would not exist to reference).
    float4 BlendWeights() {
#if !b_iLayoutHasNoVertexBlendWeights
        return vBlendWeights;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 BlendIndices() {
#if !b_iLayoutHasNoVertexBlendIndices
        return vBlendIndices;
#else
        return float4(0, 0, 0, 0);
#endif
    }

    // `HasColor_(value = vertIn.cColor;)` — absent layout leaves the initialiser.
    float4 Color() {
#if b_iLayoutHasColor
        return cColor;
#else
        return float4(0, 0, 0, 0);
#endif
    }
    float4 CustomUB4N1() {
#if b_iLayoutHasCustomUB4N1
        return cCustomUB4N1;
#else
        return float4(0, 0, 0, 0);
#endif
    }
};

// ---------------------------------------------------------------------------
// VertexTransport — the permuted VS output.  Field set + semantics are identical
// to ModelPSInput's (same interp_defines), minus SV_IsFrontFace, which is a pixel
// system value and may not appear in a vertex output signature.
// ---------------------------------------------------------------------------
public struct DefaultVSOutput
{
    float4 HPos : SV_Position;
#if SC2_HAS_FogColor
    float4 m_FogColor : SC2_SEM_FogColor;
#endif
#if SC2_HAS_WorldPos
    float4 m_WorldPos : SC2_SEM_WorldPos;
#endif
#if SC2_HAS_HPosAsUV
    float4 m_HPosAsUV : SC2_SEM_HPosAsUV;
#endif
#if SC2_HAS_ViewPos
    float3 m_ViewPos : SC2_SEM_ViewPos;
#endif
#if SC2_HAS_Normal
    float4 m_Normal : SC2_SEM_Normal;
#endif
#if SC2_HAS_Tangent
    float4 m_Tangent : SC2_SEM_Tangent;
#endif
#if SC2_HAS_Binormal
    float3 m_Binormal : SC2_SEM_Binormal;
#endif
#if SC2_HAS_Diffuse
    float3 m_Diffuse : SC2_SEM_Diffuse;
#endif
#if SC2_HAS_Specular
    float3 m_Specular : SC2_SEM_Specular;
#endif
#if SC2_HAS_ShadowDiffuse
    float3 m_ShadowDiffuse : SC2_SEM_ShadowDiffuse;
#endif
#if SC2_HAS_ShadowSpecular
    float3 m_ShadowSpecular : SC2_SEM_ShadowSpecular;
#endif
#if SC2_HAS_ShadowMapUV
    float4 m_ShadowMapUV : SC2_SEM_ShadowMapUV;
#endif
#if SC2_HAS_HalfVec
    float3 m_HalfVec : SC2_SEM_HalfVec;
#endif
#if SC2_HAS_EyeToVertex
    float3 m_EyeToVertex : SC2_SEM_EyeToVertex;
#endif
#if SC2_HAS_EyeToVertexFresnel
    float3 m_EyeToVertexFresnel : SC2_SEM_EyeToVertexFresnel;
#endif
#if SC2_HAS_FOWUV
    float4 m_FOWUV : SC2_SEM_FOWUV;
#endif
#if SC2_HAS_TerrainUV
    float4 m_TerrainUV : SC2_SEM_TerrainUV;
#endif
#if SC2_HAS_VertexColor
    float4 m_VertexColor : SC2_SEM_VertexColor;
#endif
#if SC2_HAS_VectorUI0
    float4 m_VectorUI0 : SC2_SEM_VectorUI0;
#endif
#if SC2_HAS_VectorUI1
    float4 m_VectorUI1 : SC2_SEM_VectorUI1;
#endif
#if SC2_HAS_VectorUI2
    float4 m_VectorUI2 : SC2_SEM_VectorUI2;
#endif
#if SC2_HAS_Vector4
    float4 m_Vector4 : SC2_SEM_Vector4;
#endif
#if SC2_HAS_ParallaxVector
    float3 m_ParallaxVector : SC2_SEM_ParallaxVector;
#endif
#if SC2_HAS_TriPlanarWeights
    float4 m_TriPlanarWeights : SC2_SEM_TriPlanarWeights;
#endif
#if SC2_HAS_UV
    float4 m_UV[SC2_UV_COUNT] : SC2_SEM_UV;
#endif

    // NOTE: `WRITE_INTERPOLANT_UV(i, v)` is a *macro* (model_vs.slang's
    // SC2_EMIT_UV), not a `[mutating]` method here.  A mutating method lowers to a
    // whole-struct inout parameter, and fxc then rejects the call because vertOut is
    // only partially written at that point in the body (X3508 "output parameter not
    // completely initialized") — the original's macro assigns the field in place.

    // INTERPOLANT_* read-back (gen_preamble's `interp_macros`): the packed field,
    // the Binormal reconstruction, or the 0 safety net.
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
    float4 VectorUI1()
    {
#if SC2_HAS_VectorUI1
        return m_VectorUI1;
#else
        return float4(0, 0, 0, 0);
#endif
    }
};

// ---------------------------------------------------------------------------
// $Globals for the vertex stage.
//
// Declared as a ConstantBuffer<struct> (the wc3_shaders idiom the pixel root also
// uses) so the members are struct-scoped rather than module-global symbols — the
// vertex and pixel roots share engine constant NAMES (p_vEyePos, p_cFogColor, …)
// and module-global cbuffer members would collide inside the one translation unit.
// Members drop the `p_` prefix but canonicalise to the fxc reference's names
// (bm.canon strips `p_`), which is how the behavioral comparator aligns them; the
// declaration order mirrors the reference's $Globals so the packing lines up too.
// Matrices are `row_major` (shadersystem.fx:4 `#pragma pack_matrix(row_major)`) —
// the harness feeds identical cbuffer bytes to both legs, so storage must agree.
// ---------------------------------------------------------------------------

// vsvertexwarp.fx : VertexWarp.
public struct VertexWarp
{
    row_major float3x4 vTransform;
    row_major float3x4 vInvTransform;
    float2 vStrengthRadius;
};

// slangc applies its row-major storage wrapper (`_MatrixStorage_float3x4natural`,
// i.e. one float4 per matrix ROW — byte-identical to fxc's `row_major float3x4`)
// only to *scalar* matrix members.  A matrix ARRAY member is left in the natural
// column-major layout at a 4-row stride, so `row_major float3x4 m[64]` would take
// 64 bytes per element (vs the reference's 48) AND transpose every element — the
// harness feeds both legs the same cbuffer bytes, so that silently corrupts every
// skinned vertex.  Matrix arrays are therefore declared as their float4 ROWS and
// rebuilt in code (vsBlendMatrix / vsSplatProjMatrix), which reproduces the
// reference's byte layout exactly.
#define VS_MATROWS(name, n, rows) float4 name[(n) * (rows)]

public struct DefaultVSGlobalsT
{
    // vsskinning.fx — must come first (CShaderCore::UpdateRegisters relies on it).
    // = `row_major float3x4 p_mBlendMatrices[64]` (3 float4 rows per bone).
    VS_MATROWS(mBlendMatrices, MAX_BONE_MATRICES, 3);

    // vsmodelvertexformat.fx
    float2 uvRangeOffset;

    // common.fx
    float3 vEyePos;
    float4 vSpecColorSpecularity;
    float2 vViewportOrigin;
    float2 vViewportScale;
    row_major float4x4 mShadowTransform;
    row_major float3x4 mViewTransform;
    float3 vCameraDirection;
    float4 vSpecularMultiplier_DepthBlendThreshold_HeightMapScale_AlphaFactor;
    row_major float4x4 mFOWMatrix;
    float2 vHDRScaling;
    float  fAlphaThreshold;
    float4 vClipPlanes[6];
    float  iClipPlaneCount;
    float3 vFogDensity_Falloff_MinHeight;
    float4 cFogColor;
    float4 vFogDistance;

    // vsvertexwarp.fx
    VertexWarp warps[MAX_WARPS];
    float3 vVertexWarpModelPosition;

    // vscommon.fx
    row_major float4x4 mVPTransform;

    // vsuvmapping.fx
    float3 vTriPlanarOffset[MAX_UV_EMITTERS];
    float3 vTriPlanarScale[MAX_UV_EMITTERS];
    // = `row_major float4x4 p_mSplatTextureProjMatrix[8]` (4 float4 rows each).
    VS_MATROWS(mSplatTextureProjMatrix, MAX_SPLATS, 4);
    float4 vTerrainTiling;

    // lighting.fx (vertex lighting reads the same light set the pixel stage does).
    float3           cAmbientColor;
    DirectionalLight directionalLights[3];
    PointLight       pointLights[3];
    SpotLight        spotLights[7];
    LightSetup       lightSetups[4];
    float4           vWorldToLightingRegionTransform;

    // model.fx
    row_major float4x4 mTerrainTextureMatrix;
    float4 InvCreepTextureRotation;
    float4 vCreepTextureRotation;
    row_major float4x4 mInstanceTransform;
    float4 vVectorUIColor;
    float4 vVectorUIInterpolant0;
    float4 vVectorUIInterpolant1;
    float4 vVectorUIInterpolant2;
    float4 vSplatAttenuationPlane;
    float2 fSplatAttenuationScalar_MinHeight;
    float3 vSplatTextureUVector;

    // foliage.fx — the per-cell wind/force offsets and the position compression.
    // Declared alongside the Model constants because ALL Default-family vertex
    // roots share ONE b0 buffer: the comparator aligns constants by NAME, so a
    // constant the current entry never reads is inert (it just occupies layout),
    // whereas a second cbuffer at b0 would collide.
    float4 vOffsetVectors[FOLIAGE_GRID_SIZE * FOLIAGE_GRID_SIZE];
    float3 vCompressedPositionScale;
    float3 vCompressedPositionOffset;

    // ribbonparticlecommon.fx — the per-batch keyframe times shared by the two
    // GPU-simulated families.  (.x scale, .y colour, .z alpha, .w rotation.)
    VS_MATROWS(mPRWorldTransform, MAX_BATCHED_RIBBONS, 4);
    float4 vMidKeyTimes[MAX_BATCHED_RIBBONS];
    float4 vInversedMidKeyTimes[MAX_BATCHED_RIBBONS];
    float4 vMidKeyHoldTimes[MAX_BATCHED_RIBBONS];

    // ribbon.fx — per-batch simulation state.
    VS_MATROWS(mRibbonInstanceTransform, MAX_BATCHED_RIBBONS, 4);
    VS_MATROWS(mInvPRWorldTransform, MAX_BATCHED_RIBBONS, 4);
    float4 vSystemPhysicsConstants[MAX_BATCHED_RIBBONS];      // x m, y 1/m, z gravity, w drag
    float4 vLockedStartPositionAndTime[MAX_BATCHED_RIBBONS];  // xyz clamped head, w its time
    float4 vLockedTailPositionAndTime[MAX_BATCHED_RIBBONS];   // xyz clamped tail, w its time
    float4 vGPURibbonValues[MAX_BATCHED_RIBBONS];             // x time, yz uv gen, w tail clamp
    float3 mSplineRibbonControlPoints[4 * MAX_BATCHED_RIBBONS];
    float3 vSplineRibbonSize[MAX_BATCHED_RIBBONS];
    float4 vSplineRibbonColor0[MAX_BATCHED_RIBBONS];
    float4 vSplineRibbonColor1[MAX_BATCHED_RIBBONS];
    float4 vSplineRibbonColor2[MAX_BATCHED_RIBBONS];
    // `ArrayDecl(float)` is a plain `float` array off the OpenGL/Metal paths, and
    // `floatRef(v)` is the identity — so this is a scalar array at the HLSL
    // 16-byte element stride, matching the reference's `float p_f...[32]`.
    float fRibbonBatchIndexRemappingTable[MAX_BATCH_INDEX_REMAPPING_TABLE_SIZE];

    // ---- M4 self-contained families ----------------------------------------
    // Same argument as the foliage block above: every vertex root shares this one
    // b0 buffer, so the small own-IO families' uniforms live here and are inert
    // (layout only) for every other entry.
    float3             vSize;              // p_vSize         (renderplane.fx)
    float3             vOffset;            // p_vOffset       (renderplane.fx)
    row_major float4x4 mWorldViewProj;     // p_mWorldViewProj(renderplane.fx)
    row_major float4x4 mTransform;         // p_mTransform    (minimapterrain.fx, flash.fx)
    float4             mTexgen0;           // p_mTexgen0..3   (flash.fx; float4 rows,
    float4             mTexgen1;           //   dotted against the position, not matrices)
    float4             mTexgen2;
    float4             mTexgen3;

    // particle.fx — per-batch instancing, flipbook atlas and billboard basis.
    VS_MATROWS(mParticleInstanceTransform, MAX_BATCHED_PARTICLES, 4);
    float3 vBillboardRight;
    float3 vBillboardUp;
    float4 vSystemTime_ElementScale_FlipbookMidKeyTime_FlipbookColumnCount[MAX_BATCHED_PARTICLES];
    float3 fFlipbookFrames[MAX_BATCHED_PARTICLES];
    float2 vFlipbookCellSize[MAX_BATCHED_PARTICLES];
    float fParticleBatchIndexRemappingTable[MAX_BATCH_INDEX_REMAPPING_TABLE_SIZE];

    // deferredlight.fx — the light volume's world-view-projection.  (Its
    // p_mWVTransform / p_mWorldTransform are declared but never read, so they are
    // omitted: both legs DCE them.)
    row_major float4x4 mWVPTransform;      // p_mWVPTransform

    // postprocessquad.fx + vspostprocess.fx.  Its `p_mTransform` is the SAME name
    // and type as minimapterrain/flash/image's, so it reuses `mTransform` above —
    // the comparator aligns constants by name, so a family-specific alias would be
    // fed a different random value on each leg and break every b_useTransform perm.
    float2 vCameraSize;                        // p_vCameraSize
    float2 vSrcSize;                           // p_vSrcSize (vspostprocess.fx)
    float2 vBlurOffsets[b_iSampleCount + 1];   // p_vBlurOffsets (vspostprocess.fx)
};
ConstantBuffer<DefaultVSGlobalsT> vsGlobals : register(b0);
