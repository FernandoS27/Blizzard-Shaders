// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture roles only the actor residue programs (plan M7) bind: the ghost,
// cloak, crystal, revive and tornado effects of ActorIrrad.fx and the Actor.fx
// glow layers. Declared exactly like types/textures.slang -- the register is
// per-slot measured data, `-D D3_T_<role>=tN -D D3_S_<role>=sN` -- and kept in
// their own file so the shared role table stays untouched. Their unbound
// default bindings (non-D3D targets) start at 900, clear of the shared table.

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

#ifndef D3_T_alpha1Map
#define D3_T_alpha1Map t0
#endif
#ifndef D3_S_alpha1Map
#define D3_S_alpha1Map s0
#endif
#ifndef D3_VK_T_alpha1Map
#define D3_VK_T_alpha1Map D3_VK_UNBOUND_T(900)
#endif
#ifndef D3_VK_S_alpha1Map
#define D3_VK_S_alpha1Map D3_VK_UNBOUND_S(901)
#endif
[[vk::binding(D3_VK_T_alpha1Map, D3_VK_TSET)]] Texture2D alpha1Map : register(D3_T_alpha1Map);
[[vk::binding(D3_VK_S_alpha1Map, D3_VK_SSET)]] SamplerState alpha1Map_s : register(D3_S_alpha1Map);

#ifndef D3_T_alpha2Map
#define D3_T_alpha2Map t0
#endif
#ifndef D3_S_alpha2Map
#define D3_S_alpha2Map s0
#endif
#ifndef D3_VK_T_alpha2Map
#define D3_VK_T_alpha2Map D3_VK_UNBOUND_T(902)
#endif
#ifndef D3_VK_S_alpha2Map
#define D3_VK_S_alpha2Map D3_VK_UNBOUND_S(903)
#endif
[[vk::binding(D3_VK_T_alpha2Map, D3_VK_TSET)]] Texture2D alpha2Map : register(D3_T_alpha2Map);
[[vk::binding(D3_VK_S_alpha2Map, D3_VK_SSET)]] SamplerState alpha2Map_s : register(D3_S_alpha2Map);

#ifndef D3_T_animatedMap
#define D3_T_animatedMap t0
#endif
#ifndef D3_S_animatedMap
#define D3_S_animatedMap s0
#endif
#ifndef D3_VK_T_animatedMap
#define D3_VK_T_animatedMap D3_VK_UNBOUND_T(904)
#endif
#ifndef D3_VK_S_animatedMap
#define D3_VK_S_animatedMap D3_VK_UNBOUND_S(905)
#endif
[[vk::binding(D3_VK_T_animatedMap, D3_VK_TSET)]] Texture2D animatedMap : register(D3_T_animatedMap);
[[vk::binding(D3_VK_S_animatedMap, D3_VK_SSET)]] SamplerState animatedMap_s : register(D3_S_animatedMap);

#ifndef D3_T_diffuse1Map
#define D3_T_diffuse1Map t0
#endif
#ifndef D3_S_diffuse1Map
#define D3_S_diffuse1Map s0
#endif
#ifndef D3_VK_T_diffuse1Map
#define D3_VK_T_diffuse1Map D3_VK_UNBOUND_T(906)
#endif
#ifndef D3_VK_S_diffuse1Map
#define D3_VK_S_diffuse1Map D3_VK_UNBOUND_S(907)
#endif
[[vk::binding(D3_VK_T_diffuse1Map, D3_VK_TSET)]] Texture2D diffuse1Map : register(D3_T_diffuse1Map);
[[vk::binding(D3_VK_S_diffuse1Map, D3_VK_SSET)]] SamplerState diffuse1Map_s : register(D3_S_diffuse1Map);

#ifndef D3_T_diffuse2Map
#define D3_T_diffuse2Map t0
#endif
#ifndef D3_S_diffuse2Map
#define D3_S_diffuse2Map s0
#endif
#ifndef D3_VK_T_diffuse2Map
#define D3_VK_T_diffuse2Map D3_VK_UNBOUND_T(908)
#endif
#ifndef D3_VK_S_diffuse2Map
#define D3_VK_S_diffuse2Map D3_VK_UNBOUND_S(909)
#endif
[[vk::binding(D3_VK_T_diffuse2Map, D3_VK_TSET)]] Texture2D diffuse2Map : register(D3_T_diffuse2Map);
[[vk::binding(D3_VK_S_diffuse2Map, D3_VK_SSET)]] SamplerState diffuse2Map_s : register(D3_S_diffuse2Map);

#ifndef D3_T_diffuseOverlay1Map
#define D3_T_diffuseOverlay1Map t0
#endif
#ifndef D3_S_diffuseOverlay1Map
#define D3_S_diffuseOverlay1Map s0
#endif
#ifndef D3_VK_T_diffuseOverlay1Map
#define D3_VK_T_diffuseOverlay1Map D3_VK_UNBOUND_T(910)
#endif
#ifndef D3_VK_S_diffuseOverlay1Map
#define D3_VK_S_diffuseOverlay1Map D3_VK_UNBOUND_S(911)
#endif
[[vk::binding(D3_VK_T_diffuseOverlay1Map, D3_VK_TSET)]] Texture2D diffuseOverlay1Map : register(D3_T_diffuseOverlay1Map);
[[vk::binding(D3_VK_S_diffuseOverlay1Map, D3_VK_SSET)]] SamplerState diffuseOverlay1Map_s : register(D3_S_diffuseOverlay1Map);

#ifndef D3_T_diffuseOverlay2Map
#define D3_T_diffuseOverlay2Map t0
#endif
#ifndef D3_S_diffuseOverlay2Map
#define D3_S_diffuseOverlay2Map s0
#endif
#ifndef D3_VK_T_diffuseOverlay2Map
#define D3_VK_T_diffuseOverlay2Map D3_VK_UNBOUND_T(912)
#endif
#ifndef D3_VK_S_diffuseOverlay2Map
#define D3_VK_S_diffuseOverlay2Map D3_VK_UNBOUND_S(913)
#endif
[[vk::binding(D3_VK_T_diffuseOverlay2Map, D3_VK_TSET)]] Texture2D diffuseOverlay2Map : register(D3_T_diffuseOverlay2Map);
[[vk::binding(D3_VK_S_diffuseOverlay2Map, D3_VK_SSET)]] SamplerState diffuseOverlay2Map_s : register(D3_S_diffuseOverlay2Map);

#ifndef D3_T_diffuseSampler0
#define D3_T_diffuseSampler0 t0
#endif
#ifndef D3_S_diffuseSampler0
#define D3_S_diffuseSampler0 s0
#endif
#ifndef D3_VK_T_diffuseSampler0
#define D3_VK_T_diffuseSampler0 D3_VK_UNBOUND_T(914)
#endif
#ifndef D3_VK_S_diffuseSampler0
#define D3_VK_S_diffuseSampler0 D3_VK_UNBOUND_S(915)
#endif
[[vk::binding(D3_VK_T_diffuseSampler0, D3_VK_TSET)]] Texture2D diffuseSampler0 : register(D3_T_diffuseSampler0);
[[vk::binding(D3_VK_S_diffuseSampler0, D3_VK_SSET)]] SamplerState diffuseSampler0_s : register(D3_S_diffuseSampler0);

#ifndef D3_T_dissipationMap
#define D3_T_dissipationMap t0
#endif
#ifndef D3_S_dissipationMap
#define D3_S_dissipationMap s0
#endif
#ifndef D3_VK_T_dissipationMap
#define D3_VK_T_dissipationMap D3_VK_UNBOUND_T(916)
#endif
#ifndef D3_VK_S_dissipationMap
#define D3_VK_S_dissipationMap D3_VK_UNBOUND_S(917)
#endif
[[vk::binding(D3_VK_T_dissipationMap, D3_VK_TSET)]] Texture2D dissipationMap : register(D3_T_dissipationMap);
[[vk::binding(D3_VK_S_dissipationMap, D3_VK_SSET)]] SamplerState dissipationMap_s : register(D3_S_dissipationMap);

#ifndef D3_T_flowSampler0
#define D3_T_flowSampler0 t0
#endif
#ifndef D3_S_flowSampler0
#define D3_S_flowSampler0 s0
#endif
#ifndef D3_VK_T_flowSampler0
#define D3_VK_T_flowSampler0 D3_VK_UNBOUND_T(918)
#endif
#ifndef D3_VK_S_flowSampler0
#define D3_VK_S_flowSampler0 D3_VK_UNBOUND_S(919)
#endif
[[vk::binding(D3_VK_T_flowSampler0, D3_VK_TSET)]] Texture2D flowSampler0 : register(D3_T_flowSampler0);
[[vk::binding(D3_VK_S_flowSampler0, D3_VK_SSET)]] SamplerState flowSampler0_s : register(D3_S_flowSampler0);

#ifndef D3_T_ghostMap
#define D3_T_ghostMap t0
#endif
#ifndef D3_S_ghostMap
#define D3_S_ghostMap s0
#endif
#ifndef D3_VK_T_ghostMap
#define D3_VK_T_ghostMap D3_VK_UNBOUND_T(920)
#endif
#ifndef D3_VK_S_ghostMap
#define D3_VK_S_ghostMap D3_VK_UNBOUND_S(921)
#endif
[[vk::binding(D3_VK_T_ghostMap, D3_VK_TSET)]] Texture2D ghostMap : register(D3_T_ghostMap);
[[vk::binding(D3_VK_S_ghostMap, D3_VK_SSET)]] SamplerState ghostMap_s : register(D3_S_ghostMap);

#ifndef D3_T_layer3DiffuseMap
#define D3_T_layer3DiffuseMap t0
#endif
#ifndef D3_S_layer3DiffuseMap
#define D3_S_layer3DiffuseMap s0
#endif
#ifndef D3_VK_T_layer3DiffuseMap
#define D3_VK_T_layer3DiffuseMap D3_VK_UNBOUND_T(922)
#endif
#ifndef D3_VK_S_layer3DiffuseMap
#define D3_VK_S_layer3DiffuseMap D3_VK_UNBOUND_S(923)
#endif
[[vk::binding(D3_VK_T_layer3DiffuseMap, D3_VK_TSET)]] Texture2D layer3DiffuseMap : register(D3_T_layer3DiffuseMap);
[[vk::binding(D3_VK_S_layer3DiffuseMap, D3_VK_SSET)]] SamplerState layer3DiffuseMap_s : register(D3_S_layer3DiffuseMap);

#ifndef D3_T_refractionMap
#define D3_T_refractionMap t0
#endif
#ifndef D3_S_refractionMap
#define D3_S_refractionMap s0
#endif
#ifndef D3_VK_T_refractionMap
#define D3_VK_T_refractionMap D3_VK_UNBOUND_T(924)
#endif
#ifndef D3_VK_S_refractionMap
#define D3_VK_S_refractionMap D3_VK_UNBOUND_S(925)
#endif
[[vk::binding(D3_VK_T_refractionMap, D3_VK_TSET)]] Texture2D refractionMap : register(D3_T_refractionMap);
[[vk::binding(D3_VK_S_refractionMap, D3_VK_SSET)]] SamplerState refractionMap_s : register(D3_S_refractionMap);

#ifndef D3_T_texGloss
#define D3_T_texGloss t0
#endif
#ifndef D3_S_texGloss
#define D3_S_texGloss s0
#endif
#ifndef D3_VK_T_texGloss
#define D3_VK_T_texGloss D3_VK_UNBOUND_T(926)
#endif
#ifndef D3_VK_S_texGloss
#define D3_VK_S_texGloss D3_VK_UNBOUND_S(927)
#endif
[[vk::binding(D3_VK_T_texGloss, D3_VK_TSET)]] Texture2D texGloss : register(D3_T_texGloss);
[[vk::binding(D3_VK_S_texGloss, D3_VK_SSET)]] SamplerState texGloss_s : register(D3_S_texGloss);

#ifndef D3_T_texGlow
#define D3_T_texGlow t0
#endif
#ifndef D3_S_texGlow
#define D3_S_texGlow s0
#endif
#ifndef D3_VK_T_texGlow
#define D3_VK_T_texGlow D3_VK_UNBOUND_T(928)
#endif
#ifndef D3_VK_S_texGlow
#define D3_VK_S_texGlow D3_VK_UNBOUND_S(929)
#endif
[[vk::binding(D3_VK_T_texGlow, D3_VK_TSET)]] Texture2D texGlow : register(D3_T_texGlow);
[[vk::binding(D3_VK_S_texGlow, D3_VK_SSET)]] SamplerState texGlow_s : register(D3_S_texGlow);
