// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Coverage shapes of the transparent foliage surfaces (the "_con" scene and
// prop materials), alongside the posterizing masks of scene_ps.slang.

implementing d3_shaders;

/// Coverage snapped to fully opaque from the 8-bit level `LEVEL` up
/// (`a >= LEVEL / 255 ? 1 : a`): the transparent foliage keeps its soft
/// silhouette edge but renders its solid interior without blending.
public struct AlphaOpaqueFrom<let LEVEL : int> : IAlphaShape
{
    public static float shape(float alpha)
    {
        return alpha >= float(LEVEL) / 255.0 ? 1.0 : alpha;
    }
};
