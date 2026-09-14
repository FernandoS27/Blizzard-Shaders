// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Foliage vertex shader entry point — Warcraft III Reforged 3.0.0.
//
// Two permutations, one axis:
//
//   index 0  static
//   index 1  WIND -> HAS_WIND: displace the vertex XY by the wind field
//
// 2.0.0 shipped eight (SHADOW_PASS, RECEIVE_SHADOWS, WIND). Both shadow bits
// went away with the cascade outputs: 3.0.0 hands the pixel shader the world
// position on every permutation and lets it do the projection, the same move
// the HD mesh VS made. See vs/foliage_vs_body.slang.

implementing wc3_shaders;

[shader("vertex")]
public FoliageVSOutput foliage_vs_main<let HAS_WIND : bool>(FoliageVSInput input)
{
    return foliageVSBody<HAS_WIND>(input);
}
