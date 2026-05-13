// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// ImGui pixel shader entry point.
//
// The ImGui pipeline samples the bound font / texture atlas (t0),
// modulates by the per-vertex tint (COLOR0), and optionally sRGB-
// decodes the result before writing. The decode lets the engine drive
// draws into either a linear-storage or an sRGB-aware render target
// from the same DrawList without authoring two different shader
// bytecodes.
//
// Specialisation space — one compile-time bool:
//   HAS_SRGB_DECODE — apply IEC 61966-2-1 sRGB → linear EOTF on RGB.
//                     Alpha is never touched (matches every other
//                     gamma-aware path in this module).
//
// The two resulting permutations match the engine's imgui.bls layout:
//   perm_000  HAS_SRGB_DECODE=true   sRGB decode on the modulated RGB
//   perm_001  HAS_SRGB_DECODE=false  passthrough modulate

implementing wc3_shaders;

[shader("fragment")]
public float4 imgui_ps_main<let HAS_SRGB_DECODE : bool>(
    ImGuiPSInput input) : SV_Target0
{
    float4 sample    = t_imgui.Sample(s_imgui, input.uv);
    float4 modulated = input.vertColor * sample;

    if (HAS_SRGB_DECODE)
        return float4(srgbToLinearIEC(modulated.rgb), modulated.a);
    return modulated;
}
