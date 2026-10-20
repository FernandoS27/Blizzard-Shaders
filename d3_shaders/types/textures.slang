// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Every texture and sampler a Diablo III program binds, by its retail role.
//
// A role is the name the Effects compiler gave the retail sampler object
// (`$diffuseMapt` / `$diffuseMaps` -> `diffuseMap`). Its register is NOT a
// property of the role: it is the role's position in the pass's texture stage
// list, so it moves with the features a permutation enables (a gloss map
// present or absent shifts every later stage down). The register is therefore
// per-slot data -- `-D D3_T_<role>=tN -D D3_S_<role>=sN` from the measured
// resources in d3_perms/ -- and D2 checks it.
//
// Every role is declared for every slot, so generic code type-checks whatever
// the slot binds; the defaults below only apply to roles a slot does not read,
// which slangc drops from the program. Overlapping defaults are expected and
// only warn (39001, suppressed by the sweep).
//
// `<role>_cmp` is the comparison sampler: the shadow map is sampled with
// SamplerComparisonState in some programs and plain SamplerState in others.
//
// Vulkan, OpenGL and WebGPU put every resource in one binding space, where D3D
// keeps t/s/b registers apart. For those targets the mapper also defines
// `D3_VK_T_<role>` / `D3_VK_S_<role>` (pixel textures 16+N, samplers 64+N; vertex
// 80+N / 112+N) so a texture and sampler sharing register N never collide. A role
// the slot does not bind keeps a unique default binding (200 and up): the
// non-D3D emitters can keep a declaration fxc would drop, and it must not land
// on a bound role's binding.
//
// The engine target (D3_TARGET_FLAKES) keeps the D3D registers and, on Vulkan
// and WebGPU, puts textures in set 1 and samplers in set 2 at the register plus
// the stage's offset (`D3_VK_T_<role>` / `D3_VK_S_<role>` from the mapper). It
// creates every cube as a cube-array view, so the one cube role is a
// `TextureCubeArray` read at slice 0 (roots/actor/irradiance_ps.slang). A role
// the slot does not bind sits where D3D puts it, at register 0 (the stage's
// `D3_VK_T_BASE` / `D3_VK_S_BASE`): a root that samples a role under another
// name than retail's reads what is bound there, as on D3D.

implementing d3_shaders;

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

#ifndef D3_T_alphaMap0Sampler
#define D3_T_alphaMap0Sampler t0
#endif
#ifndef D3_S_alphaMap0Sampler
#define D3_S_alphaMap0Sampler s0
#endif
#ifndef D3_VK_T_alphaMap0Sampler
#define D3_VK_T_alphaMap0Sampler D3_VK_UNBOUND_T(200)
#endif
#ifndef D3_VK_S_alphaMap0Sampler
#define D3_VK_S_alphaMap0Sampler D3_VK_UNBOUND_S(201)
#endif
[[vk::binding(D3_VK_T_alphaMap0Sampler, D3_VK_TSET)]] Texture2D alphaMap0Sampler : register(D3_T_alphaMap0Sampler);
[[vk::binding(D3_VK_S_alphaMap0Sampler, D3_VK_SSET)]] SamplerState alphaMap0Sampler_s : register(D3_S_alphaMap0Sampler);

#ifndef D3_T_alphaMap1Sampler
#define D3_T_alphaMap1Sampler t0
#endif
#ifndef D3_S_alphaMap1Sampler
#define D3_S_alphaMap1Sampler s0
#endif
#ifndef D3_VK_T_alphaMap1Sampler
#define D3_VK_T_alphaMap1Sampler D3_VK_UNBOUND_T(202)
#endif
#ifndef D3_VK_S_alphaMap1Sampler
#define D3_VK_S_alphaMap1Sampler D3_VK_UNBOUND_S(203)
#endif
[[vk::binding(D3_VK_T_alphaMap1Sampler, D3_VK_TSET)]] Texture2D alphaMap1Sampler : register(D3_T_alphaMap1Sampler);
[[vk::binding(D3_VK_S_alphaMap1Sampler, D3_VK_SSET)]] SamplerState alphaMap1Sampler_s : register(D3_S_alphaMap1Sampler);

#ifndef D3_T_alphaMap2Sampler
#define D3_T_alphaMap2Sampler t0
#endif
#ifndef D3_S_alphaMap2Sampler
#define D3_S_alphaMap2Sampler s0
#endif
#ifndef D3_VK_T_alphaMap2Sampler
#define D3_VK_T_alphaMap2Sampler D3_VK_UNBOUND_T(204)
#endif
#ifndef D3_VK_S_alphaMap2Sampler
#define D3_VK_S_alphaMap2Sampler D3_VK_UNBOUND_S(205)
#endif
[[vk::binding(D3_VK_T_alphaMap2Sampler, D3_VK_TSET)]] Texture2D alphaMap2Sampler : register(D3_T_alphaMap2Sampler);
[[vk::binding(D3_VK_S_alphaMap2Sampler, D3_VK_SSET)]] SamplerState alphaMap2Sampler_s : register(D3_S_alphaMap2Sampler);

#ifndef D3_T_backgroundMap
#define D3_T_backgroundMap t0
#endif
#ifndef D3_S_backgroundMap
#define D3_S_backgroundMap s0
#endif
#ifndef D3_VK_T_backgroundMap
#define D3_VK_T_backgroundMap D3_VK_UNBOUND_T(206)
#endif
#ifndef D3_VK_S_backgroundMap
#define D3_VK_S_backgroundMap D3_VK_UNBOUND_S(207)
#endif
[[vk::binding(D3_VK_T_backgroundMap, D3_VK_TSET)]] Texture2D backgroundMap : register(D3_T_backgroundMap);
[[vk::binding(D3_VK_S_backgroundMap, D3_VK_SSET)]] SamplerState backgroundMap_s : register(D3_S_backgroundMap);

#ifndef D3_T_bannerMap
#define D3_T_bannerMap t0
#endif
#ifndef D3_S_bannerMap
#define D3_S_bannerMap s0
#endif
#ifndef D3_VK_T_bannerMap
#define D3_VK_T_bannerMap D3_VK_UNBOUND_T(208)
#endif
#ifndef D3_VK_S_bannerMap
#define D3_VK_S_bannerMap D3_VK_UNBOUND_S(209)
#endif
[[vk::binding(D3_VK_T_bannerMap, D3_VK_TSET)]] Texture2D bannerMap : register(D3_T_bannerMap);
[[vk::binding(D3_VK_S_bannerMap, D3_VK_SSET)]] SamplerState bannerMap_s : register(D3_S_bannerMap);

#ifndef D3_T_diffuse1Sampler
#define D3_T_diffuse1Sampler t0
#endif
#ifndef D3_S_diffuse1Sampler
#define D3_S_diffuse1Sampler s0
#endif
#ifndef D3_VK_T_diffuse1Sampler
#define D3_VK_T_diffuse1Sampler D3_VK_UNBOUND_T(210)
#endif
#ifndef D3_VK_S_diffuse1Sampler
#define D3_VK_S_diffuse1Sampler D3_VK_UNBOUND_S(211)
#endif
[[vk::binding(D3_VK_T_diffuse1Sampler, D3_VK_TSET)]] Texture2D diffuse1Sampler : register(D3_T_diffuse1Sampler);
[[vk::binding(D3_VK_S_diffuse1Sampler, D3_VK_SSET)]] SamplerState diffuse1Sampler_s : register(D3_S_diffuse1Sampler);

#ifndef D3_T_diffuseMap
#define D3_T_diffuseMap t0
#endif
#ifndef D3_S_diffuseMap
#define D3_S_diffuseMap s0
#endif
#ifndef D3_VK_T_diffuseMap
#define D3_VK_T_diffuseMap D3_VK_UNBOUND_T(212)
#endif
#ifndef D3_VK_S_diffuseMap
#define D3_VK_S_diffuseMap D3_VK_UNBOUND_S(213)
#endif
[[vk::binding(D3_VK_T_diffuseMap, D3_VK_TSET)]] Texture2D diffuseMap : register(D3_T_diffuseMap);
[[vk::binding(D3_VK_S_diffuseMap, D3_VK_SSET)]] SamplerState diffuseMap_s : register(D3_S_diffuseMap);

#ifndef D3_T_diffuseOverlayMap
#define D3_T_diffuseOverlayMap t0
#endif
#ifndef D3_S_diffuseOverlayMap
#define D3_S_diffuseOverlayMap s0
#endif
#ifndef D3_VK_T_diffuseOverlayMap
#define D3_VK_T_diffuseOverlayMap D3_VK_UNBOUND_T(214)
#endif
#ifndef D3_VK_S_diffuseOverlayMap
#define D3_VK_S_diffuseOverlayMap D3_VK_UNBOUND_S(215)
#endif
[[vk::binding(D3_VK_T_diffuseOverlayMap, D3_VK_TSET)]] Texture2D diffuseOverlayMap : register(D3_T_diffuseOverlayMap);
[[vk::binding(D3_VK_S_diffuseOverlayMap, D3_VK_SSET)]] SamplerState diffuseOverlayMap_s : register(D3_S_diffuseOverlayMap);

#ifndef D3_T_diffuseSampler
#define D3_T_diffuseSampler t0
#endif
#ifndef D3_S_diffuseSampler
#define D3_S_diffuseSampler s0
#endif
#ifndef D3_VK_T_diffuseSampler
#define D3_VK_T_diffuseSampler D3_VK_UNBOUND_T(216)
#endif
#ifndef D3_VK_S_diffuseSampler
#define D3_VK_S_diffuseSampler D3_VK_UNBOUND_S(217)
#endif
[[vk::binding(D3_VK_T_diffuseSampler, D3_VK_TSET)]] Texture2D diffuseSampler : register(D3_T_diffuseSampler);
[[vk::binding(D3_VK_S_diffuseSampler, D3_VK_SSET)]] SamplerState diffuseSampler_s : register(D3_S_diffuseSampler);

#ifndef D3_T_diffuseSampler1
#define D3_T_diffuseSampler1 t0
#endif
#ifndef D3_S_diffuseSampler1
#define D3_S_diffuseSampler1 s0
#endif
#ifndef D3_VK_T_diffuseSampler1
#define D3_VK_T_diffuseSampler1 D3_VK_UNBOUND_T(218)
#endif
#ifndef D3_VK_S_diffuseSampler1
#define D3_VK_S_diffuseSampler1 D3_VK_UNBOUND_S(219)
#endif
[[vk::binding(D3_VK_T_diffuseSampler1, D3_VK_TSET)]] Texture2D diffuseSampler1 : register(D3_T_diffuseSampler1);
[[vk::binding(D3_VK_S_diffuseSampler1, D3_VK_SSET)]] SamplerState diffuseSampler1_s : register(D3_S_diffuseSampler1);

#ifndef D3_T_diffuseSampler2
#define D3_T_diffuseSampler2 t0
#endif
#ifndef D3_S_diffuseSampler2
#define D3_S_diffuseSampler2 s0
#endif
#ifndef D3_VK_T_diffuseSampler2
#define D3_VK_T_diffuseSampler2 D3_VK_UNBOUND_T(220)
#endif
#ifndef D3_VK_S_diffuseSampler2
#define D3_VK_S_diffuseSampler2 D3_VK_UNBOUND_S(221)
#endif
[[vk::binding(D3_VK_T_diffuseSampler2, D3_VK_TSET)]] Texture2D diffuseSampler2 : register(D3_T_diffuseSampler2);
[[vk::binding(D3_VK_S_diffuseSampler2, D3_VK_SSET)]] SamplerState diffuseSampler2_s : register(D3_S_diffuseSampler2);

#ifndef D3_T_diffuseSamplerA
#define D3_T_diffuseSamplerA t0
#endif
#ifndef D3_S_diffuseSamplerA
#define D3_S_diffuseSamplerA s0
#endif
#ifndef D3_VK_T_diffuseSamplerA
#define D3_VK_T_diffuseSamplerA D3_VK_UNBOUND_T(222)
#endif
#ifndef D3_VK_S_diffuseSamplerA
#define D3_VK_S_diffuseSamplerA D3_VK_UNBOUND_S(223)
#endif
[[vk::binding(D3_VK_T_diffuseSamplerA, D3_VK_TSET)]] Texture2D diffuseSamplerA : register(D3_T_diffuseSamplerA);
[[vk::binding(D3_VK_S_diffuseSamplerA, D3_VK_SSET)]] SamplerState diffuseSamplerA_s : register(D3_S_diffuseSamplerA);

#ifndef D3_T_diffuseSamplerB
#define D3_T_diffuseSamplerB t0
#endif
#ifndef D3_S_diffuseSamplerB
#define D3_S_diffuseSamplerB s0
#endif
#ifndef D3_VK_T_diffuseSamplerB
#define D3_VK_T_diffuseSamplerB D3_VK_UNBOUND_T(224)
#endif
#ifndef D3_VK_S_diffuseSamplerB
#define D3_VK_S_diffuseSamplerB D3_VK_UNBOUND_S(225)
#endif
[[vk::binding(D3_VK_T_diffuseSamplerB, D3_VK_TSET)]] Texture2D diffuseSamplerB : register(D3_T_diffuseSamplerB);
[[vk::binding(D3_VK_S_diffuseSamplerB, D3_VK_SSET)]] SamplerState diffuseSamplerB_s : register(D3_S_diffuseSamplerB);

#ifndef D3_T_diffuseTex
#define D3_T_diffuseTex t0
#endif
#ifndef D3_S_diffuseTex
#define D3_S_diffuseTex s0
#endif
#ifndef D3_VK_T_diffuseTex
#define D3_VK_T_diffuseTex D3_VK_UNBOUND_T(226)
#endif
#ifndef D3_VK_S_diffuseTex
#define D3_VK_S_diffuseTex D3_VK_UNBOUND_S(227)
#endif
[[vk::binding(D3_VK_T_diffuseTex, D3_VK_TSET)]] Texture2D diffuseTex : register(D3_T_diffuseTex);
[[vk::binding(D3_VK_S_diffuseTex, D3_VK_SSET)]] SamplerState diffuseTex_s : register(D3_S_diffuseTex);

#ifndef D3_T_environmentMap
#define D3_T_environmentMap t0
#endif
#ifndef D3_S_environmentMap
#define D3_S_environmentMap s0
#endif
#ifndef D3_VK_T_environmentMap
#define D3_VK_T_environmentMap D3_VK_UNBOUND_T(228)
#endif
#ifndef D3_VK_S_environmentMap
#define D3_VK_S_environmentMap D3_VK_UNBOUND_S(229)
#endif
[[vk::binding(D3_VK_T_environmentMap, D3_VK_TSET)]] Texture2D environmentMap : register(D3_T_environmentMap);
[[vk::binding(D3_VK_S_environmentMap, D3_VK_SSET)]] SamplerState environmentMap_s : register(D3_S_environmentMap);

#ifndef D3_T_environmentMapSampler
#define D3_T_environmentMapSampler t0
#endif
#ifndef D3_S_environmentMapSampler
#define D3_S_environmentMapSampler s0
#endif
#ifndef D3_VK_T_environmentMapSampler
#define D3_VK_T_environmentMapSampler D3_VK_UNBOUND_T(230)
#endif
#ifndef D3_VK_S_environmentMapSampler
#define D3_VK_S_environmentMapSampler D3_VK_UNBOUND_S(231)
#endif
[[vk::binding(D3_VK_T_environmentMapSampler, D3_VK_TSET)]] Texture2D environmentMapSampler : register(D3_T_environmentMapSampler);
[[vk::binding(D3_VK_S_environmentMapSampler, D3_VK_SSET)]] SamplerState environmentMapSampler_s : register(D3_S_environmentMapSampler);

#ifndef D3_T_flowSampler
#define D3_T_flowSampler t0
#endif
#ifndef D3_S_flowSampler
#define D3_S_flowSampler s0
#endif
#ifndef D3_VK_T_flowSampler
#define D3_VK_T_flowSampler D3_VK_UNBOUND_T(232)
#endif
#ifndef D3_VK_S_flowSampler
#define D3_VK_S_flowSampler D3_VK_UNBOUND_S(233)
#endif
[[vk::binding(D3_VK_T_flowSampler, D3_VK_TSET)]] Texture2D flowSampler : register(D3_T_flowSampler);
[[vk::binding(D3_VK_S_flowSampler, D3_VK_SSET)]] SamplerState flowSampler_s : register(D3_S_flowSampler);

#ifndef D3_T_flowSampler1
#define D3_T_flowSampler1 t0
#endif
#ifndef D3_S_flowSampler1
#define D3_S_flowSampler1 s0
#endif
#ifndef D3_VK_T_flowSampler1
#define D3_VK_T_flowSampler1 D3_VK_UNBOUND_T(234)
#endif
#ifndef D3_VK_S_flowSampler1
#define D3_VK_S_flowSampler1 D3_VK_UNBOUND_S(235)
#endif
[[vk::binding(D3_VK_T_flowSampler1, D3_VK_TSET)]] Texture2D flowSampler1 : register(D3_T_flowSampler1);
[[vk::binding(D3_VK_S_flowSampler1, D3_VK_SSET)]] SamplerState flowSampler1_s : register(D3_S_flowSampler1);

#ifndef D3_T_flowSampler2
#define D3_T_flowSampler2 t0
#endif
#ifndef D3_S_flowSampler2
#define D3_S_flowSampler2 s0
#endif
#ifndef D3_VK_T_flowSampler2
#define D3_VK_T_flowSampler2 D3_VK_UNBOUND_T(236)
#endif
#ifndef D3_VK_S_flowSampler2
#define D3_VK_S_flowSampler2 D3_VK_UNBOUND_S(237)
#endif
[[vk::binding(D3_VK_T_flowSampler2, D3_VK_TSET)]] Texture2D flowSampler2 : register(D3_T_flowSampler2);
[[vk::binding(D3_VK_S_flowSampler2, D3_VK_SSET)]] SamplerState flowSampler2_s : register(D3_S_flowSampler2);

#ifndef D3_T_flowSampler3
#define D3_T_flowSampler3 t0
#endif
#ifndef D3_S_flowSampler3
#define D3_S_flowSampler3 s0
#endif
#ifndef D3_VK_T_flowSampler3
#define D3_VK_T_flowSampler3 D3_VK_UNBOUND_T(238)
#endif
#ifndef D3_VK_S_flowSampler3
#define D3_VK_S_flowSampler3 D3_VK_UNBOUND_S(239)
#endif
[[vk::binding(D3_VK_T_flowSampler3, D3_VK_TSET)]] Texture2D flowSampler3 : register(D3_T_flowSampler3);
[[vk::binding(D3_VK_S_flowSampler3, D3_VK_SSET)]] SamplerState flowSampler3_s : register(D3_S_flowSampler3);

#ifndef D3_T_fogSampler
#define D3_T_fogSampler t0
#endif
#ifndef D3_S_fogSampler
#define D3_S_fogSampler s0
#endif
#ifndef D3_VK_T_fogSampler
#define D3_VK_T_fogSampler D3_VK_UNBOUND_T(240)
#endif
#ifndef D3_VK_S_fogSampler
#define D3_VK_S_fogSampler D3_VK_UNBOUND_S(241)
#endif
[[vk::binding(D3_VK_T_fogSampler, D3_VK_TSET)]] Texture2D fogSampler : register(D3_T_fogSampler);
[[vk::binding(D3_VK_S_fogSampler, D3_VK_SSET)]] SamplerState fogSampler_s : register(D3_S_fogSampler);

#ifndef D3_T_glossMap
#define D3_T_glossMap t0
#endif
#ifndef D3_S_glossMap
#define D3_S_glossMap s0
#endif
#ifndef D3_VK_T_glossMap
#define D3_VK_T_glossMap D3_VK_UNBOUND_T(242)
#endif
#ifndef D3_VK_S_glossMap
#define D3_VK_S_glossMap D3_VK_UNBOUND_S(243)
#endif
[[vk::binding(D3_VK_T_glossMap, D3_VK_TSET)]] Texture2D glossMap : register(D3_T_glossMap);
[[vk::binding(D3_VK_S_glossMap, D3_VK_SSET)]] SamplerState glossMap_s : register(D3_S_glossMap);

#ifndef D3_T_glossMapSampler
#define D3_T_glossMapSampler t0
#endif
#ifndef D3_S_glossMapSampler
#define D3_S_glossMapSampler s0
#endif
#ifndef D3_VK_T_glossMapSampler
#define D3_VK_T_glossMapSampler D3_VK_UNBOUND_T(244)
#endif
#ifndef D3_VK_S_glossMapSampler
#define D3_VK_S_glossMapSampler D3_VK_UNBOUND_S(245)
#endif
[[vk::binding(D3_VK_T_glossMapSampler, D3_VK_TSET)]] Texture2D glossMapSampler : register(D3_T_glossMapSampler);
[[vk::binding(D3_VK_S_glossMapSampler, D3_VK_SSET)]] SamplerState glossMapSampler_s : register(D3_S_glossMapSampler);

#ifndef D3_T_glowMap
#define D3_T_glowMap t0
#endif
#ifndef D3_S_glowMap
#define D3_S_glowMap s0
#endif
#ifndef D3_VK_T_glowMap
#define D3_VK_T_glowMap D3_VK_UNBOUND_T(246)
#endif
#ifndef D3_VK_S_glowMap
#define D3_VK_S_glowMap D3_VK_UNBOUND_S(247)
#endif
[[vk::binding(D3_VK_T_glowMap, D3_VK_TSET)]] Texture2D glowMap : register(D3_T_glowMap);
[[vk::binding(D3_VK_S_glowMap, D3_VK_SSET)]] SamplerState glowMap_s : register(D3_S_glowMap);

#ifndef D3_T_glowSampler
#define D3_T_glowSampler t0
#endif
#ifndef D3_S_glowSampler
#define D3_S_glowSampler s0
#endif
#ifndef D3_VK_T_glowSampler
#define D3_VK_T_glowSampler D3_VK_UNBOUND_T(248)
#endif
#ifndef D3_VK_S_glowSampler
#define D3_VK_S_glowSampler D3_VK_UNBOUND_S(249)
#endif
[[vk::binding(D3_VK_T_glowSampler, D3_VK_TSET)]] Texture2D glowSampler : register(D3_T_glowSampler);
[[vk::binding(D3_VK_S_glowSampler, D3_VK_SSET)]] SamplerState glowSampler_s : register(D3_S_glowSampler);

#ifndef D3_T_heroTintMap
#define D3_T_heroTintMap t0
#endif
#ifndef D3_S_heroTintMap
#define D3_S_heroTintMap s0
#endif
#ifndef D3_VK_T_heroTintMap
#define D3_VK_T_heroTintMap D3_VK_UNBOUND_T(250)
#endif
#ifndef D3_VK_S_heroTintMap
#define D3_VK_S_heroTintMap D3_VK_UNBOUND_S(251)
#endif
[[vk::binding(D3_VK_T_heroTintMap, D3_VK_TSET)]] Texture2D heroTintMap : register(D3_T_heroTintMap);
[[vk::binding(D3_VK_S_heroTintMap, D3_VK_SSET)]] SamplerState heroTintMap_s : register(D3_S_heroTintMap);

#ifndef D3_T_irradianceMap
#define D3_T_irradianceMap t0
#endif
#ifndef D3_S_irradianceMap
#define D3_S_irradianceMap s0
#endif
#ifndef D3_VK_T_irradianceMap
#define D3_VK_T_irradianceMap D3_VK_UNBOUND_T(252)
#endif
#ifndef D3_VK_S_irradianceMap
#define D3_VK_S_irradianceMap D3_VK_UNBOUND_S(253)
#endif
#ifdef D3_TARGET_FLAKES
[[vk::binding(D3_VK_T_irradianceMap, D3_VK_TSET)]] TextureCubeArray irradianceMap : register(D3_T_irradianceMap);
#else
[[vk::binding(D3_VK_T_irradianceMap, D3_VK_TSET)]] TextureCube irradianceMap : register(D3_T_irradianceMap);
#endif
[[vk::binding(D3_VK_S_irradianceMap, D3_VK_SSET)]] SamplerState irradianceMap_s : register(D3_S_irradianceMap);

#ifndef D3_T_layer1AlphaMap
#define D3_T_layer1AlphaMap t0
#endif
#ifndef D3_S_layer1AlphaMap
#define D3_S_layer1AlphaMap s0
#endif
#ifndef D3_VK_T_layer1AlphaMap
#define D3_VK_T_layer1AlphaMap D3_VK_UNBOUND_T(254)
#endif
#ifndef D3_VK_S_layer1AlphaMap
#define D3_VK_S_layer1AlphaMap D3_VK_UNBOUND_S(255)
#endif
[[vk::binding(D3_VK_T_layer1AlphaMap, D3_VK_TSET)]] Texture2D layer1AlphaMap : register(D3_T_layer1AlphaMap);
[[vk::binding(D3_VK_S_layer1AlphaMap, D3_VK_SSET)]] SamplerState layer1AlphaMap_s : register(D3_S_layer1AlphaMap);

#ifndef D3_T_layer1DiffuseMap
#define D3_T_layer1DiffuseMap t0
#endif
#ifndef D3_S_layer1DiffuseMap
#define D3_S_layer1DiffuseMap s0
#endif
#ifndef D3_VK_T_layer1DiffuseMap
#define D3_VK_T_layer1DiffuseMap D3_VK_UNBOUND_T(256)
#endif
#ifndef D3_VK_S_layer1DiffuseMap
#define D3_VK_S_layer1DiffuseMap D3_VK_UNBOUND_S(257)
#endif
[[vk::binding(D3_VK_T_layer1DiffuseMap, D3_VK_TSET)]] Texture2D layer1DiffuseMap : register(D3_T_layer1DiffuseMap);
[[vk::binding(D3_VK_S_layer1DiffuseMap, D3_VK_SSET)]] SamplerState layer1DiffuseMap_s : register(D3_S_layer1DiffuseMap);

#ifndef D3_T_layer2AlphaMap
#define D3_T_layer2AlphaMap t0
#endif
#ifndef D3_S_layer2AlphaMap
#define D3_S_layer2AlphaMap s0
#endif
#ifndef D3_VK_T_layer2AlphaMap
#define D3_VK_T_layer2AlphaMap D3_VK_UNBOUND_T(258)
#endif
#ifndef D3_VK_S_layer2AlphaMap
#define D3_VK_S_layer2AlphaMap D3_VK_UNBOUND_S(259)
#endif
[[vk::binding(D3_VK_T_layer2AlphaMap, D3_VK_TSET)]] Texture2D layer2AlphaMap : register(D3_T_layer2AlphaMap);
[[vk::binding(D3_VK_S_layer2AlphaMap, D3_VK_SSET)]] SamplerState layer2AlphaMap_s : register(D3_S_layer2AlphaMap);

#ifndef D3_T_layer2DiffuseMap
#define D3_T_layer2DiffuseMap t0
#endif
#ifndef D3_S_layer2DiffuseMap
#define D3_S_layer2DiffuseMap s0
#endif
#ifndef D3_VK_T_layer2DiffuseMap
#define D3_VK_T_layer2DiffuseMap D3_VK_UNBOUND_T(260)
#endif
#ifndef D3_VK_S_layer2DiffuseMap
#define D3_VK_S_layer2DiffuseMap D3_VK_UNBOUND_S(261)
#endif
[[vk::binding(D3_VK_T_layer2DiffuseMap, D3_VK_TSET)]] Texture2D layer2DiffuseMap : register(D3_T_layer2DiffuseMap);
[[vk::binding(D3_VK_S_layer2DiffuseMap, D3_VK_SSET)]] SamplerState layer2DiffuseMap_s : register(D3_S_layer2DiffuseMap);

#ifndef D3_T_lightMapSampler
#define D3_T_lightMapSampler t0
#endif
#ifndef D3_S_lightMapSampler
#define D3_S_lightMapSampler s0
#endif
#ifndef D3_VK_T_lightMapSampler
#define D3_VK_T_lightMapSampler D3_VK_UNBOUND_T(262)
#endif
#ifndef D3_VK_S_lightMapSampler
#define D3_VK_S_lightMapSampler D3_VK_UNBOUND_S(263)
#endif
[[vk::binding(D3_VK_T_lightMapSampler, D3_VK_TSET)]] Texture2D lightMapSampler : register(D3_T_lightMapSampler);
[[vk::binding(D3_VK_S_lightMapSampler, D3_VK_SSET)]] SamplerState lightMapSampler_s : register(D3_S_lightMapSampler);

#ifndef D3_T_normalMap
#define D3_T_normalMap t0
#endif
#ifndef D3_S_normalMap
#define D3_S_normalMap s0
#endif
#ifndef D3_VK_T_normalMap
#define D3_VK_T_normalMap D3_VK_UNBOUND_T(264)
#endif
#ifndef D3_VK_S_normalMap
#define D3_VK_S_normalMap D3_VK_UNBOUND_S(265)
#endif
[[vk::binding(D3_VK_T_normalMap, D3_VK_TSET)]] Texture2D normalMap : register(D3_T_normalMap);
[[vk::binding(D3_VK_S_normalMap, D3_VK_SSET)]] SamplerState normalMap_s : register(D3_S_normalMap);

#ifndef D3_T_normalMap2
#define D3_T_normalMap2 t0
#endif
#ifndef D3_S_normalMap2
#define D3_S_normalMap2 s0
#endif
#ifndef D3_VK_T_normalMap2
#define D3_VK_T_normalMap2 D3_VK_UNBOUND_T(266)
#endif
#ifndef D3_VK_S_normalMap2
#define D3_VK_S_normalMap2 D3_VK_UNBOUND_S(267)
#endif
[[vk::binding(D3_VK_T_normalMap2, D3_VK_TSET)]] Texture2D normalMap2 : register(D3_T_normalMap2);
[[vk::binding(D3_VK_S_normalMap2, D3_VK_SSET)]] SamplerState normalMap2_s : register(D3_S_normalMap2);

#ifndef D3_T_normalMapSampler
#define D3_T_normalMapSampler t0
#endif
#ifndef D3_S_normalMapSampler
#define D3_S_normalMapSampler s0
#endif
#ifndef D3_VK_T_normalMapSampler
#define D3_VK_T_normalMapSampler D3_VK_UNBOUND_T(268)
#endif
#ifndef D3_VK_S_normalMapSampler
#define D3_VK_S_normalMapSampler D3_VK_UNBOUND_S(269)
#endif
[[vk::binding(D3_VK_T_normalMapSampler, D3_VK_TSET)]] Texture2D normalMapSampler : register(D3_T_normalMapSampler);
[[vk::binding(D3_VK_S_normalMapSampler, D3_VK_SSET)]] SamplerState normalMapSampler_s : register(D3_S_normalMapSampler);

#ifndef D3_T_normalMapSampler0
#define D3_T_normalMapSampler0 t0
#endif
#ifndef D3_S_normalMapSampler0
#define D3_S_normalMapSampler0 s0
#endif
#ifndef D3_VK_T_normalMapSampler0
#define D3_VK_T_normalMapSampler0 D3_VK_UNBOUND_T(270)
#endif
#ifndef D3_VK_S_normalMapSampler0
#define D3_VK_S_normalMapSampler0 D3_VK_UNBOUND_S(271)
#endif
[[vk::binding(D3_VK_T_normalMapSampler0, D3_VK_TSET)]] Texture2D normalMapSampler0 : register(D3_T_normalMapSampler0);
[[vk::binding(D3_VK_S_normalMapSampler0, D3_VK_SSET)]] SamplerState normalMapSampler0_s : register(D3_S_normalMapSampler0);

#ifndef D3_T_normalMapSampler1
#define D3_T_normalMapSampler1 t0
#endif
#ifndef D3_S_normalMapSampler1
#define D3_S_normalMapSampler1 s0
#endif
#ifndef D3_VK_T_normalMapSampler1
#define D3_VK_T_normalMapSampler1 D3_VK_UNBOUND_T(272)
#endif
#ifndef D3_VK_S_normalMapSampler1
#define D3_VK_S_normalMapSampler1 D3_VK_UNBOUND_S(273)
#endif
[[vk::binding(D3_VK_T_normalMapSampler1, D3_VK_TSET)]] Texture2D normalMapSampler1 : register(D3_T_normalMapSampler1);
[[vk::binding(D3_VK_S_normalMapSampler1, D3_VK_SSET)]] SamplerState normalMapSampler1_s : register(D3_S_normalMapSampler1);

#ifndef D3_T_overlayMapSampler
#define D3_T_overlayMapSampler t0
#endif
#ifndef D3_S_overlayMapSampler
#define D3_S_overlayMapSampler s0
#endif
#ifndef D3_VK_T_overlayMapSampler
#define D3_VK_T_overlayMapSampler D3_VK_UNBOUND_T(274)
#endif
#ifndef D3_VK_S_overlayMapSampler
#define D3_VK_S_overlayMapSampler D3_VK_UNBOUND_S(275)
#endif
[[vk::binding(D3_VK_T_overlayMapSampler, D3_VK_TSET)]] Texture2D overlayMapSampler : register(D3_T_overlayMapSampler);
[[vk::binding(D3_VK_S_overlayMapSampler, D3_VK_SSET)]] SamplerState overlayMapSampler_s : register(D3_S_overlayMapSampler);

#ifndef D3_T_patternMap
#define D3_T_patternMap t0
#endif
#ifndef D3_S_patternMap
#define D3_S_patternMap s0
#endif
#ifndef D3_VK_T_patternMap
#define D3_VK_T_patternMap D3_VK_UNBOUND_T(276)
#endif
#ifndef D3_VK_S_patternMap
#define D3_VK_S_patternMap D3_VK_UNBOUND_S(277)
#endif
[[vk::binding(D3_VK_T_patternMap, D3_VK_TSET)]] Texture2D patternMap : register(D3_T_patternMap);
[[vk::binding(D3_VK_S_patternMap, D3_VK_SSET)]] SamplerState patternMap_s : register(D3_S_patternMap);

#ifndef D3_T_pmaMaskTex
#define D3_T_pmaMaskTex t0
#endif
#ifndef D3_S_pmaMaskTex
#define D3_S_pmaMaskTex s0
#endif
#ifndef D3_VK_T_pmaMaskTex
#define D3_VK_T_pmaMaskTex D3_VK_UNBOUND_T(278)
#endif
#ifndef D3_VK_S_pmaMaskTex
#define D3_VK_S_pmaMaskTex D3_VK_UNBOUND_S(279)
#endif
[[vk::binding(D3_VK_T_pmaMaskTex, D3_VK_TSET)]] Texture2D pmaMaskTex : register(D3_T_pmaMaskTex);
[[vk::binding(D3_VK_S_pmaMaskTex, D3_VK_SSET)]] SamplerState pmaMaskTex_s : register(D3_S_pmaMaskTex);

#ifndef D3_T_pmaTex
#define D3_T_pmaTex t0
#endif
#ifndef D3_S_pmaTex
#define D3_S_pmaTex s0
#endif
#ifndef D3_VK_T_pmaTex
#define D3_VK_T_pmaTex D3_VK_UNBOUND_T(280)
#endif
#ifndef D3_VK_S_pmaTex
#define D3_VK_S_pmaTex D3_VK_UNBOUND_S(281)
#endif
[[vk::binding(D3_VK_T_pmaTex, D3_VK_TSET)]] Texture2D pmaTex : register(D3_T_pmaTex);
[[vk::binding(D3_VK_S_pmaTex, D3_VK_SSET)]] SamplerState pmaTex_s : register(D3_S_pmaTex);

#ifndef D3_T_sampler0
#define D3_T_sampler0 t0
#endif
#ifndef D3_S_sampler0
#define D3_S_sampler0 s0
#endif
#ifndef D3_VK_T_sampler0
#define D3_VK_T_sampler0 D3_VK_UNBOUND_T(282)
#endif
#ifndef D3_VK_S_sampler0
#define D3_VK_S_sampler0 D3_VK_UNBOUND_S(283)
#endif
[[vk::binding(D3_VK_T_sampler0, D3_VK_TSET)]] Texture2D sampler0 : register(D3_T_sampler0);
[[vk::binding(D3_VK_S_sampler0, D3_VK_SSET)]] SamplerState sampler0_s : register(D3_S_sampler0);

#ifndef D3_T_sampler1
#define D3_T_sampler1 t0
#endif
#ifndef D3_S_sampler1
#define D3_S_sampler1 s0
#endif
#ifndef D3_VK_T_sampler1
#define D3_VK_T_sampler1 D3_VK_UNBOUND_T(284)
#endif
#ifndef D3_VK_S_sampler1
#define D3_VK_S_sampler1 D3_VK_UNBOUND_S(285)
#endif
[[vk::binding(D3_VK_T_sampler1, D3_VK_TSET)]] Texture2D sampler1 : register(D3_T_sampler1);
[[vk::binding(D3_VK_S_sampler1, D3_VK_SSET)]] SamplerState sampler1_s : register(D3_S_sampler1);

#ifndef D3_T_sampler2
#define D3_T_sampler2 t0
#endif
#ifndef D3_S_sampler2
#define D3_S_sampler2 s0
#endif
#ifndef D3_VK_T_sampler2
#define D3_VK_T_sampler2 D3_VK_UNBOUND_T(286)
#endif
#ifndef D3_VK_S_sampler2
#define D3_VK_S_sampler2 D3_VK_UNBOUND_S(287)
#endif
[[vk::binding(D3_VK_T_sampler2, D3_VK_TSET)]] Texture2D sampler2 : register(D3_T_sampler2);
[[vk::binding(D3_VK_S_sampler2, D3_VK_SSET)]] SamplerState sampler2_s : register(D3_S_sampler2);

#ifndef D3_T_sampler3
#define D3_T_sampler3 t0
#endif
#ifndef D3_S_sampler3
#define D3_S_sampler3 s0
#endif
#ifndef D3_VK_T_sampler3
#define D3_VK_T_sampler3 D3_VK_UNBOUND_T(288)
#endif
#ifndef D3_VK_S_sampler3
#define D3_VK_S_sampler3 D3_VK_UNBOUND_S(289)
#endif
[[vk::binding(D3_VK_T_sampler3, D3_VK_TSET)]] Texture2D sampler3 : register(D3_T_sampler3);
[[vk::binding(D3_VK_S_sampler3, D3_VK_SSET)]] SamplerState sampler3_s : register(D3_S_sampler3);

#ifndef D3_T_sampler4
#define D3_T_sampler4 t0
#endif
#ifndef D3_S_sampler4
#define D3_S_sampler4 s0
#endif
#ifndef D3_VK_T_sampler4
#define D3_VK_T_sampler4 D3_VK_UNBOUND_T(290)
#endif
#ifndef D3_VK_S_sampler4
#define D3_VK_S_sampler4 D3_VK_UNBOUND_S(291)
#endif
[[vk::binding(D3_VK_T_sampler4, D3_VK_TSET)]] Texture2D sampler4 : register(D3_T_sampler4);
[[vk::binding(D3_VK_S_sampler4, D3_VK_SSET)]] SamplerState sampler4_s : register(D3_S_sampler4);

#ifndef D3_T_sampler5
#define D3_T_sampler5 t0
#endif
#ifndef D3_S_sampler5
#define D3_S_sampler5 s0
#endif
#ifndef D3_VK_T_sampler5
#define D3_VK_T_sampler5 D3_VK_UNBOUND_T(292)
#endif
#ifndef D3_VK_S_sampler5
#define D3_VK_S_sampler5 D3_VK_UNBOUND_S(293)
#endif
[[vk::binding(D3_VK_T_sampler5, D3_VK_TSET)]] Texture2D sampler5 : register(D3_T_sampler5);
[[vk::binding(D3_VK_S_sampler5, D3_VK_SSET)]] SamplerState sampler5_s : register(D3_S_sampler5);

#ifndef D3_T_shadowMap
#define D3_T_shadowMap t0
#endif
#ifndef D3_S_shadowMap
#define D3_S_shadowMap s0
#endif
#ifndef D3_VK_T_shadowMap
#define D3_VK_T_shadowMap D3_VK_UNBOUND_T(294)
#endif
#ifndef D3_VK_S_shadowMap
#define D3_VK_S_shadowMap D3_VK_UNBOUND_S(295)
#endif
[[vk::binding(D3_VK_T_shadowMap, D3_VK_TSET)]] Texture2D shadowMap : register(D3_T_shadowMap);
[[vk::binding(D3_VK_S_shadowMap, D3_VK_SSET)]] SamplerState shadowMap_s : register(D3_S_shadowMap);
[[vk::binding(D3_VK_S_shadowMap, D3_VK_SSET)]] SamplerComparisonState shadowMap_cmp : register(D3_S_shadowMap);

#ifndef D3_T_shadowMapSampler
#define D3_T_shadowMapSampler t0
#endif
#ifndef D3_S_shadowMapSampler
#define D3_S_shadowMapSampler s0
#endif
#ifndef D3_VK_T_shadowMapSampler
#define D3_VK_T_shadowMapSampler D3_VK_UNBOUND_T(296)
#endif
#ifndef D3_VK_S_shadowMapSampler
#define D3_VK_S_shadowMapSampler D3_VK_UNBOUND_S(297)
#endif
[[vk::binding(D3_VK_T_shadowMapSampler, D3_VK_TSET)]] Texture2D shadowMapSampler : register(D3_T_shadowMapSampler);
[[vk::binding(D3_VK_S_shadowMapSampler, D3_VK_SSET)]] SamplerState shadowMapSampler_s : register(D3_S_shadowMapSampler);
[[vk::binding(D3_VK_S_shadowMapSampler, D3_VK_SSET)]] SamplerComparisonState shadowMapSampler_cmp : register(D3_S_shadowMapSampler);

#ifndef D3_T_sigilAccentMap
#define D3_T_sigilAccentMap t0
#endif
#ifndef D3_S_sigilAccentMap
#define D3_S_sigilAccentMap s0
#endif
#ifndef D3_VK_T_sigilAccentMap
#define D3_VK_T_sigilAccentMap D3_VK_UNBOUND_T(298)
#endif
#ifndef D3_VK_S_sigilAccentMap
#define D3_VK_S_sigilAccentMap D3_VK_UNBOUND_S(299)
#endif
[[vk::binding(D3_VK_T_sigilAccentMap, D3_VK_TSET)]] Texture2D sigilAccentMap : register(D3_T_sigilAccentMap);
[[vk::binding(D3_VK_S_sigilAccentMap, D3_VK_SSET)]] SamplerState sigilAccentMap_s : register(D3_S_sigilAccentMap);

#ifndef D3_T_sigilMainMap
#define D3_T_sigilMainMap t0
#endif
#ifndef D3_S_sigilMainMap
#define D3_S_sigilMainMap s0
#endif
#ifndef D3_VK_T_sigilMainMap
#define D3_VK_T_sigilMainMap D3_VK_UNBOUND_T(300)
#endif
#ifndef D3_VK_S_sigilMainMap
#define D3_VK_S_sigilMainMap D3_VK_UNBOUND_S(301)
#endif
[[vk::binding(D3_VK_T_sigilMainMap, D3_VK_TSET)]] Texture2D sigilMainMap : register(D3_T_sigilMainMap);
[[vk::binding(D3_VK_S_sigilMainMap, D3_VK_SSET)]] SamplerState sigilMainMap_s : register(D3_S_sigilMainMap);

#ifndef D3_T_ssaoSampler
#define D3_T_ssaoSampler t0
#endif
#ifndef D3_S_ssaoSampler
#define D3_S_ssaoSampler s0
#endif
#ifndef D3_VK_T_ssaoSampler
#define D3_VK_T_ssaoSampler D3_VK_UNBOUND_T(302)
#endif
#ifndef D3_VK_S_ssaoSampler
#define D3_VK_S_ssaoSampler D3_VK_UNBOUND_S(303)
#endif
[[vk::binding(D3_VK_T_ssaoSampler, D3_VK_TSET)]] Texture2D ssaoSampler : register(D3_T_ssaoSampler);
[[vk::binding(D3_VK_S_ssaoSampler, D3_VK_SSET)]] SamplerState ssaoSampler_s : register(D3_S_ssaoSampler);

#ifndef D3_T_texAlpha
#define D3_T_texAlpha t0
#endif
#ifndef D3_S_texAlpha
#define D3_S_texAlpha s0
#endif
#ifndef D3_VK_T_texAlpha
#define D3_VK_T_texAlpha D3_VK_UNBOUND_T(304)
#endif
#ifndef D3_VK_S_texAlpha
#define D3_VK_S_texAlpha D3_VK_UNBOUND_S(305)
#endif
[[vk::binding(D3_VK_T_texAlpha, D3_VK_TSET)]] Texture2D texAlpha : register(D3_T_texAlpha);
[[vk::binding(D3_VK_S_texAlpha, D3_VK_SSET)]] SamplerState texAlpha_s : register(D3_S_texAlpha);

#ifndef D3_T_texAlphaMask
#define D3_T_texAlphaMask t0
#endif
#ifndef D3_S_texAlphaMask
#define D3_S_texAlphaMask s0
#endif
#ifndef D3_VK_T_texAlphaMask
#define D3_VK_T_texAlphaMask D3_VK_UNBOUND_T(306)
#endif
#ifndef D3_VK_S_texAlphaMask
#define D3_VK_S_texAlphaMask D3_VK_UNBOUND_S(307)
#endif
[[vk::binding(D3_VK_T_texAlphaMask, D3_VK_TSET)]] Texture2D texAlphaMask : register(D3_T_texAlphaMask);
[[vk::binding(D3_VK_S_texAlphaMask, D3_VK_SSET)]] SamplerState texAlphaMask_s : register(D3_S_texAlphaMask);

#ifndef D3_T_texAnimated
#define D3_T_texAnimated t0
#endif
#ifndef D3_S_texAnimated
#define D3_S_texAnimated s0
#endif
#ifndef D3_VK_T_texAnimated
#define D3_VK_T_texAnimated D3_VK_UNBOUND_T(308)
#endif
#ifndef D3_VK_S_texAnimated
#define D3_VK_S_texAnimated D3_VK_UNBOUND_S(309)
#endif
[[vk::binding(D3_VK_T_texAnimated, D3_VK_TSET)]] Texture2D texAnimated : register(D3_T_texAnimated);
[[vk::binding(D3_VK_S_texAnimated, D3_VK_SSET)]] SamplerState texAnimated_s : register(D3_S_texAnimated);

#ifndef D3_T_texBlurredHighlight
#define D3_T_texBlurredHighlight t0
#endif
#ifndef D3_S_texBlurredHighlight
#define D3_S_texBlurredHighlight s0
#endif
#ifndef D3_VK_T_texBlurredHighlight
#define D3_VK_T_texBlurredHighlight D3_VK_UNBOUND_T(310)
#endif
#ifndef D3_VK_S_texBlurredHighlight
#define D3_VK_S_texBlurredHighlight D3_VK_UNBOUND_S(311)
#endif
[[vk::binding(D3_VK_T_texBlurredHighlight, D3_VK_TSET)]] Texture2D texBlurredHighlight : register(D3_T_texBlurredHighlight);
[[vk::binding(D3_VK_S_texBlurredHighlight, D3_VK_SSET)]] SamplerState texBlurredHighlight_s : register(D3_S_texBlurredHighlight);

#ifndef D3_T_texCrossU
#define D3_T_texCrossU t0
#endif
#ifndef D3_S_texCrossU
#define D3_S_texCrossU s0
#endif
#ifndef D3_VK_T_texCrossU
#define D3_VK_T_texCrossU D3_VK_UNBOUND_T(312)
#endif
#ifndef D3_VK_S_texCrossU
#define D3_VK_S_texCrossU D3_VK_UNBOUND_S(313)
#endif
[[vk::binding(D3_VK_T_texCrossU, D3_VK_TSET)]] Texture2D texCrossU : register(D3_T_texCrossU);
[[vk::binding(D3_VK_S_texCrossU, D3_VK_SSET)]] SamplerState texCrossU_s : register(D3_S_texCrossU);

#ifndef D3_T_texCrossV
#define D3_T_texCrossV t0
#endif
#ifndef D3_S_texCrossV
#define D3_S_texCrossV s0
#endif
#ifndef D3_VK_T_texCrossV
#define D3_VK_T_texCrossV D3_VK_UNBOUND_T(314)
#endif
#ifndef D3_VK_S_texCrossV
#define D3_VK_S_texCrossV D3_VK_UNBOUND_S(315)
#endif
[[vk::binding(D3_VK_T_texCrossV, D3_VK_TSET)]] Texture2D texCrossV : register(D3_T_texCrossV);
[[vk::binding(D3_VK_S_texCrossV, D3_VK_SSET)]] SamplerState texCrossV_s : register(D3_S_texCrossV);

#ifndef D3_T_texDepth
#define D3_T_texDepth t0
#endif
#ifndef D3_S_texDepth
#define D3_S_texDepth s0
#endif
#ifndef D3_VK_T_texDepth
#define D3_VK_T_texDepth D3_VK_UNBOUND_T(316)
#endif
#ifndef D3_VK_S_texDepth
#define D3_VK_S_texDepth D3_VK_UNBOUND_S(317)
#endif
[[vk::binding(D3_VK_T_texDepth, D3_VK_TSET)]] Texture2D texDepth : register(D3_T_texDepth);
[[vk::binding(D3_VK_S_texDepth, D3_VK_SSET)]] SamplerState texDepth_s : register(D3_S_texDepth);

#ifndef D3_T_texDiffuse
#define D3_T_texDiffuse t0
#endif
#ifndef D3_S_texDiffuse
#define D3_S_texDiffuse s0
#endif
#ifndef D3_VK_T_texDiffuse
#define D3_VK_T_texDiffuse D3_VK_UNBOUND_T(318)
#endif
#ifndef D3_VK_S_texDiffuse
#define D3_VK_S_texDiffuse D3_VK_UNBOUND_S(319)
#endif
[[vk::binding(D3_VK_T_texDiffuse, D3_VK_TSET)]] Texture2D texDiffuse : register(D3_T_texDiffuse);
[[vk::binding(D3_VK_S_texDiffuse, D3_VK_SSET)]] SamplerState texDiffuse_s : register(D3_S_texDiffuse);

#ifndef D3_T_texEnvMap
#define D3_T_texEnvMap t0
#endif
#ifndef D3_S_texEnvMap
#define D3_S_texEnvMap s0
#endif
#ifndef D3_VK_T_texEnvMap
#define D3_VK_T_texEnvMap D3_VK_UNBOUND_T(320)
#endif
#ifndef D3_VK_S_texEnvMap
#define D3_VK_S_texEnvMap D3_VK_UNBOUND_S(321)
#endif
[[vk::binding(D3_VK_T_texEnvMap, D3_VK_TSET)]] Texture2D texEnvMap : register(D3_T_texEnvMap);
[[vk::binding(D3_VK_S_texEnvMap, D3_VK_SSET)]] SamplerState texEnvMap_s : register(D3_S_texEnvMap);

#ifndef D3_T_texLayer0
#define D3_T_texLayer0 t0
#endif
#ifndef D3_S_texLayer0
#define D3_S_texLayer0 s0
#endif
#ifndef D3_VK_T_texLayer0
#define D3_VK_T_texLayer0 D3_VK_UNBOUND_T(322)
#endif
#ifndef D3_VK_S_texLayer0
#define D3_VK_S_texLayer0 D3_VK_UNBOUND_S(323)
#endif
[[vk::binding(D3_VK_T_texLayer0, D3_VK_TSET)]] Texture2D texLayer0 : register(D3_T_texLayer0);
[[vk::binding(D3_VK_S_texLayer0, D3_VK_SSET)]] SamplerState texLayer0_s : register(D3_S_texLayer0);

#ifndef D3_T_texLayer1
#define D3_T_texLayer1 t0
#endif
#ifndef D3_S_texLayer1
#define D3_S_texLayer1 s0
#endif
#ifndef D3_VK_T_texLayer1
#define D3_VK_T_texLayer1 D3_VK_UNBOUND_T(324)
#endif
#ifndef D3_VK_S_texLayer1
#define D3_VK_S_texLayer1 D3_VK_UNBOUND_S(325)
#endif
[[vk::binding(D3_VK_T_texLayer1, D3_VK_TSET)]] Texture2D texLayer1 : register(D3_T_texLayer1);
[[vk::binding(D3_VK_S_texLayer1, D3_VK_SSET)]] SamplerState texLayer1_s : register(D3_S_texLayer1);

#ifndef D3_T_texLayer2
#define D3_T_texLayer2 t0
#endif
#ifndef D3_S_texLayer2
#define D3_S_texLayer2 s0
#endif
#ifndef D3_VK_T_texLayer2
#define D3_VK_T_texLayer2 D3_VK_UNBOUND_T(326)
#endif
#ifndef D3_VK_S_texLayer2
#define D3_VK_S_texLayer2 D3_VK_UNBOUND_S(327)
#endif
[[vk::binding(D3_VK_T_texLayer2, D3_VK_TSET)]] Texture2D texLayer2 : register(D3_T_texLayer2);
[[vk::binding(D3_VK_S_texLayer2, D3_VK_SSET)]] SamplerState texLayer2_s : register(D3_S_texLayer2);

#ifndef D3_T_texLayer3
#define D3_T_texLayer3 t0
#endif
#ifndef D3_S_texLayer3
#define D3_S_texLayer3 s0
#endif
#ifndef D3_VK_T_texLayer3
#define D3_VK_T_texLayer3 D3_VK_UNBOUND_T(328)
#endif
#ifndef D3_VK_S_texLayer3
#define D3_VK_S_texLayer3 D3_VK_UNBOUND_S(329)
#endif
[[vk::binding(D3_VK_T_texLayer3, D3_VK_TSET)]] Texture2D texLayer3 : register(D3_T_texLayer3);
[[vk::binding(D3_VK_S_texLayer3, D3_VK_SSET)]] SamplerState texLayer3_s : register(D3_S_texLayer3);

#ifndef D3_T_texLayer4
#define D3_T_texLayer4 t0
#endif
#ifndef D3_S_texLayer4
#define D3_S_texLayer4 s0
#endif
#ifndef D3_VK_T_texLayer4
#define D3_VK_T_texLayer4 D3_VK_UNBOUND_T(330)
#endif
#ifndef D3_VK_S_texLayer4
#define D3_VK_S_texLayer4 D3_VK_UNBOUND_S(331)
#endif
[[vk::binding(D3_VK_T_texLayer4, D3_VK_TSET)]] Texture2D texLayer4 : register(D3_T_texLayer4);
[[vk::binding(D3_VK_S_texLayer4, D3_VK_SSET)]] SamplerState texLayer4_s : register(D3_S_texLayer4);

#ifndef D3_T_texLightmap
#define D3_T_texLightmap t0
#endif
#ifndef D3_S_texLightmap
#define D3_S_texLightmap s0
#endif
#ifndef D3_VK_T_texLightmap
#define D3_VK_T_texLightmap D3_VK_UNBOUND_T(332)
#endif
#ifndef D3_VK_S_texLightmap
#define D3_VK_S_texLightmap D3_VK_UNBOUND_S(333)
#endif
[[vk::binding(D3_VK_T_texLightmap, D3_VK_TSET)]] Texture2D texLightmap : register(D3_T_texLightmap);
[[vk::binding(D3_VK_S_texLightmap, D3_VK_SSET)]] SamplerState texLightmap_s : register(D3_S_texLightmap);

#ifndef D3_T_texMask
#define D3_T_texMask t0
#endif
#ifndef D3_S_texMask
#define D3_S_texMask s0
#endif
#ifndef D3_VK_T_texMask
#define D3_VK_T_texMask D3_VK_UNBOUND_T(334)
#endif
#ifndef D3_VK_S_texMask
#define D3_VK_S_texMask D3_VK_UNBOUND_S(335)
#endif
[[vk::binding(D3_VK_T_texMask, D3_VK_TSET)]] Texture2D texMask : register(D3_T_texMask);
[[vk::binding(D3_VK_S_texMask, D3_VK_SSET)]] SamplerState texMask_s : register(D3_S_texMask);

#ifndef D3_T_texMurk
#define D3_T_texMurk t0
#endif
#ifndef D3_S_texMurk
#define D3_S_texMurk s0
#endif
#ifndef D3_VK_T_texMurk
#define D3_VK_T_texMurk D3_VK_UNBOUND_T(336)
#endif
#ifndef D3_VK_S_texMurk
#define D3_VK_S_texMurk D3_VK_UNBOUND_S(337)
#endif
[[vk::binding(D3_VK_T_texMurk, D3_VK_TSET)]] Texture2D texMurk : register(D3_T_texMurk);
[[vk::binding(D3_VK_S_texMurk, D3_VK_SSET)]] SamplerState texMurk_s : register(D3_S_texMurk);

#ifndef D3_T_texNormal0
#define D3_T_texNormal0 t0
#endif
#ifndef D3_S_texNormal0
#define D3_S_texNormal0 s0
#endif
#ifndef D3_VK_T_texNormal0
#define D3_VK_T_texNormal0 D3_VK_UNBOUND_T(338)
#endif
#ifndef D3_VK_S_texNormal0
#define D3_VK_S_texNormal0 D3_VK_UNBOUND_S(339)
#endif
[[vk::binding(D3_VK_T_texNormal0, D3_VK_TSET)]] Texture2D texNormal0 : register(D3_T_texNormal0);
[[vk::binding(D3_VK_S_texNormal0, D3_VK_SSET)]] SamplerState texNormal0_s : register(D3_S_texNormal0);

#ifndef D3_T_texNormal1
#define D3_T_texNormal1 t0
#endif
#ifndef D3_S_texNormal1
#define D3_S_texNormal1 s0
#endif
#ifndef D3_VK_T_texNormal1
#define D3_VK_T_texNormal1 D3_VK_UNBOUND_T(340)
#endif
#ifndef D3_VK_S_texNormal1
#define D3_VK_S_texNormal1 D3_VK_UNBOUND_S(341)
#endif
[[vk::binding(D3_VK_T_texNormal1, D3_VK_TSET)]] Texture2D texNormal1 : register(D3_T_texNormal1);
[[vk::binding(D3_VK_S_texNormal1, D3_VK_SSET)]] SamplerState texNormal1_s : register(D3_S_texNormal1);

#ifndef D3_T_texNormal2
#define D3_T_texNormal2 t0
#endif
#ifndef D3_S_texNormal2
#define D3_S_texNormal2 s0
#endif
#ifndef D3_VK_T_texNormal2
#define D3_VK_T_texNormal2 D3_VK_UNBOUND_T(342)
#endif
#ifndef D3_VK_S_texNormal2
#define D3_VK_S_texNormal2 D3_VK_UNBOUND_S(343)
#endif
[[vk::binding(D3_VK_T_texNormal2, D3_VK_TSET)]] Texture2D texNormal2 : register(D3_T_texNormal2);
[[vk::binding(D3_VK_S_texNormal2, D3_VK_SSET)]] SamplerState texNormal2_s : register(D3_S_texNormal2);

#ifndef D3_T_texNormal3
#define D3_T_texNormal3 t0
#endif
#ifndef D3_S_texNormal3
#define D3_S_texNormal3 s0
#endif
#ifndef D3_VK_T_texNormal3
#define D3_VK_T_texNormal3 D3_VK_UNBOUND_T(344)
#endif
#ifndef D3_VK_S_texNormal3
#define D3_VK_S_texNormal3 D3_VK_UNBOUND_S(345)
#endif
[[vk::binding(D3_VK_T_texNormal3, D3_VK_TSET)]] Texture2D texNormal3 : register(D3_T_texNormal3);
[[vk::binding(D3_VK_S_texNormal3, D3_VK_SSET)]] SamplerState texNormal3_s : register(D3_S_texNormal3);

#ifndef D3_T_texNormal4
#define D3_T_texNormal4 t0
#endif
#ifndef D3_S_texNormal4
#define D3_S_texNormal4 s0
#endif
#ifndef D3_VK_T_texNormal4
#define D3_VK_T_texNormal4 D3_VK_UNBOUND_T(346)
#endif
#ifndef D3_VK_S_texNormal4
#define D3_VK_S_texNormal4 D3_VK_UNBOUND_S(347)
#endif
[[vk::binding(D3_VK_T_texNormal4, D3_VK_TSET)]] Texture2D texNormal4 : register(D3_T_texNormal4);
[[vk::binding(D3_VK_S_texNormal4, D3_VK_SSET)]] SamplerState texNormal4_s : register(D3_S_texNormal4);

#ifndef D3_T_texNormalMap
#define D3_T_texNormalMap t0
#endif
#ifndef D3_S_texNormalMap
#define D3_S_texNormalMap s0
#endif
#ifndef D3_VK_T_texNormalMap
#define D3_VK_T_texNormalMap D3_VK_UNBOUND_T(348)
#endif
#ifndef D3_VK_S_texNormalMap
#define D3_VK_S_texNormalMap D3_VK_UNBOUND_S(349)
#endif
[[vk::binding(D3_VK_T_texNormalMap, D3_VK_TSET)]] Texture2D texNormalMap : register(D3_T_texNormalMap);
[[vk::binding(D3_VK_S_texNormalMap, D3_VK_SSET)]] SamplerState texNormalMap_s : register(D3_S_texNormalMap);

#ifndef D3_T_texNormalMap2
#define D3_T_texNormalMap2 t0
#endif
#ifndef D3_S_texNormalMap2
#define D3_S_texNormalMap2 s0
#endif
#ifndef D3_VK_T_texNormalMap2
#define D3_VK_T_texNormalMap2 D3_VK_UNBOUND_T(350)
#endif
#ifndef D3_VK_S_texNormalMap2
#define D3_VK_S_texNormalMap2 D3_VK_UNBOUND_S(351)
#endif
[[vk::binding(D3_VK_T_texNormalMap2, D3_VK_TSET)]] Texture2D texNormalMap2 : register(D3_T_texNormalMap2);
[[vk::binding(D3_VK_S_texNormalMap2, D3_VK_SSET)]] SamplerState texNormalMap2_s : register(D3_S_texNormalMap2);

#ifndef D3_T_texOriginalHighlight
#define D3_T_texOriginalHighlight t0
#endif
#ifndef D3_S_texOriginalHighlight
#define D3_S_texOriginalHighlight s0
#endif
#ifndef D3_VK_T_texOriginalHighlight
#define D3_VK_T_texOriginalHighlight D3_VK_UNBOUND_T(352)
#endif
#ifndef D3_VK_S_texOriginalHighlight
#define D3_VK_S_texOriginalHighlight D3_VK_UNBOUND_S(353)
#endif
[[vk::binding(D3_VK_T_texOriginalHighlight, D3_VK_TSET)]] Texture2D texOriginalHighlight : register(D3_T_texOriginalHighlight);
[[vk::binding(D3_VK_S_texOriginalHighlight, D3_VK_SSET)]] SamplerState texOriginalHighlight_s : register(D3_S_texOriginalHighlight);

#ifndef D3_T_texReflection
#define D3_T_texReflection t0
#endif
#ifndef D3_S_texReflection
#define D3_S_texReflection s0
#endif
#ifndef D3_VK_T_texReflection
#define D3_VK_T_texReflection D3_VK_UNBOUND_T(354)
#endif
#ifndef D3_VK_S_texReflection
#define D3_VK_S_texReflection D3_VK_UNBOUND_S(355)
#endif
[[vk::binding(D3_VK_T_texReflection, D3_VK_TSET)]] Texture2D texReflection : register(D3_T_texReflection);
[[vk::binding(D3_VK_S_texReflection, D3_VK_SSET)]] SamplerState texReflection_s : register(D3_S_texReflection);

#ifndef D3_T_texReflection1
#define D3_T_texReflection1 t0
#endif
#ifndef D3_S_texReflection1
#define D3_S_texReflection1 s0
#endif
#ifndef D3_VK_T_texReflection1
#define D3_VK_T_texReflection1 D3_VK_UNBOUND_T(356)
#endif
#ifndef D3_VK_S_texReflection1
#define D3_VK_S_texReflection1 D3_VK_UNBOUND_S(357)
#endif
[[vk::binding(D3_VK_T_texReflection1, D3_VK_TSET)]] Texture2D texReflection1 : register(D3_T_texReflection1);
[[vk::binding(D3_VK_S_texReflection1, D3_VK_SSET)]] SamplerState texReflection1_s : register(D3_S_texReflection1);

#ifndef D3_T_texRefraction
#define D3_T_texRefraction t0
#endif
#ifndef D3_S_texRefraction
#define D3_S_texRefraction s0
#endif
#ifndef D3_VK_T_texRefraction
#define D3_VK_T_texRefraction D3_VK_UNBOUND_T(358)
#endif
#ifndef D3_VK_S_texRefraction
#define D3_VK_S_texRefraction D3_VK_UNBOUND_S(359)
#endif
[[vk::binding(D3_VK_T_texRefraction, D3_VK_TSET)]] Texture2D texRefraction : register(D3_T_texRefraction);
[[vk::binding(D3_VK_S_texRefraction, D3_VK_SSET)]] SamplerState texRefraction_s : register(D3_S_texRefraction);

#ifndef D3_T_texRipple
#define D3_T_texRipple t0
#endif
#ifndef D3_S_texRipple
#define D3_S_texRipple s0
#endif
#ifndef D3_VK_T_texRipple
#define D3_VK_T_texRipple D3_VK_UNBOUND_T(360)
#endif
#ifndef D3_VK_S_texRipple
#define D3_VK_S_texRipple D3_VK_UNBOUND_S(361)
#endif
[[vk::binding(D3_VK_T_texRipple, D3_VK_TSET)]] Texture2D texRipple : register(D3_T_texRipple);
[[vk::binding(D3_VK_S_texRipple, D3_VK_SSET)]] SamplerState texRipple_s : register(D3_S_texRipple);

#ifndef D3_T_texWhitewater
#define D3_T_texWhitewater t0
#endif
#ifndef D3_S_texWhitewater
#define D3_S_texWhitewater s0
#endif
#ifndef D3_VK_T_texWhitewater
#define D3_VK_T_texWhitewater D3_VK_UNBOUND_T(362)
#endif
#ifndef D3_VK_S_texWhitewater
#define D3_VK_S_texWhitewater D3_VK_UNBOUND_S(363)
#endif
[[vk::binding(D3_VK_T_texWhitewater, D3_VK_TSET)]] Texture2D texWhitewater : register(D3_T_texWhitewater);
[[vk::binding(D3_VK_S_texWhitewater, D3_VK_SSET)]] SamplerState texWhitewater_s : register(D3_S_texWhitewater);

#ifndef D3_T_texWhitewaterMask
#define D3_T_texWhitewaterMask t0
#endif
#ifndef D3_S_texWhitewaterMask
#define D3_S_texWhitewaterMask s0
#endif
#ifndef D3_VK_T_texWhitewaterMask
#define D3_VK_T_texWhitewaterMask D3_VK_UNBOUND_T(364)
#endif
#ifndef D3_VK_S_texWhitewaterMask
#define D3_VK_S_texWhitewaterMask D3_VK_UNBOUND_S(365)
#endif
[[vk::binding(D3_VK_T_texWhitewaterMask, D3_VK_TSET)]] Texture2D texWhitewaterMask : register(D3_T_texWhitewaterMask);
[[vk::binding(D3_VK_S_texWhitewaterMask, D3_VK_SSET)]] SamplerState texWhitewaterMask_s : register(D3_S_texWhitewaterMask);

#ifndef D3_T_tintRampMap
#define D3_T_tintRampMap t0
#endif
#ifndef D3_S_tintRampMap
#define D3_S_tintRampMap s0
#endif
#ifndef D3_VK_T_tintRampMap
#define D3_VK_T_tintRampMap D3_VK_UNBOUND_T(366)
#endif
#ifndef D3_VK_S_tintRampMap
#define D3_VK_S_tintRampMap D3_VK_UNBOUND_S(367)
#endif
[[vk::binding(D3_VK_T_tintRampMap, D3_VK_TSET)]] Texture2D tintRampMap : register(D3_T_tintRampMap);
[[vk::binding(D3_VK_S_tintRampMap, D3_VK_SSET)]] SamplerState tintRampMap_s : register(D3_S_tintRampMap);

#ifndef D3_T_vignetteMap
#define D3_T_vignetteMap t0
#endif
#ifndef D3_S_vignetteMap
#define D3_S_vignetteMap s0
#endif
#ifndef D3_VK_T_vignetteMap
#define D3_VK_T_vignetteMap D3_VK_UNBOUND_T(368)
#endif
#ifndef D3_VK_S_vignetteMap
#define D3_VK_S_vignetteMap D3_VK_UNBOUND_S(369)
#endif
[[vk::binding(D3_VK_T_vignetteMap, D3_VK_TSET)]] Texture2D vignetteMap : register(D3_T_vignetteMap);
[[vk::binding(D3_VK_S_vignetteMap, D3_VK_SSET)]] SamplerState vignetteMap_s : register(D3_S_vignetteMap);

#ifndef D3_T_vignetteSampler
#define D3_T_vignetteSampler t0
#endif
#ifndef D3_S_vignetteSampler
#define D3_S_vignetteSampler s0
#endif
#ifndef D3_VK_T_vignetteSampler
#define D3_VK_T_vignetteSampler D3_VK_UNBOUND_T(370)
#endif
#ifndef D3_VK_S_vignetteSampler
#define D3_VK_S_vignetteSampler D3_VK_UNBOUND_S(371)
#endif
[[vk::binding(D3_VK_T_vignetteSampler, D3_VK_TSET)]] Texture2D vignetteSampler : register(D3_T_vignetteSampler);
[[vk::binding(D3_VK_S_vignetteSampler, D3_VK_SSET)]] SamplerState vignetteSampler_s : register(D3_S_vignetteSampler);

#ifndef D3_T_waterSampler
#define D3_T_waterSampler t0
#endif
#ifndef D3_S_waterSampler
#define D3_S_waterSampler s0
#endif
#ifndef D3_VK_T_waterSampler
#define D3_VK_T_waterSampler D3_VK_UNBOUND_T(372)
#endif
#ifndef D3_VK_S_waterSampler
#define D3_VK_S_waterSampler D3_VK_UNBOUND_S(373)
#endif
[[vk::binding(D3_VK_T_waterSampler, D3_VK_TSET)]] Texture2D waterSampler : register(D3_T_waterSampler);
[[vk::binding(D3_VK_S_waterSampler, D3_VK_SSET)]] SamplerState waterSampler_s : register(D3_S_waterSampler);

#ifndef D3_T_texBloom
#define D3_T_texBloom t0
#endif
#ifndef D3_S_texBloom
#define D3_S_texBloom s0
#endif
#ifndef D3_VK_T_texBloom
#define D3_VK_T_texBloom D3_VK_UNBOUND_T(374)
#endif
#ifndef D3_VK_S_texBloom
#define D3_VK_S_texBloom D3_VK_UNBOUND_S(375)
#endif
[[vk::binding(D3_VK_T_texBloom, D3_VK_TSET)]] Texture2D texBloom : register(D3_T_texBloom);
[[vk::binding(D3_VK_S_texBloom, D3_VK_SSET)]] SamplerState texBloom_s : register(D3_S_texBloom);

#ifndef D3_T_texBlurred
#define D3_T_texBlurred t0
#endif
#ifndef D3_S_texBlurred
#define D3_S_texBlurred s0
#endif
#ifndef D3_VK_T_texBlurred
#define D3_VK_T_texBlurred D3_VK_UNBOUND_T(376)
#endif
#ifndef D3_VK_S_texBlurred
#define D3_VK_S_texBlurred D3_VK_UNBOUND_S(377)
#endif
[[vk::binding(D3_VK_T_texBlurred, D3_VK_TSET)]] Texture2D texBlurred : register(D3_T_texBlurred);
[[vk::binding(D3_VK_S_texBlurred, D3_VK_SSET)]] SamplerState texBlurred_s : register(D3_S_texBlurred);

#ifndef D3_T_texColorCorrectA
#define D3_T_texColorCorrectA t0
#endif
#ifndef D3_S_texColorCorrectA
#define D3_S_texColorCorrectA s0
#endif
#ifndef D3_VK_T_texColorCorrectA
#define D3_VK_T_texColorCorrectA D3_VK_UNBOUND_T(378)
#endif
#ifndef D3_VK_S_texColorCorrectA
#define D3_VK_S_texColorCorrectA D3_VK_UNBOUND_S(379)
#endif
[[vk::binding(D3_VK_T_texColorCorrectA, D3_VK_TSET)]] Texture2D texColorCorrectA : register(D3_T_texColorCorrectA);
[[vk::binding(D3_VK_S_texColorCorrectA, D3_VK_SSET)]] SamplerState texColorCorrectA_s : register(D3_S_texColorCorrectA);

#ifndef D3_T_texColorCorrectA1
#define D3_T_texColorCorrectA1 t0
#endif
#ifndef D3_S_texColorCorrectA1
#define D3_S_texColorCorrectA1 s0
#endif
#ifndef D3_VK_T_texColorCorrectA1
#define D3_VK_T_texColorCorrectA1 D3_VK_UNBOUND_T(380)
#endif
#ifndef D3_VK_S_texColorCorrectA1
#define D3_VK_S_texColorCorrectA1 D3_VK_UNBOUND_S(381)
#endif
[[vk::binding(D3_VK_T_texColorCorrectA1, D3_VK_TSET)]] Texture2D texColorCorrectA1 : register(D3_T_texColorCorrectA1);
[[vk::binding(D3_VK_S_texColorCorrectA1, D3_VK_SSET)]] SamplerState texColorCorrectA1_s : register(D3_S_texColorCorrectA1);

#ifndef D3_T_texColorCorrectA2
#define D3_T_texColorCorrectA2 t0
#endif
#ifndef D3_S_texColorCorrectA2
#define D3_S_texColorCorrectA2 s0
#endif
#ifndef D3_VK_T_texColorCorrectA2
#define D3_VK_T_texColorCorrectA2 D3_VK_UNBOUND_T(382)
#endif
#ifndef D3_VK_S_texColorCorrectA2
#define D3_VK_S_texColorCorrectA2 D3_VK_UNBOUND_S(383)
#endif
[[vk::binding(D3_VK_T_texColorCorrectA2, D3_VK_TSET)]] Texture2D texColorCorrectA2 : register(D3_T_texColorCorrectA2);
[[vk::binding(D3_VK_S_texColorCorrectA2, D3_VK_SSET)]] SamplerState texColorCorrectA2_s : register(D3_S_texColorCorrectA2);

#ifndef D3_T_texColorCorrectB
#define D3_T_texColorCorrectB t0
#endif
#ifndef D3_S_texColorCorrectB
#define D3_S_texColorCorrectB s0
#endif
#ifndef D3_VK_T_texColorCorrectB
#define D3_VK_T_texColorCorrectB D3_VK_UNBOUND_T(384)
#endif
#ifndef D3_VK_S_texColorCorrectB
#define D3_VK_S_texColorCorrectB D3_VK_UNBOUND_S(385)
#endif
[[vk::binding(D3_VK_T_texColorCorrectB, D3_VK_TSET)]] Texture2D texColorCorrectB : register(D3_T_texColorCorrectB);
[[vk::binding(D3_VK_S_texColorCorrectB, D3_VK_SSET)]] SamplerState texColorCorrectB_s : register(D3_S_texColorCorrectB);

#ifndef D3_T_texColorCorrectB1
#define D3_T_texColorCorrectB1 t0
#endif
#ifndef D3_S_texColorCorrectB1
#define D3_S_texColorCorrectB1 s0
#endif
#ifndef D3_VK_T_texColorCorrectB1
#define D3_VK_T_texColorCorrectB1 D3_VK_UNBOUND_T(386)
#endif
#ifndef D3_VK_S_texColorCorrectB1
#define D3_VK_S_texColorCorrectB1 D3_VK_UNBOUND_S(387)
#endif
[[vk::binding(D3_VK_T_texColorCorrectB1, D3_VK_TSET)]] Texture2D texColorCorrectB1 : register(D3_T_texColorCorrectB1);
[[vk::binding(D3_VK_S_texColorCorrectB1, D3_VK_SSET)]] SamplerState texColorCorrectB1_s : register(D3_S_texColorCorrectB1);

#ifndef D3_T_texColorCorrectB2
#define D3_T_texColorCorrectB2 t0
#endif
#ifndef D3_S_texColorCorrectB2
#define D3_S_texColorCorrectB2 s0
#endif
#ifndef D3_VK_T_texColorCorrectB2
#define D3_VK_T_texColorCorrectB2 D3_VK_UNBOUND_T(388)
#endif
#ifndef D3_VK_S_texColorCorrectB2
#define D3_VK_S_texColorCorrectB2 D3_VK_UNBOUND_S(389)
#endif
[[vk::binding(D3_VK_T_texColorCorrectB2, D3_VK_TSET)]] Texture2D texColorCorrectB2 : register(D3_T_texColorCorrectB2);
[[vk::binding(D3_VK_S_texColorCorrectB2, D3_VK_SSET)]] SamplerState texColorCorrectB2_s : register(D3_S_texColorCorrectB2);

#ifndef D3_T_texDistortion
#define D3_T_texDistortion t0
#endif
#ifndef D3_S_texDistortion
#define D3_S_texDistortion s0
#endif
#ifndef D3_VK_T_texDistortion
#define D3_VK_T_texDistortion D3_VK_UNBOUND_T(390)
#endif
#ifndef D3_VK_S_texDistortion
#define D3_VK_S_texDistortion D3_VK_UNBOUND_S(391)
#endif
[[vk::binding(D3_VK_T_texDistortion, D3_VK_TSET)]] Texture2D texDistortion : register(D3_T_texDistortion);
[[vk::binding(D3_VK_S_texDistortion, D3_VK_SSET)]] SamplerState texDistortion_s : register(D3_S_texDistortion);

#ifndef D3_T_texExplored
#define D3_T_texExplored t0
#endif
#ifndef D3_S_texExplored
#define D3_S_texExplored s0
#endif
#ifndef D3_VK_T_texExplored
#define D3_VK_T_texExplored D3_VK_UNBOUND_T(392)
#endif
#ifndef D3_VK_S_texExplored
#define D3_VK_S_texExplored D3_VK_UNBOUND_S(393)
#endif
[[vk::binding(D3_VK_T_texExplored, D3_VK_TSET)]] Texture2D texExplored : register(D3_T_texExplored);
[[vk::binding(D3_VK_S_texExplored, D3_VK_SSET)]] SamplerState texExplored_s : register(D3_S_texExplored);

#ifndef D3_T_texFrac
#define D3_T_texFrac t0
#endif
#ifndef D3_S_texFrac
#define D3_S_texFrac s0
#endif
#ifndef D3_VK_T_texFrac
#define D3_VK_T_texFrac D3_VK_UNBOUND_T(394)
#endif
#ifndef D3_VK_S_texFrac
#define D3_VK_S_texFrac D3_VK_UNBOUND_S(395)
#endif
[[vk::binding(D3_VK_T_texFrac, D3_VK_TSET)]] Texture2D texFrac : register(D3_T_texFrac);
[[vk::binding(D3_VK_S_texFrac, D3_VK_SSET)]] SamplerState texFrac_s : register(D3_S_texFrac);

#ifndef D3_T_texOriginal
#define D3_T_texOriginal t0
#endif
#ifndef D3_S_texOriginal
#define D3_S_texOriginal s0
#endif
#ifndef D3_VK_T_texOriginal
#define D3_VK_T_texOriginal D3_VK_UNBOUND_T(396)
#endif
#ifndef D3_VK_S_texOriginal
#define D3_VK_S_texOriginal D3_VK_UNBOUND_S(397)
#endif
[[vk::binding(D3_VK_T_texOriginal, D3_VK_TSET)]] Texture2D texOriginal : register(D3_T_texOriginal);
[[vk::binding(D3_VK_S_texOriginal, D3_VK_SSET)]] SamplerState texOriginal_s : register(D3_S_texOriginal);

#ifndef D3_T_texSampler0
#define D3_T_texSampler0 t0
#endif
#ifndef D3_S_texSampler0
#define D3_S_texSampler0 s0
#endif
#ifndef D3_VK_T_texSampler0
#define D3_VK_T_texSampler0 D3_VK_UNBOUND_T(398)
#endif
#ifndef D3_VK_S_texSampler0
#define D3_VK_S_texSampler0 D3_VK_UNBOUND_S(399)
#endif
[[vk::binding(D3_VK_T_texSampler0, D3_VK_TSET)]] Texture2D texSampler0 : register(D3_T_texSampler0);
[[vk::binding(D3_VK_S_texSampler0, D3_VK_SSET)]] SamplerState texSampler0_s : register(D3_S_texSampler0);

#ifndef D3_T_texSatVignette
#define D3_T_texSatVignette t0
#endif
#ifndef D3_S_texSatVignette
#define D3_S_texSatVignette s0
#endif
#ifndef D3_VK_T_texSatVignette
#define D3_VK_T_texSatVignette D3_VK_UNBOUND_T(400)
#endif
#ifndef D3_VK_S_texSatVignette
#define D3_VK_S_texSatVignette D3_VK_UNBOUND_S(401)
#endif
[[vk::binding(D3_VK_T_texSatVignette, D3_VK_TSET)]] Texture2D texSatVignette : register(D3_T_texSatVignette);
[[vk::binding(D3_VK_S_texSatVignette, D3_VK_SSET)]] SamplerState texSatVignette_s : register(D3_S_texSatVignette);

#ifndef D3_T_texSatVignette1
#define D3_T_texSatVignette1 t0
#endif
#ifndef D3_S_texSatVignette1
#define D3_S_texSatVignette1 s0
#endif
#ifndef D3_VK_T_texSatVignette1
#define D3_VK_T_texSatVignette1 D3_VK_UNBOUND_T(402)
#endif
#ifndef D3_VK_S_texSatVignette1
#define D3_VK_S_texSatVignette1 D3_VK_UNBOUND_S(403)
#endif
[[vk::binding(D3_VK_T_texSatVignette1, D3_VK_TSET)]] Texture2D texSatVignette1 : register(D3_T_texSatVignette1);
[[vk::binding(D3_VK_S_texSatVignette1, D3_VK_SSET)]] SamplerState texSatVignette1_s : register(D3_S_texSatVignette1);

#ifndef D3_T_texSatVignette2
#define D3_T_texSatVignette2 t0
#endif
#ifndef D3_S_texSatVignette2
#define D3_S_texSatVignette2 s0
#endif
#ifndef D3_VK_T_texSatVignette2
#define D3_VK_T_texSatVignette2 D3_VK_UNBOUND_T(404)
#endif
#ifndef D3_VK_S_texSatVignette2
#define D3_VK_S_texSatVignette2 D3_VK_UNBOUND_S(405)
#endif
[[vk::binding(D3_VK_T_texSatVignette2, D3_VK_TSET)]] Texture2D texSatVignette2 : register(D3_T_texSatVignette2);
[[vk::binding(D3_VK_S_texSatVignette2, D3_VK_SSET)]] SamplerState texSatVignette2_s : register(D3_S_texSatVignette2);
