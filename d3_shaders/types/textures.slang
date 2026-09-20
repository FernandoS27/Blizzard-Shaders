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

implementing d3_shaders;

#ifndef D3_T_alphaMap0Sampler
#define D3_T_alphaMap0Sampler t0
#endif
#ifndef D3_S_alphaMap0Sampler
#define D3_S_alphaMap0Sampler s0
#endif
#ifndef D3_VK_T_alphaMap0Sampler
#define D3_VK_T_alphaMap0Sampler 200
#endif
#ifndef D3_VK_S_alphaMap0Sampler
#define D3_VK_S_alphaMap0Sampler 201
#endif
[[vk::binding(D3_VK_T_alphaMap0Sampler, 0)]] Texture2D alphaMap0Sampler : register(D3_T_alphaMap0Sampler);
[[vk::binding(D3_VK_S_alphaMap0Sampler, 0)]] SamplerState alphaMap0Sampler_s : register(D3_S_alphaMap0Sampler);

#ifndef D3_T_alphaMap1Sampler
#define D3_T_alphaMap1Sampler t0
#endif
#ifndef D3_S_alphaMap1Sampler
#define D3_S_alphaMap1Sampler s0
#endif
#ifndef D3_VK_T_alphaMap1Sampler
#define D3_VK_T_alphaMap1Sampler 202
#endif
#ifndef D3_VK_S_alphaMap1Sampler
#define D3_VK_S_alphaMap1Sampler 203
#endif
[[vk::binding(D3_VK_T_alphaMap1Sampler, 0)]] Texture2D alphaMap1Sampler : register(D3_T_alphaMap1Sampler);
[[vk::binding(D3_VK_S_alphaMap1Sampler, 0)]] SamplerState alphaMap1Sampler_s : register(D3_S_alphaMap1Sampler);

#ifndef D3_T_alphaMap2Sampler
#define D3_T_alphaMap2Sampler t0
#endif
#ifndef D3_S_alphaMap2Sampler
#define D3_S_alphaMap2Sampler s0
#endif
#ifndef D3_VK_T_alphaMap2Sampler
#define D3_VK_T_alphaMap2Sampler 204
#endif
#ifndef D3_VK_S_alphaMap2Sampler
#define D3_VK_S_alphaMap2Sampler 205
#endif
[[vk::binding(D3_VK_T_alphaMap2Sampler, 0)]] Texture2D alphaMap2Sampler : register(D3_T_alphaMap2Sampler);
[[vk::binding(D3_VK_S_alphaMap2Sampler, 0)]] SamplerState alphaMap2Sampler_s : register(D3_S_alphaMap2Sampler);

#ifndef D3_T_backgroundMap
#define D3_T_backgroundMap t0
#endif
#ifndef D3_S_backgroundMap
#define D3_S_backgroundMap s0
#endif
#ifndef D3_VK_T_backgroundMap
#define D3_VK_T_backgroundMap 206
#endif
#ifndef D3_VK_S_backgroundMap
#define D3_VK_S_backgroundMap 207
#endif
[[vk::binding(D3_VK_T_backgroundMap, 0)]] Texture2D backgroundMap : register(D3_T_backgroundMap);
[[vk::binding(D3_VK_S_backgroundMap, 0)]] SamplerState backgroundMap_s : register(D3_S_backgroundMap);

#ifndef D3_T_bannerMap
#define D3_T_bannerMap t0
#endif
#ifndef D3_S_bannerMap
#define D3_S_bannerMap s0
#endif
#ifndef D3_VK_T_bannerMap
#define D3_VK_T_bannerMap 208
#endif
#ifndef D3_VK_S_bannerMap
#define D3_VK_S_bannerMap 209
#endif
[[vk::binding(D3_VK_T_bannerMap, 0)]] Texture2D bannerMap : register(D3_T_bannerMap);
[[vk::binding(D3_VK_S_bannerMap, 0)]] SamplerState bannerMap_s : register(D3_S_bannerMap);

#ifndef D3_T_diffuse1Sampler
#define D3_T_diffuse1Sampler t0
#endif
#ifndef D3_S_diffuse1Sampler
#define D3_S_diffuse1Sampler s0
#endif
#ifndef D3_VK_T_diffuse1Sampler
#define D3_VK_T_diffuse1Sampler 210
#endif
#ifndef D3_VK_S_diffuse1Sampler
#define D3_VK_S_diffuse1Sampler 211
#endif
[[vk::binding(D3_VK_T_diffuse1Sampler, 0)]] Texture2D diffuse1Sampler : register(D3_T_diffuse1Sampler);
[[vk::binding(D3_VK_S_diffuse1Sampler, 0)]] SamplerState diffuse1Sampler_s : register(D3_S_diffuse1Sampler);

#ifndef D3_T_diffuseMap
#define D3_T_diffuseMap t0
#endif
#ifndef D3_S_diffuseMap
#define D3_S_diffuseMap s0
#endif
#ifndef D3_VK_T_diffuseMap
#define D3_VK_T_diffuseMap 212
#endif
#ifndef D3_VK_S_diffuseMap
#define D3_VK_S_diffuseMap 213
#endif
[[vk::binding(D3_VK_T_diffuseMap, 0)]] Texture2D diffuseMap : register(D3_T_diffuseMap);
[[vk::binding(D3_VK_S_diffuseMap, 0)]] SamplerState diffuseMap_s : register(D3_S_diffuseMap);

#ifndef D3_T_diffuseOverlayMap
#define D3_T_diffuseOverlayMap t0
#endif
#ifndef D3_S_diffuseOverlayMap
#define D3_S_diffuseOverlayMap s0
#endif
#ifndef D3_VK_T_diffuseOverlayMap
#define D3_VK_T_diffuseOverlayMap 214
#endif
#ifndef D3_VK_S_diffuseOverlayMap
#define D3_VK_S_diffuseOverlayMap 215
#endif
[[vk::binding(D3_VK_T_diffuseOverlayMap, 0)]] Texture2D diffuseOverlayMap : register(D3_T_diffuseOverlayMap);
[[vk::binding(D3_VK_S_diffuseOverlayMap, 0)]] SamplerState diffuseOverlayMap_s : register(D3_S_diffuseOverlayMap);

#ifndef D3_T_diffuseSampler
#define D3_T_diffuseSampler t0
#endif
#ifndef D3_S_diffuseSampler
#define D3_S_diffuseSampler s0
#endif
#ifndef D3_VK_T_diffuseSampler
#define D3_VK_T_diffuseSampler 216
#endif
#ifndef D3_VK_S_diffuseSampler
#define D3_VK_S_diffuseSampler 217
#endif
[[vk::binding(D3_VK_T_diffuseSampler, 0)]] Texture2D diffuseSampler : register(D3_T_diffuseSampler);
[[vk::binding(D3_VK_S_diffuseSampler, 0)]] SamplerState diffuseSampler_s : register(D3_S_diffuseSampler);

#ifndef D3_T_diffuseSampler1
#define D3_T_diffuseSampler1 t0
#endif
#ifndef D3_S_diffuseSampler1
#define D3_S_diffuseSampler1 s0
#endif
#ifndef D3_VK_T_diffuseSampler1
#define D3_VK_T_diffuseSampler1 218
#endif
#ifndef D3_VK_S_diffuseSampler1
#define D3_VK_S_diffuseSampler1 219
#endif
[[vk::binding(D3_VK_T_diffuseSampler1, 0)]] Texture2D diffuseSampler1 : register(D3_T_diffuseSampler1);
[[vk::binding(D3_VK_S_diffuseSampler1, 0)]] SamplerState diffuseSampler1_s : register(D3_S_diffuseSampler1);

#ifndef D3_T_diffuseSampler2
#define D3_T_diffuseSampler2 t0
#endif
#ifndef D3_S_diffuseSampler2
#define D3_S_diffuseSampler2 s0
#endif
#ifndef D3_VK_T_diffuseSampler2
#define D3_VK_T_diffuseSampler2 220
#endif
#ifndef D3_VK_S_diffuseSampler2
#define D3_VK_S_diffuseSampler2 221
#endif
[[vk::binding(D3_VK_T_diffuseSampler2, 0)]] Texture2D diffuseSampler2 : register(D3_T_diffuseSampler2);
[[vk::binding(D3_VK_S_diffuseSampler2, 0)]] SamplerState diffuseSampler2_s : register(D3_S_diffuseSampler2);

#ifndef D3_T_diffuseSamplerA
#define D3_T_diffuseSamplerA t0
#endif
#ifndef D3_S_diffuseSamplerA
#define D3_S_diffuseSamplerA s0
#endif
#ifndef D3_VK_T_diffuseSamplerA
#define D3_VK_T_diffuseSamplerA 222
#endif
#ifndef D3_VK_S_diffuseSamplerA
#define D3_VK_S_diffuseSamplerA 223
#endif
[[vk::binding(D3_VK_T_diffuseSamplerA, 0)]] Texture2D diffuseSamplerA : register(D3_T_diffuseSamplerA);
[[vk::binding(D3_VK_S_diffuseSamplerA, 0)]] SamplerState diffuseSamplerA_s : register(D3_S_diffuseSamplerA);

#ifndef D3_T_diffuseSamplerB
#define D3_T_diffuseSamplerB t0
#endif
#ifndef D3_S_diffuseSamplerB
#define D3_S_diffuseSamplerB s0
#endif
#ifndef D3_VK_T_diffuseSamplerB
#define D3_VK_T_diffuseSamplerB 224
#endif
#ifndef D3_VK_S_diffuseSamplerB
#define D3_VK_S_diffuseSamplerB 225
#endif
[[vk::binding(D3_VK_T_diffuseSamplerB, 0)]] Texture2D diffuseSamplerB : register(D3_T_diffuseSamplerB);
[[vk::binding(D3_VK_S_diffuseSamplerB, 0)]] SamplerState diffuseSamplerB_s : register(D3_S_diffuseSamplerB);

#ifndef D3_T_diffuseTex
#define D3_T_diffuseTex t0
#endif
#ifndef D3_S_diffuseTex
#define D3_S_diffuseTex s0
#endif
#ifndef D3_VK_T_diffuseTex
#define D3_VK_T_diffuseTex 226
#endif
#ifndef D3_VK_S_diffuseTex
#define D3_VK_S_diffuseTex 227
#endif
[[vk::binding(D3_VK_T_diffuseTex, 0)]] Texture2D diffuseTex : register(D3_T_diffuseTex);
[[vk::binding(D3_VK_S_diffuseTex, 0)]] SamplerState diffuseTex_s : register(D3_S_diffuseTex);

#ifndef D3_T_environmentMap
#define D3_T_environmentMap t0
#endif
#ifndef D3_S_environmentMap
#define D3_S_environmentMap s0
#endif
#ifndef D3_VK_T_environmentMap
#define D3_VK_T_environmentMap 228
#endif
#ifndef D3_VK_S_environmentMap
#define D3_VK_S_environmentMap 229
#endif
[[vk::binding(D3_VK_T_environmentMap, 0)]] Texture2D environmentMap : register(D3_T_environmentMap);
[[vk::binding(D3_VK_S_environmentMap, 0)]] SamplerState environmentMap_s : register(D3_S_environmentMap);

#ifndef D3_T_environmentMapSampler
#define D3_T_environmentMapSampler t0
#endif
#ifndef D3_S_environmentMapSampler
#define D3_S_environmentMapSampler s0
#endif
#ifndef D3_VK_T_environmentMapSampler
#define D3_VK_T_environmentMapSampler 230
#endif
#ifndef D3_VK_S_environmentMapSampler
#define D3_VK_S_environmentMapSampler 231
#endif
[[vk::binding(D3_VK_T_environmentMapSampler, 0)]] Texture2D environmentMapSampler : register(D3_T_environmentMapSampler);
[[vk::binding(D3_VK_S_environmentMapSampler, 0)]] SamplerState environmentMapSampler_s : register(D3_S_environmentMapSampler);

#ifndef D3_T_flowSampler
#define D3_T_flowSampler t0
#endif
#ifndef D3_S_flowSampler
#define D3_S_flowSampler s0
#endif
#ifndef D3_VK_T_flowSampler
#define D3_VK_T_flowSampler 232
#endif
#ifndef D3_VK_S_flowSampler
#define D3_VK_S_flowSampler 233
#endif
[[vk::binding(D3_VK_T_flowSampler, 0)]] Texture2D flowSampler : register(D3_T_flowSampler);
[[vk::binding(D3_VK_S_flowSampler, 0)]] SamplerState flowSampler_s : register(D3_S_flowSampler);

#ifndef D3_T_flowSampler1
#define D3_T_flowSampler1 t0
#endif
#ifndef D3_S_flowSampler1
#define D3_S_flowSampler1 s0
#endif
#ifndef D3_VK_T_flowSampler1
#define D3_VK_T_flowSampler1 234
#endif
#ifndef D3_VK_S_flowSampler1
#define D3_VK_S_flowSampler1 235
#endif
[[vk::binding(D3_VK_T_flowSampler1, 0)]] Texture2D flowSampler1 : register(D3_T_flowSampler1);
[[vk::binding(D3_VK_S_flowSampler1, 0)]] SamplerState flowSampler1_s : register(D3_S_flowSampler1);

#ifndef D3_T_flowSampler2
#define D3_T_flowSampler2 t0
#endif
#ifndef D3_S_flowSampler2
#define D3_S_flowSampler2 s0
#endif
#ifndef D3_VK_T_flowSampler2
#define D3_VK_T_flowSampler2 236
#endif
#ifndef D3_VK_S_flowSampler2
#define D3_VK_S_flowSampler2 237
#endif
[[vk::binding(D3_VK_T_flowSampler2, 0)]] Texture2D flowSampler2 : register(D3_T_flowSampler2);
[[vk::binding(D3_VK_S_flowSampler2, 0)]] SamplerState flowSampler2_s : register(D3_S_flowSampler2);

#ifndef D3_T_flowSampler3
#define D3_T_flowSampler3 t0
#endif
#ifndef D3_S_flowSampler3
#define D3_S_flowSampler3 s0
#endif
#ifndef D3_VK_T_flowSampler3
#define D3_VK_T_flowSampler3 238
#endif
#ifndef D3_VK_S_flowSampler3
#define D3_VK_S_flowSampler3 239
#endif
[[vk::binding(D3_VK_T_flowSampler3, 0)]] Texture2D flowSampler3 : register(D3_T_flowSampler3);
[[vk::binding(D3_VK_S_flowSampler3, 0)]] SamplerState flowSampler3_s : register(D3_S_flowSampler3);

#ifndef D3_T_fogSampler
#define D3_T_fogSampler t0
#endif
#ifndef D3_S_fogSampler
#define D3_S_fogSampler s0
#endif
#ifndef D3_VK_T_fogSampler
#define D3_VK_T_fogSampler 240
#endif
#ifndef D3_VK_S_fogSampler
#define D3_VK_S_fogSampler 241
#endif
[[vk::binding(D3_VK_T_fogSampler, 0)]] Texture2D fogSampler : register(D3_T_fogSampler);
[[vk::binding(D3_VK_S_fogSampler, 0)]] SamplerState fogSampler_s : register(D3_S_fogSampler);

#ifndef D3_T_glossMap
#define D3_T_glossMap t0
#endif
#ifndef D3_S_glossMap
#define D3_S_glossMap s0
#endif
#ifndef D3_VK_T_glossMap
#define D3_VK_T_glossMap 242
#endif
#ifndef D3_VK_S_glossMap
#define D3_VK_S_glossMap 243
#endif
[[vk::binding(D3_VK_T_glossMap, 0)]] Texture2D glossMap : register(D3_T_glossMap);
[[vk::binding(D3_VK_S_glossMap, 0)]] SamplerState glossMap_s : register(D3_S_glossMap);

#ifndef D3_T_glossMapSampler
#define D3_T_glossMapSampler t0
#endif
#ifndef D3_S_glossMapSampler
#define D3_S_glossMapSampler s0
#endif
#ifndef D3_VK_T_glossMapSampler
#define D3_VK_T_glossMapSampler 244
#endif
#ifndef D3_VK_S_glossMapSampler
#define D3_VK_S_glossMapSampler 245
#endif
[[vk::binding(D3_VK_T_glossMapSampler, 0)]] Texture2D glossMapSampler : register(D3_T_glossMapSampler);
[[vk::binding(D3_VK_S_glossMapSampler, 0)]] SamplerState glossMapSampler_s : register(D3_S_glossMapSampler);

#ifndef D3_T_glowMap
#define D3_T_glowMap t0
#endif
#ifndef D3_S_glowMap
#define D3_S_glowMap s0
#endif
#ifndef D3_VK_T_glowMap
#define D3_VK_T_glowMap 246
#endif
#ifndef D3_VK_S_glowMap
#define D3_VK_S_glowMap 247
#endif
[[vk::binding(D3_VK_T_glowMap, 0)]] Texture2D glowMap : register(D3_T_glowMap);
[[vk::binding(D3_VK_S_glowMap, 0)]] SamplerState glowMap_s : register(D3_S_glowMap);

#ifndef D3_T_glowSampler
#define D3_T_glowSampler t0
#endif
#ifndef D3_S_glowSampler
#define D3_S_glowSampler s0
#endif
#ifndef D3_VK_T_glowSampler
#define D3_VK_T_glowSampler 248
#endif
#ifndef D3_VK_S_glowSampler
#define D3_VK_S_glowSampler 249
#endif
[[vk::binding(D3_VK_T_glowSampler, 0)]] Texture2D glowSampler : register(D3_T_glowSampler);
[[vk::binding(D3_VK_S_glowSampler, 0)]] SamplerState glowSampler_s : register(D3_S_glowSampler);

#ifndef D3_T_heroTintMap
#define D3_T_heroTintMap t0
#endif
#ifndef D3_S_heroTintMap
#define D3_S_heroTintMap s0
#endif
#ifndef D3_VK_T_heroTintMap
#define D3_VK_T_heroTintMap 250
#endif
#ifndef D3_VK_S_heroTintMap
#define D3_VK_S_heroTintMap 251
#endif
[[vk::binding(D3_VK_T_heroTintMap, 0)]] Texture2D heroTintMap : register(D3_T_heroTintMap);
[[vk::binding(D3_VK_S_heroTintMap, 0)]] SamplerState heroTintMap_s : register(D3_S_heroTintMap);

#ifndef D3_T_irradianceMap
#define D3_T_irradianceMap t0
#endif
#ifndef D3_S_irradianceMap
#define D3_S_irradianceMap s0
#endif
#ifndef D3_VK_T_irradianceMap
#define D3_VK_T_irradianceMap 252
#endif
#ifndef D3_VK_S_irradianceMap
#define D3_VK_S_irradianceMap 253
#endif
[[vk::binding(D3_VK_T_irradianceMap, 0)]] TextureCube irradianceMap : register(D3_T_irradianceMap);
[[vk::binding(D3_VK_S_irradianceMap, 0)]] SamplerState irradianceMap_s : register(D3_S_irradianceMap);

#ifndef D3_T_layer1AlphaMap
#define D3_T_layer1AlphaMap t0
#endif
#ifndef D3_S_layer1AlphaMap
#define D3_S_layer1AlphaMap s0
#endif
#ifndef D3_VK_T_layer1AlphaMap
#define D3_VK_T_layer1AlphaMap 254
#endif
#ifndef D3_VK_S_layer1AlphaMap
#define D3_VK_S_layer1AlphaMap 255
#endif
[[vk::binding(D3_VK_T_layer1AlphaMap, 0)]] Texture2D layer1AlphaMap : register(D3_T_layer1AlphaMap);
[[vk::binding(D3_VK_S_layer1AlphaMap, 0)]] SamplerState layer1AlphaMap_s : register(D3_S_layer1AlphaMap);

#ifndef D3_T_layer1DiffuseMap
#define D3_T_layer1DiffuseMap t0
#endif
#ifndef D3_S_layer1DiffuseMap
#define D3_S_layer1DiffuseMap s0
#endif
#ifndef D3_VK_T_layer1DiffuseMap
#define D3_VK_T_layer1DiffuseMap 256
#endif
#ifndef D3_VK_S_layer1DiffuseMap
#define D3_VK_S_layer1DiffuseMap 257
#endif
[[vk::binding(D3_VK_T_layer1DiffuseMap, 0)]] Texture2D layer1DiffuseMap : register(D3_T_layer1DiffuseMap);
[[vk::binding(D3_VK_S_layer1DiffuseMap, 0)]] SamplerState layer1DiffuseMap_s : register(D3_S_layer1DiffuseMap);

#ifndef D3_T_layer2AlphaMap
#define D3_T_layer2AlphaMap t0
#endif
#ifndef D3_S_layer2AlphaMap
#define D3_S_layer2AlphaMap s0
#endif
#ifndef D3_VK_T_layer2AlphaMap
#define D3_VK_T_layer2AlphaMap 258
#endif
#ifndef D3_VK_S_layer2AlphaMap
#define D3_VK_S_layer2AlphaMap 259
#endif
[[vk::binding(D3_VK_T_layer2AlphaMap, 0)]] Texture2D layer2AlphaMap : register(D3_T_layer2AlphaMap);
[[vk::binding(D3_VK_S_layer2AlphaMap, 0)]] SamplerState layer2AlphaMap_s : register(D3_S_layer2AlphaMap);

#ifndef D3_T_layer2DiffuseMap
#define D3_T_layer2DiffuseMap t0
#endif
#ifndef D3_S_layer2DiffuseMap
#define D3_S_layer2DiffuseMap s0
#endif
#ifndef D3_VK_T_layer2DiffuseMap
#define D3_VK_T_layer2DiffuseMap 260
#endif
#ifndef D3_VK_S_layer2DiffuseMap
#define D3_VK_S_layer2DiffuseMap 261
#endif
[[vk::binding(D3_VK_T_layer2DiffuseMap, 0)]] Texture2D layer2DiffuseMap : register(D3_T_layer2DiffuseMap);
[[vk::binding(D3_VK_S_layer2DiffuseMap, 0)]] SamplerState layer2DiffuseMap_s : register(D3_S_layer2DiffuseMap);

#ifndef D3_T_lightMapSampler
#define D3_T_lightMapSampler t0
#endif
#ifndef D3_S_lightMapSampler
#define D3_S_lightMapSampler s0
#endif
#ifndef D3_VK_T_lightMapSampler
#define D3_VK_T_lightMapSampler 262
#endif
#ifndef D3_VK_S_lightMapSampler
#define D3_VK_S_lightMapSampler 263
#endif
[[vk::binding(D3_VK_T_lightMapSampler, 0)]] Texture2D lightMapSampler : register(D3_T_lightMapSampler);
[[vk::binding(D3_VK_S_lightMapSampler, 0)]] SamplerState lightMapSampler_s : register(D3_S_lightMapSampler);

#ifndef D3_T_normalMap
#define D3_T_normalMap t0
#endif
#ifndef D3_S_normalMap
#define D3_S_normalMap s0
#endif
#ifndef D3_VK_T_normalMap
#define D3_VK_T_normalMap 264
#endif
#ifndef D3_VK_S_normalMap
#define D3_VK_S_normalMap 265
#endif
[[vk::binding(D3_VK_T_normalMap, 0)]] Texture2D normalMap : register(D3_T_normalMap);
[[vk::binding(D3_VK_S_normalMap, 0)]] SamplerState normalMap_s : register(D3_S_normalMap);

#ifndef D3_T_normalMap2
#define D3_T_normalMap2 t0
#endif
#ifndef D3_S_normalMap2
#define D3_S_normalMap2 s0
#endif
#ifndef D3_VK_T_normalMap2
#define D3_VK_T_normalMap2 266
#endif
#ifndef D3_VK_S_normalMap2
#define D3_VK_S_normalMap2 267
#endif
[[vk::binding(D3_VK_T_normalMap2, 0)]] Texture2D normalMap2 : register(D3_T_normalMap2);
[[vk::binding(D3_VK_S_normalMap2, 0)]] SamplerState normalMap2_s : register(D3_S_normalMap2);

#ifndef D3_T_normalMapSampler
#define D3_T_normalMapSampler t0
#endif
#ifndef D3_S_normalMapSampler
#define D3_S_normalMapSampler s0
#endif
#ifndef D3_VK_T_normalMapSampler
#define D3_VK_T_normalMapSampler 268
#endif
#ifndef D3_VK_S_normalMapSampler
#define D3_VK_S_normalMapSampler 269
#endif
[[vk::binding(D3_VK_T_normalMapSampler, 0)]] Texture2D normalMapSampler : register(D3_T_normalMapSampler);
[[vk::binding(D3_VK_S_normalMapSampler, 0)]] SamplerState normalMapSampler_s : register(D3_S_normalMapSampler);

#ifndef D3_T_normalMapSampler0
#define D3_T_normalMapSampler0 t0
#endif
#ifndef D3_S_normalMapSampler0
#define D3_S_normalMapSampler0 s0
#endif
#ifndef D3_VK_T_normalMapSampler0
#define D3_VK_T_normalMapSampler0 270
#endif
#ifndef D3_VK_S_normalMapSampler0
#define D3_VK_S_normalMapSampler0 271
#endif
[[vk::binding(D3_VK_T_normalMapSampler0, 0)]] Texture2D normalMapSampler0 : register(D3_T_normalMapSampler0);
[[vk::binding(D3_VK_S_normalMapSampler0, 0)]] SamplerState normalMapSampler0_s : register(D3_S_normalMapSampler0);

#ifndef D3_T_normalMapSampler1
#define D3_T_normalMapSampler1 t0
#endif
#ifndef D3_S_normalMapSampler1
#define D3_S_normalMapSampler1 s0
#endif
#ifndef D3_VK_T_normalMapSampler1
#define D3_VK_T_normalMapSampler1 272
#endif
#ifndef D3_VK_S_normalMapSampler1
#define D3_VK_S_normalMapSampler1 273
#endif
[[vk::binding(D3_VK_T_normalMapSampler1, 0)]] Texture2D normalMapSampler1 : register(D3_T_normalMapSampler1);
[[vk::binding(D3_VK_S_normalMapSampler1, 0)]] SamplerState normalMapSampler1_s : register(D3_S_normalMapSampler1);

#ifndef D3_T_overlayMapSampler
#define D3_T_overlayMapSampler t0
#endif
#ifndef D3_S_overlayMapSampler
#define D3_S_overlayMapSampler s0
#endif
#ifndef D3_VK_T_overlayMapSampler
#define D3_VK_T_overlayMapSampler 274
#endif
#ifndef D3_VK_S_overlayMapSampler
#define D3_VK_S_overlayMapSampler 275
#endif
[[vk::binding(D3_VK_T_overlayMapSampler, 0)]] Texture2D overlayMapSampler : register(D3_T_overlayMapSampler);
[[vk::binding(D3_VK_S_overlayMapSampler, 0)]] SamplerState overlayMapSampler_s : register(D3_S_overlayMapSampler);

#ifndef D3_T_patternMap
#define D3_T_patternMap t0
#endif
#ifndef D3_S_patternMap
#define D3_S_patternMap s0
#endif
#ifndef D3_VK_T_patternMap
#define D3_VK_T_patternMap 276
#endif
#ifndef D3_VK_S_patternMap
#define D3_VK_S_patternMap 277
#endif
[[vk::binding(D3_VK_T_patternMap, 0)]] Texture2D patternMap : register(D3_T_patternMap);
[[vk::binding(D3_VK_S_patternMap, 0)]] SamplerState patternMap_s : register(D3_S_patternMap);

#ifndef D3_T_pmaMaskTex
#define D3_T_pmaMaskTex t0
#endif
#ifndef D3_S_pmaMaskTex
#define D3_S_pmaMaskTex s0
#endif
#ifndef D3_VK_T_pmaMaskTex
#define D3_VK_T_pmaMaskTex 278
#endif
#ifndef D3_VK_S_pmaMaskTex
#define D3_VK_S_pmaMaskTex 279
#endif
[[vk::binding(D3_VK_T_pmaMaskTex, 0)]] Texture2D pmaMaskTex : register(D3_T_pmaMaskTex);
[[vk::binding(D3_VK_S_pmaMaskTex, 0)]] SamplerState pmaMaskTex_s : register(D3_S_pmaMaskTex);

#ifndef D3_T_pmaTex
#define D3_T_pmaTex t0
#endif
#ifndef D3_S_pmaTex
#define D3_S_pmaTex s0
#endif
#ifndef D3_VK_T_pmaTex
#define D3_VK_T_pmaTex 280
#endif
#ifndef D3_VK_S_pmaTex
#define D3_VK_S_pmaTex 281
#endif
[[vk::binding(D3_VK_T_pmaTex, 0)]] Texture2D pmaTex : register(D3_T_pmaTex);
[[vk::binding(D3_VK_S_pmaTex, 0)]] SamplerState pmaTex_s : register(D3_S_pmaTex);

#ifndef D3_T_sampler0
#define D3_T_sampler0 t0
#endif
#ifndef D3_S_sampler0
#define D3_S_sampler0 s0
#endif
#ifndef D3_VK_T_sampler0
#define D3_VK_T_sampler0 282
#endif
#ifndef D3_VK_S_sampler0
#define D3_VK_S_sampler0 283
#endif
[[vk::binding(D3_VK_T_sampler0, 0)]] Texture2D sampler0 : register(D3_T_sampler0);
[[vk::binding(D3_VK_S_sampler0, 0)]] SamplerState sampler0_s : register(D3_S_sampler0);

#ifndef D3_T_sampler1
#define D3_T_sampler1 t0
#endif
#ifndef D3_S_sampler1
#define D3_S_sampler1 s0
#endif
#ifndef D3_VK_T_sampler1
#define D3_VK_T_sampler1 284
#endif
#ifndef D3_VK_S_sampler1
#define D3_VK_S_sampler1 285
#endif
[[vk::binding(D3_VK_T_sampler1, 0)]] Texture2D sampler1 : register(D3_T_sampler1);
[[vk::binding(D3_VK_S_sampler1, 0)]] SamplerState sampler1_s : register(D3_S_sampler1);

#ifndef D3_T_sampler2
#define D3_T_sampler2 t0
#endif
#ifndef D3_S_sampler2
#define D3_S_sampler2 s0
#endif
#ifndef D3_VK_T_sampler2
#define D3_VK_T_sampler2 286
#endif
#ifndef D3_VK_S_sampler2
#define D3_VK_S_sampler2 287
#endif
[[vk::binding(D3_VK_T_sampler2, 0)]] Texture2D sampler2 : register(D3_T_sampler2);
[[vk::binding(D3_VK_S_sampler2, 0)]] SamplerState sampler2_s : register(D3_S_sampler2);

#ifndef D3_T_sampler3
#define D3_T_sampler3 t0
#endif
#ifndef D3_S_sampler3
#define D3_S_sampler3 s0
#endif
#ifndef D3_VK_T_sampler3
#define D3_VK_T_sampler3 288
#endif
#ifndef D3_VK_S_sampler3
#define D3_VK_S_sampler3 289
#endif
[[vk::binding(D3_VK_T_sampler3, 0)]] Texture2D sampler3 : register(D3_T_sampler3);
[[vk::binding(D3_VK_S_sampler3, 0)]] SamplerState sampler3_s : register(D3_S_sampler3);

#ifndef D3_T_sampler4
#define D3_T_sampler4 t0
#endif
#ifndef D3_S_sampler4
#define D3_S_sampler4 s0
#endif
#ifndef D3_VK_T_sampler4
#define D3_VK_T_sampler4 290
#endif
#ifndef D3_VK_S_sampler4
#define D3_VK_S_sampler4 291
#endif
[[vk::binding(D3_VK_T_sampler4, 0)]] Texture2D sampler4 : register(D3_T_sampler4);
[[vk::binding(D3_VK_S_sampler4, 0)]] SamplerState sampler4_s : register(D3_S_sampler4);

#ifndef D3_T_sampler5
#define D3_T_sampler5 t0
#endif
#ifndef D3_S_sampler5
#define D3_S_sampler5 s0
#endif
#ifndef D3_VK_T_sampler5
#define D3_VK_T_sampler5 292
#endif
#ifndef D3_VK_S_sampler5
#define D3_VK_S_sampler5 293
#endif
[[vk::binding(D3_VK_T_sampler5, 0)]] Texture2D sampler5 : register(D3_T_sampler5);
[[vk::binding(D3_VK_S_sampler5, 0)]] SamplerState sampler5_s : register(D3_S_sampler5);

#ifndef D3_T_shadowMap
#define D3_T_shadowMap t0
#endif
#ifndef D3_S_shadowMap
#define D3_S_shadowMap s0
#endif
#ifndef D3_VK_T_shadowMap
#define D3_VK_T_shadowMap 294
#endif
#ifndef D3_VK_S_shadowMap
#define D3_VK_S_shadowMap 295
#endif
[[vk::binding(D3_VK_T_shadowMap, 0)]] Texture2D shadowMap : register(D3_T_shadowMap);
[[vk::binding(D3_VK_S_shadowMap, 0)]] SamplerState shadowMap_s : register(D3_S_shadowMap);
[[vk::binding(D3_VK_S_shadowMap, 0)]] SamplerComparisonState shadowMap_cmp : register(D3_S_shadowMap);

#ifndef D3_T_shadowMapSampler
#define D3_T_shadowMapSampler t0
#endif
#ifndef D3_S_shadowMapSampler
#define D3_S_shadowMapSampler s0
#endif
#ifndef D3_VK_T_shadowMapSampler
#define D3_VK_T_shadowMapSampler 296
#endif
#ifndef D3_VK_S_shadowMapSampler
#define D3_VK_S_shadowMapSampler 297
#endif
[[vk::binding(D3_VK_T_shadowMapSampler, 0)]] Texture2D shadowMapSampler : register(D3_T_shadowMapSampler);
[[vk::binding(D3_VK_S_shadowMapSampler, 0)]] SamplerState shadowMapSampler_s : register(D3_S_shadowMapSampler);
[[vk::binding(D3_VK_S_shadowMapSampler, 0)]] SamplerComparisonState shadowMapSampler_cmp : register(D3_S_shadowMapSampler);

#ifndef D3_T_sigilAccentMap
#define D3_T_sigilAccentMap t0
#endif
#ifndef D3_S_sigilAccentMap
#define D3_S_sigilAccentMap s0
#endif
#ifndef D3_VK_T_sigilAccentMap
#define D3_VK_T_sigilAccentMap 298
#endif
#ifndef D3_VK_S_sigilAccentMap
#define D3_VK_S_sigilAccentMap 299
#endif
[[vk::binding(D3_VK_T_sigilAccentMap, 0)]] Texture2D sigilAccentMap : register(D3_T_sigilAccentMap);
[[vk::binding(D3_VK_S_sigilAccentMap, 0)]] SamplerState sigilAccentMap_s : register(D3_S_sigilAccentMap);

#ifndef D3_T_sigilMainMap
#define D3_T_sigilMainMap t0
#endif
#ifndef D3_S_sigilMainMap
#define D3_S_sigilMainMap s0
#endif
#ifndef D3_VK_T_sigilMainMap
#define D3_VK_T_sigilMainMap 300
#endif
#ifndef D3_VK_S_sigilMainMap
#define D3_VK_S_sigilMainMap 301
#endif
[[vk::binding(D3_VK_T_sigilMainMap, 0)]] Texture2D sigilMainMap : register(D3_T_sigilMainMap);
[[vk::binding(D3_VK_S_sigilMainMap, 0)]] SamplerState sigilMainMap_s : register(D3_S_sigilMainMap);

#ifndef D3_T_ssaoSampler
#define D3_T_ssaoSampler t0
#endif
#ifndef D3_S_ssaoSampler
#define D3_S_ssaoSampler s0
#endif
#ifndef D3_VK_T_ssaoSampler
#define D3_VK_T_ssaoSampler 302
#endif
#ifndef D3_VK_S_ssaoSampler
#define D3_VK_S_ssaoSampler 303
#endif
[[vk::binding(D3_VK_T_ssaoSampler, 0)]] Texture2D ssaoSampler : register(D3_T_ssaoSampler);
[[vk::binding(D3_VK_S_ssaoSampler, 0)]] SamplerState ssaoSampler_s : register(D3_S_ssaoSampler);

#ifndef D3_T_texAlpha
#define D3_T_texAlpha t0
#endif
#ifndef D3_S_texAlpha
#define D3_S_texAlpha s0
#endif
#ifndef D3_VK_T_texAlpha
#define D3_VK_T_texAlpha 304
#endif
#ifndef D3_VK_S_texAlpha
#define D3_VK_S_texAlpha 305
#endif
[[vk::binding(D3_VK_T_texAlpha, 0)]] Texture2D texAlpha : register(D3_T_texAlpha);
[[vk::binding(D3_VK_S_texAlpha, 0)]] SamplerState texAlpha_s : register(D3_S_texAlpha);

#ifndef D3_T_texAlphaMask
#define D3_T_texAlphaMask t0
#endif
#ifndef D3_S_texAlphaMask
#define D3_S_texAlphaMask s0
#endif
#ifndef D3_VK_T_texAlphaMask
#define D3_VK_T_texAlphaMask 306
#endif
#ifndef D3_VK_S_texAlphaMask
#define D3_VK_S_texAlphaMask 307
#endif
[[vk::binding(D3_VK_T_texAlphaMask, 0)]] Texture2D texAlphaMask : register(D3_T_texAlphaMask);
[[vk::binding(D3_VK_S_texAlphaMask, 0)]] SamplerState texAlphaMask_s : register(D3_S_texAlphaMask);

#ifndef D3_T_texAnimated
#define D3_T_texAnimated t0
#endif
#ifndef D3_S_texAnimated
#define D3_S_texAnimated s0
#endif
#ifndef D3_VK_T_texAnimated
#define D3_VK_T_texAnimated 308
#endif
#ifndef D3_VK_S_texAnimated
#define D3_VK_S_texAnimated 309
#endif
[[vk::binding(D3_VK_T_texAnimated, 0)]] Texture2D texAnimated : register(D3_T_texAnimated);
[[vk::binding(D3_VK_S_texAnimated, 0)]] SamplerState texAnimated_s : register(D3_S_texAnimated);

#ifndef D3_T_texBlurredHighlight
#define D3_T_texBlurredHighlight t0
#endif
#ifndef D3_S_texBlurredHighlight
#define D3_S_texBlurredHighlight s0
#endif
#ifndef D3_VK_T_texBlurredHighlight
#define D3_VK_T_texBlurredHighlight 310
#endif
#ifndef D3_VK_S_texBlurredHighlight
#define D3_VK_S_texBlurredHighlight 311
#endif
[[vk::binding(D3_VK_T_texBlurredHighlight, 0)]] Texture2D texBlurredHighlight : register(D3_T_texBlurredHighlight);
[[vk::binding(D3_VK_S_texBlurredHighlight, 0)]] SamplerState texBlurredHighlight_s : register(D3_S_texBlurredHighlight);

#ifndef D3_T_texCrossU
#define D3_T_texCrossU t0
#endif
#ifndef D3_S_texCrossU
#define D3_S_texCrossU s0
#endif
#ifndef D3_VK_T_texCrossU
#define D3_VK_T_texCrossU 312
#endif
#ifndef D3_VK_S_texCrossU
#define D3_VK_S_texCrossU 313
#endif
[[vk::binding(D3_VK_T_texCrossU, 0)]] Texture2D texCrossU : register(D3_T_texCrossU);
[[vk::binding(D3_VK_S_texCrossU, 0)]] SamplerState texCrossU_s : register(D3_S_texCrossU);

#ifndef D3_T_texCrossV
#define D3_T_texCrossV t0
#endif
#ifndef D3_S_texCrossV
#define D3_S_texCrossV s0
#endif
#ifndef D3_VK_T_texCrossV
#define D3_VK_T_texCrossV 314
#endif
#ifndef D3_VK_S_texCrossV
#define D3_VK_S_texCrossV 315
#endif
[[vk::binding(D3_VK_T_texCrossV, 0)]] Texture2D texCrossV : register(D3_T_texCrossV);
[[vk::binding(D3_VK_S_texCrossV, 0)]] SamplerState texCrossV_s : register(D3_S_texCrossV);

#ifndef D3_T_texDepth
#define D3_T_texDepth t0
#endif
#ifndef D3_S_texDepth
#define D3_S_texDepth s0
#endif
#ifndef D3_VK_T_texDepth
#define D3_VK_T_texDepth 316
#endif
#ifndef D3_VK_S_texDepth
#define D3_VK_S_texDepth 317
#endif
[[vk::binding(D3_VK_T_texDepth, 0)]] Texture2D texDepth : register(D3_T_texDepth);
[[vk::binding(D3_VK_S_texDepth, 0)]] SamplerState texDepth_s : register(D3_S_texDepth);

#ifndef D3_T_texDiffuse
#define D3_T_texDiffuse t0
#endif
#ifndef D3_S_texDiffuse
#define D3_S_texDiffuse s0
#endif
#ifndef D3_VK_T_texDiffuse
#define D3_VK_T_texDiffuse 318
#endif
#ifndef D3_VK_S_texDiffuse
#define D3_VK_S_texDiffuse 319
#endif
[[vk::binding(D3_VK_T_texDiffuse, 0)]] Texture2D texDiffuse : register(D3_T_texDiffuse);
[[vk::binding(D3_VK_S_texDiffuse, 0)]] SamplerState texDiffuse_s : register(D3_S_texDiffuse);

#ifndef D3_T_texEnvMap
#define D3_T_texEnvMap t0
#endif
#ifndef D3_S_texEnvMap
#define D3_S_texEnvMap s0
#endif
#ifndef D3_VK_T_texEnvMap
#define D3_VK_T_texEnvMap 320
#endif
#ifndef D3_VK_S_texEnvMap
#define D3_VK_S_texEnvMap 321
#endif
[[vk::binding(D3_VK_T_texEnvMap, 0)]] Texture2D texEnvMap : register(D3_T_texEnvMap);
[[vk::binding(D3_VK_S_texEnvMap, 0)]] SamplerState texEnvMap_s : register(D3_S_texEnvMap);

#ifndef D3_T_texLayer0
#define D3_T_texLayer0 t0
#endif
#ifndef D3_S_texLayer0
#define D3_S_texLayer0 s0
#endif
#ifndef D3_VK_T_texLayer0
#define D3_VK_T_texLayer0 322
#endif
#ifndef D3_VK_S_texLayer0
#define D3_VK_S_texLayer0 323
#endif
[[vk::binding(D3_VK_T_texLayer0, 0)]] Texture2D texLayer0 : register(D3_T_texLayer0);
[[vk::binding(D3_VK_S_texLayer0, 0)]] SamplerState texLayer0_s : register(D3_S_texLayer0);

#ifndef D3_T_texLayer1
#define D3_T_texLayer1 t0
#endif
#ifndef D3_S_texLayer1
#define D3_S_texLayer1 s0
#endif
#ifndef D3_VK_T_texLayer1
#define D3_VK_T_texLayer1 324
#endif
#ifndef D3_VK_S_texLayer1
#define D3_VK_S_texLayer1 325
#endif
[[vk::binding(D3_VK_T_texLayer1, 0)]] Texture2D texLayer1 : register(D3_T_texLayer1);
[[vk::binding(D3_VK_S_texLayer1, 0)]] SamplerState texLayer1_s : register(D3_S_texLayer1);

#ifndef D3_T_texLayer2
#define D3_T_texLayer2 t0
#endif
#ifndef D3_S_texLayer2
#define D3_S_texLayer2 s0
#endif
#ifndef D3_VK_T_texLayer2
#define D3_VK_T_texLayer2 326
#endif
#ifndef D3_VK_S_texLayer2
#define D3_VK_S_texLayer2 327
#endif
[[vk::binding(D3_VK_T_texLayer2, 0)]] Texture2D texLayer2 : register(D3_T_texLayer2);
[[vk::binding(D3_VK_S_texLayer2, 0)]] SamplerState texLayer2_s : register(D3_S_texLayer2);

#ifndef D3_T_texLayer3
#define D3_T_texLayer3 t0
#endif
#ifndef D3_S_texLayer3
#define D3_S_texLayer3 s0
#endif
#ifndef D3_VK_T_texLayer3
#define D3_VK_T_texLayer3 328
#endif
#ifndef D3_VK_S_texLayer3
#define D3_VK_S_texLayer3 329
#endif
[[vk::binding(D3_VK_T_texLayer3, 0)]] Texture2D texLayer3 : register(D3_T_texLayer3);
[[vk::binding(D3_VK_S_texLayer3, 0)]] SamplerState texLayer3_s : register(D3_S_texLayer3);

#ifndef D3_T_texLayer4
#define D3_T_texLayer4 t0
#endif
#ifndef D3_S_texLayer4
#define D3_S_texLayer4 s0
#endif
#ifndef D3_VK_T_texLayer4
#define D3_VK_T_texLayer4 330
#endif
#ifndef D3_VK_S_texLayer4
#define D3_VK_S_texLayer4 331
#endif
[[vk::binding(D3_VK_T_texLayer4, 0)]] Texture2D texLayer4 : register(D3_T_texLayer4);
[[vk::binding(D3_VK_S_texLayer4, 0)]] SamplerState texLayer4_s : register(D3_S_texLayer4);

#ifndef D3_T_texLightmap
#define D3_T_texLightmap t0
#endif
#ifndef D3_S_texLightmap
#define D3_S_texLightmap s0
#endif
#ifndef D3_VK_T_texLightmap
#define D3_VK_T_texLightmap 332
#endif
#ifndef D3_VK_S_texLightmap
#define D3_VK_S_texLightmap 333
#endif
[[vk::binding(D3_VK_T_texLightmap, 0)]] Texture2D texLightmap : register(D3_T_texLightmap);
[[vk::binding(D3_VK_S_texLightmap, 0)]] SamplerState texLightmap_s : register(D3_S_texLightmap);

#ifndef D3_T_texMask
#define D3_T_texMask t0
#endif
#ifndef D3_S_texMask
#define D3_S_texMask s0
#endif
#ifndef D3_VK_T_texMask
#define D3_VK_T_texMask 334
#endif
#ifndef D3_VK_S_texMask
#define D3_VK_S_texMask 335
#endif
[[vk::binding(D3_VK_T_texMask, 0)]] Texture2D texMask : register(D3_T_texMask);
[[vk::binding(D3_VK_S_texMask, 0)]] SamplerState texMask_s : register(D3_S_texMask);

#ifndef D3_T_texMurk
#define D3_T_texMurk t0
#endif
#ifndef D3_S_texMurk
#define D3_S_texMurk s0
#endif
#ifndef D3_VK_T_texMurk
#define D3_VK_T_texMurk 336
#endif
#ifndef D3_VK_S_texMurk
#define D3_VK_S_texMurk 337
#endif
[[vk::binding(D3_VK_T_texMurk, 0)]] Texture2D texMurk : register(D3_T_texMurk);
[[vk::binding(D3_VK_S_texMurk, 0)]] SamplerState texMurk_s : register(D3_S_texMurk);

#ifndef D3_T_texNormal0
#define D3_T_texNormal0 t0
#endif
#ifndef D3_S_texNormal0
#define D3_S_texNormal0 s0
#endif
#ifndef D3_VK_T_texNormal0
#define D3_VK_T_texNormal0 338
#endif
#ifndef D3_VK_S_texNormal0
#define D3_VK_S_texNormal0 339
#endif
[[vk::binding(D3_VK_T_texNormal0, 0)]] Texture2D texNormal0 : register(D3_T_texNormal0);
[[vk::binding(D3_VK_S_texNormal0, 0)]] SamplerState texNormal0_s : register(D3_S_texNormal0);

#ifndef D3_T_texNormal1
#define D3_T_texNormal1 t0
#endif
#ifndef D3_S_texNormal1
#define D3_S_texNormal1 s0
#endif
#ifndef D3_VK_T_texNormal1
#define D3_VK_T_texNormal1 340
#endif
#ifndef D3_VK_S_texNormal1
#define D3_VK_S_texNormal1 341
#endif
[[vk::binding(D3_VK_T_texNormal1, 0)]] Texture2D texNormal1 : register(D3_T_texNormal1);
[[vk::binding(D3_VK_S_texNormal1, 0)]] SamplerState texNormal1_s : register(D3_S_texNormal1);

#ifndef D3_T_texNormal2
#define D3_T_texNormal2 t0
#endif
#ifndef D3_S_texNormal2
#define D3_S_texNormal2 s0
#endif
#ifndef D3_VK_T_texNormal2
#define D3_VK_T_texNormal2 342
#endif
#ifndef D3_VK_S_texNormal2
#define D3_VK_S_texNormal2 343
#endif
[[vk::binding(D3_VK_T_texNormal2, 0)]] Texture2D texNormal2 : register(D3_T_texNormal2);
[[vk::binding(D3_VK_S_texNormal2, 0)]] SamplerState texNormal2_s : register(D3_S_texNormal2);

#ifndef D3_T_texNormal3
#define D3_T_texNormal3 t0
#endif
#ifndef D3_S_texNormal3
#define D3_S_texNormal3 s0
#endif
#ifndef D3_VK_T_texNormal3
#define D3_VK_T_texNormal3 344
#endif
#ifndef D3_VK_S_texNormal3
#define D3_VK_S_texNormal3 345
#endif
[[vk::binding(D3_VK_T_texNormal3, 0)]] Texture2D texNormal3 : register(D3_T_texNormal3);
[[vk::binding(D3_VK_S_texNormal3, 0)]] SamplerState texNormal3_s : register(D3_S_texNormal3);

#ifndef D3_T_texNormal4
#define D3_T_texNormal4 t0
#endif
#ifndef D3_S_texNormal4
#define D3_S_texNormal4 s0
#endif
#ifndef D3_VK_T_texNormal4
#define D3_VK_T_texNormal4 346
#endif
#ifndef D3_VK_S_texNormal4
#define D3_VK_S_texNormal4 347
#endif
[[vk::binding(D3_VK_T_texNormal4, 0)]] Texture2D texNormal4 : register(D3_T_texNormal4);
[[vk::binding(D3_VK_S_texNormal4, 0)]] SamplerState texNormal4_s : register(D3_S_texNormal4);

#ifndef D3_T_texNormalMap
#define D3_T_texNormalMap t0
#endif
#ifndef D3_S_texNormalMap
#define D3_S_texNormalMap s0
#endif
#ifndef D3_VK_T_texNormalMap
#define D3_VK_T_texNormalMap 348
#endif
#ifndef D3_VK_S_texNormalMap
#define D3_VK_S_texNormalMap 349
#endif
[[vk::binding(D3_VK_T_texNormalMap, 0)]] Texture2D texNormalMap : register(D3_T_texNormalMap);
[[vk::binding(D3_VK_S_texNormalMap, 0)]] SamplerState texNormalMap_s : register(D3_S_texNormalMap);

#ifndef D3_T_texNormalMap2
#define D3_T_texNormalMap2 t0
#endif
#ifndef D3_S_texNormalMap2
#define D3_S_texNormalMap2 s0
#endif
#ifndef D3_VK_T_texNormalMap2
#define D3_VK_T_texNormalMap2 350
#endif
#ifndef D3_VK_S_texNormalMap2
#define D3_VK_S_texNormalMap2 351
#endif
[[vk::binding(D3_VK_T_texNormalMap2, 0)]] Texture2D texNormalMap2 : register(D3_T_texNormalMap2);
[[vk::binding(D3_VK_S_texNormalMap2, 0)]] SamplerState texNormalMap2_s : register(D3_S_texNormalMap2);

#ifndef D3_T_texOriginalHighlight
#define D3_T_texOriginalHighlight t0
#endif
#ifndef D3_S_texOriginalHighlight
#define D3_S_texOriginalHighlight s0
#endif
#ifndef D3_VK_T_texOriginalHighlight
#define D3_VK_T_texOriginalHighlight 352
#endif
#ifndef D3_VK_S_texOriginalHighlight
#define D3_VK_S_texOriginalHighlight 353
#endif
[[vk::binding(D3_VK_T_texOriginalHighlight, 0)]] Texture2D texOriginalHighlight : register(D3_T_texOriginalHighlight);
[[vk::binding(D3_VK_S_texOriginalHighlight, 0)]] SamplerState texOriginalHighlight_s : register(D3_S_texOriginalHighlight);

#ifndef D3_T_texReflection
#define D3_T_texReflection t0
#endif
#ifndef D3_S_texReflection
#define D3_S_texReflection s0
#endif
#ifndef D3_VK_T_texReflection
#define D3_VK_T_texReflection 354
#endif
#ifndef D3_VK_S_texReflection
#define D3_VK_S_texReflection 355
#endif
[[vk::binding(D3_VK_T_texReflection, 0)]] Texture2D texReflection : register(D3_T_texReflection);
[[vk::binding(D3_VK_S_texReflection, 0)]] SamplerState texReflection_s : register(D3_S_texReflection);

#ifndef D3_T_texReflection1
#define D3_T_texReflection1 t0
#endif
#ifndef D3_S_texReflection1
#define D3_S_texReflection1 s0
#endif
#ifndef D3_VK_T_texReflection1
#define D3_VK_T_texReflection1 356
#endif
#ifndef D3_VK_S_texReflection1
#define D3_VK_S_texReflection1 357
#endif
[[vk::binding(D3_VK_T_texReflection1, 0)]] Texture2D texReflection1 : register(D3_T_texReflection1);
[[vk::binding(D3_VK_S_texReflection1, 0)]] SamplerState texReflection1_s : register(D3_S_texReflection1);

#ifndef D3_T_texRefraction
#define D3_T_texRefraction t0
#endif
#ifndef D3_S_texRefraction
#define D3_S_texRefraction s0
#endif
#ifndef D3_VK_T_texRefraction
#define D3_VK_T_texRefraction 358
#endif
#ifndef D3_VK_S_texRefraction
#define D3_VK_S_texRefraction 359
#endif
[[vk::binding(D3_VK_T_texRefraction, 0)]] Texture2D texRefraction : register(D3_T_texRefraction);
[[vk::binding(D3_VK_S_texRefraction, 0)]] SamplerState texRefraction_s : register(D3_S_texRefraction);

#ifndef D3_T_texRipple
#define D3_T_texRipple t0
#endif
#ifndef D3_S_texRipple
#define D3_S_texRipple s0
#endif
#ifndef D3_VK_T_texRipple
#define D3_VK_T_texRipple 360
#endif
#ifndef D3_VK_S_texRipple
#define D3_VK_S_texRipple 361
#endif
[[vk::binding(D3_VK_T_texRipple, 0)]] Texture2D texRipple : register(D3_T_texRipple);
[[vk::binding(D3_VK_S_texRipple, 0)]] SamplerState texRipple_s : register(D3_S_texRipple);

#ifndef D3_T_texWhitewater
#define D3_T_texWhitewater t0
#endif
#ifndef D3_S_texWhitewater
#define D3_S_texWhitewater s0
#endif
#ifndef D3_VK_T_texWhitewater
#define D3_VK_T_texWhitewater 362
#endif
#ifndef D3_VK_S_texWhitewater
#define D3_VK_S_texWhitewater 363
#endif
[[vk::binding(D3_VK_T_texWhitewater, 0)]] Texture2D texWhitewater : register(D3_T_texWhitewater);
[[vk::binding(D3_VK_S_texWhitewater, 0)]] SamplerState texWhitewater_s : register(D3_S_texWhitewater);

#ifndef D3_T_texWhitewaterMask
#define D3_T_texWhitewaterMask t0
#endif
#ifndef D3_S_texWhitewaterMask
#define D3_S_texWhitewaterMask s0
#endif
#ifndef D3_VK_T_texWhitewaterMask
#define D3_VK_T_texWhitewaterMask 364
#endif
#ifndef D3_VK_S_texWhitewaterMask
#define D3_VK_S_texWhitewaterMask 365
#endif
[[vk::binding(D3_VK_T_texWhitewaterMask, 0)]] Texture2D texWhitewaterMask : register(D3_T_texWhitewaterMask);
[[vk::binding(D3_VK_S_texWhitewaterMask, 0)]] SamplerState texWhitewaterMask_s : register(D3_S_texWhitewaterMask);

#ifndef D3_T_tintRampMap
#define D3_T_tintRampMap t0
#endif
#ifndef D3_S_tintRampMap
#define D3_S_tintRampMap s0
#endif
#ifndef D3_VK_T_tintRampMap
#define D3_VK_T_tintRampMap 366
#endif
#ifndef D3_VK_S_tintRampMap
#define D3_VK_S_tintRampMap 367
#endif
[[vk::binding(D3_VK_T_tintRampMap, 0)]] Texture2D tintRampMap : register(D3_T_tintRampMap);
[[vk::binding(D3_VK_S_tintRampMap, 0)]] SamplerState tintRampMap_s : register(D3_S_tintRampMap);

#ifndef D3_T_vignetteMap
#define D3_T_vignetteMap t0
#endif
#ifndef D3_S_vignetteMap
#define D3_S_vignetteMap s0
#endif
#ifndef D3_VK_T_vignetteMap
#define D3_VK_T_vignetteMap 368
#endif
#ifndef D3_VK_S_vignetteMap
#define D3_VK_S_vignetteMap 369
#endif
[[vk::binding(D3_VK_T_vignetteMap, 0)]] Texture2D vignetteMap : register(D3_T_vignetteMap);
[[vk::binding(D3_VK_S_vignetteMap, 0)]] SamplerState vignetteMap_s : register(D3_S_vignetteMap);

#ifndef D3_T_vignetteSampler
#define D3_T_vignetteSampler t0
#endif
#ifndef D3_S_vignetteSampler
#define D3_S_vignetteSampler s0
#endif
#ifndef D3_VK_T_vignetteSampler
#define D3_VK_T_vignetteSampler 370
#endif
#ifndef D3_VK_S_vignetteSampler
#define D3_VK_S_vignetteSampler 371
#endif
[[vk::binding(D3_VK_T_vignetteSampler, 0)]] Texture2D vignetteSampler : register(D3_T_vignetteSampler);
[[vk::binding(D3_VK_S_vignetteSampler, 0)]] SamplerState vignetteSampler_s : register(D3_S_vignetteSampler);

#ifndef D3_T_waterSampler
#define D3_T_waterSampler t0
#endif
#ifndef D3_S_waterSampler
#define D3_S_waterSampler s0
#endif
#ifndef D3_VK_T_waterSampler
#define D3_VK_T_waterSampler 372
#endif
#ifndef D3_VK_S_waterSampler
#define D3_VK_S_waterSampler 373
#endif
[[vk::binding(D3_VK_T_waterSampler, 0)]] Texture2D waterSampler : register(D3_T_waterSampler);
[[vk::binding(D3_VK_S_waterSampler, 0)]] SamplerState waterSampler_s : register(D3_S_waterSampler);
