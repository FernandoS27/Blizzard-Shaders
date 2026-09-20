// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Decoding Diablo III's packed vertex attributes.
//
// Mesh streams store texture coordinates as two 8.8 fixed-point numbers in a
// UBYTE4: for each axis the whole part is in the second channel and the 1/256
// fraction in the first (`value = hi + lo / 256`), followed by an affine map
// into the stream's range. Normals, tangents and binormals are UBYTE4 too.

implementing d3_shaders;

/// The raw 8.8 fixed-point pair of a packed UV stream, before its range map.
public float2 d3UnpackUv(uint4 packed)
{
    return float2(float(packed.y) + float(packed.x) * (1.0 / 256.0),
                  float(packed.w) + float(packed.z) * (1.0 / 256.0));
}

/// A packed UV mapped into its stream's range: `raw * scale + bias`.
public float2 d3DecodeUv(uint4 packed, float scale, float bias)
{
    return d3UnpackUv(packed) * scale + bias;
}

/// Mesh UV set 0: [0, 256) fixed point onto [-64, 64).
public float2 d3DecodeUv0(uint4 packed) { return d3DecodeUv(packed, 0.5, -64.0); }

/// Mesh UV set 1: [0, 256) fixed point onto [-4, 4).
public float2 d3DecodeUv1(uint4 packed) { return d3DecodeUv(packed, 0.03125, -4.0); }

/// The 2x3 affine texture transform the engine uploads in a 4x4 slot: rows 0
/// and 1, columns x, y and the translation in w.
public float2 d3TexTransform(float4 row0, float4 row1, float2 uv)
{
    float3 h = float3(uv, 1.0);
    return float2(dot(row0.xyw, h), dot(row1.xyw, h));
}
