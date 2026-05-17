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

// Full HD vertex attribute stream.
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

// Terrain vertex stream. The seven attribute slots arrive in the
// non-canonical order the engine's terrain VB streams them — ATTR0,
// ATTR6, ATTR1, ATTR7, ATTR2, ATTR3, ATTR4 — and slang assigns input
// registers from the struct member order, so the field ordering here
// must match the engine's binding order verbatim. ATTR2 (vertex color)
// is only read by the body when `HAS_VERTEX_COLOR` is set; the slot
// itself is always declared so the engine's vertex layout stays fixed
// regardless of which perm is active.
//
// `boneIDs` is a uint4 because the engine uses `0xFFFF` in any slot as
// a "degenerate vertex" sentinel (see TerrainVSOutput.position quirk).
public struct TerrainVSInput
{
    public [[vk::location(0)]] float3 position  : ATTR0;
    public [[vk::location(6)]] uint4  boneIDs   : ATTR6;
    public [[vk::location(1)]] float3 normal    : ATTR1;
    public [[vk::location(7)]] float4 tangent   : ATTR7;
    public [[vk::location(2)]] float4 vertColor : ATTR2;
    public [[vk::location(3)]] float2 uv0       : ATTR3;
    public [[vk::location(4)]] float2 uv1       : ATTR4;
};

// Terrain VS → PS payload. Layout matches the slot map the original
// terrain PS expects:
//
//   TEXCOORD7  boneIDs (uint4 nointerpolation)  — splat layer indices.
//   SV_Position position                         — clip-space.
//   COLOR0     color                             — vertex color or const tint.
//   TEXCOORD0  texCoord (.xy = UV0, .zw = UV1).
//   TEXCOORD1  worldPos (.xyz world, .w = 0).
//   TEXCOORD2  worldNormal (.xyz only — no .w lane).
//   TEXCOORD3  worldTangent (.xyz world, .w = handedness pass-through).
//   TEXCOORD4  shadowClip0 — cascade-0 light-clip-space position.
//   TEXCOORD5  shadowClip1 — cascade-1 light-clip-space position.
//   TEXCOORD6  shadowClip2 — cascade-2 light-clip-space position.
//
// The cascade slots are gated by `WC3_HAS_SHADOWS` (preprocessor define
// — see the VSOutput comment for why) so the non-shadow perms emit a
// smaller VS→PS signature, exactly matching the BLS layout.
public struct TerrainVSOutput
{
    public nointerpolation uint4 boneIDs : TEXCOORD7;
    public float4 position     : SV_Position;
    public float4 color        : COLOR0;
    public float4 texCoord     : TEXCOORD0;
    public float4 worldPos     : TEXCOORD1;
    public float3 worldNormal  : TEXCOORD2;
    public float4 worldTangent : TEXCOORD3;
#if WC3_HAS_SHADOWS
    public float4 shadowClip0 : TEXCOORD4;
    public float4 shadowClip1 : TEXCOORD5;
    public float4 shadowClip2 : TEXCOORD6;
#endif
};

// Foliage vertex stream. Eight attribute slots arrive in the engine
// VB binding order — ATTR0, ATTR5, ATTR6, ATTR1, ATTR7, ATTR2, ATTR3,
// ATTR4 — and slang assigns input registers from the struct member
// order, so the field ordering here must match the binding order
// verbatim. ATTR5/ATTR6 are declared so the input layout stays fixed
// regardless of which perm is active; the foliage VS body never reads
// them (no per-draw skinning on foliage).
public struct FoliageVSInput
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(5)]] float4 _boneWeight : ATTR5;
    public [[vk::location(6)]] uint4  _boneIndex  : ATTR6;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(7)]] float4 tangent     : ATTR7;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv0         : ATTR3;
    public [[vk::location(4)]] float2 uv1         : ATTR4;
};

// Foliage VS → PS payload. Shadow-cascade slots are gated by
// `HAS_SHADOWS` so the non-shadow perms emit a smaller VS→PS signature
// (matching the BLS layout where caster passes never carry cascade
// UVs even when the receive flag is set).
//
//   SV_Position  position     — clip-space.
//   COLOR0       color        — tint × per-vertex colour.
//   TEXCOORD0    texCoord     — .xy = transformed UV0, .zw = UV1.
//   TEXCOORD1    worldPos     — .xyz world, .w = 0.
//   TEXCOORD2    worldNormal  — normalized world normal (.xyz only).
//   TEXCOORD3    worldTangent — .xyz raw world tangent, .w = sign(v4.w)
//                                handedness stencil (-1 / 0 / +1).
//   TEXCOORD4-6  shadowClip0/1/2 — cascade-space clip positions
//                                  (HAS_SHADOWS only).
public struct FoliageVSOutput
{
    public float4 position     : SV_Position;
    public float4 color        : COLOR0;
    public float4 texCoord     : TEXCOORD0;
    public float4 worldPos     : TEXCOORD1;
    public float3 worldNormal  : TEXCOORD2;
    public float4 worldTangent : TEXCOORD3;
#if WC3_HAS_SHADOWS
    public float4 shadowClip0 : TEXCOORD4;
    public float4 shadowClip1 : TEXCOORD5;
    public float4 shadowClip2 : TEXCOORD6;
#endif
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

// Water vertex stream (subset of the HD stream — no tangent, no UV1,
// no skinning). Kept separate from VSInput so the water VS emits a
// 4-attribute input signature matching the engine's water vertex
// buffer rather than the 8-attribute HD one.
public struct WaterVSInput
{
    public [[vk::location(0)]] float3 position    : ATTR0;
    public [[vk::location(1)]] float3 normal      : ATTR1;
    public [[vk::location(2)]] float4 vertColor   : ATTR2;
    public [[vk::location(3)]] float2 uv          : ATTR3;
};

// Water VS → PS payload. Differs from VSOutput in two ways:
//   • no TEXCOORD2 slot — the water PS takes its geometry normal on
//     TEXCOORD3 to free TEXCOORD2 for an engine-wide reserved slot.
//   • TEXCOORD4 carries a fixed "up" axis (world Y column), which the
//     water PS uses as the TBN tangent instead of a per-vertex tangent.
// Member types are trimmed to the exact components the PS reads, so
// the compiled VS declares `dcl_output oN.xy/xyz/xyzw` accordingly
// (and doesn't emit dead writes to unused lanes).
public struct WaterVSOutput
{
    public float4 position    : SV_Position;
    public float4 color       : COLOR0;
    public float2 texCoord    : TEXCOORD0;
    public float3 worldPos    : TEXCOORD1;
    public float3 normalWS    : TEXCOORD3;
    public float4 upAxisWS    : TEXCOORD4;
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
public struct PopcornVSInput
{
    public [[vk::location(0)]] float3 position    : ATTR0;
#if POPCORN_HAS_NT
    public [[vk::location(1)]] float3 normal      : ATTR1;
#endif
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
//   TEXCOORD4      normalWS  — POPCORN_HAS_NT
//   TEXCOORD5      tangentWS — POPCORN_HAS_NT
//   TEXCOORD7      worldPos  — always
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
    public float3 normalWS  : TEXCOORD4;
    public float4 tangentWS : TEXCOORD5;
#endif

    public float3 worldPos : TEXCOORD7;
};
