// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Terrain vertex shader entry point — Warcraft III Reforged 3.0.0.
//
// Two permutations, one axis:
//
//   index 0  the diffuse tint (cb2[18]) as the vertex colour
//   index 1  VERTEX_COLOR -> HAS_VERTEX_COLOR: ATTR2 replaces the tint
//
// 2.0.0 shipped eight (SHADOW_PASS, RECEIVE_SHADOWS, VERTEX_COLOR); both
// shadow bits left with the cascade outputs. See vs/terrain_vs_body.slang.

implementing wc3_shaders;

[shader("vertex")]
public TerrainVSOutput terrain_vs_main<let HAS_VERTEX_COLOR : bool>(TerrainVSInput input)
{
    return terrainVSBody<HAS_VERTEX_COLOR>(input);
}
