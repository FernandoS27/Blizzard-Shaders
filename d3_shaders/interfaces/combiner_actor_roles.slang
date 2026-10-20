// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Texture roles of the actor programs that are stage-combiner passes (plan M7
// residue): Actor.fx's glow layers (`texDiffuse` / `texGloss` / `texGlow` /
// `texAlphaMask`) and the actor lightning flow (`diffuseSampler0` and
// `flowSampler0` beside the numbered samplers the shared table already has).
// Each only names the texture a combiner unit reads (interfaces/combiner.slang);
// `texDiffuse`, `texGloss` and `texAlphaMask` are in interfaces/combiner_roles.slang.

implementing d3_shaders;

public struct DiffuseSampler0 : ITextureRole
{
    public static float4 sample(float2 uv) { return diffuseSampler0.Sample(diffuseSampler0_s, uv); }
};

public struct FlowSampler0 : ITextureRole
{
    public static float4 sample(float2 uv) { return flowSampler0.Sample(flowSampler0_s, uv); }
};

public struct TexGlow : ITextureRole
{
    public static float4 sample(float2 uv) { return texGlow.Sample(texGlow_s, uv); }
};
