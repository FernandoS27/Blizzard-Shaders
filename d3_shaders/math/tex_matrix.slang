// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The engine's texture matrices, addressed by stage number.
//
// CBMain carries twelve texture matrices (matTex0..matTex11). A texture stage
// transforms the homogeneous UV (u, v, 0, 1): the z column is multiplied by
// zero, so each output component is `dot(row.xyw, (u, v, 1))`. Legacy passes
// forward all four rows to the pixel stage, which divides by w when it
// projects.

implementing d3_shaders;

/// Row `row` of texture matrix `index`.
public float4 d3TextureMatrixRow(int index, int row)
{
    if (index == 0) return matTex0[row];
    if (index == 1) return matTex1[row];
    if (index == 2) return matTex2[row];
    if (index == 3) return matTex3[row];
    if (index == 4) return matTex4[row];
    if (index == 5) return matTex5[row];
    if (index == 6) return matTex6[row];
    if (index == 7) return matTex7[row];
    if (index == 8) return matTex8[row];
    if (index == 9) return matTex9[row];
    if (index == 10) return matTex10[row];
    return matTex11[row];
}

/// All four rows of texture matrix `index` applied to (u, v, 0, 1).
public float4 d3TextureMatrixTransform(int index, float2 uv)
{
    float3 h = float3(uv, 1.0);
    return float4(dot(d3TextureMatrixRow(index, 0).xyw, h), dot(d3TextureMatrixRow(index, 1).xyw, h),
                  dot(d3TextureMatrixRow(index, 2).xyw, h), dot(d3TextureMatrixRow(index, 3).xyw, h));
}
