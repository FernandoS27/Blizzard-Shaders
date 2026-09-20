// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Skinning of a whole object-space tangent frame.
//
// ISkin (interfaces/skinning.slang) delivers a position and a normal in the
// UBYTE stream's raw [0, 255] units, which is what Actor.fx lights with. The
// ActorIrrad.fx programs decode every packed direction to [-1, 1] first
// (`n * 2/255 - 1`) and only then rotate it through the bone blend, and the
// bump-mapped ones carry a tangent and a binormal through the same rotation.
// Decode-then-rotate is a different function from rotate-then-decode, so the
// frame is its own policy.

implementing d3_shaders;

/// An object-space vertex: homogeneous position and its tangent frame.
///
/// The directions are in whatever units the skin delivers them: decoded to
/// [-1, 1] by the frame skins below, raw stream bytes (and no tangent frame)
/// through `FrameByteNormal`.
public struct D3ObjectFrame
{
    public float4 position;
    public float3 normal;
    public float3 tangent;
    public float3 binormal;
};

/// A UBYTE-packed direction mapped from [0, 255] onto [-1, 1].
public float3 d3DecodeDirection(uint4 packed)
{
    return float3(packed.xyz) * (2.0 / 255.0) - 1.0;
}

public interface IFrameSkin
{
    static D3ObjectFrame apply(D3VertexIn i);
}

/// The ISkin vertex as a frame: position and normal exactly as that skin
/// delivers them, no tangent frame.
public struct FrameByteNormal<TSkin : ISkin> : IFrameSkin
{
    public static D3ObjectFrame apply(D3VertexIn i)
    {
        D3ObjectVertex v = TSkin.apply(i);
        D3ObjectFrame f;
        f.position = v.position;
        f.normal = v.normal;
        f.tangent = float3(0.0, 0.0, 0.0);
        f.binormal = float3(0.0, 0.0, 0.0);
        return f;
    }
};

/// A rigid mesh: the stream position with w forced to 1 and the decoded frame.
public struct FrameRigid : IFrameSkin
{
    public static D3ObjectFrame apply(D3VertexIn i)
    {
        D3ObjectFrame f;
        f.position = float4(i.position().xyz, 1.0);
        f.normal = d3DecodeDirection(i.normalBits());
        f.tangent = d3DecodeDirection(i.tangentBits());
        f.binormal = d3DecodeDirection(i.binormalBits());
        return f;
    }
};

/// A rigid mesh drawn with the stream position's own w.
public struct FrameStream : IFrameSkin
{
    public static D3ObjectFrame apply(D3VertexIn i)
    {
        D3ObjectFrame f;
        f.position = i.position();
        f.normal = d3DecodeDirection(i.normalBits());
        f.tangent = d3DecodeDirection(i.tangentBits());
        f.binormal = d3DecodeDirection(i.binormalBits());
        return f;
    }
};

/// Three-bone linear blend: the weighted bone rows, then the position (with the
/// stream's own w) and every decoded direction through the blended 3x4.
public struct FrameBlend3 : IFrameSkin
{
    public static D3ObjectFrame apply(D3VertexIn i)
    {
        uint4 bones = i.blendIndicesBits();
        float4 weights = i.blendWeight();
        float4 blend0 = matBones[bones.x].row0 * weights.x + matBones[bones.y].row0 * weights.y
                      + matBones[bones.z].row0 * weights.z;
        float4 blend1 = matBones[bones.x].row1 * weights.x + matBones[bones.y].row1 * weights.y
                      + matBones[bones.z].row1 * weights.z;
        float4 blend2 = matBones[bones.x].row2 * weights.x + matBones[bones.y].row2 * weights.y
                      + matBones[bones.z].row2 * weights.z;
        float4 position = i.position();
        float3 normal = d3DecodeDirection(i.normalBits());
        float3 tangent = d3DecodeDirection(i.tangentBits());
        float3 binormal = d3DecodeDirection(i.binormalBits());
        D3ObjectFrame f;
        f.position = float4(dot(blend0, position), dot(blend1, position), dot(blend2, position), 1.0);
        f.normal = float3(dot(blend0.xyz, normal), dot(blend1.xyz, normal), dot(blend2.xyz, normal));
        f.tangent = float3(dot(blend0.xyz, tangent), dot(blend1.xyz, tangent), dot(blend2.xyz, tangent));
        f.binormal = float3(dot(blend0.xyz, binormal), dot(blend1.xyz, binormal), dot(blend2.xyz, binormal));
        return f;
    }
};

/// Wind sway on a rigid mesh: COLOR1.xyz is a displacement direction and
/// COLOR1.w a phase; `sin(phase + randFloat.w + randFloat.y)` times the
/// direction, scaled by `deformationScale.x`, moves the object position.
public struct FrameWindSway : IFrameSkin
{
    public static D3ObjectFrame apply(D3VertexIn i)
    {
        float phase = (i.color1().w + randFloat.w) + randFloat.y;
        float3 sway = sin(phase) * i.color1().xyz;
        D3ObjectFrame f;
        f.position = float4(sway * deformationScale.x + i.position().xyz, 1.0);
        f.normal = d3DecodeDirection(i.normalBits());
        f.tangent = d3DecodeDirection(i.tangentBits());
        f.binormal = d3DecodeDirection(i.binormalBits());
        return f;
    }
};
