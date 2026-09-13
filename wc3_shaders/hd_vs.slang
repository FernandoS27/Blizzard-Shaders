// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// HD mesh vertex shader entry point — Warcraft III Reforged 3.0.0.
//
// Specialisation space:
//   TSkin — IHDSkinning policy. `HDRigid`, or `HDFourBoneSkinning<TBones>`
//           where TBones is `ConstantBonePalette` (b3) or
//           `StructuredBonePalette` (t16).
//   TVF   — IVertexFormat: which optional attributes are live.
//
// The engine indexes its 72 permutations with a MIXED-RADIX counter, not the
// bit mask the pixel shader uses:
//
//   index = BONE_BUFFER * 1 + TANGENT * 2 + WEIGHT_INDEX * 4
//         + VERTEX_COLOR * 12 + UV_COUNT * 24
//
// with radices 2, 2, 3, 2, 3. Two of those digits are not what they look like:
// WEIGHT_INDEX 0 and 1 both mean "no skinning", and BONE_BUFFER is invisible
// unless the mesh is skinned. 72 slots therefore collapse to 36 distinct
// programs, which is exactly the number the shipped BLS carries.
//
// What 3.0.0 changed against 2.0.0 — the vertex stage got SMALLER:
//   * The shadow cascades left. 2.0.0 projected through three cascade matrices
//     into TEXCOORD4-6 behind a `SHADOWS` axis; 3.0.0 emits the world position
//     once on TEXCOORD10 and the pixel shader projects. `SHADOWS` and the
//     depth-prepass axis went with it, halving 144 permutations to 72.
//   * A tangent frame is ALWAYS produced. 2.0.0 wrote zeros into TEXCOORD3 for
//     meshes with no tangent stream; 3.0.0 generates one from the normal, and
//     falls back to it even when ATTR7 is present but transforms to nothing.
//   * One UV stream now duplicates into TEXCOORD0.zw instead of zeroing it.
//   * The bone palette can come from a shared structured buffer.
//
// The body is deliberately a flat sequence of transforms; anything with a
// decision in it lives in a policy type or a named helper.

implementing wc3_shaders;

[shader("vertex")]
public HDVSOutput vs_main<
    TSkin : IHDSkinning,
    TVF   : IVertexFormat
>(HDVSInput<TVF> input)
{
    HDVSOutput output;

    // Step 1: object space. Rigid forwards the attributes untouched; the
    // four-bone policy blends whichever palette this permutation was built
    // with and applies the result to all three attributes.
    float3 objectPos, objectNormal, objectTangent;
    TSkin.transform(
        input.position, input.normal, input.tangent.xyz,
        input.weights, input.boneIndices,
        objectPos, objectNormal, objectTangent);

    // Step 2: clip position, taken straight from object space rather than
    // through the intermediate world position, which would cost precision.
    output.position = transformClipPos(objectPos, hdVsCB2.worldViewProj);

    // Step 3: per-vertex tint. `diffuseColor` is the material tint; a mesh
    // that carries a colour stream (baked AO, hero tints) modulates it.
    if (TVF.hasVertexColor)
        output.color = hdVsCB2.diffuseColor * input.vertColor;
    else
        output.color = hdVsCB2.diffuseColor;

    // Step 4: the two 2x3 UV matrices (scrolling / tiling animation). Dead
    // streams compile out; a single stream feeds both halves.
    output.texCoord = transformMeshUVs<TVF>(
        input.uv0, input.uv1,
        hdVsCB2.texMtx0Row0, hdVsCB2.texMtx0Row1,
        hdVsCB2.texMtx1Row0, hdVsCB2.texMtx1Row1);

    // Step 5: view-space position, plus the world position 3.0.0 now always
    // needs — the pixel shader reprojects it for shadow cascades, volumetric
    // fog and the blight lookup, so 2.0.0's "read only the Z row of `world`"
    // shortcut has nothing left to save.
    float4 worldPos = computeWorldPos4(objectPos, hdVsCB2.world);
    output.viewPos.xyz = transformByWorldView(objectPos, hdVsCB2.worldView);
    output.viewPos.w = computeWaterClipDistance(
        worldPos.z, hdVsCB2.clipHeight, hdVsCB2.underWater);

    // Step 6: view-space normal. The upper 3x3 of `worldView` can be
    // degenerate (a flattened or zero-scaled bone), so the renormalise has a
    // fallback rather than dividing by zero.
    float3 n = normalizeOrFallback(
        transformNormalRaw(objectNormal, hdVsCB2.worldView), float3(0, 1, 0));
    output.normalWS = n;

    // Step 7: tangent frame. The generated frame is built either way — with a
    // tangent stream it is the fallback for a tangent that transformed to zero
    // length, without one it IS the frame.
    float3 genTangent = generatedTangent(n);
    if (TVF.hasTangent)
    {
        output.tangentWS.xyz = normalizeOrFallback(
            transformNormalRaw(objectTangent, hdVsCB2.worldView), genTangent);
        // Handedness for the pixel shader's bitangent reconstruction.
        output.tangentWS.w = input.tangent.w;
    }
    else
    {
        output.tangentWS = float4(genTangent, 1);
    }

    // Step 8: world position and the blight-map lookup built from its XY.
    output.worldPos = worldPos;
    output.blightUV = float4(blightMapUV(worldPos.xy, hdVsCB1.rect), 0, 0);

    return output;
}
