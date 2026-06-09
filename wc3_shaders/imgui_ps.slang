// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// ImGui pixel shader entry point.
//
// The ImGui pipeline samples the bound font / texture atlas (t0),
// modulates by the per-vertex tint (COLOR0), and optionally sRGB-
// decodes the VERTEX COLOUR before writing. The decode lets the engine
// drive draws into an sRGB-aware render target: ImGui's per-vertex tints
// are authored in sRGB, so they must be linearised to blend correctly,
// after which the sRGB RTV re-encodes on store.
//
// Crucially the decode is applied to the vertex colour ONLY, not to the
// sampled texel. The bound texture carries its own format (an sRGB SRV
// is already linearised by the hardware sampler; a UNORM one isn't), so
// decoding the modulated product would double-decode an sRGB image and
// render it far too dark. For the font/solid-white atlas the texel is
// 1.0, so this is identical to the old "decode the product" form; it
// only differs for textured ImGui::Image draws (e.g. live thumbnails).
//
// Specialisation space — one compile-time bool:
//   HAS_SRGB_DECODE — apply IEC 61966-2-1 sRGB → linear EOTF on the
//                     vertex-colour RGB. Alpha is never touched.
//
// The two resulting permutations match the engine's imgui.bls layout:
//   perm_000  HAS_SRGB_DECODE=true   sRGB decode on the vertex-colour RGB
//   perm_001  HAS_SRGB_DECODE=false  passthrough modulate

implementing wc3_shaders;

[shader("fragment")]
public float4 imgui_ps_main<let HAS_SRGB_DECODE : bool>(
    ImGuiPSInput input) : SV_Target0
{
    float4 sample = t_imgui.Sample(s_imgui, input.uv);

    if (HAS_SRGB_DECODE)
        return float4(srgbToLinearIEC(input.vertColor.rgb) * sample.rgb,
                      input.vertColor.a * sample.a);
    return input.vertColor * sample;
}
