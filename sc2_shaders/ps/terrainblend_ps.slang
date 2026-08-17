// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// TerrainBlend pixel shader (terrainblend.fx : TerrainBlendPixelMain).
//
// Terrain/projector texture blending — an OWN-IO family (its VertexTransport carries
// vUV0/vUV1/vClip, not the shared DefaultPixelMain transport).  Dispatches on the
// compile-time b_iTerrainBlendMode (9 modes 0..8) into diffuse / normal / spec / height-
// weighted blend paths, optionally un-swizzling DXN normal maps.  Key schema
// (TerrainBlend_BuildSection @0x102b93de0): own axes b_iUnSwizzleDXNNormalMaps@104(w1),
// b_iTerrainDebugMode@105(w1), b_iTerrainBlendMode@106(w4), then the shared Common
// section.  Measured: b_iTerrainDebugMode is always 0 (the debug blit is unreachable).

implementing sc2_shaders;

#ifndef b_iTerrainBlendMode
#define b_iTerrainBlendMode 0
#endif
#ifndef b_iUnSwizzleDXNNormalMaps
#define b_iUnSwizzleDXNNormalMaps 0
#endif

// terrainblend.fx blend-mode enum.
#define BLEND_TERRAIN_DIFFUSE       0
#define BLEND_TERRAIN_NORMAL        1
#define BLEND_PROJECTOR_DIFFUSE     2
#define BLEND_PROJECTOR_NORMAL      3
#define BLEND_COPY_TERRAIN_SPEC     4
#define BLEND_PROJECTOR_SPEC        5
#define BLEND_COPY_FINAL_SPEC       6
#define BLEND_TERRAIN_DIFFUSEHEIGHT 7
#define BLEND_TERRAIN_NORMALHEIGHT  8

// USE_CLIP_PLANES is defined for PIXEL_SHADER_VERSION >= PS_40 (our ps_5_0 target).
public struct TerrainBlendPSInput
{
    float4 vUV0  : TEXCOORD0;
    float4 vUV1  : TEXCOORD1;
    float4 vClip : TEXCOORD2;
};

public struct TerrainBlendPSOutput
{
    float4 cColor : SV_Target0;
#if (b_iTerrainBlendMode == BLEND_TERRAIN_NORMALHEIGHT)
    float4 vHeight0 : SV_Target1;
    float4 vHeight1 : SV_Target2;
#endif
};

static float4 tbSample(Texture2D<float4> t, float2 uv)
{
    return t.Sample(p_sSamp, uv);
}

// terrainblend.fx : UnSwizzleNormals — reconstruct a normal from a DXN (BC5) pair.
static float3 tbUnSwizzleNormals(float4 result)
{
    float3 finalNormal;
    finalNormal.xy = 2.0f * result.wy - 1.0f;
    finalNormal.z = sqrt(max(0.0f, 1.0f - dot(finalNormal.xy, finalNormal.xy)));
    return finalNormal;
}

static float4 tbCopyTerrainSpec(TerrainBlendPSInput vertOut)
{
    float terrainSpec = tbSample(p_sTexture0_t, vertOut.vUV1.xy).w;
    return float4(terrainSpec, terrainSpec, terrainSpec, 1.0f);
}

static float4 tbBlendProjectorSpec(TerrainBlendPSInput vertOut)
{
    float projectorSpec = dot(tbSample(p_sTexture0_t, vertOut.vUV0.xy).xyz,
                              float3(0.3f, 0.59f, 0.11f));
    float4 masks = tbSample(p_sMask0_t, vertOut.vUV0.xy);
    return float4(projectorSpec, projectorSpec, projectorSpec, masks.w);
}

static float4 tbCopyFinalSpec(TerrainBlendPSInput vertOut)
{
    float s = tbSample(p_sTexture0_t, vertOut.vUV1.xy).x;
    return float4(0.0f, 0.0f, 0.0f, s);
}

static float4 tbBlendTerrainDiffuse(TerrainBlendPSInput vertOut)
{
    float4 masks = tbSample(p_sMask0_t, vertOut.vUV1.xy);
    float4 col0 = tbSample(p_sTexture0_t, vertOut.vUV0.xy);
    float4 col1 = tbSample(p_sTexture1_t, vertOut.vUV0.xy);
    float4 col2 = tbSample(p_sTexture2_t, vertOut.vUV0.xy);
    float4 col3 = tbSample(p_sTexture3_t, vertOut.vUV0.xy);
    return col0 * masks.w + col1 * masks.x + col2 * masks.y + col3 * masks.z;
}

static float4 tbBlendTerrainDiffuseHeight(TerrainBlendPSInput vertOut)
{
    float4 masks0 = tbSample(p_sMask0_t, vertOut.vUV1.xy);
    float4 masks1 = tbSample(p_sMask1_t, vertOut.vUV1.xy);
    float4 col0 = tbSample(p_sTexture0_t, vertOut.vUV0.xy);
    float4 col1 = tbSample(p_sTexture1_t, vertOut.vUV0.xy);
    float4 col2 = tbSample(p_sTexture2_t, vertOut.vUV0.xy);
    float4 col3 = tbSample(p_sTexture3_t, vertOut.vUV0.xy);
    float4 col4 = tbSample(p_sTexture4_t, vertOut.vUV0.xy);
    float4 col5 = tbSample(p_sTexture5_t, vertOut.vUV0.xy);
    float4 col6 = tbSample(p_sTexture6_t, vertOut.vUV0.xy);
    float4 col7 = tbSample(p_sTexture7_t, vertOut.vUV0.xy);
    return col0 * masks0.w + col1 * masks0.x + col2 * masks0.y + col3 * masks0.z
         + col4 * masks1.w + col5 * masks1.x + col6 * masks1.y + col7 * masks1.z;
}

static float4 tbBlendTerrainNormal(TerrainBlendPSInput vertOut)
{
    float4 col0 = tbSample(p_sTexture0_t, vertOut.vUV0.xy);
    float4 col1 = tbSample(p_sTexture1_t, vertOut.vUV0.xy);
    float4 col2 = tbSample(p_sTexture2_t, vertOut.vUV0.xy);
    float4 col3 = tbSample(p_sTexture3_t, vertOut.vUV0.xy);
    float4 masks = tbSample(p_sMask0_t, vertOut.vUV1.xy);
    float4 result = col0 * masks.w + col1 * masks.x + col2 * masks.y + col3 * masks.z;
#if b_iUnSwizzleDXNNormalMaps
    result.xyz = tbUnSwizzleNormals(result);
    result.xyz = result.xyz * 0.5f + 0.5f;
#endif
    return result;
}

static float4 tbBlendProjectorDiffuse(TerrainBlendPSInput vertOut)
{
    float4 masks = tbSample(p_sMask0_t, vertOut.vUV0.xy);
    float4 result = tbSample(p_sTexture0_t, vertOut.vUV0.xy);
    result.w = masks.w;   // output alpha from the projector mask
    return result;
}

static float4 tbBlendProjectorNormal(TerrainBlendPSInput vertOut)
{
    float4 masks = tbSample(p_sMask0_t, vertOut.vUV0.xy);
    float4 result = tbSample(p_sTexture0_t, vertOut.vUV0.xy);
#if b_iUnSwizzleDXNNormalMaps
    result.xyz = tbUnSwizzleNormals(result);
    result.xyz = result.xyz * 0.5f + 0.5f;
#endif
    // transform normal into the projector tangent basis
    result.xyz = result.xyz * 2.0f - 1.0f;
    float3 vBinormal = cross(float3(0.0f, 0.0f, 1.0f), psGlobals.vTangent);
    result.xyz = mul(result.xyz,
                     float3x3(psGlobals.vTangent, vBinormal, float3(0.0f, 0.0f, 1.0f)));
    result.xyz = result.xyz * 0.5f + 0.5f;
    result.w = masks.w;
    return result;
}

[shader("fragment")]
public TerrainBlendPSOutput terrainblend_ps_main(TerrainBlendPSInput vertOut)
{
    TerrainBlendPSOutput pixelOut;

    // Clip planes (terrainblend.fx:333-354): projector modes discard fragments outside
    // the clip volume.  CPP_SHADER is undefined for our compile, so the early return is live.
#if (b_iTerrainBlendMode == BLEND_PROJECTOR_DIFFUSE \
     || b_iTerrainBlendMode == BLEND_PROJECTOR_NORMAL \
     || b_iTerrainBlendMode == BLEND_PROJECTOR_SPEC)
    if (vertOut.vClip.x < 0.0f || vertOut.vClip.y < 0.0f
        || vertOut.vClip.z < 0.0f || vertOut.vClip.w < 0.0f)
    {
        pixelOut.cColor = float4(0.0f, 0.0f, 0.0f, 0.0f);
        return pixelOut;
    }
#endif

    // b_iTerrainDebugMode is always 0 (measured) — the mask-blit debug path is DCE'd.

#if (b_iTerrainBlendMode == BLEND_TERRAIN_DIFFUSE)
    pixelOut.cColor = tbBlendTerrainDiffuse(vertOut);
#elif (b_iTerrainBlendMode == BLEND_TERRAIN_NORMAL)
    pixelOut.cColor = tbBlendTerrainNormal(vertOut);
#elif (b_iTerrainBlendMode == BLEND_TERRAIN_DIFFUSEHEIGHT)
    pixelOut.cColor = tbBlendTerrainDiffuseHeight(vertOut);
#elif (b_iTerrainBlendMode == BLEND_TERRAIN_NORMALHEIGHT)
    // Height-weighted blend with per-layer weight normalisation; also writes the
    // COLOR1/COLOR2 height targets (terrainblend.fx:242-285).
    {
        float4 col0 = tbSample(p_sTexture0_t, vertOut.vUV0.xy);
        float4 col1 = tbSample(p_sTexture1_t, vertOut.vUV0.xy);
        float4 col2 = tbSample(p_sTexture2_t, vertOut.vUV0.xy);
        float4 col3 = tbSample(p_sTexture3_t, vertOut.vUV0.xy);
        float4 col4 = tbSample(p_sTexture4_t, vertOut.vUV0.xy);
        float4 col5 = tbSample(p_sTexture5_t, vertOut.vUV0.xy);
        float4 col6 = tbSample(p_sTexture6_t, vertOut.vUV0.xy);
        float4 col7 = tbSample(p_sTexture7_t, vertOut.vUV0.xy);
        float4 masks0 = tbSample(p_sMask0_t, vertOut.vUV1.xy);
        float4 masks1 = tbSample(p_sMask1_t, vertOut.vUV1.xy);

        float4 heights0 = float4(col1.r, col2.r, col3.r, col0.r);
        float4 heights1 = float4(col5.r, col6.r, col7.r, col4.r);
        masks0 *= heights0 * psGlobals.vHeightScale0 + psGlobals.vHeightOffset0;
        masks1 *= heights1 * psGlobals.vHeightScale1 + psGlobals.vHeightOffset1;

        float weightMax = max(max(max(masks0.x, masks0.y), max(masks0.z, masks0.w)),
                              max(max(masks1.x, masks1.y), max(masks1.z, masks1.w)));
        masks0 *= float4(1, 1, 1, 1) - saturate(weightMax.xxxx - masks0);
        masks1 *= float4(1, 1, 1, 1) - saturate(weightMax.xxxx - masks1);
        float rcpTotal = 1.0f / (dot(float4(1, 1, 1, 1), masks0)
                                 + dot(float4(1, 1, 1, 1), masks1));
        masks0 *= rcpTotal;
        masks1 *= rcpTotal;

        float4 result = col0 * masks0.w + col1 * masks0.x + col2 * masks0.y + col3 * masks0.z
                      + col4 * masks1.w + col5 * masks1.x + col6 * masks1.y + col7 * masks1.z;
        pixelOut.vHeight0 = masks0;
        pixelOut.vHeight1 = masks1;
    #if b_iUnSwizzleDXNNormalMaps
        result.xyz = tbUnSwizzleNormals(result);
        result.xyz = result.xyz * 0.5f + 0.5f;
    #endif
        pixelOut.cColor = result;
    }
#elif (b_iTerrainBlendMode == BLEND_PROJECTOR_DIFFUSE)
    pixelOut.cColor = tbBlendProjectorDiffuse(vertOut);
#elif (b_iTerrainBlendMode == BLEND_PROJECTOR_NORMAL)
    pixelOut.cColor = tbBlendProjectorNormal(vertOut);
#elif (b_iTerrainBlendMode == BLEND_COPY_TERRAIN_SPEC)
    pixelOut.cColor = tbCopyTerrainSpec(vertOut);
#elif (b_iTerrainBlendMode == BLEND_PROJECTOR_SPEC)
    pixelOut.cColor = tbBlendProjectorSpec(vertOut);
#elif (b_iTerrainBlendMode == BLEND_COPY_FINAL_SPEC)
    pixelOut.cColor = tbCopyFinalSpec(vertOut);
#else
    pixelOut.cColor = float4(0, 0, 0, 0);
#endif
    return pixelOut;
}
