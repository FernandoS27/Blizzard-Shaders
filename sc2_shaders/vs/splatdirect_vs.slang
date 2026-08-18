// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SplatDirect family vertex shader (splatdirect.fx : SplatDirectVertexMain).
//
// The legacy batched splat: many splats in one draw, selected per vertex by
// `vBlendIndices[0]` through `p_fBatchIndexRemappingTable`, with every per-splat
// uniform an 8-entry array.  Vertices are already in world space (no skinning, no
// vertex warps — splatdirect.fx includes neither VSSkinning.fx nor VSVertexWarp.fx),
// so the body is: pick the batch, optionally replace the position with a volume
// corner for the stencil-fill pass, then fill the shared interpolant transport.
//
// The vertex stream is the Model `VertDecl` with SPLAT_VERTEX_FORMAT, whose only
// difference is `BlendIndexType = uint4` — a TRUE integer attribute, so the harness
// draws it from an integer domain (sc2_shaders_cfg.VS_INPUT_DOMAINS) instead of
// D3DCOLOR bytes.
//
// Own-ROOT on the SHARED transport (InitShader + WRITE_INTERPOLANT_*), so the live
// set is mask-derived and `inject_preamble` stays true.  Key schema: the same one its
// pixel stage decodes — own axis b_stencilFillPass@104, then Model's shared sections
// (SplatDirect_BuildFamily links exactly Model's list, minus VertexWarp).

implementing sc2_shaders;

#include "vs/model_vs_defines.slangh"

// ---------------------------------------------------------------------------
// vsmodelvertexformat.fx : VertDecl / Input under SPLAT_VERTEX_FORMAT.
// Same gating as the Model structs; only the blend-index type differs.
// ---------------------------------------------------------------------------
public struct SplatDirectVSStreamIn
{
    float4 vPosition : POSITION;
#if !b_iLayoutHasNoVertexBlendWeights
    float4 vBlendWeights : BLENDWEIGHT;
#endif
#if !b_iLayoutHasNoVertexBlendIndices
    uint4 vBlendIndices : BLENDINDICES;
#endif
    float4 vNormal : NORMAL;
#if b_iLayoutHasColor
    float4 cColor : COLOR0;
#endif
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

public struct SplatDirectVSVertex
{
    float4 vPosition;
    uint4  vBlendIndices;
    float4 vNormal;
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

    // `HasUVCoordN_( UVn = vertIn.vUVn.xy; )` — an absent coordinate set leaves the
    // 0 that EmitSplatUV initialises.
    float2 UVCoord0() {
#if (b_iUVCoordCount >= 1)
        return vUV0;
#else
        return float2(0, 0);
#endif
    }
    float2 UVCoord1() {
#if (b_iUVCoordCount >= 2)
        return vUV1;
#else
        return float2(0, 0);
#endif
    }
    float2 UVCoord2() {
#if (b_iUVCoordCount >= 3)
        return vUV2;
#else
        return float2(0, 0);
#endif
    }
    float2 UVCoord3() {
#if (b_iUVCoordCount >= 4)
        return vUV3;
#else
        return float2(0, 0);
#endif
    }
};

SplatDirectVSVertex vsTranslateSplatVert(SplatDirectVSStreamIn src)
{
    SplatDirectVSVertex dst;
    dst.vPosition = src.vPosition;
#if !b_iLayoutHasNoVertexBlendIndices
    dst.vBlendIndices = src.vBlendIndices;
#endif
#if (b_iUVCoordCount >= 1)
    dst.vUV0 = float2(src.vUV0) * vsGlobals.uvRangeOffset.x + vsGlobals.uvRangeOffset.y;
#endif
#if (b_iUVCoordCount >= 2)
    dst.vUV1 = float2(src.vUV1) * vsGlobals.uvRangeOffset.x + vsGlobals.uvRangeOffset.y;
#endif
#if (b_iUVCoordCount >= 3)
    dst.vUV2 = float2(src.vUV2) * vsGlobals.uvRangeOffset.x + vsGlobals.uvRangeOffset.y;
#endif
#if (b_iUVCoordCount >= 4)
    dst.vUV3 = float2(src.vUV3) * vsGlobals.uvRangeOffset.x + vsGlobals.uvRangeOffset.y;
#endif
    // The tangent basis arrives ubyte4n-packed; normal.w carries the handedness.
    dst.vNormal  = 2.0f * src.vNormal - 1.0f;
    dst.vTangent = 2.0f * src.vTangent - 1.0f;
    dst.vBinormal = normalize(cross(dst.vTangent.xyz, dst.vNormal.xyz))
                  * sign(dst.vNormal.w);
    return dst;
}

// ---------------------------------------------------------------------------
// splatdirect.fx : VERTEX SHADER EMITTERS
// ---------------------------------------------------------------------------
float4 vsEmitSplatHPos(SplatDirectVSVertex vertIn)
{
    return mul(vertIn.vPosition, vsGlobals.mVPTransform);
}

float4 vsEmitSplatWorldPos(SplatDirectVSVertex vertIn)
{
    return float4(vertIn.vPosition.xyz, 1.0f);
}

float3 vsEmitSplatViewPos(SplatDirectVSVertex vertIn)
{
    return mul(vsGlobals.mViewTransform, vertIn.vPosition);     // as 3x4
}

// Normal; .w is the handedness recovered from the stream binormal.
float4 vsEmitSplatNormal(SplatDirectVSVertex vertIn)
{
    float3 righthandedBinormal = cross(vertIn.vNormal.xyz, vertIn.vTangent.xyz);
    float righthanded = dot(vertIn.vBinormal, righthandedBinormal);
    return float4(vertIn.vNormal.xyz, sign(righthanded));
}

float4 vsEmitSplatTangent(SplatDirectVSVertex vertIn)
{
    return float4(vertIn.vTangent.xyz, 1);
}

float3 vsEmitSplatBinormal(SplatDirectVSVertex vertIn)
{
    return vertIn.vBinormal;
}

// One UV emitter slot.  Splats pass the local position for both spaces' positions and
// the local normal alongside the world one, and — unlike the Model root — a RUNTIME
// splat index (the remapped batch index).
float4 vsEmitSplatUV<let M : int, let I : int>(SplatDirectVSVertex vertIn,
                                               float3 vLocalPosition,
                                               float4 vLocalNormal,
                                               int iBatchIndex)
{
    return vsGenUV<M, I>(
        vLocalPosition,
        vertIn.vPosition.xyz,
        vLocalNormal.xyz,
        vertIn.vNormal.xyz,
        vertIn.UVCoord0(),
        vertIn.UVCoord1(),
        vertIn.UVCoord2(),
        vertIn.UVCoord3(),
        iBatchIndex,
        float3(0, 0, 0));
}

float4 vsEmitSplatVertexColor(SplatDirectVSVertex vertIn, int iBatchIndex)
{
    if (b_iShadingMode == VS_SHADINGMODE_VECTORUI)
        return vsGlobals.cVectorUIColors[iBatchIndex];
    else
        return float4(1, 1, 1, vsGlobals.fSplatAlphaMultiplier[iBatchIndex]);
}

float3 vsEmitSplatEyeToVertex(SplatDirectVSVertex vertIn)
{
    return normalize(vertIn.vPosition.xyz - vsGlobals.vEyePos);
}

float4 vsEmitSplatFOWUV(SplatDirectVSVertex vertIn)
{
    return mul(vertIn.vPosition, vsGlobals.mFOWMatrix);
}

// ---------------------------------------------------------------------------
// UV-emitter unroll (same shape as the Model / Foliage roots').
// ---------------------------------------------------------------------------
#if SC2_HAS_UV
  #define SC2_SPL_UV(dst, i)                                                        \
    vertOut.m_UV[dst] = vsEmitSplatUV<SC2_UVMAPPING##i, i>(                         \
        vertIn, vLocalPosition, vLocalNormal, iBatchIndex)
  #define SC2_SPL_UV_PAIR(dst, i, j)                                                \
    vertOut.m_UV[dst] = float4(                                                     \
        vsEmitSplatUV<SC2_UVMAPPING##i, i>(vertIn, vLocalPosition, vLocalNormal,    \
                                           iBatchIndex).xy,                         \
        vsEmitSplatUV<SC2_UVMAPPING##j, j>(vertIn, vLocalPosition, vLocalNormal,    \
                                           iBatchIndex).xy)
#else
  #define SC2_SPL_UV(dst, i)
  #define SC2_SPL_UV_PAIR(dst, i, j)
#endif

// ---------------------------------------------------------------------------
// Main vertex shader body.
// ---------------------------------------------------------------------------
[shader("vertex")]
public DefaultVSOutput splatdirect_vs_main(SplatDirectVSStreamIn streamIn)
{
    DefaultVSOutput vertOut;

    SplatDirectVSVertex vertIn = vsTranslateSplatVert(streamIn);

    int iBatchIndex = (int)vertIn.vBlendIndices[0];

    // The stencil-fill pass draws the splat's bounding volume, so the vertex IS a
    // corner index rather than a surface point.
#if b_stencilFillPass
    {
        int iCornerIndex = iBatchIndex;
        vertIn.vPosition = float4(vsGlobals.vSplatVolumeCorner[iCornerIndex].xyz, 1);
    }
#endif

    // Remap the index into the per-splat uniform arrays.
    iBatchIndex = (int)(vsGlobals.fBatchIndexRemappingTable[iBatchIndex] + 0.1);

    // Preserve the local position / normal (some UV mappings are based on them).
    float3 vLocalPosition = vertIn.vPosition.xyz;
    float4 vLocalNormal = vertIn.vNormal;

    vertOut.HPos = vsEmitSplatHPos(vertIn);

    float4 interpNormal   = vsEmitSplatNormal(vertIn);
    float4 interpTangent  = vsEmitSplatTangent(vertIn);
    float3 interpBinormal = vsEmitSplatBinormal(vertIn);

#if SC2_HAS_HPosAsUV
    vertOut.m_HPosAsUV = vsEmitSplatHPos(vertIn);       // EmitSplatHPosAsUV
#endif
#if SC2_HAS_WorldPos
    vertOut.m_WorldPos = vsEmitSplatWorldPos(vertIn);
#endif
#if SC2_HAS_ViewPos
    vertOut.m_ViewPos = vsEmitSplatViewPos(vertIn);
#endif
#if SC2_HAS_Normal
    vertOut.m_Normal = interpNormal;
#endif
#if SC2_HAS_Tangent
    vertOut.m_Tangent = interpTangent;
#endif
#if SC2_HAS_Binormal
    vertOut.m_Binormal = interpBinormal;
#endif
#if SC2_HAS_VertexColor
    vertOut.m_VertexColor = vsEmitSplatVertexColor(vertIn, iBatchIndex);
#endif

    // Vertex lighting — splats pass NO lighting regions (a literal 0 vector).
#if (SC2_HAS_Diffuse || SC2_HAS_Specular || SC2_HAS_ShadowDiffuse || SC2_HAS_ShadowSpecular)
    float3 cVertexSpecularLighting = float3(0, 0, 0);
    float3 cVertexShadowSpecularLighting = float3(0, 0, 0);
    float3 cVertexShadowSpecularLighting2 = float3(0, 0, 0);
  #if SC2_HAS_Diffuse
    vertOut.m_Diffuse = vsEmitDiffuse(vertOut, vertIn.vPosition.xyz, vertIn.vNormal.xyz,
                                      float4(0, 0, 0, 0), cVertexSpecularLighting,
                                      cVertexShadowSpecularLighting,
                                      cVertexShadowSpecularLighting2);
  #endif
  #if SC2_HAS_Specular
    vertOut.m_Specular = vsEmitSpecular(cVertexSpecularLighting);
  #endif
  #if SC2_HAS_ShadowDiffuse
    vertOut.m_ShadowDiffuse = vsEmitShadowDiffuse(vertIn.vNormal.xyz, float4(0, 0, 0, 0),
                                                  cVertexShadowSpecularLighting,
                                                  cVertexShadowSpecularLighting2);
  #endif
  #if SC2_HAS_ShadowSpecular
    vertOut.m_ShadowSpecular = vsEmitShadowSpecular(cVertexShadowSpecularLighting);
  #endif
#endif

#if SC2_HAS_ShadowMapUV
    vertOut.m_ShadowMapUV = vsEmitShadowMapUV(vertIn.vPosition.xyz);
#endif
#if SC2_HAS_FogColor
    vertOut.m_FogColor = vsEmitFogColor(vertIn.vPosition.xyz, float3(0, 0, 0));
#endif
#if SC2_HAS_HalfVec
    vertOut.m_HalfVec = vsComputeHalfVector(vertIn.vPosition.xyz);
#endif
#if SC2_HAS_EyeToVertex
    vertOut.m_EyeToVertex = vsEmitSplatEyeToVertex(vertIn);
#endif
#if SC2_HAS_EyeToVertexFresnel
    vertOut.m_EyeToVertexFresnel = vsEmitSplatEyeToVertex(vertIn);
#endif
#if SC2_HAS_FOWUV
    vertOut.m_FOWUV = vsEmitSplatFOWUV(vertIn);
#endif

    // --- per-emitter UVs ---------------------------------------------------
#if b_usePackedUVEmitter
  #if (b_iUVEmitterCount / 2 > 0)
    SC2_SPL_UV_PAIR(0, 0, 1);
  #endif
  #if (b_iUVEmitterCount / 2 > 1)
    SC2_SPL_UV_PAIR(1, 2, 3);
  #endif
  #if (b_iUVEmitterCount / 2 > 2)
    SC2_SPL_UV_PAIR(2, 4, 5);
  #endif
  #if (b_iUVEmitterCount / 2 > 3)
    SC2_SPL_UV_PAIR(3, 6, 7);
  #endif
  #if (b_iUVEmitterCount == 1)
    SC2_SPL_UV(0, 0);
  #elif (b_iUVEmitterCount == 3)
    SC2_SPL_UV(1, 2);
  #elif (b_iUVEmitterCount == 5)
    SC2_SPL_UV(2, 4);
  #elif (b_iUVEmitterCount == 7)
    SC2_SPL_UV(3, 6);
  #endif
#else
  #if (b_iUVEmitterCount > 0)
    SC2_SPL_UV(0, 0);
  #endif
  #if (b_iUVEmitterCount > 1)
    SC2_SPL_UV(1, 1);
  #endif
  #if (b_iUVEmitterCount > 2)
    SC2_SPL_UV(2, 2);
  #endif
  #if (b_iUVEmitterCount > 3)
    SC2_SPL_UV(3, 3);
  #endif
  #if (b_iUVEmitterCount > 4)
    SC2_SPL_UV(4, 4);
  #endif
  #if (b_iUVEmitterCount > 5)
    SC2_SPL_UV(5, 5);
  #endif
  #if (b_iUVEmitterCount > 6)
    SC2_SPL_UV(6, 6);
  #endif
  #if (b_iUVEmitterCount > 7)
    SC2_SPL_UV(7, 7);
  #endif
#endif

    // Vector-UI splats carry their shape parameters; everything else carries the
    // attenuation plane and the world position it is measured against.
    if (b_iShadingMode == VS_SHADINGMODE_VECTORUI)
    {
#if SC2_HAS_VectorUI0
        vertOut.m_VectorUI0 = vsGlobals.vVectorUIInterpolant0[iBatchIndex];
#endif
#if SC2_HAS_VectorUI1
        vertOut.m_VectorUI1 = vsGlobals.vVectorUIInterpolant1[iBatchIndex];
#endif
#if SC2_HAS_VectorUI2
        vertOut.m_VectorUI2 = vsGlobals.vVectorUIInterpolant2[iBatchIndex];
#endif
#if SC2_HAS_Vector4
        vertOut.m_Vector4 = vsGlobals.vSplatAttenuationPlane[iBatchIndex];
#endif
#if SC2_HAS_VectorUI0
        vertOut.m_VectorUI0.w = vsGlobals.fSplatAttenuationScalar_MinHeight[iBatchIndex].x;
#endif
    }
    else
    {
#if SC2_HAS_VectorUI0
        vertOut.m_VectorUI0 = vsGlobals.vSplatAttenuationPlane[iBatchIndex];
#endif
#if SC2_HAS_VectorUI1
        vertOut.m_VectorUI1.xyz = vsEmitSplatWorldPos(vertIn).xyz;
        vertOut.m_VectorUI1.w = vsGlobals.fSplatAttenuationScalar_MinHeight[iBatchIndex].x;
#endif
#if SC2_HAS_Tangent
        vertOut.m_Tangent.w = vsGlobals.fSplatAttenuationScalar_MinHeight[iBatchIndex].y;
#endif
    }

#if SC2_HAS_ParallaxVector
    vertOut.m_ParallaxVector = vsEmitParallaxVector(
        vertIn.vPosition.xyz, vsGlobals.vEyePos,
        interpNormal.xyz, interpTangent.xyz, interpBinormal);
#endif

    return vertOut;
}
