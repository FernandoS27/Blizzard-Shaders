// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture roles of the screen-space filter passes (TextureFilter.fx) that no
// mesh shader binds: the frame's colour, depth, normal and velocity targets,
// the SSAO buffers and the numbered inputs of the generic filters.
//
// Same scheme as types/textures.slang (registers are per-slot data, `D3_T_` /
// `D3_S_` from the measured resources), with one addition: multisampled depth.
//
// A multisampled texture is loaded, never sampled, so the Effects compiler
// gives it no sampler object and the retail program keeps the plain HLSL name
// `texDepth` instead of a mangled `texDeptht`. The mapper strips the last
// letter of every texture name to get the role, so the register of these
// textures arrives as `D3_T_texDept`. Retail declares the sample count in the
// texture type (`texture2dms(4)`), which makes each count its own role.
//
// Non-D3D default bindings start at 600, clear of types/textures.slang.

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

#ifndef D3_T_texColor
#define D3_T_texColor t0
#endif
#ifndef D3_S_texColor
#define D3_S_texColor s0
#endif
#ifndef D3_VK_T_texColor
#define D3_VK_T_texColor D3_VK_UNBOUND_T(600)
#endif
#ifndef D3_VK_S_texColor
#define D3_VK_S_texColor D3_VK_UNBOUND_S(601)
#endif
[[vk::binding(D3_VK_T_texColor, D3_VK_TSET)]] Texture2D texColor : register(D3_T_texColor);
[[vk::binding(D3_VK_S_texColor, D3_VK_SSET)]] SamplerState texColor_s : register(D3_S_texColor);

#ifndef D3_T_texColorMS
#define D3_T_texColorMS t0
#endif
#ifndef D3_S_texColorMS
#define D3_S_texColorMS s0
#endif
#ifndef D3_VK_T_texColorMS
#define D3_VK_T_texColorMS D3_VK_UNBOUND_T(602)
#endif
#ifndef D3_VK_S_texColorMS
#define D3_VK_S_texColorMS D3_VK_UNBOUND_S(603)
#endif
[[vk::binding(D3_VK_T_texColorMS, D3_VK_TSET)]] Texture2D texColorMS : register(D3_T_texColorMS);
[[vk::binding(D3_VK_S_texColorMS, D3_VK_SSET)]] SamplerState texColorMS_s : register(D3_S_texColorMS);

#ifndef D3_T_texDither
#define D3_T_texDither t0
#endif
#ifndef D3_S_texDither
#define D3_S_texDither s0
#endif
#ifndef D3_VK_T_texDither
#define D3_VK_T_texDither D3_VK_UNBOUND_T(604)
#endif
#ifndef D3_VK_S_texDither
#define D3_VK_S_texDither D3_VK_UNBOUND_S(605)
#endif
[[vk::binding(D3_VK_T_texDither, D3_VK_TSET)]] Texture2D texDither : register(D3_T_texDither);
[[vk::binding(D3_VK_S_texDither, D3_VK_SSET)]] SamplerState texDither_s : register(D3_S_texDither);

#ifndef D3_T_texNormal
#define D3_T_texNormal t0
#endif
#ifndef D3_S_texNormal
#define D3_S_texNormal s0
#endif
#ifndef D3_VK_T_texNormal
#define D3_VK_T_texNormal D3_VK_UNBOUND_T(606)
#endif
#ifndef D3_VK_S_texNormal
#define D3_VK_S_texNormal D3_VK_UNBOUND_S(607)
#endif
[[vk::binding(D3_VK_T_texNormal, D3_VK_TSET)]] Texture2D texNormal : register(D3_T_texNormal);
[[vk::binding(D3_VK_S_texNormal, D3_VK_SSET)]] SamplerState texNormal_s : register(D3_S_texNormal);

#ifndef D3_T_texRandom
#define D3_T_texRandom t0
#endif
#ifndef D3_S_texRandom
#define D3_S_texRandom s0
#endif
#ifndef D3_VK_T_texRandom
#define D3_VK_T_texRandom D3_VK_UNBOUND_T(610)
#endif
#ifndef D3_VK_S_texRandom
#define D3_VK_S_texRandom D3_VK_UNBOUND_S(611)
#endif
[[vk::binding(D3_VK_T_texRandom, D3_VK_TSET)]] Texture2D texRandom : register(D3_T_texRandom);
[[vk::binding(D3_VK_S_texRandom, D3_VK_SSET)]] SamplerState texRandom_s : register(D3_S_texRandom);

#ifndef D3_T_texSampler1
#define D3_T_texSampler1 t0
#endif
#ifndef D3_S_texSampler1
#define D3_S_texSampler1 s0
#endif
#ifndef D3_VK_T_texSampler1
#define D3_VK_T_texSampler1 D3_VK_UNBOUND_T(614)
#endif
#ifndef D3_VK_S_texSampler1
#define D3_VK_S_texSampler1 D3_VK_UNBOUND_S(615)
#endif
[[vk::binding(D3_VK_T_texSampler1, D3_VK_TSET)]] Texture2D texSampler1 : register(D3_T_texSampler1);
[[vk::binding(D3_VK_S_texSampler1, D3_VK_SSET)]] SamplerState texSampler1_s : register(D3_S_texSampler1);

#ifndef D3_T_texSampler2
#define D3_T_texSampler2 t0
#endif
#ifndef D3_S_texSampler2
#define D3_S_texSampler2 s0
#endif
#ifndef D3_VK_T_texSampler2
#define D3_VK_T_texSampler2 D3_VK_UNBOUND_T(616)
#endif
#ifndef D3_VK_S_texSampler2
#define D3_VK_S_texSampler2 D3_VK_UNBOUND_S(617)
#endif
[[vk::binding(D3_VK_T_texSampler2, D3_VK_TSET)]] Texture2D texSampler2 : register(D3_T_texSampler2);
[[vk::binding(D3_VK_S_texSampler2, D3_VK_SSET)]] SamplerState texSampler2_s : register(D3_S_texSampler2);

#ifndef D3_T_texSampler3
#define D3_T_texSampler3 t0
#endif
#ifndef D3_S_texSampler3
#define D3_S_texSampler3 s0
#endif
#ifndef D3_VK_T_texSampler3
#define D3_VK_T_texSampler3 D3_VK_UNBOUND_T(618)
#endif
#ifndef D3_VK_S_texSampler3
#define D3_VK_S_texSampler3 D3_VK_UNBOUND_S(619)
#endif
[[vk::binding(D3_VK_T_texSampler3, D3_VK_TSET)]] Texture2D texSampler3 : register(D3_T_texSampler3);
[[vk::binding(D3_VK_S_texSampler3, D3_VK_SSET)]] SamplerState texSampler3_s : register(D3_S_texSampler3);

#ifndef D3_T_texSSAOBuffer
#define D3_T_texSSAOBuffer t0
#endif
#ifndef D3_S_texSSAOBuffer
#define D3_S_texSSAOBuffer s0
#endif
#ifndef D3_VK_T_texSSAOBuffer
#define D3_VK_T_texSSAOBuffer D3_VK_UNBOUND_T(620)
#endif
#ifndef D3_VK_S_texSSAOBuffer
#define D3_VK_S_texSSAOBuffer D3_VK_UNBOUND_S(621)
#endif
[[vk::binding(D3_VK_T_texSSAOBuffer, D3_VK_TSET)]] Texture2D texSSAOBuffer : register(D3_T_texSSAOBuffer);
[[vk::binding(D3_VK_S_texSSAOBuffer, D3_VK_SSET)]] SamplerState texSSAOBuffer_s : register(D3_S_texSSAOBuffer);

#ifndef D3_T_texVelocity
#define D3_T_texVelocity t0
#endif
#ifndef D3_S_texVelocity
#define D3_S_texVelocity s0
#endif
#ifndef D3_VK_T_texVelocity
#define D3_VK_T_texVelocity D3_VK_UNBOUND_T(622)
#endif
#ifndef D3_VK_S_texVelocity
#define D3_VK_S_texVelocity D3_VK_UNBOUND_S(623)
#endif
[[vk::binding(D3_VK_T_texVelocity, D3_VK_TSET)]] Texture2D texVelocity : register(D3_T_texVelocity);
[[vk::binding(D3_VK_S_texVelocity, D3_VK_SSET)]] SamplerState texVelocity_s : register(D3_S_texVelocity);

#ifndef D3_T_texVignette
#define D3_T_texVignette t0
#endif
#ifndef D3_S_texVignette
#define D3_S_texVignette s0
#endif
#ifndef D3_VK_T_texVignette
#define D3_VK_T_texVignette D3_VK_UNBOUND_T(624)
#endif
#ifndef D3_VK_S_texVignette
#define D3_VK_S_texVignette D3_VK_UNBOUND_S(625)
#endif
[[vk::binding(D3_VK_T_texVignette, D3_VK_TSET)]] Texture2D texVignette : register(D3_T_texVignette);
[[vk::binding(D3_VK_S_texVignette, D3_VK_SSET)]] SamplerState texVignette_s : register(D3_S_texVignette);

#ifndef D3_T_texDept
#define D3_T_texDept t0
#endif
#ifndef D3_VK_T_texDept
#define D3_VK_T_texDept D3_VK_UNBOUND_T(626)
#endif
[[vk::binding(D3_VK_T_texDept, D3_VK_TSET)]] Texture2DMS<float4, 1> texDepthMS1 : register(D3_T_texDept);
[[vk::binding(D3_VK_T_texDept, D3_VK_TSET)]] Texture2DMS<float4, 2> texDepthMS2 : register(D3_T_texDept);
[[vk::binding(D3_VK_T_texDept, D3_VK_TSET)]] Texture2DMS<float4, 4> texDepthMS4 : register(D3_T_texDept);
[[vk::binding(D3_VK_T_texDept, D3_VK_TSET)]] Texture2DMS<float4, 8> texDepthMS8 : register(D3_T_texDept);
