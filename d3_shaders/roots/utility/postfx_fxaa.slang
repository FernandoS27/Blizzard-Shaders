// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// FXAA 3.11 "quality" (FSAA.fx, FSAA_AMD.fx), preset 12: five search steps
// (1, 1.5, 2, 4, 12 texels), edge threshold 0.166 (minimum 0.0833), sub-pixel
// aliasing removal 0.75. The luminance is read from alpha, where the
// LumaToAlpha pass stored it; `edgeFilter.xy` is one texel.
//
// The two retail programs run the same filter; they differ in whether the
// screen coordinate goes through the viewport rectangle (and its clamp) first.

implementing d3_shaders;

static const float kFxaaEdgeThreshold = 0.166;
static const float kFxaaEdgeThresholdMin = 0.0833;
static const float kFxaaSubpix = 0.75;

float fxaaLuma(float2 pos)
{
    return texSampler0.SampleLevel(texSampler0_s, pos, 0.0).w;
}

public float4 fxaaQuality(float2 posM)
{
    float2 rcpFrame = edgeFilter.xy;
    float4 rgbyM = texSampler0.SampleLevel(texSampler0_s, posM, 0.0);
    float lumaM = rgbyM.w;
    float lumaS = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(0, 1)).w;
    float lumaE = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(1, 0)).w;
    float lumaN = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(0, -1)).w;
    float lumaW = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(-1, 0)).w;

    float maxSM = max(lumaS, lumaM);
    float minSM = min(lumaS, lumaM);
    float maxESM = max(lumaE, maxSM);
    float minESM = min(lumaE, minSM);
    float maxWN = max(lumaN, lumaW);
    float minWN = min(lumaN, lumaW);
    float rangeMax = max(maxWN, maxESM);
    float rangeMin = min(minWN, minESM);
    float rangeMaxScaled = rangeMax * kFxaaEdgeThreshold;
    float range = rangeMax - rangeMin;
    float rangeMaxClamped = max(kFxaaEdgeThresholdMin, rangeMaxScaled);
    bool earlyExit = range < rangeMaxClamped;
    if (earlyExit)
        return rgbyM;

    float lumaNW = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(-1, -1)).w;
    float lumaSE = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(1, 1)).w;
    float lumaNE = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(1, -1)).w;
    float lumaSW = texSampler0.SampleLevel(texSampler0_s, posM, 0.0, int2(-1, 1)).w;

    float lumaNS = lumaN + lumaS;
    float lumaWE = lumaW + lumaE;
    float subpixRcpRange = 1.0 / range;
    float subpixNSWE = lumaNS + lumaWE;
    float edgeHorz1 = (-2.0 * lumaM) + lumaNS;
    float edgeVert1 = (-2.0 * lumaM) + lumaWE;

    float lumaNESE = lumaNE + lumaSE;
    float lumaNWNE = lumaNW + lumaNE;
    float edgeHorz2 = (-2.0 * lumaE) + lumaNESE;
    float edgeVert2 = (-2.0 * lumaN) + lumaNWNE;

    float lumaNWSW = lumaNW + lumaSW;
    float lumaSWSE = lumaSW + lumaSE;
    float edgeHorz4 = (abs(edgeHorz1) * 2.0) + abs(edgeHorz2);
    float edgeVert4 = (abs(edgeVert1) * 2.0) + abs(edgeVert2);
    float edgeHorz3 = (-2.0 * lumaW) + lumaNWSW;
    float edgeVert3 = (-2.0 * lumaS) + lumaSWSE;
    float edgeHorz = abs(edgeHorz3) + edgeHorz4;
    float edgeVert = abs(edgeVert3) + edgeVert4;

    float subpixNWSWNESE = lumaNWSW + lumaNESE;
    float lengthSign = rcpFrame.x;
    bool horzSpan = edgeHorz >= edgeVert;
    float subpixA = subpixNSWE * 2.0 + subpixNWSWNESE;

    if (!horzSpan) lumaN = lumaW;
    if (!horzSpan) lumaS = lumaE;
    if (horzSpan) lengthSign = rcpFrame.y;
    float subpixB = (subpixA * (1.0 / 12.0)) - lumaM;

    float gradientN = lumaN - lumaM;
    float gradientS = lumaS - lumaM;
    float lumaNN = lumaN + lumaM;
    float lumaSS = lumaS + lumaM;
    bool pairN = abs(gradientN) >= abs(gradientS);
    float gradient = max(abs(gradientN), abs(gradientS));
    if (pairN) lengthSign = -lengthSign;
    float subpixC = saturate(abs(subpixB) * subpixRcpRange);

    float2 posB = posM;
    float2 offNP;
    offNP.x = (!horzSpan) ? 0.0 : rcpFrame.x;
    offNP.y = (horzSpan) ? 0.0 : rcpFrame.y;
    if (!horzSpan) posB.x += lengthSign * 0.5;
    if (horzSpan) posB.y += lengthSign * 0.5;

    float2 posN;
    posN.x = posB.x - offNP.x * 1.0;
    posN.y = posB.y - offNP.y * 1.0;
    float2 posP;
    posP.x = posB.x + offNP.x * 1.0;
    posP.y = posB.y + offNP.y * 1.0;
    float subpixD = ((-2.0) * subpixC) + 3.0;
    float lumaEndN = fxaaLuma(posN);
    float subpixE = subpixC * subpixC;
    float lumaEndP = fxaaLuma(posP);

    if (!pairN) lumaNN = lumaSS;
    float gradientScaled = gradient * 1.0 / 4.0;
    float lumaMM = lumaM - lumaNN * 0.5;
    float subpixF = subpixD * subpixE;
    bool lumaMLTZero = lumaMM < 0.0;

    lumaEndN -= lumaNN * 0.5;
    lumaEndP -= lumaNN * 0.5;
    bool doneN = abs(lumaEndN) >= gradientScaled;
    bool doneP = abs(lumaEndP) >= gradientScaled;
    if (!doneN) posN.x -= offNP.x * 1.5;
    if (!doneN) posN.y -= offNP.y * 1.5;
    bool doneNP = (!doneN) || (!doneP);
    if (!doneP) posP.x += offNP.x * 1.5;
    if (!doneP) posP.y += offNP.y * 1.5;

    if (doneNP)
    {
        if (!doneN) lumaEndN = fxaaLuma(posN.xy);
        if (!doneP) lumaEndP = fxaaLuma(posP.xy);
        if (!doneN) lumaEndN = lumaEndN - lumaNN * 0.5;
        if (!doneP) lumaEndP = lumaEndP - lumaNN * 0.5;
        doneN = abs(lumaEndN) >= gradientScaled;
        doneP = abs(lumaEndP) >= gradientScaled;
        if (!doneN) posN.x -= offNP.x * 2.0;
        if (!doneN) posN.y -= offNP.y * 2.0;
        doneNP = (!doneN) || (!doneP);
        if (!doneP) posP.x += offNP.x * 2.0;
        if (!doneP) posP.y += offNP.y * 2.0;

        if (doneNP)
        {
            if (!doneN) lumaEndN = fxaaLuma(posN.xy);
            if (!doneP) lumaEndP = fxaaLuma(posP.xy);
            if (!doneN) lumaEndN = lumaEndN - lumaNN * 0.5;
            if (!doneP) lumaEndP = lumaEndP - lumaNN * 0.5;
            doneN = abs(lumaEndN) >= gradientScaled;
            doneP = abs(lumaEndP) >= gradientScaled;
            if (!doneN) posN.x -= offNP.x * 4.0;
            if (!doneN) posN.y -= offNP.y * 4.0;
            doneNP = (!doneN) || (!doneP);
            if (!doneP) posP.x += offNP.x * 4.0;
            if (!doneP) posP.y += offNP.y * 4.0;

            if (doneNP)
            {
                if (!doneN) lumaEndN = fxaaLuma(posN.xy);
                if (!doneP) lumaEndP = fxaaLuma(posP.xy);
                if (!doneN) lumaEndN = lumaEndN - lumaNN * 0.5;
                if (!doneP) lumaEndP = lumaEndP - lumaNN * 0.5;
                doneN = abs(lumaEndN) >= gradientScaled;
                doneP = abs(lumaEndP) >= gradientScaled;
                if (!doneN) posN.x -= offNP.x * 12.0;
                if (!doneN) posN.y -= offNP.y * 12.0;
                if (!doneP) posP.x += offNP.x * 12.0;
                if (!doneP) posP.y += offNP.y * 12.0;
            }
        }
    }

    float dstN = posM.x - posN.x;
    float dstP = posP.x - posM.x;
    if (!horzSpan) dstN = posM.y - posN.y;
    if (!horzSpan) dstP = posP.y - posM.y;

    bool goodSpanN = (lumaEndN < 0.0) != lumaMLTZero;
    float spanLength = (dstP + dstN);
    bool goodSpanP = (lumaEndP < 0.0) != lumaMLTZero;
    float spanLengthRcp = 1.0 / spanLength;

    bool directionN = dstN < dstP;
    float dst = min(dstN, dstP);
    bool goodSpan = directionN ? goodSpanN : goodSpanP;
    float subpixG = subpixF * subpixF;
    float pixelOffset = (dst * (-spanLengthRcp)) + 0.5;
    float subpixH = subpixG * kFxaaSubpix;

    float pixelOffsetGood = goodSpan ? pixelOffset : 0.0;
    float pixelOffsetSubpix = max(pixelOffsetGood, subpixH);
    if (!horzSpan) posM.x += pixelOffsetSubpix * lengthSign;
    if (horzSpan) posM.y += pixelOffsetSubpix * lengthSign;
    return float4(texSampler0.SampleLevel(texSampler0_s, posM, 0.0).xyz, lumaM);
}

/// FXAA over the frame at the screen coordinate the policy maps TEXCOORD0 to.
public struct Fxaa<TFrameUv : IPostFxScreenUv> : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        return fxaaQuality(TFrameUv.map(i.texcoord0().xy));
    }
};
