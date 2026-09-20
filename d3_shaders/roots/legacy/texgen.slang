// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture-coordinate generation for the legacy mesh vertex shaders.
//
// The legacy material path is a fixed-function emulation: each texture stage of
// the pixel shader gets its coordinates from one generator, and a program has up
// to seven of them. A generator either transforms a UV stream by one of the
// engine's texture matrices, passes it through, or derives coordinates from the
// vertex itself (a sphere map from the view normal, an eye-linear projection of
// the view position, a planar projection onto the camera's axes).
//
// Two auto-coordinates of the old pipeline are NOT generators here: the fog
// factor and the near-fade depth travel in their own interpolants (FOG0 and
// TEXCOORD6) and are written by the root whenever the slot's layout declares
// them.
//
// Where a generator's result lands is layout data: generator k writes the k-th
// texture interpolant the retail program declares, which is not always
// TEXCOORDk (a program may skip indices the paired pixel shader never reads).

implementing d3_shaders;

/// The per-vertex values every generator and colour policy may read.
public struct D3LegacyVertex
{
    public float4 model;    ///< object-space position, w = 1
    public float4 clip;     ///< matWorldViewProj * model
    public float4 view;     ///< matWorldView * model, all four rows
    public float3 world;    ///< (matWorld * model).xyz
    public float3 normal;   ///< unit view-space normal
    public float fog;       ///< combined depth + height fog factor
};

// --------------------------------------------------------------------------
// UV streams
// --------------------------------------------------------------------------

/// Where a mesh's texture coordinates come from and how they are encoded.
public interface IUvSource
{
    /// UV set `channel`, mapped into range `scale` (packed streams only:
    /// 0 is [-64, 64), 1 is [-4, 4)).
    static float2 uv(D3VertexIn i, int channel, int scale);
}

/// Mesh streams: two 8.8 fixed-point UBYTE4 UV sets with a per-use range map.
public struct PackedUv : IUvSource
{
    public static float2 uv(D3VertexIn i, int channel, int scale)
    {
        uint4 bits = i.texcoord0Bits();
        if (channel != 0)
            bits = i.texcoord1Bits();
        if (scale != 0)
            return d3DecodeUv1(bits);
        return d3DecodeUv0(bits);
    }
};

/// Text and debug meshes: whole-number coordinates in the first two channels.
public struct IntegerUv : IUvSource
{
    public static float2 uv(D3VertexIn i, int channel, int scale)
    {
        uint4 bits = i.texcoord0Bits();
        if (channel != 0)
            bits = i.texcoord1Bits();
        return float2(float(bits.x), float(bits.y));
    }
};

/// The simple vertex (sprites, text, minimap): float UV sets.
public struct FloatUv : IUvSource
{
    public static float2 uv(D3VertexIn i, int channel, int scale)
    {
        if (channel == 1)
            return i.texcoord1().xy;
        if (channel == 2)
            return i.texcoord2().xy;
        return i.texcoord0().xy;
    }
};

// --------------------------------------------------------------------------
// generators
// --------------------------------------------------------------------------

public interface ITexGen
{
    static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v);
}

/// `matTex[MAT] * (uv, 0, 1)`.
public struct TexGenMatrix<let MAT : int, let UV : int, let SCALE : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return d3TextureMatrixTransform(MAT, TUv.uv(i, UV, SCALE));
    }
};

/// `(uv, 0, 1)` untransformed.
public struct TexGenPassthrough<let UV : int, let SCALE : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4(TUv.uv(i, UV, SCALE), 0.0, 1.0);
    }
};

/// Sphere map from the view normal: `0.5 - 0.5 * n`, the y term repeated.
public struct TexGenSphereMap : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4(0.5 - 0.5 * v.normal.x, 0.5 - 0.5 * v.normal.y,
                      0.5 - 0.5 * v.normal.y, 0.5 - 0.5 * v.normal.y);
    }
};

/// Eye-linear: `matTex[MAT] * viewPosition` (projective and reflection maps).
public struct TexGenEyeLinear<let MAT : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4(dot(d3TextureMatrixRow(MAT, 0), v.view), dot(d3TextureMatrixRow(MAT, 1), v.view),
                      dot(d3TextureMatrixRow(MAT, 2), v.view), dot(d3TextureMatrixRow(MAT, 3), v.view));
    }
};

/// Eye-linear xy with the fog factor carried in z (the projected decal layer,
/// which has no FOG0 interpolant of its own).
public struct TexGenEyeLinearFog<let MAT : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4(dot(d3TextureMatrixRow(MAT, 0), v.view), dot(d3TextureMatrixRow(MAT, 1), v.view),
                      v.fog, 0.0);
    }
};

/// Planar projection onto the camera: the world position on the view's x and y
/// axes, through `matTex[MAT]` as a UV.
public struct TexGenCameraPlane<let MAT : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        float3 h = float3(dot(matView[0].xyz, v.world), dot(matView[1].xyz, v.world), 1.0);
        return float4(dot(d3TextureMatrixRow(MAT, 0).xyw, h), dot(d3TextureMatrixRow(MAT, 1).xyw, h), 0.0, 1.0);
    }
};

// --------------------------------------------------------------------------
// the stage set
// --------------------------------------------------------------------------

public interface ITexStage
{
    static void write<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v, inout D3Interpolants o);
}

/// Generator `G` feeding TEXCOORD`TC`.
public struct TexStage<let TC : int, G : ITexGen> : ITexStage
{
    public static void write<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v, inout D3Interpolants o)
    {
        d3SetTexcoord(o, TC, G.generate<TUv>(i, v));
    }
};

/// An unused stage.
public struct TexStageNone : ITexStage
{
    public static void write<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v, inout D3Interpolants o) {}
};

public interface ITexGenSet
{
    static void write<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v, inout D3Interpolants o);
}

/// Up to seven stages, written in stage order.
public struct TexGenSet<S0 : ITexStage, S1 : ITexStage, S2 : ITexStage, S3 : ITexStage,
                        S4 : ITexStage, S5 : ITexStage, S6 : ITexStage> : ITexGenSet
{
    public static void write<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v, inout D3Interpolants o)
    {
        S0.write<TUv>(i, v, o);
        S1.write<TUv>(i, v, o);
        S2.write<TUv>(i, v, o);
        S3.write<TUv>(i, v, o);
        S4.write<TUv>(i, v, o);
        S5.write<TUv>(i, v, o);
        S6.write<TUv>(i, v, o);
    }
};
