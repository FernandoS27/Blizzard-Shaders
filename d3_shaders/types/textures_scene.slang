// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture roles only residue scene programs bind (plan M7): the river scum
// plane, the cracked-sand ground, the sm3 per-pixel scene surface's normal map,
// the four-layer glow floors and the legacy v11 glow / cloud programs. Declared
// exactly like types/textures.slang: the register is per-slot measured data, the
// defaults only apply to a slot that does not read the role. The Vulkan defaults
// sit in their own range (800 and up) so they never meet the other role files'.

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

#ifndef D3_T_diffuseCrackSampler
#define D3_T_diffuseCrackSampler t0
#endif
#ifndef D3_S_diffuseCrackSampler
#define D3_S_diffuseCrackSampler s0
#endif
#ifndef D3_VK_T_diffuseCrackSampler
#define D3_VK_T_diffuseCrackSampler D3_VK_UNBOUND_T(802)
#endif
#ifndef D3_VK_S_diffuseCrackSampler
#define D3_VK_S_diffuseCrackSampler D3_VK_UNBOUND_S(803)
#endif
[[vk::binding(D3_VK_T_diffuseCrackSampler, D3_VK_TSET)]] Texture2D diffuseCrackSampler : register(D3_T_diffuseCrackSampler);
[[vk::binding(D3_VK_S_diffuseCrackSampler, D3_VK_SSET)]] SamplerState diffuseCrackSampler_s : register(D3_S_diffuseCrackSampler);

#ifndef D3_T_diffuseSandSampler
#define D3_T_diffuseSandSampler t0
#endif
#ifndef D3_S_diffuseSandSampler
#define D3_S_diffuseSandSampler s0
#endif
#ifndef D3_VK_T_diffuseSandSampler
#define D3_VK_T_diffuseSandSampler D3_VK_UNBOUND_T(804)
#endif
#ifndef D3_VK_S_diffuseSandSampler
#define D3_VK_S_diffuseSandSampler D3_VK_UNBOUND_S(805)
#endif
[[vk::binding(D3_VK_T_diffuseSandSampler, D3_VK_TSET)]] Texture2D diffuseSandSampler : register(D3_T_diffuseSandSampler);
[[vk::binding(D3_VK_S_diffuseSandSampler, D3_VK_SSET)]] SamplerState diffuseSandSampler_s : register(D3_S_diffuseSandSampler);

#ifndef D3_T_glowSampler0
#define D3_T_glowSampler0 t0
#endif
#ifndef D3_S_glowSampler0
#define D3_S_glowSampler0 s0
#endif
#ifndef D3_VK_T_glowSampler0
#define D3_VK_T_glowSampler0 D3_VK_UNBOUND_T(806)
#endif
#ifndef D3_VK_S_glowSampler0
#define D3_VK_S_glowSampler0 D3_VK_UNBOUND_S(807)
#endif
[[vk::binding(D3_VK_T_glowSampler0, D3_VK_TSET)]] Texture2D glowSampler0 : register(D3_T_glowSampler0);
[[vk::binding(D3_VK_S_glowSampler0, D3_VK_SSET)]] SamplerState glowSampler0_s : register(D3_S_glowSampler0);

#ifndef D3_T_glowSampler1
#define D3_T_glowSampler1 t0
#endif
#ifndef D3_S_glowSampler1
#define D3_S_glowSampler1 s0
#endif
#ifndef D3_VK_T_glowSampler1
#define D3_VK_T_glowSampler1 D3_VK_UNBOUND_T(808)
#endif
#ifndef D3_VK_S_glowSampler1
#define D3_VK_S_glowSampler1 D3_VK_UNBOUND_S(809)
#endif
[[vk::binding(D3_VK_T_glowSampler1, D3_VK_TSET)]] Texture2D glowSampler1 : register(D3_T_glowSampler1);
[[vk::binding(D3_VK_S_glowSampler1, D3_VK_SSET)]] SamplerState glowSampler1_s : register(D3_S_glowSampler1);

#ifndef D3_T_glowSampler2
#define D3_T_glowSampler2 t0
#endif
#ifndef D3_S_glowSampler2
#define D3_S_glowSampler2 s0
#endif
#ifndef D3_VK_T_glowSampler2
#define D3_VK_T_glowSampler2 D3_VK_UNBOUND_T(810)
#endif
#ifndef D3_VK_S_glowSampler2
#define D3_VK_S_glowSampler2 D3_VK_UNBOUND_S(811)
#endif
[[vk::binding(D3_VK_T_glowSampler2, D3_VK_TSET)]] Texture2D glowSampler2 : register(D3_T_glowSampler2);
[[vk::binding(D3_VK_S_glowSampler2, D3_VK_SSET)]] SamplerState glowSampler2_s : register(D3_S_glowSampler2);

#ifndef D3_T_glowSampler3
#define D3_T_glowSampler3 t0
#endif
#ifndef D3_S_glowSampler3
#define D3_S_glowSampler3 s0
#endif
#ifndef D3_VK_T_glowSampler3
#define D3_VK_T_glowSampler3 D3_VK_UNBOUND_T(812)
#endif
#ifndef D3_VK_S_glowSampler3
#define D3_VK_S_glowSampler3 D3_VK_UNBOUND_S(813)
#endif
[[vk::binding(D3_VK_T_glowSampler3, D3_VK_TSET)]] Texture2D glowSampler3 : register(D3_T_glowSampler3);
[[vk::binding(D3_VK_S_glowSampler3, D3_VK_SSET)]] SamplerState glowSampler3_s : register(D3_S_glowSampler3);

#ifndef D3_T_normalSampler
#define D3_T_normalSampler t0
#endif
#ifndef D3_S_normalSampler
#define D3_S_normalSampler s0
#endif
#ifndef D3_VK_T_normalSampler
#define D3_VK_T_normalSampler D3_VK_UNBOUND_T(814)
#endif
#ifndef D3_VK_S_normalSampler
#define D3_VK_S_normalSampler D3_VK_UNBOUND_S(815)
#endif
[[vk::binding(D3_VK_T_normalSampler, D3_VK_TSET)]] Texture2D normalSampler : register(D3_T_normalSampler);
[[vk::binding(D3_VK_S_normalSampler, D3_VK_SSET)]] SamplerState normalSampler_s : register(D3_S_normalSampler);

#ifndef D3_T_scumSampler
#define D3_T_scumSampler t0
#endif
#ifndef D3_S_scumSampler
#define D3_S_scumSampler s0
#endif
#ifndef D3_VK_T_scumSampler
#define D3_VK_T_scumSampler D3_VK_UNBOUND_T(816)
#endif
#ifndef D3_VK_S_scumSampler
#define D3_VK_S_scumSampler D3_VK_UNBOUND_S(817)
#endif
[[vk::binding(D3_VK_T_scumSampler, D3_VK_TSET)]] Texture2D scumSampler : register(D3_T_scumSampler);
[[vk::binding(D3_VK_S_scumSampler, D3_VK_SSET)]] SamplerState scumSampler_s : register(D3_S_scumSampler);

#ifndef D3_T_tex0
#define D3_T_tex0 t0
#endif
#ifndef D3_S_tex0
#define D3_S_tex0 s0
#endif
#ifndef D3_VK_T_tex0
#define D3_VK_T_tex0 D3_VK_UNBOUND_T(818)
#endif
#ifndef D3_VK_S_tex0
#define D3_VK_S_tex0 D3_VK_UNBOUND_S(819)
#endif
[[vk::binding(D3_VK_T_tex0, D3_VK_TSET)]] Texture2D tex0 : register(D3_T_tex0);
[[vk::binding(D3_VK_S_tex0, D3_VK_SSET)]] SamplerState tex0_s : register(D3_S_tex0);

#ifndef D3_T_tex1
#define D3_T_tex1 t0
#endif
#ifndef D3_S_tex1
#define D3_S_tex1 s0
#endif
#ifndef D3_VK_T_tex1
#define D3_VK_T_tex1 D3_VK_UNBOUND_T(820)
#endif
#ifndef D3_VK_S_tex1
#define D3_VK_S_tex1 D3_VK_UNBOUND_S(821)
#endif
[[vk::binding(D3_VK_T_tex1, D3_VK_TSET)]] Texture2D tex1 : register(D3_T_tex1);
[[vk::binding(D3_VK_S_tex1, D3_VK_SSET)]] SamplerState tex1_s : register(D3_S_tex1);

#ifndef D3_T_tex2
#define D3_T_tex2 t0
#endif
#ifndef D3_S_tex2
#define D3_S_tex2 s0
#endif
#ifndef D3_VK_T_tex2
#define D3_VK_T_tex2 D3_VK_UNBOUND_T(822)
#endif
#ifndef D3_VK_S_tex2
#define D3_VK_S_tex2 D3_VK_UNBOUND_S(823)
#endif
[[vk::binding(D3_VK_T_tex2, D3_VK_TSET)]] Texture2D tex2 : register(D3_T_tex2);
[[vk::binding(D3_VK_S_tex2, D3_VK_SSET)]] SamplerState tex2_s : register(D3_S_tex2);

#ifndef D3_T_tex3
#define D3_T_tex3 t0
#endif
#ifndef D3_S_tex3
#define D3_S_tex3 s0
#endif
#ifndef D3_VK_T_tex3
#define D3_VK_T_tex3 D3_VK_UNBOUND_T(824)
#endif
#ifndef D3_VK_S_tex3
#define D3_VK_S_tex3 D3_VK_UNBOUND_S(825)
#endif
[[vk::binding(D3_VK_T_tex3, D3_VK_TSET)]] Texture2D tex3 : register(D3_T_tex3);
[[vk::binding(D3_VK_S_tex3, D3_VK_SSET)]] SamplerState tex3_s : register(D3_S_tex3);
