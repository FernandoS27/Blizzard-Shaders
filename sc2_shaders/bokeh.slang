// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Bokeh family (bokeh.fx + psbokeh*.fx) — VS + PS.
//
// The bokeh depth-of-field chain (Jimenez, SIGGRAPH 2014), seven passes selected
// by one axis.  `Bokeh_BuildSection` @0x102b46a50 registers a single own axis and
// links [Common]:
//
//     b_iBokehPass @104 w3   0 TILEDOWNSAMPLE0  4 CIRCULARFILTER
//                            1 TILEDOWNSAMPLE1  5 MEDIAN
//                            2 TILENEIGHBOR     6 UPSAMPLE
//                            3 PREPASS
//
// The Common axes it inherits are the encoding triple (b_iInEncoding drives the
// depth decode, b_iOutEncoding / b_iUse8BitHDR are inert here), which is what
// makes the retail set 7 passes x 3 encodings = 21 PS permutations.
//
// Passes PREPASS..MEDIAN write TWO render targets, so the fragment struct grows a
// second target on exactly that range — matching bokeh.fx's `SFragmentOut`.
//
// The shipped configuration is fixed: HALFRES=1 (so SAMPLE_COUNT is half the max
// CoC radius), BOKEH_USE_LEGACY_COC=0 (the "camera" CoC), tile/ring optimisation
// and Karis averaging on, the debug colourings and the viewmodel hacks off, and
// the hexagonal circle-offset table.  The dead arms are noted where they sit
// rather than transcribed.
//
// Own IO (`VertexTransport`), so `inject_preamble: false`.

implementing sc2_shaders;

#ifndef b_iBokehPass
#define b_iBokehPass 0
#endif

#define BOKEH_TILEDOWNSAMPLE0 0
#define BOKEH_TILEDOWNSAMPLE1 1
#define BOKEH_TILENEIGHBOR    2
#define BOKEH_PREPASS         3
#define BOKEH_CIRCULARFILTER  4
#define BOKEH_MEDIAN          5
#define BOKEH_UPSAMPLE        6

// ---- psbokehutil.fx tuning constants ---------------------------------------
#define BOKEH_USE_LEGACY_COC         0     // use viewspace positions, not camera settings
#define DOF_MAX_COC_RADIUS_LENGTH    16
#define BOKEH_HALFRES                1
#define BOKEH_SAMPLE_COUNT           (DOF_MAX_COC_RADIUS_LENGTH / 2)

#define DOF_DEPTH_SCALE_SURFACE_CLIP 1.f
#define DOF_DEPTH_SCALE_FOREGROUND   (1.f / DOF_DEPTH_SCALE_SURFACE_CLIP)
#define DOF_SPREAD_TOE_POWER         3.0

#define DOF_SURFACE_FILTER_KARIS_AVG 1
#define DOF_SMALL_FILTER_KARIS_AVG   1
#define DOF_SMALL_FILTER_DITHER      0

#define DOF_HALF_RES_SCALE           0.5
#define DOF_HALF_RES_BIAS            (1.5 * DOF_HALF_RES_SCALE)
#define DOF_NEAR_FIELD_SCALE         0.5
#define DOF_NEAR_FIELD_BIAS          (0.0 * DOF_NEAR_FIELD_SCALE)

#define DOF_TILE_OPTIMIZATION        1
#define DOF_TILE_COC_DELTA_SCALE     0.5
#define DOF_TILE_COC_DELTA_BIAS      (1.0 * DOF_TILE_COC_DELTA_SCALE)

#define DOF_RING_OPTIMIZATION        1
#define DOF_RING_GAMMA               0.5
#define DOF_RING_MANUAL_UNROLL       1
#define DOF_RING_COUNT               3
#define DOF_MAX_RING_COUNT           4

#define DOF_SINGLE_PIXEL_RADIUS      0.7071   // length(float2(0.5, 0.5))
#define DOF_MIN_COC                  -1.0
#define DOF_MAX_COC                  1.0
#define DOF_EPS                      1e-5

#define DOF_ALPHA_INVALID            0.0
#define DOF_ALPHA_ENCODE_BIAS        (1.0 / 255.0)
#define DOF_ALPHA_ENCODE_SCALE       (254.0 / 255.0)
#define DOF_ALPHA_DECODE_BIAS        (-DOF_ALPHA_ENCODE_BIAS / DOF_ALPHA_ENCODE_SCALE)
#define DOF_ALPHA_DECODE_SCALE       (1.0 / DOF_ALPHA_ENCODE_SCALE)

#define BOKEH_PI                     3.1415926
#define BOKEH_HALF_MAX               65504

// dofParams component names (psbokehutil.fx).
#define DOF_SCALE_X       0
#define DOF_SCALE_Y       1
#define DOF_MAX_COC_RADIUS 2
#define DOF_SHARPNESS_INV 3

// ---- IO --------------------------------------------------------------------
public struct BokehVSInput
{
    float4 vPosition : POSITION;
    float2 vUV       : TEXCOORD0;
};

// bokeh.fx : VertexTransport.
public struct BokehTransport
{
    float4 vPosition : SV_Position;
    float2 vUV       : TEXCOORD0;
};

public struct BokehPSInput
{
    float4 vPosition : SV_Position;
    float2 vUV       : TEXCOORD0;
};

// bokeh.fx : SFragmentOut — the second target exists only on PREPASS..MEDIAN.
public struct BokehFragmentOut
{
    float4 vColor0 : SV_Target0;
#if (b_iBokehPass >= BOKEH_PREPASS && b_iBokehPass <= BOKEH_MEDIAN)
    float4 vColor1 : SV_Target1;
#endif
};

// ---- psbokehutil.fx : small helpers ----------------------------------------
float bkMin3(float a, float b, float c) { return min(min(a, b), c); }
float bkMax3(float a, float b, float c) { return max(max(a, b), c); }
float bkMed3(float a, float b, float c) { return max(min(a, b), min(max(a, b), c)); }

float3 bkMin3(float3 a, float3 b, float3 c)
{
    return float3(bkMin3(a.x, b.x, c.x), bkMin3(a.y, b.y, c.y), bkMin3(a.z, b.z, c.z));
}
float3 bkMax3(float3 a, float3 b, float3 c)
{
    return float3(bkMax3(a.x, b.x, c.x), bkMax3(a.y, b.y, c.y), bkMax3(a.z, b.z, c.z));
}
float3 bkMed3(float3 a, float3 b, float3 c)
{
    return float3(bkMed3(a.x, b.x, c.x), bkMed3(a.y, b.y, c.y), bkMed3(a.z, b.z, c.z));
}

float bkMin4(float4 values) { return min(bkMin3(values.x, values.y, values.z), values.w); }
float bkMax4(float4 values) { return max(bkMax3(values.x, values.y, values.z), values.w); }

struct BokehTileParams
{
    float maxCoc;
    float foregroundCoc;
    float nearestViewDepth;
    float cocDelta;
};

struct BokehPrepassParams
{
    float coc;
    float backgroundWeight;
    float foregroundWeight;
};

float4 bkPackTileParams(BokehTileParams t)
{
    return float4(t.maxCoc, t.nearestViewDepth, t.cocDelta, t.foregroundCoc);
}

BokehTileParams bkUnpackTileParams(float4 packed)
{
    BokehTileParams t;
    t.maxCoc = packed.r;
    t.nearestViewDepth = packed.g;
    t.cocDelta = packed.b;
    t.foregroundCoc = packed.a;
    return t;
}

float4 bkPackPrepassParams(BokehPrepassParams p)
{
    return float4(p.coc, p.backgroundWeight, p.foregroundWeight, 1.0);
}

BokehPrepassParams bkUnpackPrepassParams(float4 packed)
{
    BokehPrepassParams p;
    p.coc = packed.r;
    p.backgroundWeight = packed.g;
    p.foregroundWeight = packed.b;
    return p;
}

float bkClampCoc(float coc) { return saturate(abs(coc)); }

// Always false in the shipped source — the viewmodel special-case is disabled.
bool bkIsViewModelClipDepth(float clipDepth) { return false; }

// psbokehutil.fx : the gather emulation.  `GatherRed` is only reachable through
// the commented-out non-legacy arm of tex2DGatherDepth, so every live gather goes
// through this four-tap SampleLevel emulation.  NOTE the LOD: the coordinate is
// `float4(uv, 0, 1.0f)` and sampleTex2Dlod takes `coord.w`, so these sample MIP 1.
float4 bkGatherChannelEmu(Texture2D<float4> tTexture, float2 vUV, float4 vRTSize, int index)
{
    float2 pos = vUV * vRTSize.xy;
    float2 topLeftOffset = floor(pos - 0.5);

    float topLeft     = tTexture.SampleLevel(p_sSamp, (topLeftOffset + float2(0.5, 0.5)) * vRTSize.zw, 1.0f)[index];
    float topRight    = tTexture.SampleLevel(p_sSamp, (topLeftOffset + float2(1.5, 0.5)) * vRTSize.zw, 1.0f)[index];
    float bottomLeft  = tTexture.SampleLevel(p_sSamp, (topLeftOffset + float2(0.5, 1.5)) * vRTSize.zw, 1.0f)[index];
    float bottomRight = tTexture.SampleLevel(p_sSamp, (topLeftOffset + float2(1.5, 1.5)) * vRTSize.zw, 1.0f)[index];

    return float4(bottomLeft, bottomRight, topRight, topLeft);
}

float4 bkGatherBlue(Texture2D<float4> t, float2 uv, float4 vRTSize)
{
    return bkGatherChannelEmu(t, uv, vRTSize, 2);
}

// tex2DGatherDepth: gather the ALPHA channel, then run each tap through the
// pscommon.fx depth decode (the b_iInEncoding-driven `decodeDepth`, which reads
// the .a of the vector it is handed — hence the .rrrr/.gggg/... splats).
float4 bkGatherDepth(Texture2D<float4> t, float2 uv, float4 vRTSize)
{
    float4 depthVal = bkGatherChannelEmu(t, uv, vRTSize, 3);
    depthVal.r = decodeDepth(depthVal.rrrr);
    depthVal.g = decodeDepth(depthVal.gggg);
    depthVal.b = decodeDepth(depthVal.bbbb);
    depthVal.a = decodeDepth(depthVal.aaaa);
    return depthVal;
}

// pscommon.fx : SampleNormalDepth().a — Bokeh only ever reads the depth channel,
// so the normal decode (and p_mInvViewTransform with it) is dead.
float bkSampleViewDepth(Texture2D<float4> t, float2 uv)
{
    return decodeDepth(t.Sample(p_sSamp, uv));
}

float bkCalculateUnclampedCoc(float fDepth, float4 vDoFEquation)
{
    // The BOKEH_USE_LEGACY_COC arm (viewspace positions against p_fFocusDepth) is
    // compiled out; the shipped path is the "camera" method.
    fDepth = 1.f / fDepth;

    float2 coc = vDoFEquation.xz * fDepth + vDoFEquation.yw;
    return bkIsViewModelClipDepth(fDepth) ? coc.y : coc.x;
}

float bkCalculateCoc(float viewDepth, float4 dofEquation)
{
    return bkClampCoc(bkCalculateUnclampedCoc(viewDepth, dofEquation));
}

float bkDepthCmp1(float depth, float tileNearestViewDepth)
{
    return saturate(1.0 - DOF_DEPTH_SCALE_FOREGROUND * (depth - tileNearestViewDepth));
}

float2 bkDepthCmp2(float depth, float tileNearestViewDepth)
{
    float d = DOF_DEPTH_SCALE_FOREGROUND * (depth - tileNearestViewDepth);

    float2 depthCmp;
    depthCmp.x = smoothstep(0.0, 1.0, d);
    depthCmp.y = 1.0 - depthCmp.x;
    return depthCmp;
}

// Like the above, but just the background factor for all four channels.
float4 bkBackgroundFactor4(float4 depth, float tileNearestViewDepth)
{
    return smoothstep(0.0, 1.0, DOF_DEPTH_SCALE_FOREGROUND *
        (depth - float4(tileNearestViewDepth, tileNearestViewDepth,
                        tileNearestViewDepth, tileNearestViewDepth)));
}

float bkSpreadToe(float offsetCoc, float spreadCmp)
{
    return offsetCoc <= 1.0 ? pow(spreadCmp, DOF_SPREAD_TOE_POWER) : spreadCmp;
}

float bkSpreadCmp(float offsetCoc, float sampleCoc, float spreadScale)
{
    return bkSpreadToe(offsetCoc, saturate(spreadScale * sampleCoc - (offsetCoc - 1.0)));
}

float bkSampleAlpha(float sampleCoc)
{
    return min(rcp(BOKEH_PI * sampleCoc * sampleCoc),
               rcp(BOKEH_PI * DOF_SINGLE_PIXEL_RADIUS * DOF_SINGLE_PIXEL_RADIUS));
}

void bkCalculateRingParams(int maxRingCount, int ringCount, float tileMaxCoc,
                           float noise, out int maxRing, out float ringScale)
{
    maxRing = (int)clamp(round(pow(tileMaxCoc, DOF_RING_GAMMA) * ringCount + noise), 1, ringCount);
    ringScale = float(maxRingCount) / float(maxRing);
}

float bkTileCocDeltaFactor(float cocDelta, float maxCocRadius)
{
    return saturate(maxCocRadius * DOF_TILE_COC_DELTA_SCALE * cocDelta - DOF_TILE_COC_DELTA_BIAS);
}

float bkHalfResFactor(float coc, float maxCocRadius)
{
    return saturate(maxCocRadius * DOF_HALF_RES_SCALE * coc - DOF_HALF_RES_BIAS);
}

float bkEncodeAlpha(float alpha)
{
    return saturate(DOF_ALPHA_ENCODE_BIAS + DOF_ALPHA_ENCODE_SCALE * alpha);
}

float bkDecodeAlpha(float alpha)
{
    return saturate(DOF_ALPHA_DECODE_BIAS + DOF_ALPHA_DECODE_SCALE * alpha);
}

float bkLuma(float3 color) { return dot(color, float3(0.2126, 0.7152, 0.0722)); }

float bkKarisWeight(float3 color, float sharpnessInv)
{
    return rcp(1.0 + sharpnessInv * bkLuma(color));
}

// ---- psbokehtile.fx : Bokeh_TileDownSample ---------------------------------
float4 bkTileDownSample(float2 vUV)
{
    float2 coord = vUV + psGlobals.vPixelTransform.xy;

    float maxCoc = DOF_MIN_COC;
    float minCoc = DOF_MAX_COC;
    float closestDepth = BOKEH_HALF_MAX;

    [unroll]
    for (int i = 0; i < BOKEH_SAMPLE_COUNT; i++)
    {
        float3 cocDepth;
#if (b_iBokehPass == BOKEH_TILEDOWNSAMPLE0)
        cocDepth.b = bkSampleViewDepth(p_sDepthImage_t,
                                       coord + psGlobals.vPixelTransform.zw * float(i));
        cocDepth.rg = bkCalculateUnclampedCoc(cocDepth.b, psGlobals.vDoFEquation);
#else
        cocDepth = p_sInputImage_t.Sample(p_sSamp,
                                          coord + psGlobals.vPixelTransform.zw * float(i)).rgb;
#endif

        maxCoc = max(maxCoc, cocDepth.r);
        minCoc = min(minCoc, cocDepth.g);
        closestDepth = min(closestDepth, cocDepth.b);
    }

    return float4(maxCoc, minCoc, closestDepth, 0.0);
}

// ---- psbokehtileneighbor.fx : Bokeh_TileNeighbor ---------------------------
float4 bkTileNeighbor(float2 vUV)
{
    float2 texelSize = psGlobals.vTileRTSize.zw;

    float maxCoc = DOF_MIN_COC;
    float minCoc = DOF_MAX_COC;
    float closestDepth = BOKEH_HALF_MAX;

    [unroll]
    for (float i = -2.0; i <= 2.0; i += 1.0)
    {
        [unroll]
        for (float j = -2.0; j <= 2.0; j += 1.0)
        {
            float3 cocDepth = p_sInputImage_t.Sample(p_sSamp, vUV + texelSize * float2(i, j)).rgb;

            // The CoC extremes come from the inner 3x3; the nearest depth from all 25.
            if (i > -2.0 && i < 2.0 && j > -2.0 && j < 2.0)
            {
                maxCoc = max(maxCoc, cocDepth.r);
                minCoc = min(minCoc, cocDepth.g);
            }

            closestDepth = min(closestDepth, cocDepth.b);
        }
    }

    BokehTileParams tileParams;
    tileParams.maxCoc = max(bkClampCoc(maxCoc), bkClampCoc(minCoc));
    tileParams.nearestViewDepth = closestDepth;
    tileParams.cocDelta = bkTileCocDeltaFactor(
        abs(clamp(maxCoc, DOF_MIN_COC, DOF_MAX_COC) - clamp(minCoc, DOF_MIN_COC, DOF_MAX_COC)),
        psGlobals.fMaxCoCRadius);
    tileParams.foregroundCoc = bkCalculateCoc(closestDepth, psGlobals.vDoFEquation);

    return bkPackTileParams(tileParams);
}

// ---- psbokehsurfacefilter.fx : SurfaceFilter --------------------------------
#define DOF_SURFACE_FILTER_SAMPLE_COUNT 8

static const float2 c_vSurfaceFilterOffsets[8] =
{
    float2( 0.9239, -0.3827),
    float2(-0.9239,  0.3827),
    float2(-0.9239, -0.3827),
    float2( 0.9239,  0.3827),
    float2(-0.3827, -0.9239),
    float2( 0.3827,  0.9239),
    float2( 0.3827, -0.9239),
    float2(-0.3827,  0.9239),
};

float3 bkSurfaceFilter(Texture2D<float4> tColor, Texture2D<float4> tFloatZ,
                       float2 texCoords, float2 texCoordsReference,
                       float centerCoc, float centerDepth, float cocDelta,
                       float tileNearestViewDepth, float2 cocGapSpaceXform,
                       float4 dofEquation, float karisSharpnessInv, float4 vRTSize)
{
    float4 centerColor = float4(tColor.SampleLevel(p_sSamp, texCoordsReference, 1.0).rgb, 1.0);

    // DOF_SURFACE_FILTER_KARIS_AVG is 1, so this runtime `if` is always taken.
    centerColor *= bkKarisWeight(centerColor.rgb, karisSharpnessInv);

    float4 color = centerColor;

    float2 scale = max(centerCoc * cocGapSpaceXform.xy, vRTSize.zw);

    [branch]
    if (cocDelta > 0.0)
    {
        // NOTE the truncation upstream: DepthCmp2 returns a float2 and this is a
        // float, so only .x (the background factor) survives.
        float centerBackgroundFactor = bkDepthCmp2(centerDepth, tileNearestViewDepth).x;

        [unroll]
        for (int i = 0; i < DOF_SURFACE_FILTER_SAMPLE_COUNT; i++)
        {
            float2 sampleTexCoords = texCoords + scale * c_vSurfaceFilterOffsets[i];
            float4 sampleColor = float4(tColor.SampleLevel(p_sSamp, sampleTexCoords, 1.0).rgb, 1.0);

            float4 sampleDepth = bkGatherDepth(tFloatZ, sampleTexCoords, vRTSize);

            float4 sampleBackgroundFactor4 = bkBackgroundFactor4(sampleDepth, tileNearestViewDepth);

            float backgroundToBackground = bkMin4(sampleBackgroundFactor4) * centerBackgroundFactor;
            float foregroundToForeground = (1.0 - bkMax4(sampleBackgroundFactor4))
                                         * (1.0 - centerBackgroundFactor);

            // DOF_SURFACE_FILTER_VIEWMODEL_HACK is 0 (it would also read an
            // undeclared `sampleClipDepth` — the arm has bit-rotted upstream).

            float weight = saturate(backgroundToBackground + foregroundToForeground);

            sampleColor *= lerp(1.0, weight, cocDelta);
            sampleColor *= bkKarisWeight(sampleColor.rgb, karisSharpnessInv);

            color += sampleColor;
        }
    }
    else
    {
        [unroll]
        for (int i = 0; i < DOF_SURFACE_FILTER_SAMPLE_COUNT; i++)
        {
            float2 sampleTexCoords = texCoords + scale * c_vSurfaceFilterOffsets[i];
            float4 sampleColor = float4(tColor.SampleLevel(p_sSamp, sampleTexCoords, 1.0).rgb, 1.0);

            sampleColor *= bkKarisWeight(sampleColor.rgb, karisSharpnessInv);

            color += sampleColor;
        }
    }

    color.rgb /= color.w;

    return color.rgb;
}

// ---- psbokehprepass.fx : Bokeh_Prepass --------------------------------------
float4 bkCalculatePrepass(float maxDepth, float centerDepth, float unclampedCoc, float coc)
{
    float nearFieldFactor = 1.0 + smoothstep(0.0, 1.0,
        saturate(-DOF_NEAR_FIELD_SCALE * psGlobals.fMaxCoCRadius * unclampedCoc - DOF_NEAR_FIELD_BIAS));
    float alpha = bkSampleAlpha(psGlobals.fMaxCoCRadius * coc);
    float viewDepth = centerDepth;
    float2 depthCmp = bkDepthCmp2(viewDepth, maxDepth);

    float2 weight = nearFieldFactor * depthCmp;

    BokehPrepassParams prepassParams;
    prepassParams.coc = coc;
    prepassParams.backgroundWeight = weight.x;
    prepassParams.foregroundWeight = alpha * weight.y;

    return bkPackPrepassParams(prepassParams);
}

void bkSelectLargestDepth(float2 texCoords, out float centerDepth, out float2 offset)
{
    float4 centerDepth4 = bkGatherDepth(p_sDepthImage_t, texCoords, psGlobals.vRenderTargetSize);

    centerDepth = bkMax4(centerDepth4);

    offset = float2(-0.25, 0.25);
    if (centerDepth == centerDepth4.y)
        offset = float2(0.25, 0.25);
    if (centerDepth == centerDepth4.z)
        offset = float2(0.25, -0.25);
    if (centerDepth == centerDepth4.w)
        offset = float2(-0.25, -0.25);
}

float4 bkPrepass(float2 vUV, out float4 vOutColor)
{
    BokehTileParams tileParams = bkUnpackTileParams(p_sTileImage_t.Sample(p_sSamp, vUV));

    float centerDepth;
    float2 offset;
    bkSelectLargestDepth(vUV, centerDepth, offset);
    float2 texCoords = vUV + offset * psGlobals.vRenderTargetSize.zw;

    float unclampedCenterCoc = bkCalculateUnclampedCoc(centerDepth, psGlobals.vDoFEquation);
    float centerCoc = bkClampCoc(unclampedCenterCoc);

    vOutColor = float4(bkSurfaceFilter(p_sInputImage_t, p_sDepthImage_t, vUV, texCoords,
                                       centerCoc, centerDepth, tileParams.cocDelta,
                                       tileParams.nearestViewDepth,
                                       psGlobals.vCoCGapSpaceTransform, psGlobals.vDoFEquation,
                                       psGlobals.fKarisInvSharpness,
                                       psGlobals.vRenderTargetSize), 1.0);

    return bkCalculatePrepass(tileParams.nearestViewDepth, centerDepth,
                              unclampedCenterCoc, centerCoc);
}

// ---- psbokehcircularfilteroffsets.fx : the hexagonal ring table --------------
static const float3 c_vCircleOffsets[72] =
{
    float3( 0.125000, -0.216506, 1.f),
    float3(-0.125000, -0.216506, 1.f),
    float3(-0.250000,  0.000000, 1.f),
    float3(-0.125000,  0.216506, 1.f),
    float3( 0.125000,  0.216506, 1.f),
    float3( 0.250000,  0.000000, 1.f),

    float3( 0.250000, -0.433013, 2.f),
    float3( 0.000000, -0.433013, 2.f),
    float3(-0.250000, -0.433013, 2.f),
    float3(-0.375000, -0.216506, 2.f),
    float3(-0.500000,  0.000000, 2.f),
    float3(-0.375000,  0.216506, 2.f),
    float3(-0.250000,  0.433013, 2.f),
    float3( 0.000000,  0.433013, 2.f),
    float3( 0.250000,  0.433013, 2.f),
    float3( 0.375000,  0.216506, 2.f),
    float3( 0.500000,  0.000000, 2.f),
    float3( 0.375000, -0.216506, 2.f),

    float3( 0.375000, -0.649519, 3.f),
    float3( 0.187500, -0.649519, 3.f),
    float3( 0.000000, -0.649519, 3.f),
    float3(-0.187500, -0.649519, 3.f),
    float3(-0.375000, -0.649519, 3.f),
    float3(-0.468750, -0.487139, 3.f),
    float3(-0.562500, -0.324760, 3.f),
    float3(-0.656250, -0.162380, 3.f),
    float3(-0.750000,  0.000000, 3.f),
    float3(-0.656250,  0.162380, 3.f),
    float3(-0.562500,  0.324760, 3.f),
    float3(-0.468750,  0.487139, 3.f),
    float3(-0.375000,  0.649519, 3.f),
    float3(-0.187500,  0.649519, 3.f),
    float3( 0.000000,  0.649519, 3.f),
    float3( 0.187500,  0.649519, 3.f),
    float3( 0.375000,  0.649519, 3.f),
    float3( 0.468750,  0.487139, 3.f),
    float3( 0.562500,  0.324760, 3.f),
    float3( 0.656250,  0.162380, 3.f),
    float3( 0.750000,  0.000000, 3.f),
    float3( 0.656250, -0.162380, 3.f),
    float3( 0.562500, -0.324760, 3.f),
    float3( 0.468750, -0.487139, 3.f),

    float3( 0.500000, -0.866025, 4.f),
    float3( 0.300000, -0.866025, 4.f),
    float3( 0.100000, -0.866025, 4.f),
    float3(-0.100000, -0.866025, 4.f),
    float3(-0.300000, -0.866025, 4.f),
    float3(-0.500000, -0.866025, 4.f),
    float3(-0.600000, -0.692820, 4.f),
    float3(-0.700000, -0.519615, 4.f),
    float3(-0.800000, -0.346410, 4.f),
    float3(-0.900000, -0.173205, 4.f),
    float3(-1.000000,  0.000000, 4.f),
    float3(-0.900000,  0.173205, 4.f),
    float3(-0.800000,  0.346410, 4.f),
    float3(-0.700000,  0.519615, 4.f),
    float3(-0.600000,  0.692820, 4.f),
    float3(-0.500000,  0.866025, 4.f),
    float3(-0.300000,  0.866025, 4.f),
    float3(-0.100000,  0.866025, 4.f),
    float3( 0.100000,  0.866025, 4.f),
    float3( 0.300000,  0.866025, 4.f),
    float3( 0.500000,  0.866025, 4.f),
    float3( 0.600000,  0.692820, 4.f),
    float3( 0.700000,  0.519615, 4.f),
    float3( 0.800000,  0.346410, 4.f),
    float3( 0.900000,  0.173205, 4.f),
    float3( 1.000000,  0.000000, 4.f),
    float3( 0.900000, -0.173205, 4.f),
    float3( 0.800000, -0.346410, 4.f),
    float3( 0.700000, -0.519615, 4.f),
    float3( 0.600000, -0.692820, 4.f),
};

static const int   ringSampleCount[5] = { 0, 6, 18, 42, 72 };
static const float ringNormFactor[5]  = { 1.0, 0.142857f, 0.052631f, 0.023255f, 0.013888f };

// ---- psbokehcircularfilter.fx ----------------------------------------------
float bkNoiseSpatialInterleavedGradient1D(float2 position, float scale)
{
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return -scale + 2.0 * scale * frac(magic.z * frac(dot(position, magic.xy)));
}

void bkDofInternalTile(int j, float2 texCoords, float2 scale, float noise, float spreadScale,
                       inout float4 background, inout float4 foreground, inout float3 accumulation)
{
    [unroll]
    for (int i = ringSampleCount[j]; i < ringSampleCount[j + 1]; i++)
    {
        float offsetCoc = c_vCircleOffsets[i].z;

        float2 sampleNoise = noise * psGlobals.vRenderTargetSize.zw
                           * (1.0 - offsetCoc * (1.0 / DOF_RING_COUNT));
        float2 sampleTexCoords = texCoords + scale * c_vCircleOffsets[i].xy + sampleNoise;

        float3 sampleColor = p_sInputImage_t.SampleLevel(p_sSamp, sampleTexCoords, 1.0).rgb;
        BokehPrepassParams samplePrepassParams = bkUnpackPrepassParams(
            p_sPrepassImage_t.SampleLevel(p_sSamp, sampleTexCoords, 1.0));

        float spreadCmp = bkSpreadCmp(offsetCoc, samplePrepassParams.coc, spreadScale);
        samplePrepassParams.backgroundWeight *= spreadCmp;
        samplePrepassParams.foregroundWeight *= spreadCmp;

        background += samplePrepassParams.backgroundWeight * float4(sampleColor.rgb, 1.0);
        foreground += samplePrepassParams.foregroundWeight * float4(sampleColor.rgb, 1.0);

        accumulation += sampleColor.rgb;
    }
}

void bkDofInternalFast(int j, float2 texCoords, float2 scale, float noise, inout float3 color)
{
    [unroll]
    for (int i = ringSampleCount[j]; i < ringSampleCount[j + 1]; i++)
    {
        float offsetCoc = c_vCircleOffsets[i].z;
        float2 sampleNoise = noise * psGlobals.vRenderTargetSize.zw
                           * (1.0 - offsetCoc * (1.0 / DOF_RING_COUNT));
        float2 sampleTexCoords = texCoords + scale * c_vCircleOffsets[i].xy + sampleNoise;
        color += p_sInputImageLinear_t.SampleLevel(p_sSamp, sampleTexCoords, 1.0).rgb;
    }
}

float4 bkCircularFilter(float2 vUV, out float4 vOutAlpha)
{
    float4 vOutColor;

    BokehTileParams tileParams = bkUnpackTileParams(p_sTileImage_t.Sample(p_sSamp, vUV));

    float3 centerColor = p_sInputImage_t.Sample(p_sSamp, vUV).rgb;

    [branch]
    if (bkHalfResFactor(tileParams.maxCoc, psGlobals.fMaxCoCRadius) == 0.0)
    {
        vOutAlpha = DOF_ALPHA_INVALID;
        vOutColor = float4(centerColor, 1.0);
        return vOutColor;       // DOF_TILE_DEBUG_COLOR is a no-op (DOF_TILE_DEBUG = 0)
    }

    BokehPrepassParams centerPrepassParams = bkUnpackPrepassParams(
        p_sPrepassImage_t.SampleLevel(p_sSamp, vUV, 1.0));

    float noise = bkNoiseSpatialInterleavedGradient1D(vUV * psGlobals.vRenderTargetSize.xy, 0.25);

    int maxRing;
    float ringScale;
    bkCalculateRingParams(DOF_MAX_RING_COUNT, DOF_RING_COUNT, tileParams.maxCoc, noise,
                          maxRing, ringScale);

    float2 texCoords = vUV;

    float2 scale = (ringScale * tileParams.maxCoc) * psGlobals.vCoCTransform.xy;

    [branch]
    if (tileParams.cocDelta > 0.0)
    {
        float spreadScale = maxRing / tileParams.maxCoc;

        float3 accumulation = centerColor;

        float4 background = centerPrepassParams.backgroundWeight * float4(centerColor, 1.0);
        float4 foreground = centerPrepassParams.foregroundWeight * float4(centerColor, 1.0);

        // DOF_RING_MANUAL_UNROLL: the ring loop is spelled out so the console
        // compilers unroll it; each ring is skipped past maxRing.
        [unroll]
        for (int j = 0; j < DOF_RING_COUNT; j++)
        {
            [branch]
            if (j < maxRing)
                bkDofInternalTile(j, texCoords, scale, noise, spreadScale,
                                  background, foreground, accumulation);
        }

        background.rgb *= rcp(max(background.w, DOF_EPS));
        foreground.rgb *= rcp(max(foreground.w, DOF_EPS));

        float alphaNorm = 1.0 / bkSampleAlpha(psGlobals.fMaxCoCRadius * tileParams.maxCoc);
        float alpha = saturate(foreground.w * alphaNorm * ringNormFactor[maxRing]);

        alpha = lerp(sqrt(alpha), alpha,
                     bkHalfResFactor(centerPrepassParams.coc, psGlobals.fMaxCoCRadius));

        float3 color = lerp(background.rgb, foreground.rgb, alpha);

        color = lerp(ringNormFactor[maxRing] * accumulation, color, tileParams.cocDelta);

        vOutAlpha = bkEncodeAlpha(alpha);
        vOutColor = float4(color, 1.0);
    }
    else
    {
        float3 color = centerColor;

        bkDofInternalFast(0, texCoords, scale, noise, color);
        [branch]
        if (maxRing > 1)
            bkDofInternalFast(1, texCoords, scale, noise, color);
        [branch]
        if (maxRing > 2)
            bkDofInternalFast(2, texCoords, scale, noise, color);

        color *= ringNormFactor[maxRing];

        vOutAlpha = DOF_ALPHA_INVALID;
        vOutColor = float4(color, 1.0);
    }

    return vOutColor;
}

// ---- psbokehmedian.fx : Bokeh_Median ----------------------------------------
static const float2 bkSquareOffsets[9] =
{
    float2(-1.0, -1.0), float2( 0.0, -1.0), float2( 1.0, -1.0),
    float2(-1.0,  0.0), float2( 0.0,  0.0), float2( 1.0,  0.0),
    float2(-1.0,  1.0), float2( 0.0,  1.0), float2( 1.0,  1.0),
};

static const float2 bkCircleOffsets9[9] =
{
    float2( 0.7071, -0.7071),
    float2(-0.7071,  0.7071),
    float2(-1.0000,  0.0000),
    float2( 1.0000,  0.0000),
    float2( 0.0000,  0.0000),
    float2(-0.7071, -0.7071),
    float2( 0.7071,  0.7071),
    float2(-0.0000, -1.0000),
    float2( 0.0000,  1.0000),
};

void bkSort3(inout float p1, inout float p2, inout float p3)
{
    float minValue = bkMin3(p1, p2, p3);
    float medValue = bkMed3(p1, p2, p3);
    float maxValue = bkMax3(p1, p2, p3);

    p1 = minValue;
    p2 = medValue;
    p3 = maxValue;
}

void bkSort3(inout float3 p1, inout float3 p2, inout float3 p3)
{
    float3 minValue = bkMin3(p1, p2, p3);
    float3 medValue = bkMed3(p1, p2, p3);
    float3 maxValue = bkMax3(p1, p2, p3);

    p1 = minValue;
    p2 = medValue;
    p3 = maxValue;
}

// See [Smith1996], Implementing median filters in XC4000E FPGAs.  `p` is an out
// parameter: Bokeh_Median re-reads the PARTIALLY SORTED array afterwards.
float bkMedian1(Texture2D<float4> tColor, float2 texCoords, out float p_center, out float p[9])
{
    float2 texelSize = psGlobals.vRenderTargetSize.zw;

    p[0] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[0], 1.0).a;
    p[1] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[1], 1.0).a;
    p[2] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[2], 1.0).a;
    bkSort3(p[0], p[1], p[2]);

    p[3] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[3], 1.0).a;
    p[4] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[4], 1.0).a;
    p[5] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[5], 1.0).a;
    p_center = p[4];
    bkSort3(p[3], p[4], p[5]);

    p[6] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[6], 1.0).a;
    p[7] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[7], 1.0).a;
    p[8] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkSquareOffsets[8], 1.0).a;
    bkSort3(p[6], p[7], p[8]);

    p[6] = bkMax3(p[0], p[3], p[6]);
    p[2] = bkMin3(p[2], p[5], p[8]);

    bkSort3(p[1], p[4], p[7]);
    bkSort3(p[2], p[4], p[6]);

    return p[4];
}

float3 bkMedian3(Texture2D<float4> tColor, float2 texCoords)
{
    float3 p[9];
    float2 texelSize = psGlobals.vRenderTargetSize.zw;

    p[0] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[0], 1.0).rgb;
    p[1] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[1], 1.0).rgb;
    p[2] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[2], 1.0).rgb;
    bkSort3(p[0], p[1], p[2]);

    p[3] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[3], 1.0).rgb;
    p[4] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[4], 1.0).rgb;
    p[5] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[5], 1.0).rgb;
    bkSort3(p[3], p[4], p[5]);

    p[6] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[6], 1.0).rgb;
    p[7] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[7], 1.0).rgb;
    p[8] = tColor.SampleLevel(p_sSamp, texCoords + texelSize * bkCircleOffsets9[8], 1.0).rgb;
    bkSort3(p[6], p[7], p[8]);

    p[6] = bkMax3(p[0], p[3], p[6]);
    p[2] = bkMin3(p[2], p[5], p[8]);

    bkSort3(p[1], p[4], p[7]);
    bkSort3(p[2], p[4], p[6]);

    return p[4];
}

float4 bkMedian(float2 vUV, out float4 vOutAlpha)
{
    float alpha[9];
    float centerAlpha;
    // Upstream this is `float4 vAlpha = Median1(...)` — a scalar broadcast into a
    // float4 that is only ever consumed as a scalar again.
    float vAlpha = bkMedian1(p_sAlphaImage_t, vUV, centerAlpha, alpha);

    float minValue = min(bkMin3(alpha[0], alpha[1], alpha[2]), alpha[3]);
    float maxValue = max(bkMax3(alpha[5], alpha[6], alpha[7]), alpha[8]);

    if (minValue == DOF_ALPHA_INVALID)
        vAlpha = centerAlpha == DOF_ALPHA_INVALID ? maxValue : centerAlpha;

    vOutAlpha = bkDecodeAlpha(vAlpha);
    return float4(bkMedian3(p_sInputImage_t, vUV), 1.0);
}

// ---- psbokehsmallfilter.fx : SmallFilter ------------------------------------
#define DOF_SMALL_FILTER_SAMPLE_COUNT 16
#define DITHER_SAMPLE_COUNT_DIVIDER   1
#define DOF_SMALL_FILTER_RADIUS       3
#define DOF_SMALL_FILTER_MAX_RADIUS   ((1.0 + DOF_HALF_RES_BIAS) / DOF_HALF_RES_SCALE)

static const float3 c_vSmallFilterOffsets[16] =
{
    // First half:
    float3( 0.3535, -0.3535, 1.5),
    float3(-0.3535, -0.3535, 1.5),
    float3( 0.2588, -0.9659, 3.0),
    float3(-0.2588, -0.9659, 3.0),
    float3( 0.7071, -0.7071, 3.0),
    float3(-0.7071, -0.7071, 3.0),
    float3( 0.9659, -0.2588, 3.0),
    float3(-0.9659, -0.2588, 3.0),

    // Second half:
    float3(-0.3535,  0.3535, 1.5),
    float3( 0.3535,  0.3535, 1.5),
    float3(-0.2588,  0.9659, 3.0),
    float3( 0.2588,  0.9659, 3.0),
    float3(-0.7071,  0.7071, 3.0),
    float3( 0.7071,  0.7071, 3.0),
    float3(-0.9659,  0.2588, 3.0),
    float3( 0.9659,  0.2588, 3.0),
};

float3 bkSmallFilter(Texture2D<float4> tColor, Texture2D<float4> tDepth, float2 texCoords,
                     float3 centerColor, float centerDepth, float centerCoc,
                     float maxCoCRadius, float2 cocXform, BokehTileParams tileParams,
                     float karisInvSharpness)
{
    // DOF_SMALL_FILTER_DITHER is 0, so the spatio-temporal dither is compiled out.
    float noise = 1.0;

    float2 scale = (noise * min(centerCoc, DOF_SMALL_FILTER_MAX_RADIUS * rcp(maxCoCRadius)))
                 * cocXform.xy;

    float spreadScale = DOF_SMALL_FILTER_RADIUS / centerCoc;

    float4 color = float4(centerColor, 1.0);

    // NOTE: the centre tap uses the RAW Karis form (no sharpnessInv), unlike the
    // sample taps below — transcribed as written.
    color *= 1.0 / (1.0 + bkLuma(color.rgb));

    [branch]
    if (tileParams.cocDelta > 0.0)
    {
        [unroll]
        for (int i = 0; i < DOF_SMALL_FILTER_SAMPLE_COUNT / DITHER_SAMPLE_COUNT_DIVIDER; i++)
        {
            float offsetCoc = c_vSmallFilterOffsets[i].z;

            float2 sampleTexCoords = texCoords + scale * c_vSmallFilterOffsets[i].xy;
            float4 sampleColor = float4(tColor.SampleLevel(p_sSamp, sampleTexCoords, 1.0).rgb, 1.0);
            float4 sampleDepth = bkGatherDepth(tDepth, sampleTexCoords,
                                               psGlobals.vRenderTargetSize);

            float weight = saturate(1.0 - bkMax4(abs(sampleDepth - centerDepth)
                                                 / DOF_DEPTH_SCALE_SURFACE_CLIP));

            sampleColor *= lerp(1.0, weight, tileParams.cocDelta);
            sampleColor *= bkKarisWeight(sampleColor.rgb, karisInvSharpness);

            color += sampleColor;
        }
    }
    else
    {
        [unroll]
        for (int i = 0; i < DOF_SMALL_FILTER_SAMPLE_COUNT / DITHER_SAMPLE_COUNT_DIVIDER; i++)
        {
            float2 sampleTexCoords = texCoords + scale * c_vSmallFilterOffsets[i].xy;
            float4 sampleColor = float4(tColor.SampleLevel(p_sSamp, sampleTexCoords, 1.0).rgb, 1.0);

            sampleColor *= bkKarisWeight(sampleColor.rgb, karisInvSharpness);

            color += sampleColor;
        }
    }

    color.rgb /= max(color.w, DOF_EPS);

    return color.rgb;
}

// ---- psbokehupscale.fx : Bokeh_Upsample -------------------------------------
float4 bkUpsample(float2 vUV)
{
    float4 vOutColor;
    BokehTileParams tileParams = bkUnpackTileParams(p_sTileImage_t.Sample(p_sSamp, vUV));

    float centerDepth = bkSampleViewDepth(p_sDepthImage_t, vUV);
    float centerCoc = bkCalculateCoc(centerDepth, psGlobals.vDoFEquation);

    float backgroundFactor = bkHalfResFactor(centerCoc, psGlobals.fMaxCoCRadius);

    float3 colorHalfRes = p_sInputImageLinear_t.Sample(p_sSamp, vUV).rgb;

    float cocDelta = bkMax4(bkGatherBlue(p_sTileImage_t, vUV, psGlobals.vTileRTSize));

    [branch]
    if (cocDelta > 0.0 || backgroundFactor < 1.0)
    {
        // DOF_UPSCALE_VIEWMODEL_HACK is 0.
        float foregroundCoc = tileParams.foregroundCoc;

        float foregroundFactor = bkHalfResFactor(foregroundCoc, psGlobals.fMaxCoCRadius);

        float alpha = p_sAlphaImage_t.Sample(p_sSamp, vUV).a;

        float halfResFactor = lerp(backgroundFactor, foregroundFactor, alpha);

        float3 colorFullRes = p_sInputImage_t.SampleLevel(p_sSamp, vUV, 1.0).rgb;
        [branch]
        if (halfResFactor < 1.0)
            colorFullRes = bkSmallFilter(p_sFullImageLinear_t, p_sDepthImage_t, vUV,
                                         colorFullRes, centerDepth, centerCoc,
                                         psGlobals.fMaxCoCRadius, psGlobals.vCoCTransform,
                                         tileParams, psGlobals.fKarisInvSharpness);

        vOutColor = float4(lerp(colorFullRes, colorHalfRes, halfResFactor), 1.0);
    }
    else
    {
        vOutColor = float4(colorHalfRes, 1.0);
    }

    return vOutColor;
}

// ---- entry points -----------------------------------------------------------
[shader("vertex")]
public BokehTransport bokeh_vs_main(BokehVSInput vertIn)
{
    BokehTransport vertOut;
    // The D3D path takes the clip-space position straight through (the p_mTransform
    // multiply is commented out upstream; only the GL arm transforms).
    vertOut.vPosition = vertIn.vPosition;
    vertOut.vUV = vertIn.vUV;
    return vertOut;
}

[shader("pixel")]
public BokehFragmentOut bokeh_ps_main(BokehPSInput input)
{
    BokehFragmentOut output;

#if (b_iBokehPass == BOKEH_TILEDOWNSAMPLE0 || b_iBokehPass == BOKEH_TILEDOWNSAMPLE1)
    output.vColor0 = bkTileDownSample(input.vUV.xy);
#elif (b_iBokehPass == BOKEH_TILENEIGHBOR)
    output.vColor0 = bkTileNeighbor(input.vUV.xy);
#elif (b_iBokehPass == BOKEH_PREPASS)
    output.vColor0 = bkPrepass(input.vUV.xy, output.vColor1);
#elif (b_iBokehPass == BOKEH_CIRCULARFILTER)
    output.vColor0 = bkCircularFilter(input.vUV.xy, output.vColor1);
#elif (b_iBokehPass == BOKEH_MEDIAN)
    output.vColor0 = bkMedian(input.vUV.xy, output.vColor1);
#elif (b_iBokehPass == BOKEH_UPSAMPLE)
    output.vColor0 = bkUpsample(input.vUV.xy);
#else
    output.vColor0 = float4(0, 0, 0, 0);
#endif

    return output;
}
