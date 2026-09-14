// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Foliage vertex shader body — Warcraft III Reforged 3.0.0.
//
// 3.0.0 moved foliage onto the HD mesh's vertex banks: `hdVsCB1` (the blight
// rect) and `hdVsCB2` (world / worldView / worldViewProj, the tint, the UV0
// matrix and the wind clock), read at HD's offsets. What stayed foliage's own
// is the wind: the b3 wind-area rect and the t0 wind field, both only reached
// on the WIND permutation.
//
// Against 2.0.0 the payload is HD's (view-space position, normal and tangent,
// the homogeneous world position on TEXCOORD10) with the blight UV folded into
// TEXCOORD0.zw, and the cascade projections are gone: the pixel shader
// reprojects the world position itself. The wind algorithm is unchanged,
// instruction for instruction.
//
// Wind (HAS_WIND only, and only for vertices with a positive wind weight):
//   1. strength s = 0.015 * vertColor.w * min(100, |tangent.w|).
//   2. Map the vertex XY into the wind area via b3 and sample the wind field
//      at three taps -- centre, one texel back in U, one texel up in V -- for
//      a gradient clamped to [-1, 1]. The field is stored V-flipped.
//   3. Pre-displace XY by 10 * s * |tangent.w| * gradient.
//   4. Only where the gradient is EXACTLY zero on both axes (a flat field),
//      add a (cos, sin) * s swing with phase 2*pi * (frac(time) + XY).
// The displaced XY then feeds every position output; Z never moves, and the
// normal and tangent are left alone -- wind sways geometry without re-facing
// it.

implementing wc3_shaders;

// 2*pi, converting the wind phase from turns into radians.
static const float TWO_PI = 6.28318548;
// Strength per unit of wind weight and tangent magnitude, and its clamp.
static const float WIND_STRENGTH_SCALE = 0.0149999997;
static const float WIND_TANGENT_MAX = 100.0;
// Pre-displacement gain applied to the field gradient.
static const float WIND_GRADIENT_GAIN = 10.0;

// The wind field's gradient at an in-area UV, per axis, clamped to [-1, 1].
float2 sampleWindGradient(float2 uv, float texel)
{
    float vFlipped = 1.0 - uv.y;
    float centre = t_foliageWind.SampleLevel(s_foliageWind,
                       float2(uv.x, vFlipped), 0).x;
    float dx = t_foliageWind.SampleLevel(s_foliageWind,
                   float2(uv.x - texel, vFlipped), 0).x - centre;
    // One texel UP in the flipped space is `vFlipped - texel`, not `+ texel`:
    // the latter flips the sign of the Y gradient.
    float dy = t_foliageWind.SampleLevel(s_foliageWind,
                   float2(uv.x, vFlipped - texel), 0).x - centre;
    return clamp(float2(dx, dy), float2(-1, -1), float2(1, 1));
}

// Wind-displaced XY for one vertex; the input XY unchanged when the vertex
// carries no wind weight.
float2 applyWindDisplacement(float2 inputXY, float windWeight, float tangentW)
{
    if (!(0.0 < windWeight))
        return inputXY;

    float strength = min(abs(tangentW), WIND_TANGENT_MAX) * windWeight
                   * WIND_STRENGTH_SCALE;

    uint w, h, mips;
    t_foliageWind.GetDimensions(0, w, h, mips);
    float texel = 1.0 / (float)w;

    float2 areaUV = (inputXY - foliageVsCB3.windOrigin) / foliageVsCB3.windSize;
    float2 gradient = sampleWindGradient(areaUV, texel);

    float2 preDisp = (strength * abs(tangentW) * WIND_GRADIENT_GAIN) * gradient
                   + inputXY;

    bool flatField = gradient.x == 0.0 && gradient.y == 0.0;
    float2 phase = (preDisp + frac(hdVsCB2.effectTime)) * TWO_PI;
    float2 swung = strength * float2(cos(phase.x), sin(phase.y)) + preDisp;
    return flatField ? swung : preDisp;
}

public FoliageVSOutput foliageVSBody<let HAS_WIND : bool>(FoliageVSInput input)
{
    FoliageVSOutput output;

    float2 xy = HAS_WIND
        ? applyWindDisplacement(input.position.xy, input.vertColor.w, input.tangent.w)
        : input.position.xy;
    float3 objectPos = float3(xy, input.position.z);

    output.position = transformClipPos(objectPos, hdVsCB2.worldViewProj);

    // The wind weight rides in .w, so the tint takes an opaque vertex colour.
    output.color = float4(input.vertColor.xyz, 1.0) * hdVsCB2.diffuseColor;

    float4 worldPos = computeWorldPos4(objectPos, hdVsCB2.world);
    output.worldPos = worldPos;
    output.texCoord = float4(
        transformUV(input.uv0, hdVsCB2.texMtx0Row0, hdVsCB2.texMtx0Row1),
        blightMapUV(worldPos.xy, hdVsCB1.rect));

    output.viewPos = float4(transformByWorldView(objectPos, hdVsCB2.worldView), 0);

    // sign() lowers to the lt / lt / isub / itof the shipped shader uses, so
    // a zero handedness stays zero.
    output.tangentVS = float4(transformNormalRaw(input.tangent.xyz, hdVsCB2.worldView),
                              sign(input.tangent.w));
    output.normalVS = transformNormal(input.normal, hdVsCB2.worldView);

    return output;
}
