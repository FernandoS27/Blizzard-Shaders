// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// PopcornFX vertex shader entry point.
//
// Specialisation space (recovered from the original BLS bundle —
// 72 perms = 4 effective rendering modes × 8 inner-bit combinations,
// with 8 dead-axis duplicates from the engine compiling redundant
// uv_variant mirrors). The build script translates each perm into
// `-D POPCORN_*` defines that gate the VS input / output struct
// declarations *and* the matching reads in this entry body:
//
//   POPCORN_HAS_UV          — primary UV stream is bound (ATTR3).
//   POPCORN_BILLBOARD       — billboard mode: SV_VertexID-driven quad
//                             UV + axis vectors on ATTR4/ATTR5.
//   POPCORN_ATLAS           — atlas mode: ATTR3=current-frame UV,
//                             ATTR4.xy=next-frame UV, ATTR5.x=life.
//   POPCORN_HAS_BB_OR_ATLAS — billboard or atlas (slot4/slot5 are
//                             bound). Used to gate ATTR4/ATTR5 in
//                             PopcornVSInput.
//   POPCORN_HAS_RANDOM_UV   — HAS_RANDOM && HAS_UV. The shipped engine
//                             never binds ATTR6 without a UV stream,
//                             so the build collapses the conjunction.
//   POPCORN_HAS_VC          — per-vertex RGBA on ATTR2.
//   POPCORN_HAS_NT          — per-vertex normal + tangent (ATTR1 +
//                             ATTR7). Required for the lit BRDF PS
//                             paths.
//
// The VS body is a small linear stack: pivot-blend the per-vertex
// position toward the particle origin, scale uniformly, transform to
// clip + world, then forward the active mode's per-vertex auxiliaries
// (UV variants, axis vectors, random, normal/tangent).

implementing wc3_shaders;

// PopcornFX particles author the per-vertex position as the corner of
// the quad (or the per-vertex offset for mesh particles), with the
// per-particle "pivot" living in ATTR8.xyz and a per-vertex blend
// weight in ATTR8.w. The final local-space position is a lerp from
// pivot to corner driven by the weight, then uniformly scaled by
// `popcornScale` to undo any scale baked into the mesh data.
//
//     localPos = lerp(pivot.xyz, position, pivot.w) * popcornScale
public float3 popcornBlendPivot(float3 position, float4 pivot, float scale)
{
    float3 localPos = lerp(pivot.xyz, position, pivot.www);
    return localPos * scale;
}

// Quad UV from a SV_VertexID in [0, 4).
//
//   id & 3 == 0  → (0, 0)
//   id & 3 == 1  → (0, 1)
//   id & 3 == 2  → (1, 0)
//   id & 3 == 3  → (1, 1)
//
// Matches the original engine's triangle-strip quad pattern.
public float2 popcornQuadUV(uint vertexID)
{
    uint idx = vertexID & 3u;
    return float2(float(idx >> 1), float(idx & 1u));
}

[shader("vertex")]
public PopcornVSOutput popcorn_vs_main(PopcornVSInput input)
{
    PopcornVSOutput output;

    // Step 1: pivot-blend + uniform scale gives us the local-space
    // position that everything downstream operates on.
    float3 localPos = popcornBlendPivot(
        input.position, input.pivot, popcornVsCB2.popcornScale);

    // Step 2: clip-space position (single-multiply object → clip
    // bypasses the world round-trip).
    output.position = transformClipPos(localPos, popcornVsCB2.worldViewProj);

    // Step 3: vertex color — straight pass-through, no remap.
#if POPCORN_HAS_VC
    output.color = input.vertColor;
#endif

    // Step 4: per-mode UV / auxiliary outputs. Each mode writes the
    // narrow-typed output field (uv as float2 in basic/billboard,
    // uvAtlas as float4 in atlas) so fxc emits the right OSGN width
    // and packs adjacent fields the way the shipped engine does.
#if POPCORN_HAS_UV
#  if POPCORN_BILLBOARD
    output.uv       = popcornQuadUV(input.vertexID);
    output.axis0Out = input.modeSlot4;          // axis0 (.xyzw)
    output.axis1Out = input.modeSlot5;          // axis1 (.xyzw)
#  elif POPCORN_ATLAS
    // .xy = current frame, .zw = next frame. The PS lerps between two
    // t0 samples by `lifeOut` (the life-ratio fractional part below).
    output.uvAtlas = float4(input.uv0, input.modeSlot4.xy);
#  else
    // BasicUV — straight pass-through.
    output.uv = input.uv0;
#  endif
#endif

    // Step 5: per-particle random scalar pass-through. Only meaningful
    // when there's a UV stream — see PopcornVSOutput for the rationale
    // (the engine never binds ATTR6 without a UV stream, so the
    // RANDOM && UV conjunction collapses into one define).
#if POPCORN_HAS_RANDOM_UV
    output.randomOut = input.random;
#endif

    // Step 6: world-space normal + tangent. The popcorn world matrix
    // is assumed to be a similarity transform (no shear), so we skip
    // the renormalize step the HD pipeline runs. tangent.w carries the
    // bitangent handedness sign passed straight through.
#if POPCORN_HAS_NT
    float3 worldNormal  = transformNormalRaw(input.normal,       popcornVsCB2.world);
    float3 worldTangent = transformNormalRaw(input.tangent.xyz,  popcornVsCB2.world);
    output.normalWS  = worldNormal;
    output.tangentWS = float4(worldTangent, input.tangent.w);
#endif

    // Step 7: world-space position, always emitted (the PS uses it
    // for soft-particles depth reprojection, fog, IBL, etc.).
    output.worldPos = transformByWorld(localPos, popcornVsCB2.world);

    // Step 8: atlas blend factor — single float at TEXCOORD1.x. fxc
    // packs this into the same physical register as worldPos.yzw on
    // the shipped engine, so emitting it as a scalar (rather than a
    // wider float4) keeps register packing aligned. Emitted at the
    // end so the `frac` instruction lands after the worldPos
    // transform, matching the original engine's ordering.
#if POPCORN_ATLAS
    output.lifeOut = frac(input.modeSlot5.x);
#endif

    return output;
}
