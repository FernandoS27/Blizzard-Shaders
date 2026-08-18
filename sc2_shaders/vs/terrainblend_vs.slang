// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// TerrainBlend family vertex shader (terrainblend.fx : TerrainBlendVertexMain).
//
// The smallest own-ROOT vertex family: 9 retail permutations, one per
// `b_iTerrainBlendMode`.  It draws a single unit box scaled into place and emits two
// UV sets whose meaning flips with the mode — terrain tiling + mask tiling for the
// four TERRAIN modes, a projector-matrix projection + a back-buffer UV for the
// projector / copy modes.
//
// Own IO (its `VertexTransport` is declared in terrainblend.fx itself, not injected),
// so `inject_preamble` is false for both stages and the live-interpolant set is empty.
// `USE_CLIP_PLANES` is defined whenever PIXEL_SHADER_VERSION >= PS_40, which our
// ps_5_0/vs_5_0 target always is, so `vClip` is unconditional here.
//
// Key schema: the SAME one the pixel stage decodes (a family PermSchema covers both
// stages) — own axes b_iUnSwizzleDXNNormalMaps@104 / b_iTerrainDebugMode@105 /
// b_iTerrainBlendMode@106(w4), then the shared Common section.  Of those only
// b_iTerrainBlendMode reaches the vertex closure.

implementing sc2_shaders;

#include "vs/model_vs_defines.slangh"

public struct TerrainBlendVSInput
{
    float4 vPosition : POSITION;
};

// terrainblend.fx : VertexTransport.  The pixel stage takes the same three
// interpolants (ps/terrainblend_ps.slang : TerrainBlendPSInput) without vPos.
public struct TerrainBlendVSOutput
{
    float4 vPos  : SV_Position;
    float4 vUV0  : TEXCOORD0;
    float4 vUV1  : TEXCOORD1;
    float4 vClip : TEXCOORD2;
};

[shader("vertex")]
public TerrainBlendVSOutput terrainblend_vs_main(TerrainBlendVSInput vertIn)
{
    TerrainBlendVSOutput vertOut;

    float3 vPos = vertIn.vPosition.xyz * vsGlobals.vSize + vsGlobals.vCenter;

    vertOut.vPos = mul(float4(vPos, 1), vsGlobals.mWorldViewProj);
    vertOut.vUV0 = float4(0, 0, 0, 0);
    vertOut.vUV1 = float4(0, 0, 0, 0);

#if (b_iTerrainBlendMode == VS_BLEND_TERRAIN_DIFFUSE        \
  || b_iTerrainBlendMode == VS_BLEND_TERRAIN_NORMAL         \
  || b_iTerrainBlendMode == VS_BLEND_TERRAIN_DIFFUSEHEIGHT  \
  || b_iTerrainBlendMode == VS_BLEND_TERRAIN_NORMALHEIGHT)
    // Terrain-space tiling, with V flipped into texture space.
    vertOut.vUV0.xy = vPos.xy * vsGlobals.vTiling.xy + vsGlobals.vTiling.zw;
    vertOut.vUV0.y = 1 - vertOut.vUV0.y;
    vertOut.vUV1.xy = vPos.xy * vsGlobals.vMaskTiling.xy + vsGlobals.vMaskTiling.zw;
    vertOut.vUV1.y = 1 - vertOut.vUV1.y;
#else
    // Projector UV.
    float4 uv = mul(float4(vPos, 1), vsGlobals.mprojectorMatrix);
    uv.xy /= uv.w;
    vertOut.vUV0.xy = uv.xy * float2(0.5f, -0.5f) + 0.5f;

    // Back-buffer UV.  Only BLEND_COPY_TERRAIN_SPEC / BLEND_COPY_FINAL_SPEC use it,
    // and both always cover the whole viewport, so the raw (unscaled) input vertex
    // IS the normalised UV — hence vertIn, not vPos.
    vertOut.vUV1.xy = vertIn.vPosition.xy * vsGlobals.vMaskTiling.xy
                    + vsGlobals.vMaskTiling.zw;
#endif

    // Clip planes (USE_CLIP_PLANES — always on at PS_40+).
    vertOut.vClip = float4(0.0f, 0.0f, 0.0f, 0.0f);
#if (b_iTerrainBlendMode == VS_BLEND_PROJECTOR_DIFFUSE  \
  || b_iTerrainBlendMode == VS_BLEND_PROJECTOR_NORMAL   \
  || b_iTerrainBlendMode == VS_BLEND_PROJECTOR_SPEC)
    vertOut.vClip.x = dot(vertOut.vPos, vsGlobals.vClipPlanes[0]);
    vertOut.vClip.y = dot(vertOut.vPos, vsGlobals.vClipPlanes[1]);
    vertOut.vClip.z = dot(vertOut.vPos, vsGlobals.vClipPlanes[2]);
    vertOut.vClip.w = dot(vertOut.vPos, vsGlobals.vClipPlanes[3]);
#endif

    return vertOut;
}
