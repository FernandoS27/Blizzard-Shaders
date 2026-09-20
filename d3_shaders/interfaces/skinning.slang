// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Skinning: object-space position and normal of a mesh vertex.
//
// Skinned meshes blend up to three bones out of CBBones. BLENDINDICES holds bone
// numbers (the shader indexes the bone rows at 3x the index) and BLENDWEIGHT
// their weights; the normal stays in the UBYTE stream's raw [0, 255] units,
// because every consumer normalizes after transforming it.

implementing d3_shaders;

/// An object-space vertex: homogeneous position and untransformed normal.
public struct D3ObjectVertex
{
    public float4 position;
    public float3 normal;
};

public interface ISkin
{
    static D3ObjectVertex apply(D3VertexIn i);
}

/// A rigid mesh: the stream position with w forced to 1.
public struct SkinNone : ISkin
{
    public static D3ObjectVertex apply(D3VertexIn i)
    {
        D3ObjectVertex v;
        v.position = float4(i.position().xyz, 1.0);
        v.normal = float3(i.normalBits().xyz);
        return v;
    }
};

/// Three-bone linear blend: the weighted bone rows, then position (with the
/// stream's own w) and normal through the blended 3x4.
public struct SkinBlend3 : ISkin
{
    public static D3ObjectVertex apply(D3VertexIn i)
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
        float3 normal = float3(i.normalBits().xyz);
        D3ObjectVertex v;
        v.position = float4(dot(row0, position), dot(row1, position), dot(row2, position), 1.0);
        v.normal = float3(dot(row0.xyz, normal), dot(row1.xyz, normal), dot(row2.xyz, normal));
        return v;
    }
};
