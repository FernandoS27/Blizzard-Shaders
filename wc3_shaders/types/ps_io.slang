// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Pixel shader input and output layouts. Mirrors the VS output types in
// vs_io.slang — the semantic slot indices must match.

implementing wc3_shaders;

// HD pixel shader input. Mirrors VSOutput; see vs_io.slang for the
// meaning of each slot. Note that worldPos.w carries the fog-depth
// scalar rather than a homogeneous coordinate.
public struct PSInput
{
    public float4 svPosition   : SV_Position;
    public float4 vertColor    : COLOR0;
    public float4 uv           : TEXCOORD0;
    public float4 worldPos     : TEXCOORD1;
    public float3 normalWS     : TEXCOORD2;
    public float4 tangentWS    : TEXCOORD3;
    public float4 shadowClip0  : TEXCOORD4;
    public float4 shadowClip1  : TEXCOORD5;
    public float4 shadowClip2  : TEXCOORD6;
};

// HD pixel shader output. When the MRT path is disabled the specular and
// normal targets are compiled out entirely thanks to `Conditional`, so
// the shader binds a single render target just like the non-MRT builds.
// When the depth-prepass path is enabled, `color` itself is compiled out
// — the prepass pass binds no color render targets and the shipped game
// shader has no SV_Target entries in that signature; emitting one would
// force a dummy color write against a non-existent RTV.
//   color    = final lit + fog + color-matrixed RGBA
//   specular = view-space depth (x) for screen-space resolve effects
//   normal   = packed world-space normal (xyz) + pre-fog alpha (w)
//
// SPIR-V note: slangc's emit for Conditional<float4, true> drops the
// Output Location decoration, so every SV_TargetN ends up at Location 0
// in the .spv. build_bls.py post-processes each .spv to renumber
// colliding Output locations by OpEntryPoint interface order — so the
// HLSL semantic shape here is preserved while still producing valid
// SPIR-V. No [[vk::location]] annotations help: slangc honors them on
// non-Conditional fields but loses them through the Conditional wrapper.
public struct PSOutput<let IS_MRT : bool, let HAS_COLOR : bool>
{
    public Conditional<float4, HAS_COLOR> color    : SV_Target0;
    public Conditional<float4, IS_MRT>    specular : SV_Target1;
    public Conditional<float4, IS_MRT>    normal   : SV_Target2;
};

// SD classic pipeline pixel shader input. No normals or tangents because
// the classic renderer has no per-pixel lighting — the vertex color
// already contains the lit result.
public struct SDPSInput
{
    public float4 svPosition : SV_Position;
    public float4 vertColor  : COLOR0;
    public float4 uv         : TEXCOORD0;
    public float3 worldPos   : TEXCOORD1;
};

// Water pixel shader input. Matches `WaterVSOutput` slot-for-slot:
// TEXCOORD2 is skipped (the water pass has no tangent attribute), the
// world-space geometry normal arrives on TEXCOORD3, and TEXCOORD4
// carries the per-object "up" axis used as the TBN tangent.
public struct WaterPSInput
{
    public float4 svPosition   : SV_Position;
    public float4 vertColor    : COLOR0;
    public float2 uv           : TEXCOORD0;
    public float3 worldPos     : TEXCOORD1;
    public float3 geomNormalWS : TEXCOORD3;
    public float4 upAxisWS     : TEXCOORD4;
};

// SD classic pipeline PS output. Single target; no MRT, no debug split.
public struct SDPSOutput
{
    public float4 color : SV_Target0;
};

// Tonemap pixel shader input. Full-screen pass — only a UV is consumed;
// `svPosition` is declared so the ISGN still contains the SV_POSITION
// entry expected by the shipped shader signature, even though the body
// never reads it.
public struct TonemapPSInput
{
    public float4 svPosition : SV_Position;
    public float2 uv         : TEXCOORD0;
};

// Terrain pixel shader input. Mirrors `TerrainVSOutput` slot-for-slot.
// The cascade clip slots are declared unconditionally — slangc's PS
// input layout is fixed at the struct level, but fxc DCEs the
// `dcl_input_ps` for unread slots on the non-shadow perms (matching
// what every other slang PS in this module does).
public struct TerrainPSInput
{
    public nointerpolation uint4 boneIDs : TEXCOORD7;
    public float4 svPosition   : SV_Position;
    public float4 color        : COLOR0;
    public float4 texCoord     : TEXCOORD0;
    public float4 worldPos     : TEXCOORD1;
    public float3 worldNormal  : TEXCOORD2;
    public float4 worldTangent : TEXCOORD3;
    public float4 shadowClip0  : TEXCOORD4;
    public float4 shadowClip1  : TEXCOORD5;
    public float4 shadowClip2  : TEXCOORD6;
};

// Terrain pixel shader output. The single colour target is gated by
// `HAS_COLOR` so the engine's NULL_PASS stub (which emits no output
// signature whatsoever — `dcl_output` is absent in the original DXBC)
// can be reconstructed by passing `HAS_COLOR=false`. The two MRT targets
// (depth-feedback in .x = view-Z, and packed world normal + 1) are
// independently gated by `HAS_MRT`.
public struct TerrainPSOutput<let HAS_COLOR : bool, let HAS_MRT : bool>
{
    public Conditional<float4, HAS_COLOR>    color      : SV_Target0;
    public Conditional<float4, HAS_MRT>      depthFeed  : SV_Target1;
    public Conditional<float4, HAS_MRT>      normalEnc  : SV_Target2;
};

// Foliage pixel shader input. Mirrors `FoliageVSOutput` slot-for-slot.
// The cascade clip slots are declared unconditionally — slangc's PS
// input layout is fixed at the struct level, but fxc DCEs the
// `dcl_input_ps` for unread slots on the non-shadow perms.
public struct FoliagePSInput
{
    public float4 svPosition   : SV_Position;
    public float4 color        : COLOR0;
    public float4 texCoord     : TEXCOORD0;
    public float4 worldPos     : TEXCOORD1;
    public float3 worldNormal  : TEXCOORD2;
    public float4 worldTangent : TEXCOORD3;
    public float4 shadowClip0  : TEXCOORD4;
    public float4 shadowClip1  : TEXCOORD5;
    public float4 shadowClip2  : TEXCOORD6;
};

// Foliage pixel shader output. Like `TerrainPSOutput`, the colour
// target is gated by `HAS_COLOR` so the engine's NULL_PASS stub
// (no SV_Target entries) can be reconstructed by passing
// `HAS_COLOR=false`. The two MRT targets are independently gated.
public struct FoliagePSOutput<let HAS_COLOR : bool, let HAS_MRT : bool>
{
    public Conditional<float4, HAS_COLOR>    color      : SV_Target0;
    public Conditional<float4, HAS_MRT>      depthFeed  : SV_Target1;
    public Conditional<float4, HAS_MRT>      normalEnc  : SV_Target2;
};

// Sprite pixel shader input. Mirrors SpriteVSOutput. svPosition is
// declared so the ISGN matches the shipped shader signature (the
// original sprite shader emits SV_POSITION even though the body never
// reads it — fxc DCEs the unused interpolant from the dcl_input list).
public struct SpritePSInput
{
    public float4 svPosition : SV_Position;
    public float2 uv         : TEXCOORD0;
};

// PopcornFX pixel shader input. Mirrors the live members of
// `PopcornVSOutput` slot-for-slot — each optional slot is `#if`-gated
// by the same `POPCORN_HAS_*` define that gates the matching VS output
// field, so d3d12 PSO validation (which requires PS ISG1 ⊆ VS OSG1)
// accepts the link. The entry body in popcorn_ps_body.slang guards
// every read of an optional slot with the same `#if`.
//
// Slot map:
//
//   SV_Position   svPosition
//   COLOR0        vertColor      — POPCORN_HAS_VC
//   TEXCOORD0     uv             — POPCORN_HAS_UV (basic / billboard
//                                  use only .xy; atlas widens to
//                                  .xyzw and packs the next-frame UV
//                                  in .zw — see PopcornVSOutput)
//   TEXCOORD1     slot1          — POPCORN_HAS_BB_OR_ATLAS
//                                  (billboard: per-particle UV
//                                   scale/bias .xyzw; atlas: life-
//                                   ratio fractional part in .x)
//   TEXCOORD2     uvAxis         — POPCORN_BILLBOARD (per-cell two-
//                                  triangle scales .xyzw)
//   TEXCOORD3     random         — POPCORN_HAS_RANDOM_UV (.x is the
//                                  per-particle random; read only by
//                                  the HAS_ALPHA_LUT path)
//   TEXCOORD4     normalWS       — POPCORN_HAS_NT
//   TEXCOORD5     tangentWS      — POPCORN_HAS_NT (.w = handedness)
//   TEXCOORD7     worldPos
//
// The popcorn pipeline carries `worldPos.xyz` only — the .w fog-depth
// channel HD piggybacks on the same slot doesn't exist here (popcorn
// fog reads `worldPos.z` directly).
public struct PopcornPSInput
{
    public float4 svPosition : SV_Position;
#if POPCORN_HAS_VC
    public float4 vertColor  : COLOR0;
#endif
#if POPCORN_HAS_UV
#  if POPCORN_ATLAS
    public float4 uv         : TEXCOORD0;
#  else
    public float2 uv         : TEXCOORD0;
#  endif
#endif
#if POPCORN_HAS_BB_OR_ATLAS
    public float4 slot1      : TEXCOORD1;
#endif
#if POPCORN_BILLBOARD
    public float4 uvAxis     : TEXCOORD2;
#endif
#if POPCORN_HAS_RANDOM_UV
    public float4 random     : TEXCOORD3;
#endif
#if POPCORN_HAS_NT
    public float3 normalWS   : TEXCOORD4;
    public float4 tangentWS  : TEXCOORD5;
#endif
    public float3 worldPos   : TEXCOORD7;
};

// PopcornFX pixel shader output. Single-target colour pass by default;
// the deferred g-buffer payload (a packed depth + a default material
// slot, both matching the engine's deferred composition convention)
// is gated by `HAS_GBUFFER` and compiled out otherwise via
// `Conditional`.
//
//   color        — final RGBA. In MOTION_PASS, .xy carries the
//                  bias-encoded motion vector and .zw is (0, 1).
//   depthRT      — .x = view-space depth, .yzw = (0, 0, 1) packed
//                  normal hint (deferred resolve reconstructs the
//                  particle normal from the quad).
//   materialRT   — .xyz = (1, 0.5, 0.5) default material params,
//                  .w   = pre-SP-fade surface alpha (the deferred
//                  resolver reapplies its own alpha blending).
public struct PopcornPSOutput<let HAS_GBUFFER : bool>
{
    public float4                              color      : SV_Target0;
    public Conditional<float4, HAS_GBUFFER>    depthRT    : SV_Target1;
    public Conditional<float4, HAS_GBUFFER>    materialRT : SV_Target2;
};
