// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The interpolant layout -- what one retail program passes between stages.
//
// A Diablo III interpolant struct is not a fixed type. Each retail program
// declares the semantics its paired stage writes, in the order its author's
// `#ifdef`s left them, at the width the source declared -- including values the
// pixel shader never reads -- and fxc packs signature elements strictly in
// declaration order (a scalar only fills the free components of the register
// currently being packed). So order and width ARE the register layout: a
// `float FOG0` declared right after a `float3 COLOR1` lands in `.w` of that
// register, declared after a `float2` it lands in `.z`. The corpus uses the
// same semantic at different positions even within one subfamily, which is why
// no named struct can reproduce it.
//
// The layout is therefore data. `D3Interpolants` has `D3_IO_SLOTS` positions;
// for a slot the mapper (tools/d3_shaders_cfg.py) defines, from the retail
// signature in d3_perms/,
//     D3_IO_<n>=1  D3_IO_<n>_TYPE=float3  D3_IO_<n>_SEM=COLOR1
//     D3_IO_AT_COLOR1=io<n>
// and gate D2 checks every resulting signature row against retail.
//
// Roots never name a position. They read and write interpolants through the
// semantic accessors below, which widen to float4 on read and narrow on write;
// an accessor for a semantic the slot does not declare reads zero and writes
// nothing. `SV_ClipDistance` members exist only on the D3D targets.

implementing d3_shaders;

/// Placeholder for a semantic the current slot does not declare.
public struct D3Absent {};

public float4 d3_widen(float v)    { return float4(v, 0, 0, 0); }
public float4 d3_widen(float2 v)   { return float4(v, 0, 0); }
public float4 d3_widen(float3 v)   { return float4(v, 0); }
public float4 d3_widen(float4 v)   { return v; }
public float4 d3_widen(D3Absent v) { return float4(0, 0, 0, 0); }

public void d3_store(out float dst, float4 v)  { dst = v.x; }
public void d3_store(out float2 dst, float4 v) { dst = v.xy; }
public void d3_store(out float3 dst, float4 v) { dst = v.xyz; }
public void d3_store(out float4 dst, float4 v) { dst = v; }
public void d3_store(D3Absent dst, float4 v)   {}

#ifndef D3_IO_AT_SV_POSITION0
#define D3_IO_AT_SV_POSITION0 D3Absent()
#endif
#ifndef D3_IO_AT_COLOR0
#define D3_IO_AT_COLOR0 D3Absent()
#endif
#ifndef D3_IO_AT_COLOR1
#define D3_IO_AT_COLOR1 D3Absent()
#endif
#ifndef D3_IO_AT_FOG0
#define D3_IO_AT_FOG0 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD0
#define D3_IO_AT_TEXCOORD0 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD1
#define D3_IO_AT_TEXCOORD1 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD2
#define D3_IO_AT_TEXCOORD2 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD3
#define D3_IO_AT_TEXCOORD3 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD4
#define D3_IO_AT_TEXCOORD4 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD5
#define D3_IO_AT_TEXCOORD5 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD6
#define D3_IO_AT_TEXCOORD6 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD7
#define D3_IO_AT_TEXCOORD7 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD8
#define D3_IO_AT_TEXCOORD8 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD9
#define D3_IO_AT_TEXCOORD9 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD10
#define D3_IO_AT_TEXCOORD10 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD11
#define D3_IO_AT_TEXCOORD11 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD12
#define D3_IO_AT_TEXCOORD12 D3Absent()
#endif
#ifndef D3_IO_AT_TEXCOORD13
#define D3_IO_AT_TEXCOORD13 D3Absent()
#endif
#ifndef D3_IO_AT_SV_CLIPDISTANCE0
#define D3_IO_AT_SV_CLIPDISTANCE0 D3Absent()
#endif
#ifndef D3_IO_AT_SV_CLIPDISTANCE1
#define D3_IO_AT_SV_CLIPDISTANCE1 D3Absent()
#endif

public struct D3Interpolants
{
#ifdef D3_IO_0
    D3_IO_0_TYPE io0 : D3_IO_0_SEM;
#endif
#ifdef D3_IO_1
    D3_IO_1_TYPE io1 : D3_IO_1_SEM;
#endif
#ifdef D3_IO_2
    D3_IO_2_TYPE io2 : D3_IO_2_SEM;
#endif
#ifdef D3_IO_3
    D3_IO_3_TYPE io3 : D3_IO_3_SEM;
#endif
#ifdef D3_IO_4
    D3_IO_4_TYPE io4 : D3_IO_4_SEM;
#endif
#ifdef D3_IO_5
    D3_IO_5_TYPE io5 : D3_IO_5_SEM;
#endif
#ifdef D3_IO_6
    D3_IO_6_TYPE io6 : D3_IO_6_SEM;
#endif
#ifdef D3_IO_7
    D3_IO_7_TYPE io7 : D3_IO_7_SEM;
#endif
#ifdef D3_IO_8
    D3_IO_8_TYPE io8 : D3_IO_8_SEM;
#endif
#ifdef D3_IO_9
    D3_IO_9_TYPE io9 : D3_IO_9_SEM;
#endif
#ifdef D3_IO_10
    D3_IO_10_TYPE io10 : D3_IO_10_SEM;
#endif
#ifdef D3_IO_11
    D3_IO_11_TYPE io11 : D3_IO_11_SEM;
#endif
#ifdef D3_IO_12
    D3_IO_12_TYPE io12 : D3_IO_12_SEM;
#endif
#ifdef D3_IO_13
    D3_IO_13_TYPE io13 : D3_IO_13_SEM;
#endif
#ifdef D3_IO_14
    D3_IO_14_TYPE io14 : D3_IO_14_SEM;
#endif
#ifdef D3_IO_15
    D3_IO_15_TYPE io15 : D3_IO_15_SEM;
#endif


    /// Every declared interpolant cleared: the starting value of a vertex
    /// shader's output, so the semantic setters below always write into an
    /// initialized struct (fxc rejects a partially initialized `out` otherwise).
    public static D3Interpolants zero()
    {
        D3Interpolants o;
#ifdef D3_IO_0
        o.io0 = 0;
#endif
#ifdef D3_IO_1
        o.io1 = 0;
#endif
#ifdef D3_IO_2
        o.io2 = 0;
#endif
#ifdef D3_IO_3
        o.io3 = 0;
#endif
#ifdef D3_IO_4
        o.io4 = 0;
#endif
#ifdef D3_IO_5
        o.io5 = 0;
#endif
#ifdef D3_IO_6
        o.io6 = 0;
#endif
#ifdef D3_IO_7
        o.io7 = 0;
#endif
#ifdef D3_IO_8
        o.io8 = 0;
#endif
#ifdef D3_IO_9
        o.io9 = 0;
#endif
#ifdef D3_IO_10
        o.io10 = 0;
#endif
#ifdef D3_IO_11
        o.io11 = 0;
#endif
#ifdef D3_IO_12
        o.io12 = 0;
#endif
#ifdef D3_IO_13
        o.io13 = 0;
#endif
#ifdef D3_IO_14
        o.io14 = 0;
#endif
#ifdef D3_IO_15
        o.io15 = 0;
#endif
        return o;
    }

    public float4 position() { return d3_widen(D3_IO_AT_SV_POSITION0); }
    [mutating] public void setPosition(float4 v) { d3_store(D3_IO_AT_SV_POSITION0, v); }
    public float4 color0() { return d3_widen(D3_IO_AT_COLOR0); }
    [mutating] public void setColor0(float4 v) { d3_store(D3_IO_AT_COLOR0, v); }
    public float4 color1() { return d3_widen(D3_IO_AT_COLOR1); }
    [mutating] public void setColor1(float4 v) { d3_store(D3_IO_AT_COLOR1, v); }
    public float4 fog() { return d3_widen(D3_IO_AT_FOG0); }
    [mutating] public void setFog(float4 v) { d3_store(D3_IO_AT_FOG0, v); }
    public float4 texcoord0() { return d3_widen(D3_IO_AT_TEXCOORD0); }
    [mutating] public void setTexcoord0(float4 v) { d3_store(D3_IO_AT_TEXCOORD0, v); }
    public float4 texcoord1() { return d3_widen(D3_IO_AT_TEXCOORD1); }
    [mutating] public void setTexcoord1(float4 v) { d3_store(D3_IO_AT_TEXCOORD1, v); }
    public float4 texcoord2() { return d3_widen(D3_IO_AT_TEXCOORD2); }
    [mutating] public void setTexcoord2(float4 v) { d3_store(D3_IO_AT_TEXCOORD2, v); }
    public float4 texcoord3() { return d3_widen(D3_IO_AT_TEXCOORD3); }
    [mutating] public void setTexcoord3(float4 v) { d3_store(D3_IO_AT_TEXCOORD3, v); }
    public float4 texcoord4() { return d3_widen(D3_IO_AT_TEXCOORD4); }
    [mutating] public void setTexcoord4(float4 v) { d3_store(D3_IO_AT_TEXCOORD4, v); }
    public float4 texcoord5() { return d3_widen(D3_IO_AT_TEXCOORD5); }
    [mutating] public void setTexcoord5(float4 v) { d3_store(D3_IO_AT_TEXCOORD5, v); }
    public float4 texcoord6() { return d3_widen(D3_IO_AT_TEXCOORD6); }
    [mutating] public void setTexcoord6(float4 v) { d3_store(D3_IO_AT_TEXCOORD6, v); }
    public float4 texcoord7() { return d3_widen(D3_IO_AT_TEXCOORD7); }
    [mutating] public void setTexcoord7(float4 v) { d3_store(D3_IO_AT_TEXCOORD7, v); }
    public float4 texcoord8() { return d3_widen(D3_IO_AT_TEXCOORD8); }
    [mutating] public void setTexcoord8(float4 v) { d3_store(D3_IO_AT_TEXCOORD8, v); }
    public float4 texcoord9() { return d3_widen(D3_IO_AT_TEXCOORD9); }
    [mutating] public void setTexcoord9(float4 v) { d3_store(D3_IO_AT_TEXCOORD9, v); }
    public float4 texcoord10() { return d3_widen(D3_IO_AT_TEXCOORD10); }
    [mutating] public void setTexcoord10(float4 v) { d3_store(D3_IO_AT_TEXCOORD10, v); }
    public float4 texcoord11() { return d3_widen(D3_IO_AT_TEXCOORD11); }
    [mutating] public void setTexcoord11(float4 v) { d3_store(D3_IO_AT_TEXCOORD11, v); }
    public float4 texcoord12() { return d3_widen(D3_IO_AT_TEXCOORD12); }
    [mutating] public void setTexcoord12(float4 v) { d3_store(D3_IO_AT_TEXCOORD12, v); }
    public float4 texcoord13() { return d3_widen(D3_IO_AT_TEXCOORD13); }
    [mutating] public void setTexcoord13(float4 v) { d3_store(D3_IO_AT_TEXCOORD13, v); }
    public float4 clip0() { return d3_widen(D3_IO_AT_SV_CLIPDISTANCE0); }
    [mutating] public void setClip0(float4 v) { d3_store(D3_IO_AT_SV_CLIPDISTANCE0, v); }
    public float4 clip1() { return d3_widen(D3_IO_AT_SV_CLIPDISTANCE1); }
    [mutating] public void setClip1(float4 v) { d3_store(D3_IO_AT_SV_CLIPDISTANCE1, v); }
};
