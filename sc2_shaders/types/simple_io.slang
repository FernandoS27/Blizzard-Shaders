// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Simple family (simple.fx) IO structs + bindings.
//
// Mirrors simple.fx's SVertexFormatIn / SVertexFormatOut and its three
// globals.  The `.fx` compiles with `#pragma pack_matrix(row_major)`
// (shadersystem.fx:4), so p_mProjection is declared `row_major` here to
// match the reference's constant-buffer storage byte-for-byte (the
// validator feeds identical CB bytes into both legs, so the matrix
// storage convention must agree).  Names keep their `p_` prefix so they
// canonicalise to the same logical names the fxc reference emits
// (`mProjection` / `cColor` / `fAlphaThreshold` / `sTexture`).

implementing sc2_shaders;

// Vertex input — POSITION / COLOR0 / TEXCOORD0 (SVertexFormatIn).
public struct SimpleVSInput
{
    float4 vPosition : POSITION;
    float4 cColor    : COLOR0;
    float2 vUV       : TEXCOORD0;
};

// Vertex output / pixel input transport (SVertexFormatOut).  vHPos carries
// the clip-space position as a plain TEXCOORD1 interpolant (the original
// emits it alongside SV_Position).
public struct SimpleVSOutput
{
    float4 vPosition : SV_Position;
    float4 cColor    : COLOR0;
    float2 vUV       : TEXCOORD0;
    float4 vHPos     : TEXCOORD1;
};

// Pixel input — only the interpolants SimplePixelMain actually reads
// (cColor + vUV); matches the fxc reference's minimal PS input signature.
public struct SimplePSInput
{
    float4 cColor : COLOR0;
    float2 vUV    : TEXCOORD0;
};

// Globals ($Globals in the fxc reference).  row_major matches the .fx
// pack_matrix pragma; p_fAlphaThreshold is the alpha-test reference the
// PS clips against when b_iAlphaTest is set.
cbuffer SimpleGlobals : register(b0)
{
    row_major float4x4 p_mProjection;
    float4             p_cColor;
    float              p_fAlphaThreshold;
};

// Diffuse texture (texDecl2D(p_sTexture) -> Texture2D p_sTexture_t + sampler).
Texture2D<float4> p_sTexture_t : register(t0);
SamplerState      p_sTexture_s : register(s0);
