// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// SD highspec / lowspec (classic) vertex shader entry points.
//
// This is the retail SD pipeline: per-vertex Blinn-Phong-ish lighting,
// no shadows, no tangent frame. The VS is the only place where
// lighting is evaluated — the PS (sd_classic_ps.slang) just modulates
// the lit color with up to two fixed-function texture stages.
//
// `NUM_LIGHTS` is a compile-time count so the light loop unrolls; the
// engine instantiates variants for 0..8 active lights.
//
// `sd_lowspec_vs` (3.0.0) is this program over a 72-bone palette, compiled for
// shader model 4: its 162 permutations match highspec's instruction for
// instruction, the bone bank's length the only difference.

implementing wc3_shaders;

SDVSOutput sdClassicVS<
    TSkin : ISkinning,
    TVF   : IVertexFormat,
    let NUM_LIGHTS : int,
    TBones : ISDBoneSource
>(SDHighspecVSInput<TVF> input)
{
    SDVSOutput output;

    // Skinning (rigid / four-bone), identical to the HD entry — except that
    // this family has no tangent attribute at all (no shipped permutation
    // declares ATTR7), so a constant is passed and the skinned tangent is
    // discarded. It folds out: G4 still lands on retail's 108 classes.
    float3 skinnedPos, skinnedNormal, skinnedTangent;
    TSkin.transform<TBones>(
        input.position, input.normal, float4(0, 0, 0, 1),
        input.weights, input.boneIndices,
        skinnedPos, skinnedNormal, skinnedTangent);

    // World and clip transforms come from the SD highspec CB (b0)
    // rather than the shared vsCB2 — the SD highspec pipeline has a
    // different constant buffer layout.
    float3 worldPos = transformByWorld(skinnedPos, sdHighspecVsCB0.world);
    output.position = transformClipPos(skinnedPos, sdHighspecVsCB0.worldViewProj);
    output.worldPos = worldPos;

    // Material tint × optional per-vertex color.
    float4 material = sdHighspecVsCB0.diffuseColor;
    if (TVF.hasVertexColor)
        material = material * input.vertColor;

    // When at least one light is active, run the per-vertex light
    // loop and emit its output as the PS color; otherwise emit the
    // raw material so the PS still gets a tint to modulate.
    if (NUM_LIGHTS > 0)
    {
        float3 worldNormal = transformNormal(skinnedNormal, sdHighspecVsCB0.world);
        float3 lit = sdComputePerVertexLighting<NUM_LIGHTS>(
            worldNormal, worldPos, material, sdHighspecVsCB0.lights);
        output.color = float4(lit, material.w);
    }
    else
    {
        output.color = material;
    }

    // UV transforms — same as the HD path.
    output.texCoord = transformUVs<TVF>(
        input.uv0, input.uv1,
        sdHighspecVsCB0.texMtx0Row0, sdHighspecVsCB0.texMtx0Row1,
        sdHighspecVsCB0.texMtx1Row0, sdHighspecVsCB0.texMtx1Row1);

    return output;
}

[shader("vertex")]
public SDVSOutput sd_highspec_vs_main<
    TSkin : ISkinning,
    TVF   : IVertexFormat,
    let NUM_LIGHTS : int
>(SDHighspecVSInput<TVF> input)
{
    return sdClassicVS<TSkin, TVF, NUM_LIGHTS, ClassicBonePalette>(input);
}

[shader("vertex")]
public SDVSOutput sd_lowspec_vs_main<
    TSkin : ISkinning,
    TVF   : IVertexFormat,
    let NUM_LIGHTS : int
>(SDHighspecVSInput<TVF> input)
{
    return sdClassicVS<TSkin, TVF, NUM_LIGHTS, LowspecBonePalette>(input);
}
