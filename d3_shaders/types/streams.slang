// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The vertex-stream layout -- which attributes one retail vertex shader reads.
//
// Like the interpolants (types/transport.slang) the input signature is data: a
// retail vertex shader declares the streams of its vertex declaration in that
// declaration's order, including streams it never reads, and the same semantic
// arrives as a packed `uint4` in one declaration and a `float` vector in
// another. `D3VertexIn` has `D3_IN_SLOTS` positions filled by the mapper,
//     D3_IN_<n>=1  D3_IN_<n>_TYPE=uint4  D3_IN_<n>_SEM=NORMAL0
//     D3_IN_AT_NORMAL0=in<n>
// and gate D2 checks the resulting signature against retail.
//
// A packed stream is read with the `...Bits()` accessor and a float stream with
// the plain one; calling the wrong one for the slot's declared type does not
// compile, so a mapper that picks the wrong vertex source fails loudly. An
// undeclared stream reads zero.

implementing d3_shaders;

public float4 d3_float4(float v)    { return float4(v, 0, 0, 0); }
public float4 d3_float4(float2 v)   { return float4(v, 0, 0); }
public float4 d3_float4(float3 v)   { return float4(v, 0); }
public float4 d3_float4(float4 v)   { return v; }
public float4 d3_float4(D3Absent v) { return float4(0, 0, 0, 0); }

public uint4 d3_bits(uint4 v)       { return v; }
// A float stream read through `...Bits()` truncates like the float4 case's
// implicit conversion does; these only exist so every accessor type-checks for
// a slot declaring a narrower float stream (a cloth TEXCOORD2 float3).
public uint4 d3_bits(float v)       { return uint4(uint(v), 0, 0, 0); }
public uint4 d3_bits(float2 v)      { return uint4(uint2(v), 0, 0); }
public uint4 d3_bits(float3 v)      { return uint4(uint3(v), 0); }
public uint4 d3_bits(D3Absent v)    { return uint4(0, 0, 0, 0); }

// ---------------------------------------------------------------------------
// The engine target (D3_TARGET_FLAKES): one fixed vertex stream
// ---------------------------------------------------------------------------
//
// The WhiteoutFlakes renderer feeds every mesh one record (and skinned geosets
// a second, bone stream) whatever the program, and every particle retail's own
// 56-byte vertex. Under the target `D3VertexIn` declares those elements instead
// of the retail positions (the location order IS the engine's element order):
//
//   FlakesMeshStream       0 POSITION float3     4 COLOR    float4 (UNORM16:
//                          1 NORMAL   float3       lane = colour | aux colour << 8)
//                          2 TEXCOORD float4     5 BINORMAL uint4
//                            (uv0.xy, uv1.xy)    6 BLENDWEIGHT  float4 } D3_FL_SKINNED
//                          3 TANGENT  float4     7 BLENDINDICES uint4  }
//   FlakesParticleStream   0 POSITION  1 COLOR  2 COLORB  3-6 TEXCOORD,
//                          TEXCOORDB..D (stage uv)  7 TEXCOORDE (quaternion)
//                          8 TEXCOORDF (centre, spin)
//
// The accessors stay the retail ones: the mapper still names each retail stream
// of the slot with its declared type (`D3_FL_<SEM>=uint4`), and `D3_IN_AT_<SEM>`
// becomes that stream's retail value rebuilt from the engine's -- the packed
// bytes re-encoded from the decoded floats, which the decodes make exact. A
// stream the slot does not declare reads zero, as in the retail target. Every
// semantic is index-free: slang appends a `0` to each one (COLOR1 -> COLOR10).

#ifdef D3_TARGET_FLAKES

/// One retail stream in the slot's declared type: the packed bytes of a UBYTE4
/// stream, the float lanes of any other.
public uint4 d3FlTyped(uint4 bits, float4 value, uint4 tag)   { return bits; }
public float d3FlTyped(uint4 bits, float4 value, float tag)   { return value.x; }
public float2 d3FlTyped(uint4 bits, float4 value, float2 tag) { return value.xy; }
public float3 d3FlTyped(uint4 bits, float4 value, float3 tag) { return value.xyz; }
public float4 d3FlTyped(uint4 bits, float4 value, float4 tag) { return value; }

/// A direction the engine decoded as `b * 2/255 - 1`, back to its bytes; a
/// deformed (cloth) direction rounds as retail's packing would.
public uint3 d3FlDirectionBytes(float3 v)
{
    return uint3(clamp(round((v + 1.0) * 127.5), 0.0, 255.0));
}

/// A UV the engine decoded as `u16 / scale + bias`, back to the UBYTE4 its
/// stream holds: each axis' u16 as (low byte, high byte).
public uint4 d3FlUvBytes(float2 uv, float scale, float bias)
{
    uint2 u = uint2(clamp(round((uv - bias) * scale), 0.0, 65535.0));
    return uint4(u.x & 0xFFu, u.x >> 8, u.y & 0xFFu, u.y >> 8);
}

/// UNORM8 as the input assembler converts it, the correctly rounded c / 255
/// (as bits: a multiply by 1/255 is one ulp off on half the bytes).
static const uint kD3FlUnorm8[256] = {
    0x00000000, 0x3B808081, 0x3C008081, 0x3C40C0C1, 0x3C808081, 0x3CA0A0A1, 0x3CC0C0C1, 0x3CE0E0E1,
    0x3D008081, 0x3D109091, 0x3D20A0A1, 0x3D30B0B1, 0x3D40C0C1, 0x3D50D0D1, 0x3D60E0E1, 0x3D70F0F1,
    0x3D808081, 0x3D888889, 0x3D909091, 0x3D989899, 0x3DA0A0A1, 0x3DA8A8A9, 0x3DB0B0B1, 0x3DB8B8B9,
    0x3DC0C0C1, 0x3DC8C8C9, 0x3DD0D0D1, 0x3DD8D8D9, 0x3DE0E0E1, 0x3DE8E8E9, 0x3DF0F0F1, 0x3DF8F8F9,
    0x3E008081, 0x3E048485, 0x3E088889, 0x3E0C8C8D, 0x3E109091, 0x3E149495, 0x3E189899, 0x3E1C9C9D,
    0x3E20A0A1, 0x3E24A4A5, 0x3E28A8A9, 0x3E2CACAD, 0x3E30B0B1, 0x3E34B4B5, 0x3E38B8B9, 0x3E3CBCBD,
    0x3E40C0C1, 0x3E44C4C5, 0x3E48C8C9, 0x3E4CCCCD, 0x3E50D0D1, 0x3E54D4D5, 0x3E58D8D9, 0x3E5CDCDD,
    0x3E60E0E1, 0x3E64E4E5, 0x3E68E8E9, 0x3E6CECED, 0x3E70F0F1, 0x3E74F4F5, 0x3E78F8F9, 0x3E7CFCFD,
    0x3E808081, 0x3E828283, 0x3E848485, 0x3E868687, 0x3E888889, 0x3E8A8A8B, 0x3E8C8C8D, 0x3E8E8E8F,
    0x3E909091, 0x3E929293, 0x3E949495, 0x3E969697, 0x3E989899, 0x3E9A9A9B, 0x3E9C9C9D, 0x3E9E9E9F,
    0x3EA0A0A1, 0x3EA2A2A3, 0x3EA4A4A5, 0x3EA6A6A7, 0x3EA8A8A9, 0x3EAAAAAB, 0x3EACACAD, 0x3EAEAEAF,
    0x3EB0B0B1, 0x3EB2B2B3, 0x3EB4B4B5, 0x3EB6B6B7, 0x3EB8B8B9, 0x3EBABABB, 0x3EBCBCBD, 0x3EBEBEBF,
    0x3EC0C0C1, 0x3EC2C2C3, 0x3EC4C4C5, 0x3EC6C6C7, 0x3EC8C8C9, 0x3ECACACB, 0x3ECCCCCD, 0x3ECECECF,
    0x3ED0D0D1, 0x3ED2D2D3, 0x3ED4D4D5, 0x3ED6D6D7, 0x3ED8D8D9, 0x3EDADADB, 0x3EDCDCDD, 0x3EDEDEDF,
    0x3EE0E0E1, 0x3EE2E2E3, 0x3EE4E4E5, 0x3EE6E6E7, 0x3EE8E8E9, 0x3EEAEAEB, 0x3EECECED, 0x3EEEEEEF,
    0x3EF0F0F1, 0x3EF2F2F3, 0x3EF4F4F5, 0x3EF6F6F7, 0x3EF8F8F9, 0x3EFAFAFB, 0x3EFCFCFD, 0x3EFEFEFF,
    0x3F008081, 0x3F018182, 0x3F028283, 0x3F038384, 0x3F048485, 0x3F058586, 0x3F068687, 0x3F078788,
    0x3F088889, 0x3F09898A, 0x3F0A8A8B, 0x3F0B8B8C, 0x3F0C8C8D, 0x3F0D8D8E, 0x3F0E8E8F, 0x3F0F8F90,
    0x3F109091, 0x3F119192, 0x3F129293, 0x3F139394, 0x3F149495, 0x3F159596, 0x3F169697, 0x3F179798,
    0x3F189899, 0x3F19999A, 0x3F1A9A9B, 0x3F1B9B9C, 0x3F1C9C9D, 0x3F1D9D9E, 0x3F1E9E9F, 0x3F1F9FA0,
    0x3F20A0A1, 0x3F21A1A2, 0x3F22A2A3, 0x3F23A3A4, 0x3F24A4A5, 0x3F25A5A6, 0x3F26A6A7, 0x3F27A7A8,
    0x3F28A8A9, 0x3F29A9AA, 0x3F2AAAAB, 0x3F2BABAC, 0x3F2CACAD, 0x3F2DADAE, 0x3F2EAEAF, 0x3F2FAFB0,
    0x3F30B0B1, 0x3F31B1B2, 0x3F32B2B3, 0x3F33B3B4, 0x3F34B4B5, 0x3F35B5B6, 0x3F36B6B7, 0x3F37B7B8,
    0x3F38B8B9, 0x3F39B9BA, 0x3F3ABABB, 0x3F3BBBBC, 0x3F3CBCBD, 0x3F3DBDBE, 0x3F3EBEBF, 0x3F3FBFC0,
    0x3F40C0C1, 0x3F41C1C2, 0x3F42C2C3, 0x3F43C3C4, 0x3F44C4C5, 0x3F45C5C6, 0x3F46C6C7, 0x3F47C7C8,
    0x3F48C8C9, 0x3F49C9CA, 0x3F4ACACB, 0x3F4BCBCC, 0x3F4CCCCD, 0x3F4DCDCE, 0x3F4ECECF, 0x3F4FCFD0,
    0x3F50D0D1, 0x3F51D1D2, 0x3F52D2D3, 0x3F53D3D4, 0x3F54D4D5, 0x3F55D5D6, 0x3F56D6D7, 0x3F57D7D8,
    0x3F58D8D9, 0x3F59D9DA, 0x3F5ADADB, 0x3F5BDBDC, 0x3F5CDCDD, 0x3F5DDDDE, 0x3F5EDEDF, 0x3F5FDFE0,
    0x3F60E0E1, 0x3F61E1E2, 0x3F62E2E3, 0x3F63E3E4, 0x3F64E4E5, 0x3F65E5E6, 0x3F66E6E7, 0x3F67E7E8,
    0x3F68E8E9, 0x3F69E9EA, 0x3F6AEAEB, 0x3F6BEBEC, 0x3F6CECED, 0x3F6DEDEE, 0x3F6EEEEF, 0x3F6FEFF0,
    0x3F70F0F1, 0x3F71F1F2, 0x3F72F2F3, 0x3F73F3F4, 0x3F74F4F5, 0x3F75F5F6, 0x3F76F6F7, 0x3F77F7F8,
    0x3F78F8F9, 0x3F79F9FA, 0x3F7AFAFB, 0x3F7BFBFC, 0x3F7CFCFD, 0x3F7DFDFE, 0x3F7EFEFF, 0x3F800000
};

public float4 d3FlUnorm8(uint4 c)
{
    return float4(asfloat(kD3FlUnorm8[c.x]), asfloat(kD3FlUnorm8[c.y]),
                  asfloat(kD3FlUnorm8[c.z]), asfloat(kD3FlUnorm8[c.w]));
}

// Each stream's source: its packed bytes, then its float lanes. A retail stream
// the engine has no counterpart for (cloth's rest-position TEXCOORD2, a mesh's
// TEXCOORD3-5, a particle's mesh streams) gets the closest value: the position
// or zero. The tangent's 4th byte and the normal's (always 0 in retail) are 0.
#define D3_FL_SRC_ZERO uint4(0, 0, 0, 0), float4(0.0, 0.0, 0.0, 0.0)
#define D3_FL_SRC_POSITION0 uint4(0, 0, 0, 0), float4(flPositionIn, 1.0)
#ifdef D3_FL_PARTICLE
#define D3_FL_SRC_NORMAL0 D3_FL_SRC_ZERO
#define D3_FL_SRC_COLOR0 uint4(round(flColor0In * 255.0)), flColor0In
#define D3_FL_SRC_COLOR1 uint4(round(flColor1In * 255.0)), flColor1In
#define D3_FL_SRC_TEXCOORD0 flUv0In, float4(flUv0In)
#define D3_FL_SRC_TEXCOORD1 flUv1In, float4(flUv1In)
#define D3_FL_SRC_TEXCOORD2 flUv2In, float4(flUv2In)
#define D3_FL_SRC_TEXCOORD3 flUv3In, float4(flUv3In)
#define D3_FL_SRC_TEXCOORD4 flOrientationIn, float4(flOrientationIn)
#define D3_FL_SRC_TEXCOORD5 uint4(0, 0, 0, 0), flCenterIn
#define D3_FL_SRC_TANGENT0 D3_FL_SRC_ZERO
#define D3_FL_SRC_BINORMAL0 D3_FL_SRC_ZERO
#define D3_FL_SRC_BLENDINDICES0 D3_FL_SRC_ZERO
#define D3_FL_SRC_BLENDWEIGHT0 D3_FL_SRC_ZERO
#else
#define D3_FL_SRC_NORMAL0 flNormalBits(), float4(flNormalIn, 0.0)
#define D3_FL_SRC_COLOR0 flColor0Bits(), d3FlUnorm8(flColor0Bits())
#define D3_FL_SRC_COLOR1 flColor1Bits(), d3FlUnorm8(flColor1Bits())
#define D3_FL_SRC_TEXCOORD0 d3FlUvBytes(flTexcoordIn.xy, 512.0, -64.0), float4(flTexcoordIn.xy, 0.0, 1.0)
#define D3_FL_SRC_TEXCOORD1 d3FlUvBytes(flTexcoordIn.zw, 8192.0, -4.0), float4(flTexcoordIn.zw, 0.0, 1.0)
#define D3_FL_SRC_TEXCOORD2 uint4(0, 0, 0, 0), float4(flPositionIn, 1.0)
#define D3_FL_SRC_TEXCOORD3 D3_FL_SRC_ZERO
#define D3_FL_SRC_TEXCOORD4 D3_FL_SRC_ZERO
#define D3_FL_SRC_TEXCOORD5 D3_FL_SRC_ZERO
#define D3_FL_SRC_TANGENT0 uint4(d3FlDirectionBytes(flTangentIn.xyz), 0), float4(flTangentIn.xyz, 0.0)
#define D3_FL_SRC_BINORMAL0 flBinormalIn, float4(flBinormalIn)
#ifdef D3_FL_SKINNED
#define D3_FL_SRC_BLENDINDICES0 flBlendIndicesIn, float4(flBlendIndicesIn)
#define D3_FL_SRC_BLENDWEIGHT0 uint4(round(flBlendWeightIn * 255.0)), flBlendWeightIn
#else
#define D3_FL_SRC_BLENDINDICES0 D3_FL_SRC_ZERO
#define D3_FL_SRC_BLENDWEIGHT0 D3_FL_SRC_ZERO
#endif
#endif

#ifdef D3_FL_POSITION0
#define D3_IN_AT_POSITION0 d3FlTyped(D3_FL_SRC_POSITION0, D3_FL_POSITION0(0))
#endif
#ifdef D3_FL_NORMAL0
#define D3_IN_AT_NORMAL0 d3FlTyped(D3_FL_SRC_NORMAL0, D3_FL_NORMAL0(0))
#endif
#ifdef D3_FL_COLOR0
#define D3_IN_AT_COLOR0 d3FlTyped(D3_FL_SRC_COLOR0, D3_FL_COLOR0(0))
#endif
#ifdef D3_FL_COLOR1
#define D3_IN_AT_COLOR1 d3FlTyped(D3_FL_SRC_COLOR1, D3_FL_COLOR1(0))
#endif
#ifdef D3_FL_TEXCOORD0
#define D3_IN_AT_TEXCOORD0 d3FlTyped(D3_FL_SRC_TEXCOORD0, D3_FL_TEXCOORD0(0))
#endif
#ifdef D3_FL_TEXCOORD1
#define D3_IN_AT_TEXCOORD1 d3FlTyped(D3_FL_SRC_TEXCOORD1, D3_FL_TEXCOORD1(0))
#endif
#ifdef D3_FL_TEXCOORD2
#define D3_IN_AT_TEXCOORD2 d3FlTyped(D3_FL_SRC_TEXCOORD2, D3_FL_TEXCOORD2(0))
#endif
#ifdef D3_FL_TEXCOORD3
#define D3_IN_AT_TEXCOORD3 d3FlTyped(D3_FL_SRC_TEXCOORD3, D3_FL_TEXCOORD3(0))
#endif
#ifdef D3_FL_TEXCOORD4
#define D3_IN_AT_TEXCOORD4 d3FlTyped(D3_FL_SRC_TEXCOORD4, D3_FL_TEXCOORD4(0))
#endif
#ifdef D3_FL_TEXCOORD5
#define D3_IN_AT_TEXCOORD5 d3FlTyped(D3_FL_SRC_TEXCOORD5, D3_FL_TEXCOORD5(0))
#endif
#ifdef D3_FL_BLENDINDICES0
#define D3_IN_AT_BLENDINDICES0 d3FlTyped(D3_FL_SRC_BLENDINDICES0, D3_FL_BLENDINDICES0(0))
#endif
#ifdef D3_FL_BLENDWEIGHT0
#define D3_IN_AT_BLENDWEIGHT0 d3FlTyped(D3_FL_SRC_BLENDWEIGHT0, D3_FL_BLENDWEIGHT0(0))
#endif
#ifdef D3_FL_TANGENT0
#define D3_IN_AT_TANGENT0 d3FlTyped(D3_FL_SRC_TANGENT0, D3_FL_TANGENT0(0))
#endif
#ifdef D3_FL_BINORMAL0
#define D3_IN_AT_BINORMAL0 d3FlTyped(D3_FL_SRC_BINORMAL0, D3_FL_BINORMAL0(0))
#endif

#endif

#ifndef D3_IN_AT_POSITION0
#define D3_IN_AT_POSITION0 D3Absent()
#endif
#ifndef D3_IN_AT_NORMAL0
#define D3_IN_AT_NORMAL0 D3Absent()
#endif
#ifndef D3_IN_AT_COLOR0
#define D3_IN_AT_COLOR0 D3Absent()
#endif
#ifndef D3_IN_AT_COLOR1
#define D3_IN_AT_COLOR1 D3Absent()
#endif
#ifndef D3_IN_AT_TEXCOORD0
#define D3_IN_AT_TEXCOORD0 D3Absent()
#endif
#ifndef D3_IN_AT_TEXCOORD1
#define D3_IN_AT_TEXCOORD1 D3Absent()
#endif
#ifndef D3_IN_AT_TEXCOORD2
#define D3_IN_AT_TEXCOORD2 D3Absent()
#endif
#ifndef D3_IN_AT_TEXCOORD3
#define D3_IN_AT_TEXCOORD3 D3Absent()
#endif
#ifndef D3_IN_AT_TEXCOORD4
#define D3_IN_AT_TEXCOORD4 D3Absent()
#endif
#ifndef D3_IN_AT_TEXCOORD5
#define D3_IN_AT_TEXCOORD5 D3Absent()
#endif
#ifndef D3_IN_AT_BLENDINDICES0
#define D3_IN_AT_BLENDINDICES0 D3Absent()
#endif
#ifndef D3_IN_AT_BLENDWEIGHT0
#define D3_IN_AT_BLENDWEIGHT0 D3Absent()
#endif
#ifndef D3_IN_AT_TANGENT0
#define D3_IN_AT_TANGENT0 D3Absent()
#endif
#ifndef D3_IN_AT_BINORMAL0
#define D3_IN_AT_BINORMAL0 D3Absent()
#endif

public struct D3VertexIn
{
#ifdef D3_IN_0
    D3_IN_0_TYPE in0 : D3_IN_0_SEM;
#endif
#ifdef D3_IN_1
    D3_IN_1_TYPE in1 : D3_IN_1_SEM;
#endif
#ifdef D3_IN_2
    D3_IN_2_TYPE in2 : D3_IN_2_SEM;
#endif
#ifdef D3_IN_3
    D3_IN_3_TYPE in3 : D3_IN_3_SEM;
#endif
#ifdef D3_IN_4
    D3_IN_4_TYPE in4 : D3_IN_4_SEM;
#endif
#ifdef D3_IN_5
    D3_IN_5_TYPE in5 : D3_IN_5_SEM;
#endif
#ifdef D3_IN_6
    D3_IN_6_TYPE in6 : D3_IN_6_SEM;
#endif
#ifdef D3_IN_7
    D3_IN_7_TYPE in7 : D3_IN_7_SEM;
#endif
#ifdef D3_IN_8
    D3_IN_8_TYPE in8 : D3_IN_8_SEM;
#endif
#ifdef D3_IN_9
    D3_IN_9_TYPE in9 : D3_IN_9_SEM;
#endif
#ifdef D3_IN_10
    D3_IN_10_TYPE in10 : D3_IN_10_SEM;
#endif
#ifdef D3_IN_11
    D3_IN_11_TYPE in11 : D3_IN_11_SEM;
#endif

#ifdef D3_TARGET_FLAKES
#ifdef D3_FL_PARTICLE
    // FlakesParticleStream: retail's own particle vertex, element for element.
    [[vk::location(0)]] float3 flPositionIn : POSITION;
    [[vk::location(1)]] float4 flColor0In : COLOR;
    [[vk::location(2)]] float4 flColor1In : COLORB;
    [[vk::location(3)]] uint4 flUv0In : TEXCOORD;
    [[vk::location(4)]] uint4 flUv1In : TEXCOORDB;
    [[vk::location(5)]] uint4 flUv2In : TEXCOORDC;
    [[vk::location(6)]] uint4 flUv3In : TEXCOORDD;
    [[vk::location(7)]] uint4 flOrientationIn : TEXCOORDE;
    [[vk::location(8)]] float4 flCenterIn : TEXCOORDF;
#else
    // FlakesMeshStream: the engine's mesh record, plus its bone stream when the
    // slot reads one.
    [[vk::location(0)]] float3 flPositionIn : POSITION;
    [[vk::location(1)]] float3 flNormalIn : NORMAL;
    [[vk::location(2)]] float4 flTexcoordIn : TEXCOORD;
    [[vk::location(3)]] float4 flTangentIn : TANGENT;
    [[vk::location(4)]] float4 flColorIn : COLOR;
    [[vk::location(5)]] uint4 flBinormalIn : BINORMAL;
#ifdef D3_FL_SKINNED
    [[vk::location(6)]] float4 flBlendWeightIn : BLENDWEIGHT;
    [[vk::location(7)]] uint4 flBlendIndicesIn : BLENDINDICES;
#endif

    uint4 flNormalBits() { return uint4(d3FlDirectionBytes(flNormalIn), 0); }
    // COLOR's lanes hold `colour | aux colour << 8`.
    uint4 flColor0Bits() { return uint4(round(flColorIn * 65535.0)) & 0xFFu; }
    uint4 flColor1Bits() { return uint4(round(flColorIn * 65535.0)) >> 8; }
#endif
#endif

    public float4 position() { return d3_float4(D3_IN_AT_POSITION0); }
    public uint4 positionBits() { return d3_bits(D3_IN_AT_POSITION0); }
    public float4 normal() { return d3_float4(D3_IN_AT_NORMAL0); }
    public uint4 normalBits() { return d3_bits(D3_IN_AT_NORMAL0); }
    public float4 color0() { return d3_float4(D3_IN_AT_COLOR0); }
    public uint4 color0Bits() { return d3_bits(D3_IN_AT_COLOR0); }
    public float4 color1() { return d3_float4(D3_IN_AT_COLOR1); }
    public uint4 color1Bits() { return d3_bits(D3_IN_AT_COLOR1); }
    public float4 texcoord0() { return d3_float4(D3_IN_AT_TEXCOORD0); }
    public uint4 texcoord0Bits() { return d3_bits(D3_IN_AT_TEXCOORD0); }
    public float4 texcoord1() { return d3_float4(D3_IN_AT_TEXCOORD1); }
    public uint4 texcoord1Bits() { return d3_bits(D3_IN_AT_TEXCOORD1); }
    public float4 texcoord2() { return d3_float4(D3_IN_AT_TEXCOORD2); }
    public uint4 texcoord2Bits() { return d3_bits(D3_IN_AT_TEXCOORD2); }
    public float4 texcoord3() { return d3_float4(D3_IN_AT_TEXCOORD3); }
    public uint4 texcoord3Bits() { return d3_bits(D3_IN_AT_TEXCOORD3); }
    public float4 texcoord4() { return d3_float4(D3_IN_AT_TEXCOORD4); }
    public uint4 texcoord4Bits() { return d3_bits(D3_IN_AT_TEXCOORD4); }
    public float4 texcoord5() { return d3_float4(D3_IN_AT_TEXCOORD5); }
    public uint4 texcoord5Bits() { return d3_bits(D3_IN_AT_TEXCOORD5); }
    public float4 blendIndices() { return d3_float4(D3_IN_AT_BLENDINDICES0); }
    public uint4 blendIndicesBits() { return d3_bits(D3_IN_AT_BLENDINDICES0); }
    public float4 blendWeight() { return d3_float4(D3_IN_AT_BLENDWEIGHT0); }
    public uint4 blendWeightBits() { return d3_bits(D3_IN_AT_BLENDWEIGHT0); }
    public float4 tangent() { return d3_float4(D3_IN_AT_TANGENT0); }
    public uint4 tangentBits() { return d3_bits(D3_IN_AT_TANGENT0); }
    public float4 binormal() { return d3_float4(D3_IN_AT_BINORMAL0); }
    public uint4 binormalBits() { return d3_bits(D3_IN_AT_BINORMAL0); }
};
