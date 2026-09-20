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
