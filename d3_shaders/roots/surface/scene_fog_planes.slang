// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The interactive fog-plane variants beside FogPlaneMasks (scene_ps.slang):
// the corruption planes (InteractiveFog.fx ps_fog_evil, ps_fog_evil_vert_alpha)
// and the scum planes of the rivers (ps_fog_qt).

implementing d3_shaders;

/// A corruption plane: the three alpha masks carve the silhouette like
/// FogPlaneMasks, but the fog map's red channel GROWS it instead of eroding it,
/// and the coverage is doubled last. The third mask's colour tints it, doubled
/// by the vertex colour; with VERTEX_ALPHA the vertex colour carries a coverage
/// factor instead and the mask colour is used as is.
public struct FogPlaneCorruption<let VERTEX_ALPHA : bool> : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float mask0 = alphaMap0Sampler.Sample(alphaMap0Sampler_s, i.texcoord1().xy).a;
        float mask1 = alphaMap1Sampler.Sample(alphaMap1Sampler_s, i.texcoord2().xy).a;
        float4 shape = alphaMap2Sampler.Sample(alphaMap2Sampler_s, i.texcoord3().xy);
        float growth = fogSampler.Sample(fogSampler_s, i.texcoord4().xy).r;

        float alpha = (mask0 * mask1) * shape.a * growth;
        float3 tint = shape.rgb;
        if (VERTEX_ALPHA)
            alpha = alpha * i.color0().a;
        else
            tint = (2.0 * i.color0().rgb) * shape.rgb;
        return float4(d3ApplyFog(tint, i.fog().x), 2.0 * alpha);
    }
};

/// A scum plane: the diffuse map (TEXCOORD1) takes the first alpha mask's
/// place and supplies the colour, doubled by the vertex colour; the two
/// remaining masks (TEXCOORD2/3) carve it, the scum map's red channel
/// (TEXCOORD5) thins it and the fog map's red channel (TEXCOORD4) erodes it.
public struct FogPlaneScum : ISurfacePixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = diffuseSampler.Sample(diffuseSampler_s, i.texcoord1().xy);
        float mask1 = alphaMap1Sampler.Sample(alphaMap1Sampler_s, i.texcoord2().xy).a;
        float shape = alphaMap2Sampler.Sample(alphaMap2Sampler_s, i.texcoord3().xy).a;
        float solid = 1.0 - fogSampler.Sample(fogSampler_s, i.texcoord4().xy).r;
        float scum = scumSampler.Sample(scumSampler_s, i.texcoord5().xy).r;

        float alpha = 2.0 * (shape * (mask1 * diffuse.a)) * scum * solid;
        return float4(d3ApplyFog((2.0 * i.color0().rgb) * diffuse.rgb, i.fog().x), alpha);
    }
};
