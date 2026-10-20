// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The minimap composite (Minimap.fx): the map texture (TEXCOORD0), masked to
// the minimap's frame shape (TEXCOORD1) and to the explored area
// (TEXCOORD2), faded by the vertex alpha. The layer coordinates come from
// postfx_vs_main's MinimapLayers.

implementing d3_shaders;

/// Coverage every minimap pass shares: map alpha x vertex alpha x frame mask x
/// explored mask.
float minimapCoverage(D3Interpolants i, float mapAlpha, float exploredAlpha)
{
    float frameMask = texMask.Sample(texMask_s, i.texcoord1().xy).w;
    return mapAlpha * i.color0().w * frameMask * exploredAlpha;
}

/// The map tinted by the explored layer's colour.
public struct MinimapExplored : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 map = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy);
        float4 explored = texExplored.Sample(texExplored_s, i.texcoord2().xy);
        return float4(map.rgb * explored.rgb, minimapCoverage(i, map.w, explored.w));
    }
};

/// Debug view: magenta, with the map's and explored layer's green channels
/// (dimmed to 30%) showing through where both are lit.
public struct MinimapExploredDebug : IPostFxPass
{
    public static float4 shade(D3Interpolants i)
    {
        float4 map = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy);
        float4 explored = texExplored.Sample(texExplored_s, i.texcoord2().xy);
        float green = map.g * explored.g * 0.3;
        return float4(1.0, green, 1.0, minimapCoverage(i, map.w, explored.w));
    }
};
