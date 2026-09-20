// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The legacy mesh vertex shader (Legacy.fx vs_legacy and its siblings in
// Distortion.fx, Scene.fx, PostFX.fx; the weather, pre-pass and projected-layer
// entries of Legacy.fx).
//
// It emulates the fixed-function pipeline the legacy material path was written
// for: pose the vertex (optionally skinned or swayed), transform it, colour it
// (vertex colour or a per-vertex light rig, an ambient fade, an edge-alpha rim),
// generate the texture coordinates (roots/legacy/texgen.slang), and emit fog,
// near-fade depth and the user clip planes. Fog and near-fade depth are written
// whenever the slot's interpolant layout declares them.

implementing d3_shaders;

// --------------------------------------------------------------------------
// pose
// --------------------------------------------------------------------------

/// A mesh normal from its UBYTE stream: `n * 2/255 - 1`.
public float3 d3DecodeNormal(uint4 bits)
{
    return float3(bits.xyz) * (2.0 / 255.0) - 1.0;
}

/// Object-space position and normal of a mesh vertex.
public interface IMeshPose
{
    /// `normal` is the decoded object-space normal; the result's normal is
    /// transformed along with the position.
    static D3ObjectVertex pose(D3VertexIn i, float3 normal);
}

/// An unskinned mesh: the stream position with w forced to 1.
public struct PoseStatic : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        D3ObjectVertex v;
        v.position = float4(i.position().xyz, 1.0);
        v.normal = normal;
        return v;
    }
};

/// Rigid attachment to one bone (BLENDINDICES.x), no weights.
public struct PoseOneBone : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        uint bone = i.blendIndicesBits().x;
        float4 position = i.position();
        D3ObjectVertex v;
        v.position = float4(dot(matBones[bone].row0, position), dot(matBones[bone].row1, position),
                            dot(matBones[bone].row2, position), 1.0);
        v.normal = float3(dot(matBones[bone].row0.xyz, normal), dot(matBones[bone].row1.xyz, normal),
                          dot(matBones[bone].row2.xyz, normal));
        return v;
    }
};

/// Three-bone linear blend by BLENDWEIGHT.xyz.
public struct PoseThreeBones : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        uint4 bones = i.blendIndicesBits();
        float4 weights = i.blendWeight();
        float4 row0 = matBones[bones.x].row0 * weights.x + matBones[bones.y].row0 * weights.y
                    + matBones[bones.z].row0 * weights.z;
        float4 row1 = matBones[bones.x].row1 * weights.x + matBones[bones.y].row1 * weights.y
                    + matBones[bones.z].row1 * weights.z;
        float4 row2 = matBones[bones.x].row2 * weights.x + matBones[bones.y].row2 * weights.y
                    + matBones[bones.z].row2 * weights.z;
        float4 position = i.position();
        D3ObjectVertex v;
        v.position = float4(dot(row0, position), dot(row1, position), dot(row2, position), 1.0);
        v.normal = float3(dot(row0.xyz, normal), dot(row1.xyz, normal), dot(row2.xyz, normal));
        return v;
    }
};

/// Weather sway: the vertex moves along COLOR1.xyz by a sine of its phase
/// (COLOR1.w) plus the animated phase in randFloat.
public struct PoseWeatherSway : IMeshPose
{
    public static D3ObjectVertex pose(D3VertexIn i, float3 normal)
    {
        float4 sway = i.color1();
        float wave = sin(sway.w + randFloat.w + randFloat.y);
        D3ObjectVertex v;
        v.position = float4(i.position().xyz + wave * sway.xyz * deformationScale.x * weatherIntensity.x, 1.0);
        v.normal = normal;
        return v;
    }
};

// --------------------------------------------------------------------------
// colour
// --------------------------------------------------------------------------

/// COLOR0.rgb.
public interface ILegacyRgb
{
    static float3 rgb(D3VertexIn i, D3LegacyVertex v);
}

/// The vertex colour.
public struct RgbVertex : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v) { return i.color0().rgb; }
};

/// The legacy light rig: the primary point light, the linear point lights and
/// one cylindrical light, ambient + diffuse; VCADD adds the vertex colour on top.
public struct RgbLit<let VCADD : bool> : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v)
    {
        D3VertexLight light;
        d3AddPrimaryPointLight(v.view.xyz, v.normal, light);
        d3AddLinearPointLights(v.view.xyz, v.normal, light);
        d3AddCylindricalLight(v.view.xyz, v.normal, light);
        float3 rgb = light.ambient + light.diffuse;
        if (VCADD)
            rgb = rgb + i.color0().rgb;
        return rgb;
    }
};

/// Fades another colour toward the ambient colour by the vertex alpha.
public struct RgbAmbientBlend<T : ILegacyRgb> : ILegacyRgb
{
    public static float3 rgb(D3VertexIn i, D3LegacyVertex v)
    {
        return lerp(colAmbient.xyz, T.rgb(i, v), i.color0().w);
    }
};

/// COLOR0.a.
public interface ILegacyAlpha
{
    static float alpha(D3VertexIn i, D3LegacyVertex v);
}

/// The vertex alpha.
public struct AlphaVertex : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v) { return i.color0().w; }
};

/// A view-facing rim: `pow(dot(-V, N), 2 * edgealphaParams.x) * Factor.w`.
/// SAT clamps the facing term before the power, EXPSAT and MIN clamp the power,
/// ONEX inverts it (rim vs inverse rim).
public struct AlphaEdge<let SAT : bool, let MIN : bool, let ONEX : bool, let EXPSAT : bool> : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v)
    {
        float facing = dot(-normalize(v.view.xyz), v.normal);
        if (SAT)
            facing = saturate(facing);
        float edge = pow(facing, edgealphaParams.x + edgealphaParams.x);
        if (EXPSAT)
        {
            // otherwise fxc knows the power is non-negative and spells the clamp
            // as a bare min(., 1), which maps a NaN power (a back-facing
            // unclamped facing term) to 1 where saturate maps it to 0
            edge = d3SaturateExact(edge);
        }
        if (MIN)
            edge = min(edge, 1.0);
        if (ONEX)
            edge = 1.0 - edge;
        return edge * Factor.w;
    }
};

/// Another alpha scaled by the weather intensity.
public struct AlphaWeather<T : ILegacyAlpha> : ILegacyAlpha
{
    public static float alpha(D3VertexIn i, D3LegacyVertex v)
    {
        return T.alpha(i, v) * weatherIntensity.x;
    }
};

// --------------------------------------------------------------------------
// root
// --------------------------------------------------------------------------

[shader("vertex")]
public D3Interpolants texgen_vs_main<TPose : IMeshPose, TUv : IUvSource, TRgb : ILegacyRgb,
                                     TAlpha : ILegacyAlpha, TTex : ITexGenSet>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();

    D3ObjectVertex obj = TPose.pose(i, d3DecodeNormal(i.normalBits()));
    D3LegacyVertex v;
    v.model = obj.position;
    v.clip = mul(matWorldViewProj, v.model);
    v.view = mul(matWorldView, v.model);
    v.world = mul(matWorld, v.model).xyz;
    v.normal = normalize(mul((float3x3)matWorldView, obj.normal));
    v.fog = d3VertexFog(v.clip.z, v.world.z);

    o.setPosition(v.clip);
    o.setColor0(float4(TRgb.rgb(i, v), TAlpha.alpha(i, v)));
    o.setColor1(i.color1());
    TTex.write<TUv>(i, v, o);
    o.setFog(float4(v.fog, 0.0, 0.0, 0.0));
    o.setTexcoord6(float4(v.clip.z, 0.0, 0.0, 0.0));
    d3WriteClipPlanes(v.clip, o);
    return o;
}
