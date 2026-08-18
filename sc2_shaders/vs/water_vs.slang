// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Water family vertex shader (water.fx : WaterVertexMain).
//
// An own-ROOT vertex shader on the SHARED interpolant transport: it declares its own
// one-attribute `Input` but fills the engine-injected `VertexTransport` through
// InitShader/WRITE_INTERPOLANT_*, exactly like the Default roots — so its live set is
// mask-derived and `inject_preamble` stays true.
//
// The surface is a flat grid displaced by a sum of Gerstner waves (skipped entirely
// under `b_iCheapWater`, which is also what packs the Normal/Tangent varyings out).
// The wave loop's bound is the CONSTANT `p_fNumWaveVectors.x`, so the harness pins it
// to a legal index range (sc2_shaders_cfg.VS_CONST_DOMAINS) — an unconstrained draw
// would ask the interpreter for ~1e38 iterations.
//
// Key schema: the SAME one the pixel stage decodes — own axes b_iCheapWater@104 …
// b_useCubemapReflections@108, then Common@112 / Lighting@136 / MRT@168 / FOW@184.

implementing sc2_shaders;

#include "vs/model_vs_defines.slangh"

public struct WaterVSInput
{
    float4 vPosition : POSITION;
};

// ---------------------------------------------------------------------------
// water.fx : VERTEX SHADER EMITTERS
// ---------------------------------------------------------------------------
float4 vsEmitWaterHPos(WaterVSInput vertIn)
{
    return mul(vertIn.vPosition, vsGlobals.mWorldViewProj);
}

// p_mView is a 3x4, so it multiplies transposed.
float3 vsEmitWaterViewPos(WaterVSInput vertIn)
{
    return mul(vsGlobals.mView, vertIn.vPosition);
}

float4 vsEmitWaterWorldPos(WaterVSInput vertIn)
{
    return float4(vertIn.vPosition.xyz, 1.0f);
}

float4 vsEmitWaterFOWUV(WaterVSInput vertIn)
{
    return mul(vertIn.vPosition, vsGlobals.mFOWMatrix);
}

// ---------------------------------------------------------------------------
// water.fx : GerstnerWave / GerstnerWaveNormal.
//
// The `#if PIXEL_SHADER_VERSION >= SHADER_VERSION_PS_30` guard around both loops is
// always true for our target, and the loop bound is the D3D form (the OpenGL path's
// literal NUMWAVES is not ours).
// ---------------------------------------------------------------------------
float3 vsGerstnerWave(float3 x0)
{
    float2 x = float2(0, 0);
    float z = 0;
    float4 k;

    for (int i = 0; i < vsGlobals.fNumWaveVectors.x; i++)
    {
        k = vsGlobals.vWaveVectors[i];

        // frequency w^2 = g * |k|
        float omeg = sqrt(4.8f * length(k.xy));

        float s, c;
        sincos(omeg * vsGlobals.fTime - dot(k.xy, x0.xy), s, c);

        x += k.w * k.z * normalize(k.xy) * s;
        z += k.w * k.z * c;
    }
    return float3(x0.xy + x, x0.z + z);
}

float3 vsGerstnerWaveNormal(float3 x0)
{
    float2 adcx = float2(0, 0), adcy = float2(0, 0), ask = float2(0, 0);
    float4 k;

    for (int i = 0; i < vsGlobals.fNumWaveVectors.x; i++)
    {
        k = vsGlobals.vWaveVectors[i];

        float omeg = sqrt(4.8f * length(k.xy));

        float s, c;
        sincos(omeg * vsGlobals.fTime - dot(k.xy, x0.xy), s, c);

        // wave direction
        float2 d = normalize(k.xy);

        float a = k.z * k.w;
        float2 adc = a * d * c;
        adcx += adc * k.x;
        adcy += adc * k.y;
        ask += a * s * k.xy;
    }

    // tangents in x / y (dH/dx, dH/dy)
    float3 tx = float3(1 - adcx.x, -adcx.y, ask.x);
    float3 ty = float3(-adcy.x, 1 - adcy.y, ask.y);

    return normalize(cross(tx, ty));
}

// ---------------------------------------------------------------------------
// Main vertex shader body.
// ---------------------------------------------------------------------------
[shader("vertex")]
public DefaultVSOutput water_vs_main(WaterVSInput streamIn)
{
    DefaultVSOutput vertOut;
    WaterVSInput vertIn = streamIn;     // the original mutates its `in` parameter

    // World position.
    vertIn.vPosition.xyz *= vsGlobals.vWaterScale;
    vertIn.vPosition.xyz += vsGlobals.vWaterTranslation;

    // Add the wave displacement.
#if !b_iCheapWater
    vertIn.vPosition.xyz = vsGerstnerWave(vertIn.vPosition.xyz);
#endif

    // UVs from the world position: one scrolled set in .xy, a second in .zw.
    // (water.fx's p_vTiling is a float2; the shared uniform is the wider float4 that
    // terrainblend.fx declares under the same name — see types/model_vs_io.slang.)
    float4 vUv;
    vUv.xy = vertIn.vPosition.xy * vsGlobals.vTiling.xy;
    float4 scroll = vsGlobals.fTime * vsGlobals.vScrollVectors;
    vUv.y = 1.f - vUv.y;
    vUv.zw = vUv.xy + scroll.zw;
    vUv.xy = vUv.xy + scroll.xy;
    vUv.xy = mul(float4(vUv.xy, 0, 1), vsGlobals.mUvMatrix).xy;
    vUv.zw = mul(float4(vUv.zw, 0, 1), vsGlobals.mUvMatrix).xy;

    vertOut.HPos = vsEmitWaterHPos(vertIn);

#if SC2_HAS_HPosAsUV
    vertOut.m_HPosAsUV = mul(vertIn.vPosition, vsGlobals.mWorldViewProj);
#endif
#if SC2_HAS_WorldPos
    vertOut.m_WorldPos = vsEmitWaterWorldPos(vertIn);
#endif
#if SC2_HAS_HalfVec
    vertOut.m_HalfVec = vsComputeHalfVector(vertIn.vPosition.xyz);
#endif
#if SC2_HAS_Vector4
    vertOut.m_Vector4 = vUv.xyzw;
#endif
#if SC2_HAS_ViewPos
    vertOut.m_ViewPos = vsEmitWaterViewPos(vertIn);
#endif
#if SC2_HAS_FogColor
    vertOut.m_FogColor = vsEmitFogColor(vertIn.vPosition.xyz, float3(0, 0, 0));
#endif
#if SC2_HAS_FOWUV
    vertOut.m_FOWUV = vsEmitWaterFOWUV(vertIn);
#endif

    // Vertex lighting.  Water feeds a flat +Z normal and no lighting regions; the
    // scratch values thread between the emitters exactly as in the Model root.
#if (SC2_HAS_Diffuse || SC2_HAS_Specular || SC2_HAS_ShadowDiffuse || SC2_HAS_ShadowSpecular)
    float3 cVertexSpecularLighting = float3(0, 0, 0);
    float3 cVertexShadowSpecularLighting = float3(0, 0, 0);
    float3 cVertexShadowSpecularLighting2 = float3(0, 0, 0);
  #if SC2_HAS_Diffuse
    vertOut.m_Diffuse = vsEmitDiffuse(vertOut, vertIn.vPosition.xyz, float3(0, 0, 1),
                                      float4(0, 0, 0, 0), cVertexSpecularLighting,
                                      cVertexShadowSpecularLighting,
                                      cVertexShadowSpecularLighting2);
  #endif
  #if SC2_HAS_Specular
    vertOut.m_Specular = vsEmitSpecular(cVertexSpecularLighting);
  #endif
#endif

    // The shadow varyings sit under `if (b_useShadows)` in the original; the live
    // mask is the authority, and it agrees (no retail Water key makes them live with
    // b_useShadows off).  NOTE: water.fx calls EmitShadowDiffuse with THREE arguments
    // against a four-parameter declaration — the missing `vLightingRegions`.  That
    // only survives because the write macro is a no-op on every retail permutation,
    // which discards the argument text before fxc parses it; were ShadowDiffuse ever
    // live here the ORIGINAL would not compile.  Zero regions is the intent.
#if b_useShadows
  #if SC2_HAS_ShadowMapUV
    vertOut.m_ShadowMapUV = vsEmitShadowMapUV(vertIn.vPosition.xyz);
  #endif
  #if SC2_HAS_ShadowDiffuse
    vertOut.m_ShadowDiffuse = vsEmitShadowDiffuse(float3(0, 0, 1), float4(0, 0, 0, 0),
                                                  cVertexShadowSpecularLighting,
                                                  cVertexShadowSpecularLighting2);
  #endif
  #if SC2_HAS_ShadowSpecular
    vertOut.m_ShadowSpecular = vsEmitShadowSpecular(cVertexShadowSpecularLighting);
  #endif
#endif

    // Cheap water is flat, so it neither computes nor carries a wave normal.
#if !b_iCheapWater
  #if SC2_HAS_Normal
    vertOut.m_Normal = float4(vsGerstnerWaveNormal(vertIn.vPosition.xyz), 1);
  #endif
#endif
#if SC2_HAS_Tangent
    vertOut.m_Tangent = float4(vsComputeGridTangent(vertOut.Normal().xyz), 1);
#endif

    return vertOut;
}
