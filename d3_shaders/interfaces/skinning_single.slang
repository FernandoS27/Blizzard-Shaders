// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Rigid single-bone skinning: each vertex follows exactly one bone, named by
// BLENDINDICES.x, with no weight blend (BLENDWEIGHT may be present in the
// stream but is not read).

implementing d3_shaders;

/// One bone per vertex: position (with the stream's own w) and normal through
/// that bone's 3x4.
public struct SkinSingleBone : ISkin
{
    public static D3ObjectVertex apply(D3VertexIn i)
    {
        uint bone = i.blendIndicesBits().x;
        float4 position = i.position();
        float3 normal = float3(i.normalBits().xyz);
        D3ObjectVertex v;
        v.position = float4(dot(matBones[bone].row0, position), dot(matBones[bone].row1, position),
                            dot(matBones[bone].row2, position), 1.0);
        v.normal = float3(dot(matBones[bone].row0.xyz, normal), dot(matBones[bone].row1.xyz, normal),
                          dot(matBones[bone].row2.xyz, normal));
        return v;
    }
};
