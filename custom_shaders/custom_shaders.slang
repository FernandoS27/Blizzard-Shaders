// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Module root for custom / mod shaders that sit on top of the reconstructed
// Warcraft III Reforged pipeline.
//
// Everything in `wc3_shaders` is the faithful reconstruction of the shipped
// shaders — same entry points, same resource layout, same binding slots. This
// module pulls that in via `import wc3_shaders;` and is where drop-in
// alternative pixel / vertex shader bodies go: ones that match a shipped
// pipeline's VS/PS contract but replace its shading model. Consumers compile
// `custom_shaders.slang` directly (not `wc3_shaders.slang`) when building the
// variant BLS files.
//
// It ships empty. The toon and gritty HD variants that used to live here were
// written against the 2.0.0 HD contract (`VSOutput`, `PSInput`, `psCB2`, the
// `IFogMode` compile-time fog axes) and were removed when `hd_ps` / `hd_vs`
// moved to 3.0.0 — a variant of the 3.0.0 HD pipeline has to be written
// against `HDPSInput` / `HDVSOutput`, `hdPsCB1-2` / `hdVsCB1-3`, and the
// 10-bit / mixed-radix permutation layouts in compile_all_slang.py.
//
// To add one: write the body and entry point here, `__include` it below, add a
// family to custom_shaders.json (with `template_override` pointing at the
// shipped BLS it clones binding metadata from), and add a `map_<family>`
// function plus a MAPPERS entry in compile_all_slang.py.

module custom_shaders;

// Pull in the entire reconstructed pipeline (constant buffers,
// texture/sampler bindings, VS/PS I/O structs, BRDF helpers, IBL sampling,
// fresnel / cloak / multilayer effects, shadow lookups, debug
// visualisation). Everything marked `public` inside wc3_shaders is visible
// here.
import wc3_shaders;
