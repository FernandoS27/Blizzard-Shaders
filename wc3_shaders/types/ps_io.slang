// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Pixel shader input and output layouts. Mirrors the VS output types in
// vs_io.slang — the semantic slot indices must match.

implementing wc3_shaders;

// HD mesh pixel shader input, 3.0.0 layout. Mirrors `HDVSOutput` slot for
// slot; see vs_io.slang for what each one carries.
//
// `viewPos.z` is the view depth every fog mode is evaluated against, and
// `viewPos.w` the water-clip distance the shader discards on — the two jobs
// 2.0.0 packed into a single `worldPos.w` scalar, now separated because the
// real world position travels on its own slot.
public struct HDPSInput
{
    public float4 svPosition : SV_Position;
    public float4 vertColor  : COLOR0;
    public float4 uv         : TEXCOORD0;
    public float4 viewPos    : TEXCOORD1;
    public float3 normalWS   : TEXCOORD2;
    public float4 tangentWS  : TEXCOORD3;
    public float4 worldPos   : TEXCOORD10;
    public float4 blightUV   : TEXCOORD11;
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
// Field gating uses two preprocessor defines that the build script sets
// per perm via -D:
//   WC3_IS_DEPTH_PREPASS=1  on depth-only perms
//   WC3_IS_MRT=1            on MRT perms
// The struct-level gates WC3_HAS_COLOR / WC3_HAS_MRT are *derived* from
// those — see the #if block right below. Deriving in the slang source
// rather than the script means files in the same module that don't set
// PS-perm defines (e.g., we compile a VS family alongside the PS files
// because they share the module) still see consistent struct shapes.
//
// History: these used to be `Conditional<float4, BOOL>` template-gated
// fields on a `<let IS_MRT, let HAS_COLOR>` struct template, but slangc
// 2026.x emits Conditional as `array<float4, 1>` in WGSL and WGSL
// forbids @location on array types. The #if form produces the same
// per-perm field layout on every other target (slang's preprocessor
// runs before any backend emit). The `WC3_` prefix avoids colliding
// with the `IS_MRT`/`HAS_COLOR` slang template-param identifiers still
// used in body code below.
//
// SPIR-V note: slangc's emit for Conditional<float4, true> dropped the
// Output Location decoration, requiring build_bls.py to post-process
// each .spv to renumber colliding Output locations by OpEntryPoint
// interface order. The #if form keeps explicit [[vk::location]]
// honored — but the post-processing pass is still harmless on bytecode
// that already has correct locations.
// Per-struct gating flags, derived (defaulted-on) from the per-perm
// inhibit/enable defines the script sets:
//
//   WC3_IS_DEPTH_PREPASS=1   → PSOutput has no color/mrt (hd-style)
//   WC3_IS_MRT=1             → PSOutput has mrt (hd-style)
//
// Every 3.0.0 lit family (hd, crystal, sd_on_hd, popcorn, foliage,
// terrain) shares this one output struct and these two defines. 2.0.0
// terrain and foliage had their own `WC3_TERRAIN_NULL_PASS` / `WC3_HAS_MRT`
// pair and a TerrainPSOutput; both went when those families moved onto
// HD's permutation layout.
#if !defined(WC3_IS_DEPTH_PREPASS)
#define WC3_PSO_HAS_COLOR 1
#endif
#if defined(WC3_IS_MRT) && !defined(WC3_IS_DEPTH_PREPASS)
#define WC3_PSO_HAS_MRT 1
#endif

public struct PSOutput
{
#if WC3_PSO_HAS_COLOR
    public float4 color    : SV_Target0;
#endif
#if WC3_PSO_HAS_MRT
    public float4 specular : SV_Target1;
    public float4 normal   : SV_Target2;
#endif
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

// Water pixel shader input, 3.0.0. Mirrors `WaterVSOutput` slot for slot.
public struct WaterPSInput
{
    public float4 svPosition : SV_Position;
    public float4 vertColor  : COLOR0;
    public float4 uv         : TEXCOORD0;
    public float3 viewPos    : TEXCOORD1;
    public float3 normalVS   : TEXCOORD2;
    public float4 tangentVS  : TEXCOORD3;
    public float4 worldPos   : TEXCOORD10;
};

// Water writes TWO targets on every shaded permutation -- the colour and the
// view depth -- and none on the depth prepass, which is an empty program.
public struct WaterPSOutput
{
#if WC3_PSO_HAS_COLOR
    public float4 color : SV_Target0;
    public float4 depth : SV_Target1;
#endif
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

// Terrain pixel shader input, 3.0.0. Mirrors `TerrainVSOutput` slot for slot:
// the flat-interpolated layer indices first, then foliage's payload. As with
// foliage, SV_IsFrontFace is a separate entry-point parameter that retail
// declares and never reads.
public struct TerrainPSInput
{
    public nointerpolation uint4 layers : TEXCOORD8;
    public float4 svPosition : SV_Position;
    public float4 vertColor  : COLOR0;
    public float4 uv         : TEXCOORD0;
    public float4 viewPos    : TEXCOORD1;
    public float4 tangentVS  : TEXCOORD3;
    public float3 normalVS   : TEXCOORD2;
    public float4 worldPos   : TEXCOORD10;
};

// Foliage pixel shader input, 3.0.0. Mirrors `FoliageVSOutput` slot for
// slot, tangent before normal. The front-face flag is taken as a separate
// entry-point parameter, as HD takes it: retail declares SV_IsFrontFace in
// the signature and never reads it -- foliage does not flip its normal for
// back faces.
public struct FoliagePSInput
{
    public float4 svPosition : SV_Position;
    public float4 vertColor  : COLOR0;
    public float4 uv         : TEXCOORD0;
    public float4 viewPos    : TEXCOORD1;
    public float4 tangentVS  : TEXCOORD3;
    public float3 normalVS   : TEXCOORD2;
    public float4 worldPos   : TEXCOORD10;
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

// ImGui pixel shader input. Mirrors `ImGuiVSOutput` slot-for-slot.
// `svPosition` is declared so the ISGN contains the SV_POSITION entry
// the shipped shader emits; the body never reads it (fxc DCEs the
// unused interpolant from the `dcl_input_ps` list).
public struct ImGuiPSInput
{
    public float4 svPosition : SV_Position;
    public float2 uv         : TEXCOORD0;
    public float4 vertColor  : COLOR0;
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
    // Mirrors `PopcornVSOutput` component for component, because the widths
    // are part of the signature the two stages have to agree on: the atlas
    // variant's TEXCOORD1 is a single life-ratio scalar, not a vector, and so
    // is the alpha-LUT random stream. Both are declared as float4 by an
    // over-wide struct and the shipped blobs then disagree with ours on the
    // interpolant mask — which the differential gate cannot see, because it
    // aligns inputs by semantic (see docs/WC3_30_PORT_PLAN.md, 4b).
#if POPCORN_BILLBOARD
    public float4 slot1      : TEXCOORD1;
    public float4 uvAxis     : TEXCOORD2;
#elif POPCORN_ATLAS
    public float  slot1      : TEXCOORD1;
#endif
#if POPCORN_HAS_RANDOM_UV
    public float  random     : TEXCOORD3;
#endif
#if POPCORN_HAS_NT
    // VIEW space, not world — the VS rotates both by the worldView matrix, and
    // the shading below is done in the same space as `viewPos`.
    public float3 normalWS   : TEXCOORD4;
    public float4 tangentWS  : TEXCOORD5;
#endif
    // View-space position: it is the vector from the eye, so the view direction
    // is `normalize(-viewPos)`, and `.z` is the depth that fog and the
    // soft-particle / motion depth tests compare against.
    //
    // It was `worldPos` under 2.0.0 and it is the same interpolant — the VS has
    // always rotated it by worldView, together with the normal and tangent. The
    // old name was simply wrong, and 3.0.0 makes that visible by adding a real
    // world position alongside it.
    public float3 viewPos    : TEXCOORD7;
    // 3.0.0 addition. The volumetric fog arm needs a WORLD position (it measures
    // a radial distance from the camera and a height above a ground plane), and
    // a view-space one cannot give it either. Declared unconditionally because
    // all 288 shipped permutations declare it — including the motion pass, which
    // never reads it.
    public float3 worldPos   : TEXCOORD8;
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
// HAS_GBUFFER migrated to `WC3_POPCORN_HAS_GBUFFER` preprocessor define
// (set per perm by map_popcorn_ps). The WC3_ prefix avoids clashing
// with slang template-param identifiers elsewhere.
public struct PopcornPSOutput
{
    public float4 color      : SV_Target0;
#if WC3_POPCORN_HAS_GBUFFER
    public float4 depthRT    : SV_Target1;
    public float4 materialRT : SV_Target2;
#endif
};

// CMAA pixel shader input. All four passes are full-screen and consume only
// the pixel position (SV_Position.xy → integer texel coord); svPosition is
// declared so the ISGN matches the shipped shaders, whose signature lists
// SV_POSITION with only xy used.
public struct CmaaPSInput
{
    public float4 svPosition : SV_Position;
};

// edge0 output: the packed per-texel edge bytes for the 2x2 quad (uint4
// render target) plus a depth/stencil marker set to 1.0 when the quad
// contains any edge (lets later passes early-reject flat regions).
public struct CmaaEdge0PSOutput
{
    public uint4 edges : SV_Target0;
    public float depth : SV_Depth;
};

// edge-combine output: only the depth/stencil marker (1.0 where a shape
// candidate exists). The combined masks are scattered through a UAV.
public struct CmaaDepthOnlyPSOutput
{
    public float depth : SV_Depth;
};
