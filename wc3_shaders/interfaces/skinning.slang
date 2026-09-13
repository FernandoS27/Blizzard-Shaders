// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Compile-time skinning policy. `Rigid` passes vertex attributes through
// unchanged; `FourBoneSkinning` / `SDFourBoneSkinning` apply a 4-bone
// linear blend against the bone palette in `BonePalette`.
//
// Each bone is a float4x3 affine transform (transpose of the engine's
// 3x4 row-major upload). The position multiply puts the vector on the
// left — `mul(float4(pos, 1), M)` — and the normal/tangent use the
// top-left 3x3 so the translation column drops out.

implementing wc3_shaders;

public interface ISkinning
{
    static const bool isSkinned;

    static void transform(
        float3 objectPos, float3 objectNormal, float4 objectTangent,
        float4 weights, uint4 boneIndices,
        BonePalette bones,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent);
};

// Non-skinned geometry: the object-space attributes are forwarded as-is.
public struct Rigid : ISkinning
{
    static const bool isSkinned = false;

    static void transform(
        float3 objectPos, float3 objectNormal, float4 objectTangent,
        float4 weights, uint4 boneIndices,
        BonePalette bones,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent)
    {
        skinnedPos     = objectPos;
        skinnedNormal  = objectNormal;
        skinnedTangent = objectTangent.xyz;
    }
};

// HD 4-bone linear blend skinning.
// Weighted-sum the four bone matrices into `M`, then apply it to the
// position (affine) and to the rotation part for normal/tangent. The
// .y weight is summed first because the original shader was compiled
// that way, and preserving the accumulation order keeps the numerical
// output bit-identical.
// The `weightSum != 0` guard protects against unloaded or zero-weight
// vertices which would otherwise produce a zero-position spike.
public struct FourBoneSkinning : ISkinning
{
    static const bool isSkinned = true;

    static void transform(
        float3 objectPos, float3 objectNormal, float4 objectTangent,
        float4 weights, uint4 boneIndices,
        BonePalette bones,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent)
    {

        float weightSum = dot(weights, float4(1, 1, 1, 1));
        if (weightSum != 0.0)
        {
            float4x3 M  = bones.matrices[boneIndices.y] * weights.y;
            M          += bones.matrices[boneIndices.x] * weights.x;
            M          += bones.matrices[boneIndices.z] * weights.z;
            M          += bones.matrices[boneIndices.w] * weights.w;

            float3x3 R = (float3x3)M;

            // Full affine transform for the position (homogeneous w = 1).
            skinnedPos = mul(float4(objectPos, 1.0), M);

            // Normal / tangent use only the rotation portion. The HD path
            // skips the length rescale after skinning because the PS
            // renormalises both vectors when it reconstructs the
            // world-space basis.
            skinnedNormal  = mul(objectNormal,       R);
            skinnedTangent = mul(objectTangent.xyz,  R);
        }
        else
        {
            // Degenerate vertex (no weights): treat as rigid.
            skinnedPos     = objectPos;
            skinnedNormal  = objectNormal;
            skinnedTangent = objectTangent.xyz;
        }
    }
};

// SD-on-HD variant. Identical to FourBoneSkinning except the skinned
// normal is renormalised in the VS — the SD pixel shader paths use the
// raw (unrenormalised) world normal and expect the VS to have already
// produced a unit-length normal at transform time.
public struct SDFourBoneSkinning : ISkinning
{
    static const bool isSkinned = true;

    static void transform(
        float3 objectPos, float3 objectNormal, float4 objectTangent,
        float4 weights, uint4 boneIndices,
        BonePalette bones,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent)
    {
        float weightSum = dot(weights, float4(1, 1, 1, 1));
        if (weightSum != 0.0)
        {
            float4x3 M  = bones.matrices[boneIndices.y] * weights.y;
            M          += bones.matrices[boneIndices.x] * weights.x;
            M          += bones.matrices[boneIndices.z] * weights.z;
            M          += bones.matrices[boneIndices.w] * weights.w;

            float3x3 R = (float3x3)M;

            skinnedPos     = mul(float4(objectPos, 1.0), M);
            skinnedNormal  = mul(objectNormal,      R);

            // Required by the SD shading path, which does not renormalise
            // in the PS before evaluating NdotL/NdotV.
            float len2 = dot(skinnedNormal, skinnedNormal);
            skinnedNormal = skinnedNormal * rsqrt(len2);

            skinnedTangent = mul(objectTangent.xyz, R);
        }
        else
        {
            skinnedPos     = objectPos;
            skinnedNormal  = objectNormal;
            skinnedTangent = objectTangent.xyz;
        }
    }
};

// ---------------------------------------------------------------------------
// 3.0.0 HD mesh skinning
// ---------------------------------------------------------------------------
//
// Two axes instead of one. `IHDSkinning` still picks rigid vs four-bone, but
// 3.0.0 added a second choice — where the bone palette lives — so the skinned
// policy is generic over an `IBoneSource`. Nesting it inside the skinning
// policy rather than putting it beside it mirrors what the engine does: the
// palette source is invisible on an unskinned mesh, which is exactly why the
// 72 permutation slots collapse to 36 distinct programs.

// Apply a blended bone to a point. Row `k` dotted with the homogeneous
// position gives component `k` — the affine translation rides in row.w.
public float3 applyBoneToPoint(BoneTransform m, float3 p)
{
    float4 p4 = float4(p, 1.0);
    return float3(dot(m.row0, p4), dot(m.row1, p4), dot(m.row2, p4));
}

// Apply a blended bone to a direction: the same rows minus the translation
// column, so normals and tangents rotate without being displaced.
public float3 applyBoneToDirection(BoneTransform m, float3 d)
{
    return float3(dot(m.row0.xyz, d), dot(m.row1.xyz, d), dot(m.row2.xyz, d));
}

// Where the bone palette for this draw comes from.
public interface IBoneSource
{
    static BoneTransform fetch(int index);
};

// 256-bone constant buffer at b3 — the classic palette.
public struct ConstantBonePalette : IBoneSource
{
    static BoneTransform fetch(int index)
    {
        return hdVsCB3.bones[index];
    }
};

// Shared structured buffer at t16. One buffer serves many draws, so the index
// is biased by a per-draw base. That base is already an integer sitting in a
// float slot, hence `asint` rather than a numeric cast — reading it as a float
// would truncate every base above 2^24 and silently mis-skin the mesh.
public struct StructuredBonePalette : IBoneSource
{
    static BoneTransform fetch(int index)
    {
        return t_hdBones[index + asint(hdVsCB2.boneBufferBase)];
    }
};

public interface IHDSkinning
{
    static const bool isSkinned;

    static void transform(
        float3 objectPos, float3 objectNormal, float3 objectTangent,
        float4 weights, uint4 boneIndices,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent);
};

// Unskinned geometry: the object-space attributes are forwarded as-is. The
// bone source never appears here, so both BONE_BUFFER values compile to the
// same program.
public struct HDRigid : IHDSkinning
{
    static const bool isSkinned = false;

    static void transform(
        float3 objectPos, float3 objectNormal, float3 objectTangent,
        float4 weights, uint4 boneIndices,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent)
    {
        skinnedPos     = objectPos;
        skinnedNormal  = objectNormal;
        skinnedTangent = objectTangent;
    }
};

// Four-bone linear blend against `TBones`.
//
// The weights are summed and compared against zero before anything is read:
// a vertex with no weights is unskinned, and because the palette is then not
// touched at all a mesh may legitimately leave the bone streams as garbage on
// those vertices. Testing `!= 0` rather than `> 0` is deliberate — it is what
// the shipped shader does, and weights that cancel out reach the same arm.
public struct HDFourBoneSkinning<TBones : IBoneSource> : IHDSkinning
{
    static const bool isSkinned = true;

    static void transform(
        float3 objectPos, float3 objectNormal, float3 objectTangent,
        float4 weights, uint4 boneIndices,
        out float3 skinnedPos, out float3 skinnedNormal, out float3 skinnedTangent)
    {
        skinnedPos     = objectPos;
        skinnedNormal  = objectNormal;
        skinnedTangent = objectTangent;

        if (dot(weights, float4(1, 1, 1, 1)) != 0.0)
        {
            int4 b = int4(boneIndices);
            BoneTransform b0 = TBones.fetch(b.x);
            BoneTransform b1 = TBones.fetch(b.y);
            BoneTransform b2 = TBones.fetch(b.z);
            BoneTransform b3 = TBones.fetch(b.w);

            // Blend row by row, so the four fetched bones collapse into one
            // affine that is then applied once to each attribute.
            BoneTransform m;
            m.row0 = b0.row0 * weights.x + b1.row0 * weights.y
                   + b2.row0 * weights.z + b3.row0 * weights.w;
            m.row1 = b0.row1 * weights.x + b1.row1 * weights.y
                   + b2.row1 * weights.z + b3.row1 * weights.w;
            m.row2 = b0.row2 * weights.x + b1.row2 * weights.y
                   + b2.row2 * weights.z + b3.row2 * weights.w;

            skinnedPos     = applyBoneToPoint(m, objectPos);
            skinnedNormal  = applyBoneToDirection(m, objectNormal);
            skinnedTangent = applyBoneToDirection(m, objectTangent);
        }
    }
};
