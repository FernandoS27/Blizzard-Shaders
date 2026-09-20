// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Where a surface vertex sits before the camera sees it: scenery, terrain and
// water meshes are rigid, skinned to three bones, or swayed by wind.
//
// Unlike the actor skin (interfaces/skinning.slang) a surface placement hands
// back the normal already unpacked from its UBYTE stream to [-1, 1]: every
// surface program decodes the normal first and only then transforms it, so a
// skinned normal is the blended rows applied to the signed vector.

implementing d3_shaders;

/// An object-space surface vertex: homogeneous position and signed normal.
public struct D3SurfaceObject
{
    public float4 position;
    public float3 normal;
};

/// A UBYTE direction stream (normal, tangent, binormal) as a signed vector.
public float3 d3UnpackDirection(uint4 packed)
{
    return float3(packed.xyz) * (2.0 / 255.0) - 1.0;
}

public interface ISurfacePlacement
{
    static D3SurfaceObject place(D3VertexIn i);
}

/// A rigid mesh: the stream position as it is, w included.
public struct RigidMesh : ISurfacePlacement
{
    public static D3SurfaceObject place(D3VertexIn i)
    {
        D3SurfaceObject s;
        s.position = i.position();
        s.normal = d3UnpackDirection(i.normalBits());
        return s;
    }
};

/// A rigid mesh whose stream w is ignored: the position is a point (w = 1).
public struct RigidMeshPoint : ISurfacePlacement
{
    public static D3SurfaceObject place(D3VertexIn i)
    {
        D3SurfaceObject s;
        s.position = float4(i.position().xyz, 1.0);
        s.normal = d3UnpackDirection(i.normalBits());
        return s;
    }
};

/// Three-bone linear blend skinning: the weighted bone rows applied to the
/// stream position (with its own w, the result a point) and to the signed normal.
public struct SkinnedMesh : ISurfacePlacement
{
    public static D3SurfaceObject place(D3VertexIn i)
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
        float3 normal = d3UnpackDirection(i.normalBits());
        D3SurfaceObject s;
        s.position = float4(dot(row0, position), dot(row1, position), dot(row2, position), 1.0);
        s.normal = float3(dot(row0.xyz, normal), dot(row1.xyz, normal), dot(row2.xyz, normal));
        return s;
    }
};

/// Wind sway: the vertex swings along its COLOR1 direction with a sine of its
/// COLOR1.w phase plus two per-instance randoms, scaled by the deformation
/// strength and, in weather-driven materials, by the weather intensity. The
/// normal is not swayed.
public struct WindSway<let WEATHER : bool> : ISurfacePlacement
{
    public static D3SurfaceObject place(D3VertexIn i)
    {
        float4 sway = i.color1();
        float4 position = i.position();
        float3 offset = sin(sway.w + randFloat.w + randFloat.y) * sway.xyz * deformationScale.x;
        if (WEATHER)
            offset = offset * weatherIntensity.x;
        D3SurfaceObject s;
        s.position = float4(offset + position.xyz, position.w);
        s.normal = d3UnpackDirection(i.normalBits());
        return s;
    }
};

/// One period of the foliage sway curve, sampled at 16 points; the last four
/// entries repeat the first so the interpolation wraps.
static const float kSwayCurve[20] = {
    -0.00111371896, -0.0808530897, -0.00966650620, 0.336331,
     0.0938256904,   0.0168618876, -0.0582040437, -0.0554788895,
     0.0434125364,  -0.0287690908,  0.0100579923,  0.0667788535,
     0.169124246,   -0.0381360091, -0.0850374475, -0.00856550597,
    -0.00111371896, -0.0808530897, -0.00966650620, 0.336331,
};

/// Noisy foliage sway: the phase is a per-instance random plus the vertex
/// height, looked up (linearly interpolated) in the sway curve; the vertex
/// swings along COLOR1 by that amount, horizontally by appearanceFX.x and
/// vertically by appearanceFX.y.
public struct CurveSway : ISurfacePlacement
{
    public static D3SurfaceObject place(D3VertexIn i)
    {
        float4 position = i.position();
        float phase = fmod((randFloat.z * 16.0 + abs(position.z)) * 0.0625, 1.0);
        float sample = phase * 16.0;
        int index = int(sample);
        float blend = phase * 16.0 - trunc(sample);
        float wave = lerp(kSwayCurve[index], kSwayCurve[index + 1], blend);
        D3SurfaceObject s;
        s.position = float4(wave * i.color1().xyz * appearanceFX.xxy + position.xyz, position.w);
        s.normal = d3UnpackDirection(i.normalBits());
        return s;
    }
};
