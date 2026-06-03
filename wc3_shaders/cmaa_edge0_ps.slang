// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// CMAA pass 1 of 4 — EDGE DETECTION (ffxcmaaedge0).
//
// This is Intel CMAA 1.x `DetectEdges` (the `edge1` program in Intel's
// reference). Single-permutation full-screen pass dispatched at HALF
// resolution: each invocation processes a 2x2 quad of the full-res scene.
// For every quad texel it measures the Rec.709 luma contrast to its RIGHT and
// DOWN neighbours, thresholds and quantises each to a 4-bit strength, and packs
// them as `right | (down << 4)` into a byte. The four bytes are emitted as a
// uint4 render target. In parallel it accumulates, per neighbourhood pixel, a
// "store flag" (the sum of edge strengths touching that pixel) and copies the
// colour of every edge-adjacent pixel into the working-colour UAV the final
// pass blends from. A depth/stencil marker is set to 1.0 for any quad with an
// edge so later passes can early-reject flat regions.
//
// Reference: Intel CMAA (Filip Strugar, 2014). Variable names mirror the
// reference (`pixelCR`, `EdgeDetectColorCalcDiff`, `et`, `eti`,
// `storeFlagPixel*`). Faithful reconstruction of ffxcmaaedge0.bls — verified
// against re_shaders/cmaa/ffxcmaaedge0/perm_000.asm, which is where the
// per-load neighbour offsets and store_uav scatters were recovered (the
// decompiled HLSL had dropped them).

implementing wc3_shaders;

// Rec.709 luma weights (Intel CMAA `c_lumWeights`).
static const float3 CMAA_LUMA = float3(0.212599993, 0.715200007, 0.0722000003);

// Edge threshold = 1/13 (Intel CMAA `#define EDGE_DETECT_THRESHOLD 13.0`).
static const float CMAA_EDGE_THRESHOLD = 0.0769230798;

// Luma-weighted colour difference (Intel CMAA `EdgeDetectColorCalcDiff`).
float cmaaColorDiff(float3 colorA, float3 colorB)
{
    return dot(abs(colorA - colorB), CMAA_LUMA);
}

// Per-texel edge strengths `et`: .x = edge to the RIGHT neighbour, .y = edge
// DOWN, each `saturate(diff - threshold)` (Intel CMAA `et = saturate(et - threshold)`).
float2 cmaaDetectEdges(float3 self, float3 rightNeighbour, float3 downNeighbour)
{
    float2 et = float2(cmaaColorDiff(self, rightNeighbour),
                       cmaaColorDiff(self, downNeighbour));
    return saturate(et - CMAA_EDGE_THRESHOLD);
}

// Quantise the two edge strengths to 4 bits and pack `right | (down << 4)`
// (Intel CMAA `eti = ivec2(et * 15.0 + 0.99); edges.x = eti.x | (eti.y << 4)`).
int cmaaPackStrength(float2 et)
{
    int2 eti = (int2)(et * 15.0 + 0.99000001);
    return eti.x | (eti.y << 4);
}

[shader("fragment")]
public CmaaEdge0PSOutput cmaa_edge0_ps_main(CmaaPSInput input)
{
    CmaaEdge0PSOutput output;

    int2 quadCoord = (int2)input.svPosition.xy;
    int2 base      = quadCoord * 2;          // full-res top-left of the 2x2 quad

    // 3x3 source-colour neighbourhood, named pixel<Column><Row> as in the
    // reference (the (2,2) corner is never needed). Full RGBA is kept: the edge
    // metric uses .xyz, but the working-buffer copy preserves source alpha.
    float4 pixel00 = t_cmaaColor.Load(int3(base + int2(0, 0), 0));
    float4 pixel10 = t_cmaaColor.Load(int3(base + int2(1, 0), 0));
    float4 pixel20 = t_cmaaColor.Load(int3(base + int2(2, 0), 0));
    float4 pixel01 = t_cmaaColor.Load(int3(base + int2(0, 1), 0));
    float4 pixel11 = t_cmaaColor.Load(int3(base + int2(1, 1), 0));
    float4 pixel21 = t_cmaaColor.Load(int3(base + int2(2, 1), 0));
    float4 pixel02 = t_cmaaColor.Load(int3(base + int2(0, 2), 0));
    float4 pixel12 = t_cmaaColor.Load(int3(base + int2(1, 2), 0));

    // Right/down edge strengths for each of the quad's four texels.
    float2 et00 = cmaaDetectEdges(pixel00.xyz, pixel10.xyz, pixel01.xyz);
    float2 et10 = cmaaDetectEdges(pixel10.xyz, pixel20.xyz, pixel11.xyz);
    float2 et01 = cmaaDetectEdges(pixel01.xyz, pixel11.xyz, pixel02.xyz);
    float2 et11 = cmaaDetectEdges(pixel11.xyz, pixel21.xyz, pixel12.xyz);

    int4 packedEdges = int4(cmaaPackStrength(et00), cmaaPackStrength(et10),
                            cmaaPackStrength(et01), cmaaPackStrength(et11));

    output.edges = (uint4)packedEdges;
    output.depth = any(packedEdges != 0) ? 1.0 : 0.0;

    if (any(packedEdges != 0))
    {
        // storeFlagPixel<CR> = sum of edge strengths touching that pixel; when
        // it is > 0 the pixel borders an edge, so its colour is copied to the
        // working-colour buffer for the final blend (Intel CMAA `storeFlagPixel*`).
        float storeFlagPixel00 = et00.x + et00.y;
        float storeFlagPixel10 = et00.x + et10.x + et10.y;
        float storeFlagPixel20 = et10.x;
        float storeFlagPixel01 = et00.y + et01.x + et01.y;
        float storeFlagPixel11 = et10.y + et01.x + et11.x + et11.y;
        float storeFlagPixel02 = et01.y;
        float storeFlagPixel21 = et11.x;
        float storeFlagPixel12 = et11.y;

        if (storeFlagPixel00 != 0.0) u_cmaaColor[uint2(base + int2(0, 0))] = pixel00;
        if (storeFlagPixel10 != 0.0) u_cmaaColor[uint2(base + int2(1, 0))] = pixel10;
        if (storeFlagPixel20 != 0.0) u_cmaaColor[uint2(base + int2(2, 0))] = pixel20;
        if (storeFlagPixel01 != 0.0) u_cmaaColor[uint2(base + int2(0, 1))] = pixel01;
        if (storeFlagPixel02 != 0.0) u_cmaaColor[uint2(base + int2(0, 2))] = pixel02;
        if (storeFlagPixel11 != 0.0) u_cmaaColor[uint2(base + int2(1, 1))] = pixel11;
        if (storeFlagPixel21 != 0.0) u_cmaaColor[uint2(base + int2(2, 1))] = pixel21;
        if (storeFlagPixel12 != 0.0) u_cmaaColor[uint2(base + int2(1, 2))] = pixel12;
    }

    return output;
}
