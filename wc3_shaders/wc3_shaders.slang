// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Module root for the Warcraft III Reforged shader reconstruction.
//
// This file is the single unit of compilation: every other `.slang`
// source in this tree declares `implementing wc3_shaders;` and is
// pulled in through one of the `__include` directives below. Each
// permutation the engine asks for instantiates one of the entry points
// in the bottom section (hd_ps / hd_vs / sd_* / sd_classic_*) with the
// appropriate policy types + compile-time flags.
//
// File layout:
//
//   types/        Constant buffer / texture / sampler bindings and the
//                 VS/PS I/O struct layouts.
//   math/         Stateless math primitives: color-space transforms,
//                 normal-map decode, analytic BRDF building blocks.
//   interfaces/   Compile-time policy interfaces (traits): fog mode,
//                 alpha test, skinning, vertex format, texture stages,
//                 material layer. These drive specialisation.
//   effects/      Higher-level "visual effects" that the HD body stack
//                 composes: cloak, fresnel overlay, multi-layer team
//                 blend.
//   ps/           Pixel-shader bodies, shared across entry points.
//   vs/           Vertex-shader helpers and per-vertex lighting.
//
// The entry points at the bottom map to:
//
//   hd_ps        — HD pipeline pixel shader (PBR / IBL).
//   hd_vs        — HD pipeline vertex shader.
//   crystal_ps   — HD refractive / transparent variant (gem / glass props).
//   sd_on_hd_ps  — SD assets rendered through the HD pipeline (PS).
//   sd_on_hd_vs  — SD assets rendered through the HD pipeline (VS).
//   sd_highspec_vs — SD pipeline per-vertex-lit VS.
//   sd_classic_ps — SD pipeline fixed-function texture-stage PS.
//   popcorn_vs    — PopcornFX particle vertex shader (4 modes ×
//                   3 inner-bit feature axes).
//   popcorn_ps    — PopcornFX particle pixel shader: COLOR pass
//                   (lit / diffuse / fog / soft-particles / alpha-LUT
//                   / gbuffer) and MOTION pass (motion-vector encode).

module wc3_shaders;

// Data types: constant buffers, bindings, VS/PS I/O structs.
__include "types/cb_structs";
__include "types/vs_io";
__include "types/ps_io";

// Math primitives.
__include "math/color";
__include "math/normal";
__include "math/brdf";

// Compile-time policy interfaces.
__include "interfaces/fog";
__include "interfaces/material";
__include "interfaces/alpha_test";
__include "interfaces/skinning";
__include "interfaces/vertex_format";
__include "interfaces/texture_stage";
__include "interfaces/popcorn_mode";

// Higher-level visual effects used by the PS bodies. The 2.0.0 cloak, fresnel
// overlay and multi-layer blend are gone: 3.0.0 folded all three into
// `hdFresnelAndCloak` / `sampleHDMaterial`, and P6 retired the last family
// that still called the old ones.
__include "effects/crystal_refract";

// HD mesh pixel-shader bodies, 3.0.0: material sampling + the fresnel/cloak
// finish, the two shadow lookups, clustered-forward lighting, the runtime fog
// stack, and the two depth-prepass bodies.
__include "ps/hd_ps_material";
__include "ps/hd_ps_shadows";
__include "ps/hd_ps_lighting";
__include "ps/fog_factor";
__include "ps/hd_ps_post";
__include "ps/hd_ps_prepass";

// Crystal pixel-shader body, 3.0.0: the alpha-tested depth prepass. Crystal's
// three material differences from HD live in effects/crystal_refract; the plain
// prepass and everything in the colour pass are HD's own bodies, called.
__include "ps/crystal_ps_body";

// SD-on-HD pixel-shader body, 3.0.0: the albedo-only material, the cloak and
// the depth prepass. Everything else this family needs is HD's.
__include "ps/sd_on_hd_ps_body";

// SD classic pixel-shader body (fixed-function texture stages).
__include "ps/sd_classic_ps_body";

// PopcornFX pixel-shader body.
__include "ps/popcorn_ps_body";

// Tonemap pixel-shader body.
__include "ps/tonemap_ps_body";

// Vertex-shader helpers.
__include "vs/vs_body";
__include "vs/hd_vs_body";
__include "vs/sd_vs_lighting";
__include "vs/terrain_vs_body";
__include "vs/foliage_vs_body";

// Entry points.
__include "hd_ps";
__include "hd_vs";
__include "crystal_ps";
__include "sd_on_hd_ps";
__include "sd_on_hd_vs";
__include "sd_highspec_vs";
__include "sd_classic_ps";
__include "water_vs";
__include "water_ps";
__include "popcorn_vs";
__include "popcorn_ps";
__include "tonemap_ps";
__include "sprite_vs";
__include "sprite_ps";
__include "terrain_vs";
__include "terrain_ps";
__include "foliage_vs";
__include "foliage_ps";
__include "cliffblightmiscterrain_vs";
__include "cliffblightmiscterrain_ps";
__include "distortion_ps";
__include "imgui_vs";
__include "imgui_ps";

// CMAA (Conservative Morphological Anti-Aliasing) post-process passes.
__include "cmaa_edge0_ps";
__include "cmaa_edge1_ps";
__include "cmaa_edge_combine_ps";
__include "cmaa_process_apply_ps";

// Bloom post-process passes (bright-pass extract + composite).
__include "bloomextract_ps";
__include "bloomcombine_ps";

// Separable Gaussian blur (shared by both blur axes; bridges the bloom passes).
__include "gaussianblur_ps";

// Bokeh depth of field (single-pass golden-angle spiral gather).
__include "depthoffield_ps";

// Small screen / world passes (P13).
__include "screen_passes";
__include "world_passes";
__include "cone_indicator";
