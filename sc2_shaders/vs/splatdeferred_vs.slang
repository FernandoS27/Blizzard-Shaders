// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SplatDeferred family vertex shader (splatdeferred.fx : SplatDeferredVertexMain).
//
// The single-splat deferred variant: a position + normal stream, a world transform,
// and a flat UV taken straight from the local position.  It is an own-ROOT vertex
// shader on the SHARED interpolant transport (InitShader + WRITE_INTERPOLANT_*), so
// the live set is mask-derived and `inject_preamble` stays true.
//
// Key schema: the same one its pixel stage decodes — own axes b_iUseHardwareDepth@104,
// b_iUseMinimumHeight@105, b_iSplatBoxRender@106, then Model's shared sections.  None
// of the three reaches this vertex closure (they drive the pixel-side box-render
// preamble); what does is b_iShadingMode, the lighting axes and b_iUVEmitterCount.
//
// Measured across all 12 retail VS permutations: b_iUVEmitterCount is 0 on every one
// (so the UV loop never runs and the UV array is never live) and b_iLayoutHasColor is
// 0 on every one — which is just as well, see the `HasColor_` note in the body.

implementing sc2_shaders;

#include "vs/model_vs_defines.slangh"

// splatdeferred.fx : SplatVertIn — position + normal only.
public struct SplatDeferredVSInput
{
    float4 vPosition : POSITION;
    float4 vNormal   : NORMAL;
};

// splatdeferred.fx : EmitSplatVertexColor.  Single splat, so the uniforms are
// scalars — they are element 0 of the shared per-splat arrays (see
// types/model_vs_io.slang).
float4 vsEmitSplatDeferredVertexColor()
{
    if (b_iShadingMode == VS_SHADINGMODE_VECTORUI)
        return vsGlobals.cVectorUIColor;
    else
        return float4(1, 1, 1, vsGlobals.fSplatAlphaMultiplier[0]);
}

// The flat UV every emitter slot gets: the local position mapped into [0,1] with V
// flipped.  Only .xy is written — the original's WRITE_INTERPOLANT_SWIZZLE_UV(i, xy, …)
// leaves .zw untouched, so the vertex output write mask must too.
#if SC2_HAS_UV
  #define SC2_SD_UV(i)                                                             \
    vertOut.m_UV[i].xy = float2(vLocalPosition.x + 0.5f, -vLocalPosition.y + 0.5f)
#else
  #define SC2_SD_UV(i)
#endif

// ---------------------------------------------------------------------------
// Main vertex shader body.
// ---------------------------------------------------------------------------
[shader("vertex")]
public DefaultVSOutput splatdeferred_vs_main(SplatDeferredVSInput streamIn)
{
    DefaultVSOutput vertOut;
    SplatDeferredVSInput vertIn = streamIn;   // the original mutates its `in` parameter

    // Preserve the local position (the UV mapping is based on it).
    float3 vLocalPosition = vertIn.vPosition.xyz;

    vertIn.vPosition = mul(vertIn.vPosition, vsGlobals.mWorldTransform);
    vertOut.HPos = mul(vertIn.vPosition, vsGlobals.mVPTransform);

#if SC2_HAS_HPosAsUV
    vertOut.m_HPosAsUV = mul(vertIn.vPosition, vsGlobals.mVPTransform);
#endif
#if SC2_HAS_WorldPos
    vertOut.m_WorldPos = float4(vertIn.vPosition.xyz, 1.0f);
#endif
#if SC2_HAS_ViewPos
    vertOut.m_ViewPos = mul(vsGlobals.mViewTransform, vertIn.vPosition);
#endif
#if SC2_HAS_Normal
    vertOut.m_Normal = vertIn.vNormal;
#endif
#if SC2_HAS_Tangent
    vertOut.m_Tangent = vsGlobals.vTangent;
#endif

    // "We may be using vertex alpha for something else, so just recalculate the 4th
    // region."  The original guards that recompute with `HasColor_()` and reads
    // `vertIn.cColor` — but SplatVertIn has no colour attribute at all, so the family
    // compiles only because b_iLayoutHasColor is 0 on every retail SplatDeferred
    // permutation and the macro erases the text before fxc sees it.  Transcribing it
    // as an inert `#if` here would be WRONG rather than merely redundant: the whole
    // module is ONE translation unit, so a MODEL slot with b_iLayoutHasColor=1 turns
    // the guard on inside this file and breaks that unrelated family's compile.
    float4 vLightingRegions = float4(0, 0, 0, 0);

#if (SC2_HAS_Diffuse || SC2_HAS_Specular || SC2_HAS_ShadowDiffuse || SC2_HAS_ShadowSpecular)
    float3 cVertexSpecularLighting = float3(0, 0, 0);
    float3 cVertexShadowSpecularLighting = float3(0, 0, 0);
    float3 cVertexShadowSpecularLighting2 = float3(0, 0, 0);
  #if SC2_HAS_Diffuse
    vertOut.m_Diffuse = vsEmitDiffuse(vertOut, vertIn.vPosition.xyz, vertIn.vNormal.xyz,
                                      vLightingRegions, cVertexSpecularLighting,
                                      cVertexShadowSpecularLighting,
                                      cVertexShadowSpecularLighting2);
  #endif
  #if SC2_HAS_Specular
    vertOut.m_Specular = vsEmitSpecular(cVertexSpecularLighting);
  #endif
    // As in water.fx, the original calls EmitShadowDiffuse with THREE arguments
    // against its four-parameter declaration (the missing vLightingRegions); it only
    // survives because the write macro is a no-op on every retail permutation and so
    // discards the argument text.  Zero regions is the intent.
  #if SC2_HAS_ShadowDiffuse
    vertOut.m_ShadowDiffuse = vsEmitShadowDiffuse(vertIn.vNormal.xyz, float4(0, 0, 0, 0),
                                                  cVertexShadowSpecularLighting,
                                                  cVertexShadowSpecularLighting2);
  #endif
  #if SC2_HAS_ShadowSpecular
    vertOut.m_ShadowSpecular = vsEmitShadowSpecular(cVertexShadowSpecularLighting);
  #endif
#endif

#if SC2_HAS_FogColor
    vertOut.m_FogColor = vsEmitFogColor(vertIn.vPosition.xyz, float3(0, 0, 0));
#endif
#if SC2_HAS_EyeToVertex
    vertOut.m_EyeToVertex = normalize(vertIn.vPosition.xyz - vsGlobals.vEyePos);
#endif
#if SC2_HAS_EyeToVertexFresnel
    vertOut.m_EyeToVertexFresnel = normalize(vertIn.vPosition.xyz - vsGlobals.vEyePos);
#endif
#if SC2_HAS_FOWUV
    vertOut.m_FOWUV = mul(vertIn.vPosition, vsGlobals.mFOWMatrix);
#endif
#if SC2_HAS_VertexColor
    vertOut.m_VertexColor = vsEmitSplatDeferredVertexColor();
#endif

    // The per-emitter UV loop (`for (uvIndex = 0; uvIndex < b_iUVEmitterCount; …)`)
    // over a compile-time bound.  The commented-out GenUV variant in the original is
    // left out, exactly as it is there.
#if (b_iUVEmitterCount > 0 && SC2_UV_COUNT > 0)
    SC2_SD_UV(0);
#endif
#if (b_iUVEmitterCount > 1 && SC2_UV_COUNT > 1)
    SC2_SD_UV(1);
#endif
#if (b_iUVEmitterCount > 2 && SC2_UV_COUNT > 2)
    SC2_SD_UV(2);
#endif
#if (b_iUVEmitterCount > 3 && SC2_UV_COUNT > 3)
    SC2_SD_UV(3);
#endif
#if (b_iUVEmitterCount > 4 && SC2_UV_COUNT > 4)
    SC2_SD_UV(4);
#endif
#if (b_iUVEmitterCount > 5 && SC2_UV_COUNT > 5)
    SC2_SD_UV(5);
#endif
#if (b_iUVEmitterCount > 6 && SC2_UV_COUNT > 6)
    SC2_SD_UV(6);
#endif
#if (b_iUVEmitterCount > 7 && SC2_UV_COUNT > 7)
    SC2_SD_UV(7);
#endif

    // Vector-UI shape parameters, else the splat attenuation plane.
    if (b_iShadingMode == VS_SHADINGMODE_VECTORUI)
    {
#if SC2_HAS_VectorUI0
        vertOut.m_VectorUI0 = vsGlobals.vVectorUIInterpolant0[0];
#endif
#if SC2_HAS_VectorUI1
        vertOut.m_VectorUI1 = vsGlobals.vVectorUIInterpolant1[0];
#endif
#if SC2_HAS_VectorUI2
        vertOut.m_VectorUI2 = vsGlobals.vVectorUIInterpolant2[0];
#endif
#if SC2_HAS_Vector4
        vertOut.m_Vector4 = vsGlobals.vSplatAttenuationPlane[0];
#endif
#if SC2_HAS_VectorUI0
        vertOut.m_VectorUI0.w = vsGlobals.fSplatAttenuationScalar_MinHeight[0].x;
#endif
    }
    else
    {
#if SC2_HAS_VectorUI0
        vertOut.m_VectorUI0 = vsGlobals.vSplatAttenuationPlane[0];
#endif
#if SC2_HAS_VectorUI1
        vertOut.m_VectorUI1.xyz = float4(vertIn.vPosition.xyz, 1.0f).xyz;
        vertOut.m_VectorUI1.w = vsGlobals.fSplatAttenuationScalar_MinHeight[0].x;
#endif
#if SC2_HAS_Tangent
        vertOut.m_Tangent.w = vsGlobals.fSplatAttenuationScalar_MinHeight[0].y;
#endif
    }

    // Parallax vector, from a basis built around the fixed splat tangent.
#if SC2_HAS_ParallaxVector
    float3 binormal = normalize(cross(vsGlobals.vTangent.xyz, vertIn.vNormal.xyz));
    float3 tangent = cross(vertIn.vNormal.xyz, binormal);
    vertOut.m_ParallaxVector = vsEmitParallaxVector(vertIn.vPosition.xyz,
                                                    vsGlobals.vEyePos,
                                                    vertIn.vNormal.xyz,
                                                    tangent, binormal);
#endif

    return vertOut;
}
