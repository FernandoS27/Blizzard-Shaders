// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture roles only residue particle programs bind (plan M7): the blend-add
// pair of Billboard.fx / SoftBillboard.fx (`diffuseMap` + `alphaMap`) and the
// water-sim sprite (`texDiffuse0`). Declared exactly like types/textures.slang:
// the register is per-slot measured data, the defaults only apply to a slot
// that does not read the role. The Vulkan defaults sit in their own range so
// they never meet the ones in types/textures.slang.

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

#ifndef D3_T_alphaMap
#define D3_T_alphaMap t0
#endif
#ifndef D3_S_alphaMap
#define D3_S_alphaMap s0
#endif
#ifndef D3_VK_T_alphaMap
#define D3_VK_T_alphaMap D3_VK_UNBOUND_T(640)
#endif
#ifndef D3_VK_S_alphaMap
#define D3_VK_S_alphaMap D3_VK_UNBOUND_S(641)
#endif
[[vk::binding(D3_VK_T_alphaMap, D3_VK_TSET)]] Texture2D alphaMap : register(D3_T_alphaMap);
[[vk::binding(D3_VK_S_alphaMap, D3_VK_SSET)]] SamplerState alphaMap_s : register(D3_S_alphaMap);

#ifndef D3_T_texDiffuse0
#define D3_T_texDiffuse0 t0
#endif
#ifndef D3_S_texDiffuse0
#define D3_S_texDiffuse0 s0
#endif
#ifndef D3_VK_T_texDiffuse0
#define D3_VK_T_texDiffuse0 D3_VK_UNBOUND_T(642)
#endif
#ifndef D3_VK_S_texDiffuse0
#define D3_VK_S_texDiffuse0 D3_VK_UNBOUND_S(643)
#endif
[[vk::binding(D3_VK_T_texDiffuse0, D3_VK_TSET)]] Texture2D texDiffuse0 : register(D3_T_texDiffuse0);
[[vk::binding(D3_VK_S_texDiffuse0, D3_VK_SSET)]] SamplerState texDiffuse0_s : register(D3_S_texDiffuse0);
