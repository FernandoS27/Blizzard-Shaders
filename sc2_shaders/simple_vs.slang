// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Simple family vertex shader (simple.fx : SimpleVertexMain).
//
// A minimal transform: clip-space position via p_mProjection, vertex
// colour modulated by p_cColor, UV passed through, and the clip position
// re-emitted as vHPos.  No compile-time axis (the retail Simple VS has a
// single, axis-less permutation).  The D3D (non-OpenGL) path only — the
// engine's `COMPILING_SHADER_FOR_OPENGL` branch is not reproduced here.

implementing sc2_shaders;

[shader("vertex")]
public SimpleVSOutput simple_vs_main(SimpleVSInput input)
{
    SimpleVSOutput output;
    output.vPosition = mul(input.vPosition, p_mProjection);
    output.vUV       = input.vUV;
    output.cColor    = input.cColor * p_cColor;
    output.vHPos     = output.vPosition;
    return output;
}
