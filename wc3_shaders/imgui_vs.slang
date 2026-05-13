// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// ImGui vertex shader entry point.
//
// Single permutation, no specialisation axes. The engine uploads a
// column-major 2D projection at cb2[8..11]: cb2[8] / cb2[9] are the X
// and Y basis columns and cb2[11] is the translation column. Column 2
// (cb2[10]) is unused — input positions are 2D, so the .z lane of the
// transform is elided.
//
// Three pass-throughs round out the entry: the UV travels TEXCOORD0
// into the PS, and the per-vertex tint travels COLOR0 (the PS
// modulates the sampled texel by it).
//
// The body's multiplication order (pos.y · col1 first, then mad with
// pos.x · col0, then add col3) mirrors the shipped engine's
// instruction sequence exactly — fxc / slangc are otherwise free to
// re-order commutative multiplies, but writing the operands in this
// specific order keeps the rebuilt VS DXBC bit-identical to the
// shipped one.

implementing wc3_shaders;

[shader("vertex")]
public ImGuiVSOutput imgui_vs_main(ImGuiVSInput input)
{
    ImGuiVSOutput output;

    // 2D projection: pos.x · col0 + pos.y · col1 + col3.
    float4 row     = imguiVsCB2.projection[1] * input.position.y;
    row            = input.position.x * imguiVsCB2.projection[0] + row;
    output.position = imguiVsCB2.projection[3] + row;

    output.uv        = input.uv;
    output.vertColor = input.vertColor;
    return output;
}
