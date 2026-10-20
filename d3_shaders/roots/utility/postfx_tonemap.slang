// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Colour grading ("tonemap", PostFX.fx): the frame looked up in 64^3 colour
// lookup tables.
//
// A table is stored as a 512x512 texture of 8x8 tiles, one 64x64 red/green
// slice per blue level. The lookup samples the red/green texel centre in the
// two blue slices around the colour and blends them by the blue fraction,
// which leaves the texture's own bilinear filter to do red and green.
//
// A grade set is two such tables, A and B, mixed per pixel by the red channel
// of a saturation/vignette mask: B at mask 0, A at mask 1. A pass applies one
// set, or cross-fades two (`colorCorrectionBlend.x`) while a grade transition
// runs; either can then fade towards grey (`colorCorrectionBlend.y`).

implementing d3_shaders;

/// The two texture coordinates and blend of one colour's table lookup.
public struct ColorLutCoord
{
    public float2 lower;
    public float2 upper;
    public float blend;
};

/// Tile corner (in texture units) of blue slice `slice` of a 64^3 table.
float2 colorLutTile(float slice)
{
    return float2(floor(fmod(slice, 8.0)), floor(slice / 8.0)) / 8.0;
}

public ColorLutCoord colorLutCoord(float3 color)
{
    float2 texel = color.rg * 63.0 + 0.5;
    float slice = color.b * 63.0;
    ColorLutCoord coord;
    coord.upper = texel / 512.0 + colorLutTile(color.b * 63.0 + 1.0);
    coord.lower = texel / 512.0 + colorLutTile(slice);
    coord.blend = frac(slice);
    return coord;
}

public float3 colorLutRead(Texture2D table, SamplerState tableSampler, ColorLutCoord coord)
{
    float3 lower = table.Sample(tableSampler, coord.lower).rgb;
    float3 upper = table.Sample(tableSampler, coord.upper).rgb;
    return lerp(lower, upper, coord.blend);
}

/// Which grade set(s) a pass applies.
public interface IColorGrade
{
    static float3 grade(float3 color, float2 screenUv);
}

/// The single set texColorCorrectA / texColorCorrectB / texSatVignette.
public struct GradeSingle : IColorGrade
{
    public static float3 grade(float3 color, float2 screenUv)
    {
        ColorLutCoord coord = colorLutCoord(color);
        float3 gradeA = colorLutRead(texColorCorrectA, texColorCorrectA_s, coord);
        float3 gradeB = colorLutRead(texColorCorrectB, texColorCorrectB_s, coord);
        float mask = texSatVignette.Sample(texSatVignette_s, screenUv).x;
        return lerp(gradeB, gradeA, mask);
    }
};

/// Two sets (suffix 1 and 2), cross-faded by `colorCorrectionBlend.x`.
public struct GradeCrossFade : IColorGrade
{
    public static float3 grade(float3 color, float2 screenUv)
    {
        ColorLutCoord coord = colorLutCoord(color);
        float3 gradeA2 = colorLutRead(texColorCorrectA2, texColorCorrectA2_s, coord);
        float3 gradeB2 = colorLutRead(texColorCorrectB2, texColorCorrectB2_s, coord);
        float3 second = lerp(gradeB2, gradeA2, texSatVignette2.Sample(texSatVignette2_s, screenUv).x);
        float3 gradeA1 = colorLutRead(texColorCorrectA1, texColorCorrectA1_s, coord);
        float3 gradeB1 = colorLutRead(texColorCorrectB1, texColorCorrectB1_s, coord);
        float3 first = lerp(gradeB1, gradeA1, texSatVignette1.Sample(texSatVignette1_s, screenUv).x);
        return lerp(first, second, colorCorrectionBlend.x);
    }
};

/// The viewport's frame through a grade; `GRAY` then fades the graded colour
/// towards its luminance by `colorCorrectionBlend.y`. Output is opaque.
public struct ToneMap<TGrade : IColorGrade, let GRAY : bool> : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float2 screenUv = i.texcoord0().xy;
        float3 frame = texOriginal.Sample(texOriginal_s, ScreenUvViewport.map(screenUv)).rgb;
        float3 graded = TGrade.grade(frame, screenUv);
        if (GRAY)
        {
            float luma = dot(graded, kPostFxLuma);
            graded = lerp(graded, float3(luma, luma, luma), colorCorrectionBlend.y);
        }
        return float4(graded, 1.0);
    }
};
