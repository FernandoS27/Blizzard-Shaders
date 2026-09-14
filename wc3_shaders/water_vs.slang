// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Water vertex shader entry point — Warcraft III Reforged 3.0.0.
//
// One permutation. 3.0.0 moved water onto the HD mesh's vertex banks --
// `hdVsCB1` (the blight rect, plus the wave height in its second row) and
// `hdVsCB2` (world / worldView / worldViewProj, the UV0 matrix and the shared
// effect clock) -- and gave it something no other vertex stage in the module
// has: a VERTEX TEXTURE FETCH. The water normal map is sampled twice at two
// counter-scrolling coordinates, and the decoded normals' Y components displace
// the vertex along object Z. Every position output (clip, view, world, and so
// the blight UV) is taken from the displaced vertex; the normal is not.
//
// The two taps are the pixel shader's small octave: the same 0.014 tiling, the
// same 0.0035 scroll, the same (-0.5, 0.5) shift on the second tap -- so the
// geometry heaves with the ripples the pixel shader draws on it.

implementing wc3_shaders;

static const float WATER_WAVE_SCROLL = 0.00350000034;
static const float WATER_WAVE_TILING = 0.0140000004;

// Height offset from the two ripple taps, before the per-draw wave height.
float waterWaveHeight(float2 uv, float time)
{
    float phase = frac(WATER_WAVE_SCROLL * time);
    float2 uvA = uv * WATER_WAVE_TILING + phase;
    float2 uvB = (uv + float2(-0.5, 0.5)) * WATER_WAVE_TILING - phase;
    float yA = decodeNormalMap(t_waterVsNormal.SampleLevel(s_waterVsNormal, uvA, 0).xyw).y;
    float yB = decodeNormalMap(t_waterVsNormal.SampleLevel(s_waterVsNormal, uvB, 0).xyw).y;
    return yA + yB;
}

// The shore-opacity remap, unchanged from 2.0.0: a' = 0.5 * (a^2 - a) + a.
float remapShoreAlpha(float a)
{
    return (a * a - a) * 0.5 + a;
}

[shader("vertex")]
public WaterVSOutput water_vs_main(WaterVSInput input)
{
    WaterVSOutput output;

    float2 uv = transformUV(input.uv, hdVsCB2.texMtx0Row0, hdVsCB2.texMtx0Row1);
    float height = waterWaveHeight(uv, hdVsCB2.effectTime);
    float3 objectPos = float3(input.position.xy,
                              height * hdVsCB1.waterWave.x + input.position.z);

    output.position = transformClipPos(objectPos, hdVsCB2.worldViewProj);
    output.color = float4(input.vertColor.rgb, remapShoreAlpha(input.vertColor.a));

    float4 worldPos = computeWorldPos4(objectPos, hdVsCB2.world);
    output.worldPos = worldPos;
    output.texCoord = float4(uv, blightMapUV(worldPos.xy, hdVsCB1.rect));

    output.viewPos = transformByWorldView(objectPos, hdVsCB2.worldView);
    output.normalVS = transformNormal(input.normal, hdVsCB2.worldView);
    // The object's Y axis: worldView's second column.
    output.tangentVS = float4(transformNormalRaw(float3(0, 1, 0), hdVsCB2.worldView), 1);

    return output;
}
