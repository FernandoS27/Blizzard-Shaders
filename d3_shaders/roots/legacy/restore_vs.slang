// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The depth restore vertex shader (Legacy.fx; depth_restore_xbox,
// fast_depth_restore_xbox, hiz_restore_xbox): a screen-covering quad whose
// corners come in the first packed UV set, in [0, 1] screen space. The vertex
// lands in clip space directly (y flipped, no camera), and the pixel shader gets
// the corner as a texel position of the render target.

implementing d3_shaders;

/// How the quad corner becomes the pixel shader's coordinate.
public interface IRestoreCoordinate
{
    static float4 coordinate(float2 corner);
}

/// The corner in render-target texels, sampled at texel centres.
public struct RestoreTexelCentre : IRestoreCoordinate
{
    public static float4 coordinate(float2 corner)
    {
        return float4(corner * targetDimensions.xy + 0.5, 0.0, 0.0);
    }
};

[shader("vertex")]
public D3Interpolants restore_vs_main<TCoord : IRestoreCoordinate>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    float2 corner = d3DecodeUv0(i.texcoord0Bits());
    o.setPosition(float4((corner - 0.5) * float2(2.0, -2.0), 0.0, 1.0));
    o.setTexcoord0(TCoord.coordinate(corner));
    return o;
}
