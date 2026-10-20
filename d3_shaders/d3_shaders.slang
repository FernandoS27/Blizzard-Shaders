// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Module root for the Diablo III shader reconstruction (`d3_shaders`).
//
// Diablo III ships its `.fx` über-shaders as 2,848 retail permutation keys that
// compile to 1,594 distinct programs. This module reproduces that permutation
// SET: every distinct retail program is one slot of one of eight bundles
// (pixel|vertex x legacy / surface / actor / utility), each slot behaviourally
// identical to its retail program under tools/d3_validate_all.py.
//
// Design: docs/D3_SHADERS_MODULE_DESIGN.md. Plan: docs/D3_SHADERS_PLAN.md.
//
// A slot is compiled by selecting one root entry point and specializing it:
//   * `-specialize` picks the algorithm (interfaces) and constants (value
//     generics) -- what the retail program COMPUTES;
//   * `-D D3_*` carries what the retail program DECLARES: its interpolant and
//     vertex-stream layouts (types/transport.slang, types/streams.slang) and
//     its texture registers. Those are measured from the retail bytes
//     (d3_perms/), not chosen, and the D2 gate checks them row for row.
//
// File layout:
//   types/       constant buffers, interpolant and vertex-stream layouts, textures
//   math/        packed-attribute decode, fog, lights
//   interfaces/  the policies roots are generic over
//   roots/       one file per domain root, each with its entry point(s)

module d3_shaders;

__include "portable";

__include "types/cbuffers";
__include "types/transport";
__include "types/streams";
__include "types/textures";
__include "types/textures_actor";
__include "types/textures_residue";
__include "types/texfilter_textures";
__include "types/textures_particle";
__include "types/textures_scene";

__include "math/decode";
__include "math/fog";
__include "math/lights";
__include "math/tex_matrix";
__include "math/surface";
__include "math/surface_lights";
__include "math/lights_specular";

__include "interfaces/skinning";
__include "interfaces/alpha_test";
__include "interfaces/skinning_single";
__include "interfaces/surface_placement";
__include "interfaces/vertex_alpha";
__include "interfaces/combiner";
__include "interfaces/flow";
__include "interfaces/frame_skinning";
__include "interfaces/combiner_actor_roles";
__include "interfaces/combiner_roles";

__include "roots/utility/filter";
__include "roots/actor/actor_vs";
__include "roots/actor/actor_ps";
__include "roots/legacy/legacy_aux_ps";
__include "roots/utility/cookie";
__include "roots/legacy/particle_vs";
__include "roots/surface/surface_vs";
__include "roots/surface/landscape_shading";
__include "roots/surface/landscape_ps";
__include "roots/surface/water_ps";
__include "roots/legacy/combiner_ps";
__include "roots/actor/irradiance_vs";
__include "roots/actor/irradiance_ps";
__include "roots/surface/scene_ps";
__include "roots/surface/scene_lighting";
__include "roots/surface/scene_models";
__include "roots/legacy/texgen";
__include "roots/legacy/texgen_vs";
__include "roots/actor/effects_vs";
__include "roots/actor/effects_ps";
__include "roots/legacy/legacy_aux_projected";
__include "roots/legacy/legacy_fixed_ps";
__include "roots/legacy/depth_clear_ps";
__include "roots/utility/texfilter_vs";
__include "roots/utility/cookie_tint";
__include "roots/utility/texfilter_ps";
__include "roots/utility/texfilter_copy";
__include "roots/utility/texfilter_blur";
__include "roots/utility/texfilter_scene";
__include "roots/utility/texfilter_depth";
__include "roots/legacy/combiner_particle";
__include "roots/legacy/texgen_soft";
__include "roots/utility/postfx_ps";
__include "roots/utility/postfx_tonemap";
__include "roots/utility/postfx_fxaa";
__include "roots/utility/postfx_minimap";
__include "roots/utility/postfx_vs";
__include "roots/surface/water_scene_variants";
__include "roots/actor/irradiance_gloss";
__include "roots/surface/scene_coverage";
__include "roots/surface/scene_fog_planes";
__include "roots/surface/scene_cracked_ground";
__include "roots/surface/scene_sphere_gloss";
__include "roots/surface/scene_unlit";
__include "roots/legacy/texgen_residue";
__include "roots/legacy/restore_vs";
__include "roots/surface/surface_residue_vs";
__include "roots/actor/actor_residue_vs";
