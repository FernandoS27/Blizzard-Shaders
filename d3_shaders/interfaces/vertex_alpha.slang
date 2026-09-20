// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The opacity a surface vertex hands its pixel shader: the material's fade
// factor, the painted vertex alpha, or both.

implementing d3_shaders;

public interface IVertexAlpha
{
    static float alpha(D3VertexIn i, D3SurfaceVertex v);
}

/// The material fade factor alone (vertex alpha unused).
public struct MaterialAlpha : IVertexAlpha
{
    public static float alpha(D3VertexIn i, D3SurfaceVertex v) { return Factor.w; }
};

/// The painted vertex alpha alone.
public struct VertexAlpha : IVertexAlpha
{
    public static float alpha(D3VertexIn i, D3SurfaceVertex v) { return i.color0().w; }
};

/// Painted vertex alpha scaled by the material fade factor.
public struct VertexMaterialAlpha : IVertexAlpha
{
    public static float alpha(D3VertexIn i, D3SurfaceVertex v) { return i.color0().w * Factor.w; }
};

/// Vertex-material alpha that also fades out geometry close to the camera,
/// fully transparent at clip depth 0 and opaque from depth 40.
public struct NearFadeAlpha : IVertexAlpha
{
    public static float alpha(D3VertexIn i, D3SurfaceVertex v)
    {
        return i.color0().w * Factor.w * saturate(v.clip.z * 0.025);
    }
};
