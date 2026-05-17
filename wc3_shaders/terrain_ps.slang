// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Terrain pixel shader entry point.
//
// Specialisation space — four functional axes; the engine ships 128
// perms (7 raw bits) but bits 3/4/5 are reserved (collapse to the same
// output) and bit 1 (`HAS_NULL_PASS`) overrides every other axis with
// an empty stub.
//
//   HAS_NULL_PASS  — empty shader, no outputs (engine "skip" stub).
//                    Overrides every other axis: 64 of 128 perms map
//                    here. The output struct's color/MRT slots are
//                    gated out via `Conditional` so the dxbc emits no
//                    SV_Target entries, matching the shipped layout.
//   HAS_MRT        — emit SV_Target1 (depth-feedback in .x = view-Z)
//                    and SV_Target2 (encoded world normal + 1) in
//                    addition to SV_Target0.
//   HAS_SHADOWS    — sample the 3 cascaded shadow maps with PCF and
//                    multiply visibility into the dominant light.
//   HAS_TINT       — `TINT_OVERRIDE` in engine terms: per-splat layer
//                    color/UV substitution + the debug-viz output
//                    router. Bypasses the post-grade colour matrix.
//
// All of the heavy lifting lives in `terrainPSBody`
// (ps/terrain_ps_body.slang); this file just dispatches to it under
// the right specialisation and packs the result into the output
// payload.

implementing wc3_shaders;

// HAS_NULL_PASS / HAS_MRT migrated to WC3_TERRAIN_NULL_PASS / WC3_HAS_MRT
// preprocessor defines so TerrainPSOutput's color + MRT slots can be
// gated via #if instead of `Conditional<>`. WC3_HAS_COLOR is derived
// (= !WC3_TERRAIN_NULL_PASS) and WC3_HAS_MRT is set only when both
// !NULL_PASS && HAS_MRT — both done in compile_all_slang.py's
// map_terrain_ps. HAS_SHADOWS / HAS_TINT stay as slang template params
// (body logic only, no IO).
[shader("fragment")]
public TerrainPSOutput terrain_ps_main<
    let HAS_SHADOWS : bool,
    let HAS_TINT    : bool>(
    TerrainPSInput input)
{
    TerrainPSOutput output;

#if WC3_TERRAIN_NULL_PASS
    {
        // 64-perm "skip" stub — PSOutput has no fields on this perm
        // (gated by the WC3_HAS_COLOR / WC3_HAS_MRT #ifs in ps_io.slang),
        // so the dxbc emits a bare `ret` matching the shipped layout.
        return output;
    }
#else
    {

    TerrainShadeResult shaded = terrainPSBody<HAS_SHADOWS, HAS_TINT>(input);
    output.color = shaded.color;

#if WC3_HAS_MRT
    {
        // Depth-feedback target: world-space Z carried through the VS
        // payload.
        output.depthFeed = float4(shaded.viewZ, 0, 0, 1);

        if (HAS_TINT)
        {
            // Engine quirk: in TINT_OVERRIDE / debug-viz mode the
            // normal MRT is intentionally left uninitialised; only .w
            // gets a constant write so the depth-feedback resolver
            // still sees a valid alpha.
            output.normalEnc = float4(0, 0, 0, 1);
        }
        else
        {
            // Encoded world normal: (n + 1) · 0.5 in RGB, .w = 1.
            output.normalEnc = float4(shaded.worldNormal * 0.5 + 0.5, 1.0);
        }
    }
#endif

    return output;

    }
#endif
}
