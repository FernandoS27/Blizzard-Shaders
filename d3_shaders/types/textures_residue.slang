// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture roles only residue ps_legacy programs bind (plan M7): the same
// declaration pattern as types/textures.slang -- per-slot registers from the
// measured resources, a default for roles a slot does not read, and a unique
// single-binding-space default for the non-D3D targets (400 and up, clear of
// textures.slang's range).

implementing d3_shaders;

// The engine target's sets and unbound-role registers, as in types/textures.slang
// (a #define does not cross __include).
#ifdef D3_TARGET_FLAKES
#define D3_VK_TSET 1
#define D3_VK_SSET 2
#ifndef D3_VK_T_BASE
#define D3_VK_T_BASE 0
#endif
#ifndef D3_VK_S_BASE
#define D3_VK_S_BASE 0
#endif
#define D3_VK_UNBOUND_T(binding) D3_VK_T_BASE
#define D3_VK_UNBOUND_S(binding) D3_VK_S_BASE
#else
#define D3_VK_TSET 0
#define D3_VK_SSET 0
#define D3_VK_UNBOUND_T(binding) binding
#define D3_VK_UNBOUND_S(binding) binding
#endif

#ifndef D3_T_alphaSampler
#define D3_T_alphaSampler t0
#endif
#ifndef D3_S_alphaSampler
#define D3_S_alphaSampler s0
#endif
#ifndef D3_VK_T_alphaSampler
#define D3_VK_T_alphaSampler D3_VK_UNBOUND_T(420)
#endif
#ifndef D3_VK_S_alphaSampler
#define D3_VK_S_alphaSampler D3_VK_UNBOUND_S(421)
#endif
[[vk::binding(D3_VK_T_alphaSampler, D3_VK_TSET)]] Texture2D alphaSampler : register(D3_T_alphaSampler);
[[vk::binding(D3_VK_S_alphaSampler, D3_VK_SSET)]] SamplerState alphaSampler_s : register(D3_S_alphaSampler);

#ifndef D3_T_ambientMapSampler
#define D3_T_ambientMapSampler t0
#endif
#ifndef D3_S_ambientMapSampler
#define D3_S_ambientMapSampler s0
#endif
#ifndef D3_VK_T_ambientMapSampler
#define D3_VK_T_ambientMapSampler D3_VK_UNBOUND_T(422)
#endif
#ifndef D3_VK_S_ambientMapSampler
#define D3_VK_S_ambientMapSampler D3_VK_UNBOUND_S(423)
#endif
[[vk::binding(D3_VK_T_ambientMapSampler, D3_VK_TSET)]] Texture2D ambientMapSampler : register(D3_T_ambientMapSampler);
[[vk::binding(D3_VK_S_ambientMapSampler, D3_VK_SSET)]] SamplerState ambientMapSampler_s : register(D3_S_ambientMapSampler);

#ifndef D3_T_noiseMapSampler
#define D3_T_noiseMapSampler t0
#endif
#ifndef D3_S_noiseMapSampler
#define D3_S_noiseMapSampler s0
#endif
#ifndef D3_VK_T_noiseMapSampler
#define D3_VK_T_noiseMapSampler D3_VK_UNBOUND_T(424)
#endif
#ifndef D3_VK_S_noiseMapSampler
#define D3_VK_S_noiseMapSampler D3_VK_UNBOUND_S(425)
#endif
[[vk::binding(D3_VK_T_noiseMapSampler, D3_VK_TSET)]] Texture2D noiseMapSampler : register(D3_T_noiseMapSampler);
[[vk::binding(D3_VK_S_noiseMapSampler, D3_VK_SSET)]] SamplerState noiseMapSampler_s : register(D3_S_noiseMapSampler);

#ifndef D3_T_texDiffuse1
#define D3_T_texDiffuse1 t0
#endif
#ifndef D3_S_texDiffuse1
#define D3_S_texDiffuse1 s0
#endif
#ifndef D3_VK_T_texDiffuse1
#define D3_VK_T_texDiffuse1 D3_VK_UNBOUND_T(428)
#endif
#ifndef D3_VK_S_texDiffuse1
#define D3_VK_S_texDiffuse1 D3_VK_UNBOUND_S(429)
#endif
[[vk::binding(D3_VK_T_texDiffuse1, D3_VK_TSET)]] Texture2D texDiffuse1 : register(D3_T_texDiffuse1);
[[vk::binding(D3_VK_S_texDiffuse1, D3_VK_SSET)]] SamplerState texDiffuse1_s : register(D3_S_texDiffuse1);

#ifndef D3_T_texFresnel
#define D3_T_texFresnel t0
#endif
#ifndef D3_S_texFresnel
#define D3_S_texFresnel s0
#endif
#ifndef D3_VK_T_texFresnel
#define D3_VK_T_texFresnel D3_VK_UNBOUND_T(430)
#endif
#ifndef D3_VK_S_texFresnel
#define D3_VK_S_texFresnel D3_VK_UNBOUND_S(431)
#endif
[[vk::binding(D3_VK_T_texFresnel, D3_VK_TSET)]] Texture2D texFresnel : register(D3_T_texFresnel);
[[vk::binding(D3_VK_S_texFresnel, D3_VK_SSET)]] SamplerState texFresnel_s : register(D3_S_texFresnel);

#ifndef D3_T_texLightMap
#define D3_T_texLightMap t0
#endif
#ifndef D3_S_texLightMap
#define D3_S_texLightMap s0
#endif
#ifndef D3_VK_T_texLightMap
#define D3_VK_T_texLightMap D3_VK_UNBOUND_T(434)
#endif
#ifndef D3_VK_S_texLightMap
#define D3_VK_S_texLightMap D3_VK_UNBOUND_S(435)
#endif
[[vk::binding(D3_VK_T_texLightMap, D3_VK_TSET)]] Texture2D texLightMap : register(D3_T_texLightMap);
[[vk::binding(D3_VK_S_texLightMap, D3_VK_SSET)]] SamplerState texLightMap_s : register(D3_S_texLightMap);
