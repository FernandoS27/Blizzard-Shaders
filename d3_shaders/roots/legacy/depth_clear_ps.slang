// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Depth clear pass (Legacy.fx `clear_depth`, plan M7 residue): a full-screen
// primitive that resets the depth buffer to the depth its vertex stage passes
// in TEXCOORD0.x, writing transparent black to the (masked) colour target.
// The only legacy pixel stage that writes SV_Depth, hence its own root.

implementing d3_shaders;

public struct D3ColorDepth
{
    public float4 color : SV_Target;
    public float depth : SV_Depth;
};

[shader("fragment")]
public D3ColorDepth depth_clear_ps_main<TAlpha : IAlphaTest>(D3Interpolants i)
{
    D3ColorDepth o;
    o.color = float4(0.0, 0.0, 0.0, 0.0);
    o.depth = i.texcoord0().x;
    TAlpha.apply(o.color.a);
    return o;
}
