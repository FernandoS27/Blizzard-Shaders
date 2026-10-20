// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Projected premultiplied layer variants without an effect entry point (plan M7
// residue): the same projected box, edge fade, mask and premultiplied fog as
// ProjectedLayerPremultiplied (roots/legacy/legacy_aux_ps.slang), with a
// different gate -- none, a hard threshold on the gate, or a flat debug tint.

implementing d3_shaders;

/// The projected box of TEXCOORD0.xy, clipped to [0,1]: signed distance to
/// the nearest edge on each axis.
float2 d3ProjectedBox(D3Interpolants i)
{
    float2 box = 0.5 - abs(i.texcoord0().xy - 0.5);
    clip(box);
    return box;
}

/// The layer weighted by the box edge fade and the mask, still premultiplied
/// (colour in .rgb, destination transmittance in .a).
float4 d3ProjectedLayerCovered(D3Interpolants i, float2 box)
{
    float2 edge = saturate(box * 10.0);
    float2 fade = edge * edge * (edge * -2.0 + 3.0);
    float coverage = min(fade.y, fade.x);
    coverage = min(coverage, pmaMaskTex.Sample(pmaMaskTex_s, i.texcoord2().xy).x);
    float4 layer = pmaTex.Sample(pmaTex_s, i.texcoord0().xy);
    return lerp(kNoProjectedLayer, layer, coverage);
}

/// Premultiplied fog: the layer faded towards the fog colour, minus the fog
/// the destination keeps through the layer's transmittance.
float3 d3ProjectedLayerFog(float4 covered, float fog)
{
    return lerp(fogColor.rgb, covered.rgb, fog) - (covered.a * fogColor.rgb) * (1.0 - fog);
}

/// The layer with no diffuse gate: fogged colour and its transmittance.
public struct ProjectedLayerUngated : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 covered = d3ProjectedLayerCovered(i, d3ProjectedBox(i));
        return float4(d3ProjectedLayerFog(covered, i.texcoord0().z), covered.a);
    }
};

/// The layer where the diffuse alpha times vertex alpha exceeds 1/128, and no
/// layer (black, fully transmissive) elsewhere.
public struct ProjectedLayerThresholded : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 covered = d3ProjectedLayerCovered(i, d3ProjectedBox(i));
        float4 layer = float4(d3ProjectedLayerFog(covered, i.texcoord0().z), covered.a);
        float gate = diffuseTex.Sample(diffuseTex_s, i.texcoord1().xy).a * i.color0().w;
        return (0.0078125 >= gate) ? kNoProjectedLayer : layer;
    }
};

/// Debug view of the projected box: a flat magenta tint with the layer's
/// alpha, clipped to the box.
public struct ProjectedLayerDebugTint : ILegacyAuxPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        d3ProjectedBox(i);
        float alpha = sampler1.Sample(sampler1_s, i.texcoord0().xy).a;
        return float4(0.25, 0.0, 0.25, alpha);
    }
};
