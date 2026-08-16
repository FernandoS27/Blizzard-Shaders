// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Module root for the StarCraft II shader reconstruction (`sc2_shaders`).
//
// This is the SC2 analogue of `wc3_shaders`: the original shipped `.fx`
// shader families, rewritten as one idiomatic Slang translation unit and
// compiled per-family into BLS bundles whose permutation slots reproduce
// each family's retail permutation set, in retail cache order (design:
// docs/SC2_SHADERS_MODULE_DESIGN.md; plan: docs/SC2_SHADERS_IMPLEMENTATION.md).
//
// Every other `.slang` in this tree declares `implementing sc2_shaders;`
// and is pulled in through one of the `__include` directives below; each
// permutation the engine asks for instantiates one entry point with the
// appropriate compile-time `#if b_*` / specialisation axes.
//
// Validation: each entry is checked against the ORIGINAL `.fx` compile of
// the same decoded permutation (fxc ps_5_0 / vs_5_0 reference vs slangc
// candidate, both run through dxbc_interp on identical random inputs) by
// tools/sc2_validate_family.py — no Blizzard-fxc drift, purely our own
// toolchain.
//
// File layout (grows milestone by milestone):
//   types/   Constant buffers, texture/sampler bindings, VS/PS IO structs.
//   (ps/, vs/, math/, interfaces/, effects/ added as families land.)

module sc2_shaders;

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
__include "ps/model_main_shading";

// --- Entry points -----------------------------------------------------------
// Simple family (simple.fx) — the walking-skeleton family (M0).
__include "simple_vs";
__include "simple_ps";

// Model family (model.fx / psmainshading.fx : DefaultPixelMain) — the shared
// material/shading pixel root (M1). Standard shading mode, growing by feature.
__include "model_ps";
