// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Foliage vertex shader entry point.
//
// Specialisation space — two compile-time bools that map onto the
// engine's three-bit foliage VS perm encoding:
//
//   HAS_SHADOWS — RECEIVE_SHADOWS && !SHADOW_PASS in engine terms.
//                 The `SHADOW_PASS` flag acts as a cascade-output
//                 suppression override — a draw rendering its own
//                 caster pass never emits cascade UVs even when the
//                 receive flag is also set.
//   HAS_WIND    — sample the wind-direction texture and pre-displace
//                 + swing the vertex XY in world space; Z is fixed.
//
// The engine's eight perms collapse to four functionally distinct
// outputs — the perm-mapper handles the redundant slots.

implementing wc3_shaders;

// HAS_SHADOWS migrated to the `WC3_HAS_SHADOWS` preprocessor define
// (see types/vs_io.slang) so the cascade slots in FoliageVSOutput can
// disappear via `#if` without slangc emitting them as `array<float4, 1>`
// in WGSL. HAS_WIND stays as a slang template param — it gates body
// logic only, not VS→PS struct fields, so the WGSL array-varying issue
// doesn't apply to it.
[shader("vertex")]
public FoliageVSOutput foliage_vs_main<
    let HAS_WIND : bool>(FoliageVSInput input)
{
    return foliageVSBody<HAS_WIND>(input);
}
