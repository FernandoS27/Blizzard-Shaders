// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Foliage family vertex shader (foliage.fx : FoliageVertexMain).
//
// Foliage is the smallest of the four Default families (96 retail permutations) and
// the simplest vertex root: no skinning, no vertex warps, no triplanar, no shading-
// mode dispatch.  What it does have that Model does not is a COMPRESSED vertex
// stream — position xy from the POSITION stream, z + ambient occlusion from a
// second ALTPOSITION0 stream, UVs scaled by a fixed range, and a right-handed basis
// packed as ubyte4n — plus a per-cell wind/force displacement blended from four
// `p_vOffsetVectors[]` entries.
//
// Unlike Model's, its `Input` struct is FIXED: foliage.fx declares every attribute
// unconditionally, so none of the `b_iLayoutHas*` / `b_iUVCoordCount` axes apply
// here (they exist in the schema but this family never reads them).
//
// The interpolant transport, the vertex-lighting emitters, `GenUV`, the fog/shadow
// emitters and the parallax vector are all shared with the Model root — foliage.fx
// includes the same VS*.fx headers.

implementing sc2_shaders;

#include "vs/model_vs_defines.slangh"

// ---------------------------------------------------------------------------
// foliage.fx : Input — the compressed foliage vertex stream (fixed layout).
// ALTPOSITION0_ resolves to POSITION1 on the D3D path (shadersystem.fx:99).
// ---------------------------------------------------------------------------
public struct FoliageVSInput
{
    float4 vPosition      : POSITION;
    float2 vCompressedPos : POSITION1;
    float4 vBlendWeights  : BLENDWEIGHT;
    float4 vBlendIndices  : BLENDINDICES;
    float3 vNormal        : NORMAL;
    float2 vUV0           : TEXCOORD0;
    float2 vUV1           : TEXCOORD1;
    float3 vTangent       : TANGENT;
    float3 vBinormal      : BINORMAL;
    float4 cColor         : COLOR0;
};

// vsutils.fx : DecompressRightHandedBasis — the basis arrives ubyte4n-encoded.
void vsDecompressRightHandedBasis(inout float3 vNormalWS, inout float3 vTangentWS,
                                  out float3 vBinormalWS)
{
    vNormalWS  = vNormalWS * 2.0f - 1.0f;      // common.fx : DecodeNormal
    vTangentWS = vTangentWS * 2.0f - 1.0f;
    vBinormalWS = normalize(cross(vTangentWS, vNormalWS));
}

// ---------------------------------------------------------------------------
// foliage.fx : VERTEX SHADER EMITTERS
// ---------------------------------------------------------------------------
float4 vsEmitFoliageHPos(FoliageVSInput vertIn)
{
    return mul(vertIn.vPosition, vsGlobals.mVPTransform);
}

float4 vsEmitFoliageWorldPos(FoliageVSInput vertIn)
{
    return float4(vertIn.vPosition.xyz, 1.0f);
}

float3 vsEmitFoliageViewPos(FoliageVSInput vertIn)
{
    return mul(vsGlobals.mViewTransform, vertIn.vPosition);     // as 3x4
}

// Normal; .w carries the basis handedness recovered from the stream binormal.
float4 vsEmitFoliageNormal(FoliageVSInput vertIn)
{
    float3 righthandedBinormal = cross(vertIn.vNormal.xyz, vertIn.vTangent.xyz);
    float righthanded = dot(vertIn.vBinormal, righthandedBinormal);
    return float4(vertIn.vNormal.xyz, sign(righthanded));
}

float4 vsEmitFoliageTangent(FoliageVSInput vertIn)
{
    return float4(vertIn.vTangent.xyz, 1);
}

float3 vsEmitFoliageBinormal(FoliageVSInput vertIn)
{
    return vertIn.vBinormal;
}

// UVs.  Foliage feeds GenUV the same position for local and world space, its normal
// for both normals, and — unlike Model — a RUNTIME splat index taken from the first
// blend index.  (The `:TODO:` in the original passes vUV0 for UV2/UV3 as well.)
float4 vsEmitFoliageUV<let M : int, let I : int>(FoliageVSInput vertIn)
{
    return vsGenUV<M, I>(
        vertIn.vPosition.xyz,
        vertIn.vPosition.xyz,
        vertIn.vNormal.xyz,
        vertIn.vNormal.xyz,
        vertIn.vUV0.xy,
        vertIn.vUV1.xy,
        vertIn.vUV0.xy,        // :TODO: (original) These are missing?
        vertIn.vUV0.xy,
        (int)vertIn.vBlendIndices[0],
        float3(0, 0, 0));
}

// Vertex colour: the decompressed ambient occlusion in rgb, stream alpha in a.
float4 vsEmitFoliageVertexColor(FoliageVSInput vertIn, float fAO)
{
    return float4(fAO, fAO, fAO, vertIn.cColor.a);
}

float3 vsEmitFoliageEyeToVertex(FoliageVSInput vertIn)
{
    return normalize(vertIn.vPosition.xyz - vsGlobals.vEyePos);
}

float4 vsEmitFoliageFOWUV(FoliageVSInput vertIn)
{
    return mul(vertIn.vPosition, vsGlobals.mFOWMatrix);
}

// ---------------------------------------------------------------------------
// UV-emitter unroll (same shape as the Model root's).
// ---------------------------------------------------------------------------
#if SC2_HAS_UV
  #define SC2_FOL_UV(dst, i)                                                         \
    vertOut.m_UV[dst] = vsEmitFoliageUV<SC2_UVMAPPING##i, i>(vertIn)
  #define SC2_FOL_UV_PAIR(dst, i, j)                                                 \
    vertOut.m_UV[dst] = float4(vsEmitFoliageUV<SC2_UVMAPPING##i, i>(vertIn).xy,      \
                               vsEmitFoliageUV<SC2_UVMAPPING##j, j>(vertIn).xy)
#else
  #define SC2_FOL_UV(dst, i)
  #define SC2_FOL_UV_PAIR(dst, i, j)
#endif

// ---------------------------------------------------------------------------
// Main vertex shader body.
// ---------------------------------------------------------------------------
[shader("vertex")]
public DefaultVSOutput foliage_vs_main(FoliageVSInput streamIn)
{
    DefaultVSOutput vertOut;
    FoliageVSInput vertIn = streamIn;    // the original mutates its `in` parameter

    {
        float3 n = vertIn.vNormal, t = vertIn.vTangent, b;
        vsDecompressRightHandedBasis(n, t, b);
        vertIn.vNormal = n;
        vertIn.vTangent = t;
        vertIn.vBinormal = b;
    }

    // Decompress the position: xy from the POSITION stream, z from ALTPOSITION0.x.
    vertIn.vPosition.xy = (vertIn.vPosition.xy * vsGlobals.vCompressedPositionScale.xy)
                        + vsGlobals.vCompressedPositionOffset.xy;
    vertIn.vPosition.z = (vertIn.vCompressedPos.x * vsGlobals.vCompressedPositionScale.z)
                       + vsGlobals.vCompressedPositionOffset.z;
    vertIn.vPosition.w = 1.0f;
    float fAO = vertIn.vCompressedPos.y;

    // Decompress the UVs.
    vertIn.vUV0 *= FOLIAGE_UV_RANGE;
    vertIn.vUV1 *= FOLIAGE_UV_RANGE;

    // Offset the vertex by the per-cell forces (a plain truncating cast here, NOT
    // D3DCOLORtoUBYTE4 — foliage indexes a 64-entry force table, not a bone palette).
    int4 iFoliageIndices = (int4)vertIn.vBlendIndices;
    vertIn.vPosition.xyz += vsGlobals.vOffsetVectors[iFoliageIndices[0]].xyz * vertIn.vBlendWeights.x;
    vertIn.vPosition.xyz += vsGlobals.vOffsetVectors[iFoliageIndices[1]].xyz * vertIn.vBlendWeights.y;
    vertIn.vPosition.xyz += vsGlobals.vOffsetVectors[iFoliageIndices[2]].xyz * vertIn.vBlendWeights.z;
    vertIn.vPosition.xyz += vsGlobals.vOffsetVectors[iFoliageIndices[3]].xyz * vertIn.vBlendWeights.w;

    vertOut.HPos = vsEmitFoliageHPos(vertIn);

    float4 interpNormal   = vsEmitFoliageNormal(vertIn);
    float4 interpTangent  = vsEmitFoliageTangent(vertIn);
    float3 interpBinormal = vsEmitFoliageBinormal(vertIn);

#if SC2_HAS_HPosAsUV
    vertOut.m_HPosAsUV = mul(vertIn.vPosition, vsGlobals.mVPTransform);
#endif
#if SC2_HAS_WorldPos
    vertOut.m_WorldPos = vsEmitFoliageWorldPos(vertIn);
#endif
#if SC2_HAS_ViewPos
    vertOut.m_ViewPos = vsEmitFoliageViewPos(vertIn);
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
    vertOut.m_VertexColor = vsEmitFoliageVertexColor(vertIn, fAO);
#endif

    // Vertex lighting — foliage passes NO lighting regions (a literal 0 vector).
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
    // EmitFogColor's triplanar-weights argument defaults to 0 for foliage.
    vertOut.m_FogColor = vsEmitFogColor(vertIn.vPosition.xyz, float3(0, 0, 0));
#endif
#if SC2_HAS_HalfVec
    vertOut.m_HalfVec = vsComputeHalfVector(vertIn.vPosition.xyz);
#endif
#if SC2_HAS_EyeToVertex
    vertOut.m_EyeToVertex = vsEmitFoliageEyeToVertex(vertIn);
#endif
#if SC2_HAS_EyeToVertexFresnel
    vertOut.m_EyeToVertexFresnel = vsEmitFoliageEyeToVertex(vertIn);
#endif
#if SC2_HAS_FOWUV
    vertOut.m_FOWUV = vsEmitFoliageFOWUV(vertIn);
#endif

#if b_usePackedUVEmitter
  #if (b_iUVEmitterCount / 2 > 0)
    SC2_FOL_UV_PAIR(0, 0, 1);
  #endif
  #if (b_iUVEmitterCount / 2 > 1)
    SC2_FOL_UV_PAIR(1, 2, 3);
  #endif
  #if (b_iUVEmitterCount / 2 > 2)
    SC2_FOL_UV_PAIR(2, 4, 5);
  #endif
  #if (b_iUVEmitterCount / 2 > 3)
    SC2_FOL_UV_PAIR(3, 6, 7);
  #endif
  #if (b_iUVEmitterCount == 1)
    SC2_FOL_UV(0, 0);
  #elif (b_iUVEmitterCount == 3)
    SC2_FOL_UV(1, 2);
  #elif (b_iUVEmitterCount == 5)
    SC2_FOL_UV(2, 4);
  #elif (b_iUVEmitterCount == 7)
    SC2_FOL_UV(3, 6);
  #endif
#else
  #if (b_iUVEmitterCount > 0)
    SC2_FOL_UV(0, 0);
  #endif
  #if (b_iUVEmitterCount > 1)
    SC2_FOL_UV(1, 1);
  #endif
  #if (b_iUVEmitterCount > 2)
    SC2_FOL_UV(2, 2);
  #endif
  #if (b_iUVEmitterCount > 3)
    SC2_FOL_UV(3, 3);
  #endif
  #if (b_iUVEmitterCount > 4)
    SC2_FOL_UV(4, 4);
  #endif
  #if (b_iUVEmitterCount > 5)
    SC2_FOL_UV(5, 5);
  #endif
  #if (b_iUVEmitterCount > 6)
    SC2_FOL_UV(6, 6);
  #endif
  #if (b_iUVEmitterCount > 7)
    SC2_FOL_UV(7, 7);
  #endif
#endif

#if SC2_HAS_ParallaxVector
    vertOut.m_ParallaxVector = vsEmitParallaxVector(
        vertIn.vPosition.xyz, vsGlobals.vEyePos,
        interpNormal.xyz, interpTangent.xyz, interpBinormal.xyz);
#endif

    return vertOut;
}
