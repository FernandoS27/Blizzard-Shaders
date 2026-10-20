// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// More texture roles a combiner stage can read (plan M7 residue programs):
// stage-combiner passes of other effects name their units after the
// material's maps (`texDiffuse`, `diffuseMap`, `texLayer0`, ...) instead of
// Legacy.fx's `sampler<n>`. The role only names the global; its register is
// the slot's measured data.

implementing d3_shaders;

public struct DiffuseMap : ITextureRole { public static float4 sample(float2 uv) { return diffuseMap.Sample(diffuseMap_s, uv); } };
public struct DiffuseTex : ITextureRole { public static float4 sample(float2 uv) { return diffuseTex.Sample(diffuseTex_s, uv); } };
public struct TexDiffuse : ITextureRole { public static float4 sample(float2 uv) { return texDiffuse.Sample(texDiffuse_s, uv); } };
public struct TexDiffuse0 : ITextureRole { public static float4 sample(float2 uv) { return texDiffuse0.Sample(texDiffuse0_s, uv); } };
public struct TexDiffuse1 : ITextureRole { public static float4 sample(float2 uv) { return texDiffuse1.Sample(texDiffuse1_s, uv); } };
public struct TexEnvMap : ITextureRole { public static float4 sample(float2 uv) { return texEnvMap.Sample(texEnvMap_s, uv); } };
public struct TexGloss : ITextureRole { public static float4 sample(float2 uv) { return texGloss.Sample(texGloss_s, uv); } };
public struct TexMask : ITextureRole { public static float4 sample(float2 uv) { return texMask.Sample(texMask_s, uv); } };
public struct TexAlphaMask : ITextureRole { public static float4 sample(float2 uv) { return texAlphaMask.Sample(texAlphaMask_s, uv); } };
public struct TexLayer0 : ITextureRole { public static float4 sample(float2 uv) { return texLayer0.Sample(texLayer0_s, uv); } };
public struct TexLayer1 : ITextureRole { public static float4 sample(float2 uv) { return texLayer1.Sample(texLayer1_s, uv); } };
public struct AlphaSampler : ITextureRole { public static float4 sample(float2 uv) { return alphaSampler.Sample(alphaSampler_s, uv); } };
public struct EnvironmentMapSampler : ITextureRole { public static float4 sample(float2 uv) { return environmentMapSampler.Sample(environmentMapSampler_s, uv); } };
public struct GlossMapSampler : ITextureRole { public static float4 sample(float2 uv) { return glossMapSampler.Sample(glossMapSampler_s, uv); } };
public struct LightMapSampler : ITextureRole { public static float4 sample(float2 uv) { return lightMapSampler.Sample(lightMapSampler_s, uv); } };
public struct NoiseMapSampler : ITextureRole { public static float4 sample(float2 uv) { return noiseMapSampler.Sample(noiseMapSampler_s, uv); } };
public struct AmbientMapSampler : ITextureRole { public static float4 sample(float2 uv) { return ambientMapSampler.Sample(ambientMapSampler_s, uv); } };
public struct TexReflection : ITextureRole { public static float4 sample(float2 uv) { return texReflection.Sample(texReflection_s, uv); } };
public struct TexFresnel : ITextureRole { public static float4 sample(float2 uv) { return texFresnel.Sample(texFresnel_s, uv); } };
public struct TexLightMap : ITextureRole { public static float4 sample(float2 uv) { return texLightMap.Sample(texLightMap_s, uv); } };
public struct TexNormalMap : ITextureRole { public static float4 sample(float2 uv) { return texNormalMap.Sample(texNormalMap_s, uv); } };
public struct NormalMap : ITextureRole { public static float4 sample(float2 uv) { return normalMap.Sample(normalMap_s, uv); } };
public struct DiffuseOverlayMap : ITextureRole { public static float4 sample(float2 uv) { return diffuseOverlayMap.Sample(diffuseOverlayMap_s, uv); } };
public struct PmaTex : ITextureRole { public static float4 sample(float2 uv) { return pmaTex.Sample(pmaTex_s, uv); } };
public struct PmaMaskTex : ITextureRole { public static float4 sample(float2 uv) { return pmaMaskTex.Sample(pmaMaskTex_s, uv); } };
