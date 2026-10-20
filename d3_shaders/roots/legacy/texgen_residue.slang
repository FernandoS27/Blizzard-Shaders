// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Further policies of the legacy mesh vertex shader (roots/legacy/texgen_vs.slang),
// for the fixed-function programs outside the Legacy.fx permutation set: the
// debug/overlay primitives (clear, 3d prims, the 3D cursor, text outlines), the
// DX8-era "_v11" / "_dx8" materials (un-decoded normals, constant texture
// stages, a lighting solve modulated or offset by the vertex colour) and the
// scene glow layers.

implementing d3_shaders;

// --------------------------------------------------------------------------
// pose
// --------------------------------------------------------------------------

/// An unskinned vertex whose w comes from the stream rather than being forced
/// to 1 (primitives and the scene layers submit homogeneous positions).
public struct PoseStream : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        D3ObjectVertex v;
        v.position = i.position();
        v.normal = normal;
        return v;
    }
};

/// The 3D cursor: the stream position scaled up by the cursor's model size.
public struct PoseCursor : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        D3ObjectVertex v;
        v.position = i.position() * 30.1;
        v.normal = normal;
        return v;
    }
};

/// A text glyph pushed out by its outline offset (the second float UV set).
public struct PoseGlyphOffset : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        D3ObjectVertex v;
        v.position = float4(i.position().xy + i.texcoord1().xy, i.position().z, 1.0);
        v.normal = normal;
        return v;
    }
};

/// Another pose fed the raw UBYTE normal instead of the `2n/255 - 1` decode
/// (the DX8 materials skin and normalise it as it comes from the stream).
public struct PoseRawNormal<P : IMeshPose> : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        return P.pose(i, float3(i.normalBits().xyz));
    }
};

// --------------------------------------------------------------------------
// colour
// --------------------------------------------------------------------------

/// Another colour modulated by the vertex colour.
public struct RgbTimesVertex<T : ILegacyRgb> : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v) { return T.rgb(i, v) * i.color0().rgb; }
};

/// Another colour with the vertex colour added after it (outside an ambient fade).
public struct RgbPlusVertex<T : ILegacyRgb> : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v) { return T.rgb(i, v) + i.color0().rgb; }
};

/// The light rig with the ambient term at double weight, halved: the scene
/// layers' `(2 ambient + diffuse) / 2`.
public struct RgbLitHalfDiffuse : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v)
    {
        D3VertexLight light;
        d3AddPrimaryPointLight(v.view.xyz, v.normal, light);
        d3AddLinearPointLights(v.view.xyz, v.normal, light);
        d3AddCylindricalLight(v.view.xyz, v.normal, light);
        return (light.ambient * 2.0 + light.diffuse) * 0.5;
    }
};

/// Mid grey: an unlit layer whose pixel shader doubles it back to white.
public struct RgbHalf : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v) { return float3(0.5, 0.5, 0.5); }
};

/// The clear colour the engine sets in Constant0.
public struct RgbConstant0 : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v) { return Constant0.xyz; }
};

/// The second vertex colour (text outlines).
public struct RgbSecondary : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v) { return i.color1().rgb; }
};

/// A fixed key light for the domino debug primitive: the world normal against
/// the (1,1,1) diagonal, floored at 0 plus a 0.25 ambient, on the vertex colour,
/// tinted by Factor.
public struct RgbKeyLight : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v)
    {
        float3 n = normalize(mul((float3x3)matWorld, d3DecodeNormal(i.normalBits())));
        float key = max(dot(n, float3(0.577, 0.577, 0.577)), 0.0) + 0.25;
        return (key * i.color0().rgb) * Factor.xyz;
    }
};

/// Opaque.
public struct AlphaOne : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v) { return 1.0; }
};

/// The clear alpha in Constant0.
public struct AlphaConstant0 : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v) { return Constant0.w; }
};

/// The second vertex alpha.
public struct AlphaSecondary : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v) { return i.color1().w; }
};

/// Another alpha tinted by Factor.w.
public struct AlphaFactor<T : ILegacyAlpha> : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v) { return T.alpha(i, v) * Factor.w; }
};

/// The view-facing rim of AlphaEdge without the Factor.w tint (the DX8 shell).
public struct AlphaEdgeUntinted<let SAT : bool> : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v)
    {
        float facing = dot(-normalize(v.view.xyz), v.normal);
        if (SAT)
            facing = saturate(facing);
        return pow(facing, edgealphaParams.x + edgealphaParams.x);
    }
};

// --------------------------------------------------------------------------
// generators
// --------------------------------------------------------------------------

/// Zero (a stage the paired pixel shader never samples).
public struct TexGenZero : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v) { return float4(0.0, 0.0, 0.0, 0.0); }
};

/// The homogeneous origin (0, 0, 0, 1).
public struct TexGenOrigin : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v) { return float4(0.0, 0.0, 0.0, 1.0); }
};

/// A packed UV set the vertex format does not carry: its bits read zero, so
/// the coordinate is the low corner of the range map (-64 or -4).
public float2 d3AbsentPackedUv(int scale)
{
    uint4 bits = uint4(0, 0, 0, 0);
    if (scale != 0)
        return d3DecodeUv1(bits);
    return d3DecodeUv0(bits);
}

/// `matTex[MAT] * (uv, 0, 1)` of an absent packed UV set.
public struct TexGenMatrixAbsentUv<let MAT : int, let SCALE : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return d3TextureMatrixTransform(MAT, d3AbsentPackedUv(SCALE));
    }
};

/// `(uv, 0, 1)` of an absent packed UV set.
public struct TexGenPassthroughAbsentUv<let SCALE : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4(d3AbsentPackedUv(SCALE), 0.0, 1.0);
    }
};

/// `matTex[MAT] * stream` on a whole float4 texture stream (the DX8 cloud layers
/// submit homogeneous coordinates).
public struct TexGenMatrixStream<let MAT : int, let STREAM : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        float4 s = i.texcoord0();
        if (STREAM == 1)
            s = i.texcoord1();
        return float4(dot(d3TextureMatrixRow(MAT, 0), s), dot(d3TextureMatrixRow(MAT, 1), s),
                      dot(d3TextureMatrixRow(MAT, 2), s), dot(d3TextureMatrixRow(MAT, 3), s));
    }
};

/// The Constant0 register as a coordinate (the depth clear's value).
public struct TexGenConstant0 : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v) { return Constant0; }
};

/// UV set 0 shifted by one field line, `SIGN * targetDimensions.w`, in v: the
/// taps of the interlaced upscale.
public struct TexGenFieldTap<let SIGN : int> : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        float2 uv = TUv.uv(i, 0, 0);
        return float4(uv.x, uv.y + float(SIGN) * targetDimensions.w, 0.0, 1.0);
    }
};

/// `matTex[0] * uv0` with the glyph outline offset (UV set 1) scaled by
/// Constant0.xy added to its first two rows.
public struct TexGenGlyphOutline : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        float4 t = d3TextureMatrixTransform(0, TUv.uv(i, 0, 0));
        return float4(t.xy + TUv.uv(i, 1, 0) * Constant0.xy, t.zw);
    }
};

/// The screen-space reflection coordinate of a mirror floor: the view normal
/// relative to the screen's z axis, offset by the clip position and mapped to
/// [0, w] (projective), with clip z and w carried along.
public struct TexGenScreenReflection : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        float2 bent = v.normal.xy - wvScreenZAxis.xy;
        return float4((bent * v.clip.w + v.clip.xy + v.clip.w) * 0.5, v.clip.zw);
    }
};

/// A Schlick-style fresnel weight in every channel: `(1 - max(dot(-V, N), 0))^5`
/// mapped to [0.5, 1].
public struct TexGenFresnel : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        float grazing = 1.0 - max(dot(normalize(-v.view.xyz), v.normal), 0.0);
        float square = grazing * grazing;
        float weight = (square * square) * grazing * 0.5 + 0.5;
        return float4(weight, weight, weight, weight);
    }
};

/// The projective screen coordinate of the vertex: `((clip.xy + w) / 2, clip.zw)`.
public struct TexGenScreenPosition : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4((v.clip.xy + v.clip.w) * 0.5, v.clip.zw);
    }
};

// --------------------------------------------------------------------------
// stages beyond the texture interpolants
// --------------------------------------------------------------------------

/// The secondary colour held at white, replacing the COLOR1 pass-through (the
/// 2D primitives carry no second colour stream).
public struct TexStageSecondaryWhite : ITexStage
{
    public static void write<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v, inout D3Interpolants o)
    {
        o.setColor1(float4(1.0, 1.0, 1.0, 1.0));
    }
};
