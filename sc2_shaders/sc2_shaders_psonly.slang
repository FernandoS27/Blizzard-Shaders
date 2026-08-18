// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// PS-ONLY module root — a validation harness variant that includes only the
// pixel-shader body stack + PS entry points, omitting the vertex-shader includes.
// Used to validate the PS families (Model/Particle/Ribbon/Foliage + the M2 shading
// arms) INDEPENDENTLY of any in-progress VS work in the shared module: the VS files
// carry `#error` directives for un-transcribed features that would otherwise abort a
// PS compile whenever a PS perm's define set trips them (the whole module is one
// translation unit).  Mirror sc2_shaders.slang's PS include list; do not add VS
// includes here.

module sc2_shaders;

// --- Cross-backend intrinsic shims ------------------------------------------
__include "portable";

// --- Data types -------------------------------------------------------------
__include "types/simple_io";
__include "types/model_io";

// --- Pixel-shader body stack (Model/DefaultPixelMain families) --------------
__include "ps/model_material";
__include "ps/model_layers";
__include "ps/model_normal";
__include "ps/model_shadow";
__include "ps/model_lighting";
__include "ps/model_fog";
__include "ps/model_fow";
__include "ps/model_gbuffer";
__include "ps/model_envio";
__include "ps/model_parallax";
// --- Non-standard shading-mode arms (M2.1) ----------------------------------
__include "ps/model_layers_m2";
__include "ps/model_displace";
__include "ps/model_vectorui";
__include "ps/model_volume";
__include "ps/model_reflection";
__include "ps/model_cloaking";
__include "ps/model_creep";
__include "ps/model_terrain";
__include "ps/model_main_shading";

// --- Entry points -----------------------------------------------------------
__include "simple_vs";
__include "simple_ps";
__include "model_ps";
__include "ps/splatdirect_ps";
__include "ps/splatdeferred_ps";
__include "ps/terrainblend_ps";
__include "ps/water_ps";
