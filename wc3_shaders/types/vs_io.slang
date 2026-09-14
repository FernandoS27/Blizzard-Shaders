// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Vertex shader input and output layouts.
//
// `VSInput` is generic over an `IVertexFormat` policy so that unused
// attributes (tangent, uv1, vertex color, etc.) can be compiled out
// cleanly at specialization time without changing the input element
// layout — the engine always binds the full attribute set.

implementing wc3_shaders;

// SD highspec vertex input, 3.0.0 layout.
//
// Two things differ from the 2.0.0 `VSInput` below, and a third from both:
//
//   * ATTR5 and ATTR6 swapped FORMATS. 3.0.0 puts the uint bone indices on
//     ATTR5 and the float weights on ATTR6; 2.0.0 had it the other way round.
//     Visible in the shipped signature (`ATTR 5 ... uint` / `ATTR 6 ... float`)
//     and followed through the body, where the palette-index multiply moved
//     from v2 to v1 and the weight broadcast from v1.yyyy to v2.yyyy. It is the
//     same swap `HDVSInput` already carries.
//   * Member order is the engine's binding order, not a tidy ascending one.
//     Slang assigns input registers from member order, and retail puts the two
//     skinning streams immediately after position: `ATTR0, ATTR5, ATTR6, ATTR1,
//     ATTR2, ATTR3, ATTR4` maps to v0..v6 in every shipped permutation. This
//     ordering is unchanged BETWEEN versions — only the formats swapped.
//   * There is no ATTR7. **No** sd_highspec permutation declares a tangent, in
//     either version (0 of 162): the family has no tangent frame, because its
//     pixel shader runs fixed-function texture stages rather than normal
//     mapping. The entry point therefore passes a constant to the skinning
//     policy and discards the skinned tangent.
//
// A separate struct rather than an edit to `VSInput`, because `sd_on_hd_vs`
// still binds the 2.0.0 order and shares this translation unit — 54 of the 162
// sd_highspec permutations change here, and none of sd_on_hd_vs's 144 should.
public struct SDHighspecVSInput<TVF : IVertexFormat>
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(5)]] uint4  boneIndices : ATTR5;
    public [[vk::location(6)]] float4 weights     : ATTR6;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv0         : ATTR3;
    public [[vk::location(4)]] float2 uv1         : ATTR4;
};

// Full 2.0.0 vertex attribute stream, still bound by `sd_on_hd_vs`.
// `weights` + `boneIndices` are only consulted when the skinning policy
// is `FourBoneSkinning`; `tangent.w` carries the handedness sign used to
// reconstruct the bitangent in the pixel shader.
public struct VSInput<TVF : IVertexFormat>
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv0         : ATTR3;
    public [[vk::location(4)]] float2 uv1         : ATTR4;
    public [[vk::location(5)]] float4 weights     : ATTR5;
    public [[vk::location(6)]] uint4  boneIndices : ATTR6;
    public [[vk::location(7)]] float4 tangent     : ATTR7;
};

// Full HD vertex-to-pixel payload.
// worldPos.w carries the pre-computed fog-depth scalar (see
// computeFogDepth) rather than a real homogeneous coordinate — the PS
// reads it to evaluate fog without recomputing the view-space Z.
// The three shadowClip slots carry the cascade-space clip positions
// when shadows are enabled; they compile out entirely via `#if HAS_SHADOWS`
// in the non-shadow permutations — the shipped game shader omits them
// from the VS output signature rather than emitting dead zero writes,
// and we follow that layout so VS→PS linkage matches.
//
// WC3_HAS_SHADOWS is a per-permutation preprocessor define (set via -D by
// compile_all_slang.py). It used to be a `<let HAS_SHADOWS : bool>` template
// param wrapping each cascade field in `Conditional<float4, HAS_SHADOWS>`,
// but slangc 2026.x emits Conditional as `array<float4, 1>` in WGSL, and
// WGSL forbids @location on array types. The #if form sidesteps that emit
// path while preserving the same per-perm field-omission behavior on every
// other target (slang's preprocessor expands before any backend emit).
//
// The `WC3_` prefix avoids colliding with the `HAS_SHADOWS` identifier
// that's still in use as a slang template param in unmigrated shaders
// (terrain_ps, foliage_ps, etc); slang's preprocessor is global to the
// compilation unit, so a `-D HAS_SHADOWS=1` would expand the identifier
// inside those files too and break their template-param resolution.
public struct VSOutput
{
    public float4 position    : SV_Position;
    public float4 color       : COLOR0;
    public float4 texCoord    : TEXCOORD0;
    public float4 worldPos    : TEXCOORD1;
    public float3 normalWS    : TEXCOORD2;
    public float4 tangentWS   : TEXCOORD3;
#if WC3_HAS_SHADOWS
    public float4 shadowClip0 : TEXCOORD4;
    public float4 shadowClip1 : TEXCOORD5;
    public float4 shadowClip2 : TEXCOORD6;
#endif
};

// ---------------------------------------------------------------------------
// 3.0.0 HD mesh pipeline
// ---------------------------------------------------------------------------

// HD mesh vertex stream, 3.0.0 layout.
//
// Two things differ from the 2.0.0 `VSInput` above and both matter:
//
//   * ATTR5 and ATTR6 swapped roles. 3.0.0 puts the bone INDICES on ATTR5 and
//     the WEIGHTS on ATTR6; 2.0.0 had it the other way round.
//   * The declaration order is the engine's binding order, with the two
//     skinning streams sitting between position and normal. Slang assigns
//     input registers from member order, so writing them in any other order
//     would produce a different register layout than the shipped shader.
//
// As with `VSInput`, every slot is declared on every permutation so the
// engine's vertex layout stays fixed; `TVF` gates the *reads*, which is what
// lets the dead transforms fall out per permutation.
public struct HDVSInput<TVF : IVertexFormat>
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(5)]] uint4  boneIndices : ATTR5;
    public [[vk::location(6)]] float4 weights     : ATTR6;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(7)]] float4 tangent     : ATTR7;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv0         : ATTR3;
    public [[vk::location(4)]] float2 uv1         : ATTR4;
};

// HD mesh vertex-to-pixel payload, 3.0.0 layout.
//
// The cascade slots are gone: 2.0.0 projected the position through three
// cascade matrices into TEXCOORD4-6 behind a `SHADOWS` axis, and 3.0.0 hands
// the pixel shader the world position once on TEXCOORD10 and lets it do the
// projection. That is why this struct has no `#if` in it at all — every
// permutation writes the same eight slots, which is also why the 3.0.0
// permutation count halved.
//
//   TEXCOORD1   .xyz view-space position, .w the signed height above the
//               water clip plane the pixel shader discards on.
//   TEXCOORD2   view-space normal. Declared float3, not float4, so the
//               compiled shader emits `dcl_output o4.xyz` like the original.
//   TEXCOORD3   .xyz view-space tangent, .w handedness for the bitangent.
//   TEXCOORD10  world position, homogeneous — shadow cascades, volumetric
//               fog and the debug stripe all reproject from it.
//   TEXCOORD11  .xy blight-map UV, .zw zero.
public struct HDVSOutput
{
    public float4 position  : SV_Position;
    public float4 color     : COLOR0;
    public float4 texCoord  : TEXCOORD0;
    public float4 viewPos   : TEXCOORD1;
    public float3 normalWS  : TEXCOORD2;
    public float4 tangentWS : TEXCOORD3;
    public float4 worldPos  : TEXCOORD10;
    public float4 blightUV  : TEXCOORD11;
};

// Compact payload used by the SD classic pipeline, which does all
// lighting in the vertex shader and therefore only needs the lit color,
// the transformed UVs and a world-space position for fog.
public struct SDVSOutput
{
    public float4 position    : SV_Position;
    public float4 color       : COLOR0;
    public float4 texCoord    : TEXCOORD0;
    public float3 worldPos    : TEXCOORD1;
};

// Terrain vertex stream, 3.0.0. Seven slots in the engine's binding order --
// ATTR0, ATTR6, ATTR1, ATTR7, ATTR2, ATTR3, ATTR4 -- and slang assigns input
// registers from member order, so the order here IS the binding order. ATTR6
// is not a bone weight on terrain: it is the four splat LAYER indices of the
// cell, an array slice each, with 0xFFFF meaning "no layer". ATTR2 is read
// only by the VERTEX_COLOR permutation; ATTR4 is declared and never read.
public struct TerrainVSInput
{
    public [[vk::location(0)]] float3 position  : ATTR0;
    public [[vk::location(6)]] uint4  layers    : ATTR6;
    public [[vk::location(1)]] float3 normal    : ATTR1;
    public [[vk::location(7)]] float4 tangent   : ATTR7;
    public [[vk::location(2)]] float4 vertColor : ATTR2;
    public [[vk::location(3)]] float2 uv0       : ATTR3;
    public [[vk::location(4)]] float2 uv1       : ATTR4;
};

// Terrain VS -> PS payload, 3.0.0 layout: foliage's payload with the splat
// layer indices riding in FRONT of everything, as a flat-interpolated uint4
// on TEXCOORD8 -- retail's signature puts it in register 0, ahead of
// SV_Position, and fxc assigns registers in declaration order.
//
//   TEXCOORD8   the four splat layer indices, passed through untouched
//   TEXCOORD0   .xy raw UV0 (no texture matrix on terrain), .zw blight UV
//   TEXCOORD1   .xyz view-space position, .w zero
//   TEXCOORD3   .xyz view-space tangent (not renormalised), .w handedness
//   TEXCOORD2   view-space normal, from the bent and renormalised object
//               normal, not renormalised after the transform
//   TEXCOORD10  world position, homogeneous
public struct TerrainVSOutput
{
    public nointerpolation uint4 layers : TEXCOORD8;
    public float4 position  : SV_Position;
    public float4 color     : COLOR0;
    public float4 texCoord  : TEXCOORD0;
    public float4 viewPos   : TEXCOORD1;
    public float4 tangentVS : TEXCOORD3;
    public float3 normalVS  : TEXCOORD2;
    public float4 worldPos  : TEXCOORD10;
};

// Foliage vertex stream, 3.0.0. The engine binds foliage through the HD
// mesh's eight-slot layout -- ATTR0, ATTR5, ATTR6, ATTR1, ATTR7, ATTR2,
// ATTR3, ATTR4 -- and slang assigns input registers from member order, so
// the member order here IS the binding order. ATTR5 (bone indices, uint)
// and ATTR6 (weights) keep the layout fixed and are never read; ATTR4 is
// declared and unread too. ATTR2.w is not an alpha: it is the per-vertex
// wind weight, and ATTR7.w doubles as the wind strength and the handedness.
public struct FoliageVSInput
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(5)]] uint4  boneIndices : ATTR5;
    public [[vk::location(6)]] float4 weights     : ATTR6;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(7)]] float4 tangent     : ATTR7;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv0         : ATTR3;
    public [[vk::location(4)]] float2 uv1         : ATTR4;
};

// Foliage VS -> PS payload, 3.0.0 layout. It is HD's payload with the
// blight UV folded into TEXCOORD0.zw instead of riding its own TEXCOORD11,
// and with the tangent declared BEFORE the normal: retail's signature puts
// TEXCOORD3 in register 4 and TEXCOORD2 in register 5, and fxc assigns
// registers in declaration order. The cascade slots of 2.0.0 are gone --
// the pixel shader reprojects TEXCOORD10 itself, exactly as HD does.
//
//   TEXCOORD0   .xy transformed UV0, .zw blight-map UV
//   TEXCOORD1   .xyz view-space position, .w zero (foliage has no water
//               clip plane)
//   TEXCOORD3   .xyz view-space tangent (not renormalised), .w sign of the
//               authored handedness
//   TEXCOORD2   view-space normal, renormalised
//   TEXCOORD10  world position, homogeneous
public struct FoliageVSOutput
{
    public float4 position  : SV_Position;
    public float4 color     : COLOR0;
    public float4 texCoord  : TEXCOORD0;
    public float4 viewPos   : TEXCOORD1;
    public float4 tangentVS : TEXCOORD3;
    public float3 normalVS  : TEXCOORD2;
    public float4 worldPos  : TEXCOORD10;
};

// Sprite vertex stream. The sprite pipeline takes a pre-projected
// position straight through (no transform stack — the engine uploads
// already-clip-space xy + a depth in z) plus a UV0 lane for the sample.
// The two slots are non-contiguous (ATTR0 + ATTR3) so the engine can
// feed sprite draws from the same vertex buffer layout that drives the
// HD pipeline (which uses ATTR3 for uv0).
// SpriteVSInput has a gap between ATTR0 and ATTR3 (no normal / vertColor
// in the sprite vertex stream). Slang's SPIR-V emit for standalone
// (non-generic) structs with non-contiguous semantic indices assigns
// sequential locations instead of using the semantic index — so without
// [[vk::location(3)]], `uv` would land at Location 1, mismatching the
// renderer's HD-style vertex layout (which puts uv at Location 3 to
// match every other ATTR3 use). Forcing the location matches the
// shipped HD layout and is a no-op on HLSL targets.
public struct SpriteVSInput
{
    [[vk::location(0)]] public float3 position : ATTR0;
    [[vk::location(3)]] public float2 uv       : ATTR3;
};

// Sprite VS → PS payload. Single TEXCOORD0 — the sprite PS samples one
// texture and writes one render target.
public struct SpriteVSOutput
{
    public float4 position : SV_Position;
    public float2 uv       : TEXCOORD0;
};

// ImGui vertex stream. The engine binds a 4-attribute layout for the
// in-engine ImGui draws, even though only three of those slots are
// actually consumed by the math:
//
//   ATTR0  position  — 2D position (.xy used; .z lives in the input
//                      signature as the engine's vertex layout declares
//                      a float3 here, but the projection only consumes
//                      the .xy lanes).
//   ATTR1  _unused1  — declared in the original ISGN with mask `xyz`
//                      and a `Used` column of zero. The engine still
//                      binds the stream, so we declare it here as well
//                      to keep the input signature aligned.
//   ATTR2  vertColor — per-vertex RGBA tint (forwarded to PS COLOR0).
//   ATTR3  uv        — per-vertex texture coords (forwarded to PS TEXCOORD0).
public struct ImGuiVSInput
{
    public [[vk::location(0)]] float3 position  : ATTR0;
    public [[vk::location(1)]] float3 _unused1  : ATTR1;
    public [[vk::location(2)]] float4 vertColor : ATTR2;
    public [[vk::location(3)]] float2 uv        : ATTR3;
};

// ImGui VS → PS payload. Slot order mirrors the engine's OSGN: clip-
// space position on SV_Position, UV at TEXCOORD0, vertex colour at
// COLOR0 (the PS reads these in the same order via `ImGuiPSInput`).
public struct ImGuiVSOutput
{
    public float4 position  : SV_Position;
    public float2 uv        : TEXCOORD0;
    public float4 vertColor : COLOR0;
};

// Water vertex stream: four slots, ATTR0-3 in order. No tangent, no second
// UV set, no skinning.
public struct WaterVSInput
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv          : ATTR3;
};

// Water VS -> PS payload, 3.0.0 layout (retail's register order):
//
//   TEXCOORD0   .xy transformed UV0, .zw blight-map UV
//   TEXCOORD1   view-space position of the WAVE-DISPLACED vertex
//   TEXCOORD2   view-space geometry normal, renormalised (the undisplaced
//               normal: the waves move the surface, not its facing)
//   TEXCOORD3   .xyz the object's Y axis in view space -- water has no
//               tangent attribute, so this is the frame's tangent -- .w 1
//   TEXCOORD10  world position, homogeneous
//
// 2.0.0 carried the geometry normal on TEXCOORD3 and the axis on TEXCOORD4,
// and had no world position or blight UV at all.
public struct WaterVSOutput
{
    public float4 position  : SV_Position;
    public float4 color     : COLOR0;
    public float4 texCoord  : TEXCOORD0;
    public float3 viewPos   : TEXCOORD1;
    public float3 normalVS  : TEXCOORD2;
    public float4 tangentVS : TEXCOORD3;
    public float4 worldPos  : TEXCOORD10;
};

// PopcornFX vertex stream.
//
// Per-perm `-D POPCORN_HAS_*` defines from compile_all_slang.py gate
// which optional attributes are declared. Slangc lowers each compiled
// permutation to a DXIL whose input signature only carries the fields
// the engine actually binds for that perm, so d3d12 PSO creation no
// longer rejects popcorn_vs (which previously declared all ten ATTRs
// regardless of permutation). The defines also gate the matching reads
// in `popcorn_vs.slang` — without the `#if` guard there, the body
// would reference fields that don't exist on the current perm.
//
// We use the preprocessor here rather than `Conditional<T, gate>` on
// the input struct because slangc 2026.1 (VulkanSDK 1.4.341.1 build)
// miscompiles compound-bool Conditional gates into raw HLSL
// `Conditional_0<float, false>`, and the 2026.8 build stack-overflows
// when an entry-point parameter is a struct containing Conditional
// fields (only when the file is compiled through the `wc3_shaders`
// module — standalone repros pass).
//
// Slot map (recovered from the original BLS input signatures):
//
//   ATTR0  pivot-blended position
//   ATTR1  object-space normal              (POPCORN_HAS_NT)
//   ATTR2  per-vertex RGBA color            (POPCORN_HAS_VC)
//   ATTR3  primary UV                       (POPCORN_HAS_UV;
//                                            BILLBOARD declares it but
//                                            ignores it — the engine
//                                            still binds the stream)
//   ATTR4  BILLBOARD: axis0 (.xyzw) /
//          ATLAS:     uv1   (.xy)            (POPCORN_HAS_BB_OR_ATLAS)
//   ATTR5  BILLBOARD: axis1 (.xyzw) /
//          ATLAS:     lifeRatio (.x)         (POPCORN_HAS_BB_OR_ATLAS)
//   ATTR6  per-particle random scalar       (POPCORN_HAS_RANDOM_UV —
//                                            the engine never binds
//                                            random without a UV
//                                            stream, so the build
//                                            collapses RANDOM && UV
//                                            into a single define)
//   ATTR7  object-space tangent + handedness in .w  (POPCORN_HAS_NT)
//   ATTR8  particle pivot (.xyz) + per-vertex blend weight (.w)
//   SV_VertexID                              (read only by BILLBOARD)
//
// ATTR4/ATTR5 are declared as float4 to cover the BILLBOARD axis
// vectors; the ATLAS path uses the .xy / .x lanes of the same slot.
// `[[vk::location(N)]]` pins the SPIR-V input Location to N regardless
// of which fields are present in the current perm — without it slang
// assigns SPIR-V locations from struct member order, so dropping a
// field via `#if` would shift every later field's location and break
// the engine's CornFx vertex layout (which binds at Locations 0/2/3/8
// to match the shipped engine, not 0/1/2/3). On HLSL targets slang
// concatenates the location number into the semantic index — e.g. an
// `ATTR1` field with `[[vk::location(1)]]` is emitted as `ATTR10` —
// and `fix_dxbc_signatures` in build_bls.py divides every sem_idx that
// is a multiple of 10 by 10 to undo that shift in the BLS-packed DXBC
// and DXIL.
// Declared in RETAIL'S BINDING ORDER, which is not ascending: the normal and
// tangent pair sits at the END, after ATTR6, in every one of the 72 shipped
// permutations. Enumerating the distinct input signatures across the retail
// blobs gives tuples like `(0, 2, 3, 4, 5, 6, 1, 7, 8)` — never `(0, 1, 2, …)`.
// Ascending order was what put 42 of this family's 72 permutations in the §4b
// mismatch list, and it is the one part of that finding that is unambiguously
// an error rather than a pruning question: the SET is right either way, only
// the order was wrong. The differential cannot see this (it aligns inputs by
// semantic), so `tools/wc3_vs_signature_check.py` is what covers it.
public struct PopcornVSInput
{
    public [[vk::location(0)]] float3 position    : ATTR0;
#if POPCORN_HAS_VC
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
#endif
#if POPCORN_HAS_UV
    public [[vk::location(3)]] float2 uv0         : ATTR3;
#endif
#if POPCORN_HAS_BB_OR_ATLAS
    public [[vk::location(4)]] float4 modeSlot4   : ATTR4;
    public [[vk::location(5)]] float4 modeSlot5   : ATTR5;
#endif
#if POPCORN_HAS_RANDOM_UV
    public [[vk::location(6)]] float  random      : ATTR6;
#endif
#if POPCORN_HAS_NT
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(7)]] float4 tangent     : ATTR7;
#endif
    public [[vk::location(8)]] float4 pivot       : ATTR8;
    public uint   vertexID    : SV_VertexID;
};

// PopcornFX VS → PS payload. Per-perm `-D POPCORN_HAS_*` defines gate
// which optional fields are declared so the wire signature only carries
// what the active permutation actually populates — narrow per-mode
// widths let fxc pack adjacent fields into the same physical register
// the way the shipped engine does.
//
// Slot map:
//
//   SV_Position    clipPos       — always
//   COLOR0         color         — POPCORN_HAS_VC
//   TEXCOORD0      uv      (float2) — POPCORN_HAS_UV && !POPCORN_ATLAS
//                  uvAtlas (float4) — POPCORN_ATLAS (.xy current frame,
//                                                    .zw next frame)
//   TEXCOORD1      axis0Out (float4) — POPCORN_BILLBOARD raw axis vector
//                  lifeOut  (float)  — POPCORN_ATLAS life-frac (.x only)
//   TEXCOORD2      axis1Out — POPCORN_BILLBOARD only (.xyzw)
//   TEXCOORD3      randomOut (float) — POPCORN_HAS_RANDOM_UV (the engine
//                                      never binds ATTR6 without a UV
//                                      stream, so the build collapses
//                                      RANDOM && UV into one define)
//   TEXCOORD4      normalVS  — POPCORN_HAS_NT (VIEW space)
//   TEXCOORD5      tangentVS — POPCORN_HAS_NT (VIEW space)
//   TEXCOORD7      viewPos   — always
//   TEXCOORD8      worldPos  — always, 3.0.0 addition
//
// TEXCOORD7 was called `worldPos` under 2.0.0 and it was never a world
// position: the matrix the VS multiplies it by is `worldView`, and the same
// matrix rotates the normal and tangent, which is why the pixel shader's IBL
// block rotates them back with an INVERSE VIEW. The old name was harmless
// while only one matrix was live and actively misleading now that both are —
// 3.0.0 added a real world position at TEXCOORD8 for the volumetric fog, which
// measures a radial distance from the camera and a height above a ground
// plane, neither of which a view-space position can give it.
//
// Two fields can share a semantic when their gates are mutually
// exclusive (uv vs uvAtlas on TEXCOORD0, axis0Out vs lifeOut on
// TEXCOORD1) — the `#if` form keeps that explicit and lets the SDK
// slangc emit a clean OSGN, which the previous `Conditional<>` form
// did not (slangc 2026.1 leaked unlowered `Conditional_0<...>` types
// through to HLSL emit, breaking the d3d11/d3d12 popcorn_vs builds).
public struct PopcornVSOutput
{
    public float4 position : SV_Position;

#if POPCORN_HAS_VC
    public float4 color : COLOR0;
#endif

#if POPCORN_HAS_UV
#  if POPCORN_ATLAS
    public float4 uvAtlas : TEXCOORD0;
#  else
    public float2 uv      : TEXCOORD0;
#  endif
#endif

#if POPCORN_BILLBOARD
    public float4 axis0Out : TEXCOORD1;
    public float4 axis1Out : TEXCOORD2;
#elif POPCORN_ATLAS
    public float  lifeOut  : TEXCOORD1;
#endif

#if POPCORN_HAS_RANDOM_UV
    public float randomOut : TEXCOORD3;
#endif

#if POPCORN_HAS_NT
    public float3 normalVS  : TEXCOORD4;
    public float4 tangentVS : TEXCOORD5;
#endif

    public float3 viewPos  : TEXCOORD7;
    public float3 worldPos : TEXCOORD8;
};
