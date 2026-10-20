// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The deforming glossy trees (tree_deform_spec): irradiance-lit like the
// ActorIrrad pixel models of irradiance_ps.slang.

implementing d3_shaders;

/// The irradiance-lit diffuse plus a gloss reflection weighted by COLOR1, the
/// animated pixel model without its scrolling layer: environment map at
/// TEXCOORD6 masked by the gloss map at the diffuse coordinate, vertex tint and
/// fog.
public struct IrradianceGlossPixel : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float2 uv = i.texcoord0().xy;
        float4 diffuse = diffuseMap.Sample(diffuseMap_s, uv);
        float alpha = FactorUniform.coverage(diffuse, i.color0().w);

        float3 color = d3IrradianceDiffuse(diffuse, i);
        float3 specular = environmentMap.Sample(environmentMap_s, i.texcoord6().xy).xyz
                        * glossMap.Sample(glossMap_s, uv).xyz;
        color += specular * (i.color1().xyz + 0.5);
        return float4(d3VertexTintedFog(color, i), alpha);
    }
};
