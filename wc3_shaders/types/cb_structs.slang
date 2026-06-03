// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Constant buffer layouts, texture bindings, and sampler bindings shared
// across the HD, SD-on-HD, SD highspec, and SD classic pipelines.
//
// The struct member padding (`_padN`, `_pN`) is intentional: these layouts
// must match what the original Warcraft III engine uploads at each slot, so
// explicit padding pins the offsets of every named field to the expected
// 16-byte alignment boundaries imposed by D3D11 constant buffers.

implementing wc3_shaders;

// Per-stage binding offsets within each descriptor set (CB / SRV /
// Sampler). HLSL gives each shader stage its own register namespace
// (`register(b<N>)` in a VS and the same in a PS are independent
// slots). Vulkan descriptor sets are global across stages, so we shift
// every PS-side binding by `PsBindingOffset` to keep VS- and PS-side
// resources from colliding. The engine's Vulkan backend mirrors the
// same offset on Bind* calls. Future stages claim their own slice
// (`GsBindingOffset = 32`, `HsBindingOffset = 48`, …) when added.
public static const int PsBindingOffset = 16;

// Tighter PS offsets under WGSL so the runtime bind-group layout fits
// WebGPU's per-stage caps (12 uniforms / 16 textures / 16 samplers).
#ifdef WGSL_TARGET
public static const int PsCbBindingOffset      = 4;
public static const int PsSrvBindingOffset     = 12;
public static const int PsSamplerBindingOffset = 12;
#else
public static const int PsCbBindingOffset      = PsBindingOffset;
public static const int PsSrvBindingOffset     = PsBindingOffset;
public static const int PsSamplerBindingOffset = PsBindingOffset;
#endif

// One analytical light as uploaded by the engine.
// type == 0 => directional (position is actually the light direction).
// type  > 0 => point light (position is a world-space position).
// _pad2.x is repurposed as "ambient weight" in the IBL combine path.
//
// All four members are float4 so the CB layout is identical across
// HLSL register-packing (D3D11) and Slang's Metal natural-buffer layout.
// The original engine wire format stores xyz components plus a trailing
// scalar in each 16-byte slot; the `.w` channels carry the pad/type
// scalars that used to be standalone fields.
public struct ShaderLight
{
    public float4 ambient;       // .xyz = ambient color, .w = _pad0
    public float4 diffuse;       // .xyz = diffuse color, .w = _pad1
    public float4 position;      // .xyz = position/direction, .w = type
    public float4 _pad2;
};

// Per-draw constants for the HD pixel shader (b2).
// Holds fog + alpha-test parameters, view/projection matrices used by IBL,
// effect knobs (cloak, fresnel overlay, emissive gain), IBL blend state
// between the "from" and "to" probe cubemaps, and the active light list.
//
// Under WGSL the padding `float3 _p0` is split into three scalar lanes:
// WebGPU's std140-style uniform layout forces vec3 to a 16-byte
// alignment boundary, which would shift every following field by 12
// bytes relative to the engine's wire format (alphaRef@0, _p0@4..16).
// Splitting `_p0` into `_p0_x/_p0_y/_p0_z` keeps the WGSL byte layout
// identical to the original HLSL cbuffer packing — the padding lanes
// are never read by any shader, so the split is invisible to callers.
// Same pattern applied to every `scalar; float3 _pad;` group below.
public struct PSPerDraw
{
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // WGSL std140 and Slang's Metal natural-buffer layout both put a
    // `float3` at the next 16-byte boundary, which would push `fogStart`
    // from offset 16 (HLSL register-packing) to 32 and shift every
    // following field by 16 bytes — and the host CB writer expects the
    // HLSL/D3D wire layout. Splitting `_p0` into three scalars makes
    // them pack into the same 16-byte register as `alphaRef`, matching
    // the original HLSL packing on every target.
    public float   alphaRef;
    public float   _p0_x;            public float  _p0_y;
    public float   _p0_z;
#else
    public float   alphaRef;         public float3 _p0;
#endif
    public float   fogStart;         public float  fogEnd;
    public float   fogDensity;       public float  _p1;
    public float4  fogColor;
    public float4x4 worldView;
    public float4x4 view;
    public float4x4 projection;
    public float4  viewport;
    public float   inverseSoftness;  public float  cloakAmount;
    public float   fresnelTeamColor; public float  _p2;
    public float4  _pad17;
    public float4  fresnelColor;
    public float   envFromMipEnd;    public float  envToMipEnd;
    public float   envTransitionT;   public float  _p3;
    public float   effectTime;       public float  emissiveGain;
    public float   lightCount;       public float  useNdf;
    public ShaderLight lights[8];
};

// The three cascade view-projection matrices used by the shadow map PCF
// sampling path. Uploaded at b1 in the vertex stage.
public struct ShadowCascades
{
    public float4x4 cascade0;
    public float4x4 cascade1;
    public float4x4 cascade2;
};

// Per-draw constants for the HD vertex shader (b2).
// Holds transforms, the fog-depth clip plane (used to pre-bias world Z when
// underwater), vertex-color tint, and two 2x3 texture-coordinate matrices
// stored as two float4 rows each (the .z column is unused).
//
// Matrix field ordering here matches the engine's upload offsets exactly:
//   world          @ 0x000 — object → world.  Its .z after the transform
//                            is a world-space altitude that the fog apply()
//                            compares against `clipHeight` (the water-line);
//                            its full xyzw feeds the shadow cascade matrices.
//   worldView      @ 0x040 — object → view.   The VS emits this as the PS's
//                            "worldPos" TEXCOORD1 input. Strictly speaking
//                            view-space — the PS's `invView` transform
//                            brings it back out into probe space.
//   worldViewProj  @ 0x080 — object → clip.   Writes SV_POSITION.
public struct VSPerDraw
{
    public float4x4 world;
    public float4x4 worldView;
    public float4x4 worldViewProj;
    public float   effectTime;   public float popcornScale;
    public float   clipHeight;   public float underWater;
    public float4  diffuseColor;
    public float4  texMtx0Row0;
    public float4  texMtx0Row1;
    public float4  texMtx1Row0;
    public float4  texMtx1Row1;
};

// Skeletal palette at b3: up to 256 bones, each an affine transform.
// Declared as float4x3 so Slang's default column-major CB packing places
// the three columns in three consecutive float4s — preserving the engine
// upload layout (256 bones * 48 bytes = 12288 bytes) while letting
// skinning code treat each entry as a proper matrix. The matrix is the
// transpose of the engine's 3x4 row-major affine, so world-space results
// come from `mul(float4(pos, 1), M)` (row vector on the left).
public struct BonePalette
{
    public float4x3 matrices[256];
};

// Debug visualisation controls (b3 in PS).
// `enabledShaders` is a bitfield toggling various debug overrides:
//   bit 0 — replace albedo.rgb with overrideAlbedo.
//   bit 1 — replace the t2 control map with overrideOrm (used by crystal):
//           scalar form (standard / ML) reads .x as a refractMask override,
//           vector form (IBL paths) reads .xyz as a full ORM override.
// `debugMode` selects one of the visualisation paths in debugVisualize().
// The `overrideOrm` slot is unused by the HD pipeline and exists here so
// the crystal pipeline shares the same b3 layout.
public struct DebugVisCB
{
    public uint  enabledShaders;  public float  debugMode;
    public float2 _p0;
    // `overrideAlbedo` / `overrideOrm` are float4 so the CB layout is
    // identical across HLSL register-packing (D3D11), WGSL std140, and
    // Slang's Metal natural-buffer layout — see PSPerDraw for the same
    // rationale on `_p0`. Callers read `.xyz` for the float3 portion and
    // `.w` (formerly `_p1` / `_p2`) is unused padding.
    public float4 overrideAlbedo; // .xyz override, .w = _p1
    public float4 overrideOrm;    // .xyz override, .w = _p2
};

public [[vk::binding(PsCbBindingOffset + 2, 0)]] ConstantBuffer<PSPerDraw>      psCB2 : register(b2);
public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<DebugVisCB>     psCB3 : register(b3);
public [[vk::binding(1, 0)]] ConstantBuffer<ShadowCascades> vsCB1 : register(b1);
public [[vk::binding(2, 0)]] ConstantBuffer<VSPerDraw>      vsCB2 : register(b2);
public [[vk::binding(3, 0)]] ConstantBuffer<BonePalette>    vsCB3 : register(b3);

// HD material textures. Slot ordering matches the engine-side bindings:
//   t0 albedo, t1 normal (XY + AA mask in W), t2 ORM (occ/rough/metal/mask),
//   t3 emissive, t4 team color mask.
//   t13/t14 are the two IBL cubemap arrays we blend between during
//   environment transitions; t15 is the split-sum BRDF LUT.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4>         t_albedo    : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4>         t_normal    : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4>         t_orm       : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4>         t_emissive  : register(t3);
public [[vk::binding(PsSrvBindingOffset + 4, 1)]] Texture2D<float4>         t_teamColor : register(t4);
public [[vk::binding(PsSrvBindingOffset + 13, 1)]] TextureCubeArray<float4>  t_iblFrom   : register(t13);
public [[vk::binding(PsSrvBindingOffset + 14, 1)]] TextureCubeArray<float4>  t_iblTo     : register(t14);
public [[vk::binding(PsSrvBindingOffset + 15, 1)]] Texture2D<float4>         t_brdfLut   : register(t15);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_albedo    : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_normal    : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_orm       : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_emissive  : register(s3);
public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_teamColor : register(s4);
public [[vk::binding(PsSamplerBindingOffset + 13, 2)]] SamplerState s_iblFrom   : register(s13);
public [[vk::binding(PsSamplerBindingOffset + 14, 2)]] SamplerState s_iblTo     : register(s14);
public [[vk::binding(PsSamplerBindingOffset + 15, 2)]] SamplerState s_brdfLut   : register(s15);

// Per-draw constants for the SD-on-HD pixel shader (b2).
// The layout mirrors the original SD engine CB, so most fields are
// preserved as padding; only the values that are actually consumed by the
// remastered path (fog, alpha ref, inv-view rows, env mip ranges, cloak,
// and lights) are named. invViewRowN are the rows of the transposed
// view-to-world rotation used to orient the IBL cubemap samples.
public struct SDPSPerDraw
{
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float   alphaRef;
    public float   _p0_x;            public float  _p0_y;
    public float   _p0_z;
#else
    public float   alphaRef;         public float3 _p0;
#endif
    public float   fogStart;         public float  fogEnd;
    public float   fogDensity;       public float  _p1;
    public float4  fogColor;

    public float4  _pad3;
    public float4  _pad4;
    public float4  _pad5;
    public float4  _pad6;

    public float4  invViewRow0;
    public float4  invViewRow1;
    public float4  invViewRow2;

    public float4  _pad10;
    public float4  _pad11;
    public float4  _pad12;
    public float4  _pad13;
    public float4  _pad14;
    public float4  _pad15;

    public float   inverseSoftness;  public float  cloakAmount;
    public float2  _p16;

    public float4  _pad17;
    public float4  _pad18;

    public float   envFromMipEnd;    public float  envToMipEnd;
    public float   envTransitionT;   public float  _p19;

    // lightCountSlot.z holds the uint-reinterpreted active light count.
    public float4  lightCountSlot;

    public ShaderLight lights[8];
};

// Scalar cascade count for the shadow sampler PS path (b1).
// Shared between the HD (IBL) and SD-on-HD pipelines — both consume the
// same cb1[0].x active-cascade count.
public struct ShadowCascadeCount
{
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float numCascades;
    public float _pad_x;       public float _pad_y;
    public float _pad_z;
#else
    public float numCascades;  public float3 _pad;
#endif
};

public [[vk::binding(PsCbBindingOffset + 2, 0)]] ConstantBuffer<SDPSPerDraw>        sdPsCB2 : register(b2);
public [[vk::binding(PsCbBindingOffset + 1, 0)]] ConstantBuffer<ShadowCascadeCount> sdPsCB1 : register(b1);

// Shadow cascades at t10-12 / s10-12. Bytecode must stay bit-identical
// to the shipped Blizzard shaders on D3D, hence Texture2D<float4>. WGSL
// needs Texture2D<float> so slangc emits texture_depth_2d. PCF helpers
// take `ShadowMapTex` which aliases the right form per target.
#ifdef WGSL_TARGET
public typealias ShadowMapTex = Texture2D<float>;
#else
public typealias ShadowMapTex = Texture2D<float4>;
#endif
public [[vk::binding(PsSrvBindingOffset + 10, 1)]] ShadowMapTex sd_t_shadow0 : register(t10);
public [[vk::binding(PsSrvBindingOffset + 11, 1)]] ShadowMapTex sd_t_shadow1 : register(t11);
public [[vk::binding(PsSrvBindingOffset + 12, 1)]] ShadowMapTex sd_t_shadow2 : register(t12);
public [[vk::binding(PsSamplerBindingOffset + 10, 2)]] SamplerComparisonState sd_s_shadow0 : register(s10);
public [[vk::binding(PsSamplerBindingOffset + 11, 2)]] SamplerComparisonState sd_s_shadow1 : register(s11);
public [[vk::binding(PsSamplerBindingOffset + 12, 2)]] SamplerComparisonState sd_s_shadow2 : register(s12);

// Per-draw constants for the SD highspec vertex shader (b0): transforms,
// tint, two texcoord matrices, and the light list — per-vertex lighting
// happens entirely in the VS here, so the PS path doesn't need them.
public struct SDHighspecVSPerDraw
{
    public float4x4 world;
    public float4x4 worldViewProj;
    public float4   diffuseColor;
    public float4   texMtx0Row0;
    public float4   texMtx0Row1;
    public float4   texMtx1Row0;
    public float4   texMtx1Row1;
    public ShaderLight lights[8];
};

// Per-draw constants for the SD classic pixel shader (b0): the classic
// pipeline only needs fog and alpha-ref; everything else comes from the
// texture-stage ops and the interpolated vertex color.
public struct SDClassicPSPerDraw
{
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float  alphaRef;
    public float  _p0_x;        public float  _p0_y;
    public float  _p0_z;
#else
    public float  alphaRef;     public float3 _p0;
#endif
    public float  fogStart;     public float  fogEnd;
    public float  fogDensity;   public float  _p1;
    public float4 fogColor;
};

public [[vk::binding(0, 0)]] ConstantBuffer<SDHighspecVSPerDraw>  sdHighspecVsCB0 : register(b0);
public [[vk::binding(PsCbBindingOffset + 0, 0)]] ConstantBuffer<SDClassicPSPerDraw>   sdClassicPsCB0  : register(b0);

// Per-draw constants for the water pixel shader (b2). Shares most of
// its layout with `PSPerDraw` — fog, invView rotation, IBL probe params,
// effect time, and the analytic light list are identical slot-for-slot
// — but repurposes a few fields the HD path doesn't need:
//   • `worldToClip` (cb2[11..14], aka HD's `projection`) is used as the
//     full world-space → clip-space matrix by the SSR march.
//   • `ambientClamp` (cb2[16].xyz) is an HDR ceiling on the emissive
//     probe color (HD uses these 3 scalars as cloak / fresnel knobs).
//   • `refractSoftness` / `litSoftness` (cb2[17].xy) parameterise the
//     two depth-based shore ramps.
//
// `lights[8]` over-declares the last 16 bytes relative to what the
// engine actually uploads (which stops at light[7].position+type), but
// the water shader never reads that slot and D3D tolerates the extra.
public struct WaterPSPerDraw
{
    public float4  _pad0;                                 // cb2[0]

    public float   fogStart;        public float  fogEnd;
    public float   fogDensity;      public float  _p1;           // cb2[1]
    public float4  fogColor;                              // cb2[2]

    float4x4 _padWorldView;                        // cb2[3..6] (unused by water)
    public float4x4 view;                                 // cb2[7..10]
    public float4x4 worldToClip;                          // cb2[11..14]
    public float4   viewport;                             // cb2[15]

    // cb2[16]: HDR clamp applied to the emissive probe color.
    public float3   ambientClamp;   public float _p16;           // cb2[16]

    // cb2[17]: depth-based shore ramp distances.
    public float    refractSoftness;
    public float    litSoftness;    public float2 _p17;          // cb2[17]

    public float4   _pad18;                               // cb2[18]

    public float    envFromMipEnd;  public float  envToMipEnd;
    public float    envTransitionT; public float  _p19;          // cb2[19]

    public float    effectTime;     public float  _p20_y;
    public float    lightCount;     public float  useNdf;        // cb2[20]

    public ShaderLight lights[8];                         // cb2[21..]
};

public [[vk::binding(PsCbBindingOffset + 2, 0)]] ConstantBuffer<WaterPSPerDraw> waterPsCB2 : register(b2);

// Water PS texture bindings. The water draw reuses HD slot numbers but
// binds different resources there — the aliases below make the intent
// explicit in the shader body. Slang only emits bindings that the
// compiled entry actually uses, so these don't collide with the HD
// `t_albedo` / `t_normal` / ... declarations above.
//   t0 = previous-frame scene color (for refraction & SSR hits)
//   t1 = previous-frame depth buffer, sampled as .x
//   t2 = tiling water normal map (DXT5nm-style two-channel packing)
//   t3 = emissive / lightmap probe (sampled at mip 16 ≈ average color)
//
//   s4 = scene-color sampler (note: paired with t0, not s0)
//   s1/s2/s3 match their texture counterparts
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_waterScene  : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_waterDepth  : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4> t_waterNormal : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4> t_waterProbe  : register(t3);

public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_waterScene  : register(s4);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_waterDepth  : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_waterNormal : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_waterProbe  : register(s3);

// Per-draw constants for the foliage vertex shader (b2). 16 float4
// slots — superset of the terrain VS layout with two extra float4s for
// the constant tint colour (cb2[13]) and the 2×3 UV0 transform matrix
// (cb2[14..15]). The wind-animation perms additionally read
// `effectTime` from cb2[12].x.
//
//   shadowWorld   @ cb2[0..3]   — full 4×4 model→world used to feed the
//                                 cascade matrices in cb1 (shadow path
//                                 only).
//   worldRow0/1/2 @ cb2[4..6]   — three rows of the model→world rotation
//                                 (.xyz of each are the columns of the
//                                 world 3×3 used for normals/tangents).
//   worldTranslate@ cb2[7]      — model→world translation (.xyz only).
//   worldViewProj @ cb2[8..11]  — model→clip 4×4 for SV_Position.
//   effectTime    @ cb2[12].x   — engine clock used as the cos/sin
//                                 wind-swing phase. .yzw are unused.
//   tintColor     @ cb2[13]     — RGBA constant tint multiplied against
//                                 the per-vertex COLOR.
//   texMtx0Row0   @ cb2[14]     — UV0 affine row 0 (.xyw lanes only).
//   texMtx0Row1   @ cb2[15]     — UV0 affine row 1 (.xyw lanes only).
//
// The vertex-color slot is always read by the body, so the foliage VS
// has no `HAS_VERTEX_COLOR` axis. fxc still shrinks the cb declaration
// based on highest indexed access, so wind-on perms emit `CB2[16]`
// while wind-off perms emit `CB2[16]` as well (the latter still touches
// cb2[14..15] for the UV transform).
public struct FoliageVSPerDraw
{
    public float4x4 shadowWorld;     // cb2[0..3]
    public float4   worldRow0;       // cb2[4]
    public float4   worldRow1;       // cb2[5]
    public float4   worldRow2;       // cb2[6]
    public float4   worldTranslate;  // cb2[7]
    public float4x4 worldViewProj;   // cb2[8..11]
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float    effectTime;
    public float    _padTime_x;      public float _padTime_y;
    public float    _padTime_z;      // cb2[12]
#else
    public float    effectTime;      public float3 _padTime; // cb2[12]
#endif
    public float4   tintColor;       // cb2[13]
    public float4   texMtx0Row0;     // cb2[14]
    public float4   texMtx0Row1;     // cb2[15]
};

public [[vk::binding(2, 0)]] ConstantBuffer<FoliageVSPerDraw> foliageVsCB2 : register(b2);

// Wind-area parameters (b3, only bound when WIND_ANIMATION is active).
//   .xy = world-space origin of the wind area (anchor for the gradient
//          texture mapping).
//   .zw = wind area size in world units (used as the UV scale).
public struct FoliageWindCB
{
    public float2 windOrigin;
    public float2 windSize;
};

public [[vk::binding(3, 0)]] ConstantBuffer<FoliageWindCB> foliageVsCB3 : register(b3);

// Foliage VS wind-direction texture (only bound on WIND_ANIMATION
// perms). Single-channel scalar field sampled at three nearby texels
// to recover a 2D gradient.
public [[vk::binding(0, 1)]] Texture2D<float4> t_foliageWind : register(t0);
public [[vk::binding(0, 2)]] SamplerState      s_foliageWind : register(s0);

// Foliage pixel-shader textures. Slot ordering matches the engine
// bindings recovered from the BLS perms:
//   t0 albedo + alpha, t1 packed normal map (xyw lanes), t2 mask
//   (yz = roughness/metallic), t3 emissive, t4 lightmap / AO (.w lane).
// Cascaded shadow + IBL probe + BRDF LUT bindings are reused from the
// shared HD aliases (sd_t_shadow*, t_iblFrom/To, t_brdfLut).
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_foliageAlbedo   : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_foliageNormal   : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4> t_foliageMask     : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4> t_foliageEmissive : register(t3);
public [[vk::binding(PsSrvBindingOffset + 4, 1)]] Texture2D<float4> t_foliageLightmap : register(t4);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_foliageAlbedo   : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_foliageNormal   : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_foliageMask     : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_foliageEmissive : register(s3);
public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_foliageLightmap : register(s4);

// Per-draw constants for the terrain vertex shader (b2). The terrain
// pipeline uses a layout distinct from the HD `VSPerDraw`:
//
//   shadowWorld   @ cb2[0..3]   — full 4×4 model→world used to feed the
//                                 cascade matrices in cb1 (shadow path
//                                 only — fxc DCE'ds it on non-shadow
//                                 perms because nothing reads it).
//   worldRow0/1/2 @ cb2[4..6]   — three rows of the model→world rotation
//                                 (the .xyz of each are taken as the
//                                 columns of the world 3×3); used to
//                                 transform normals + tangents.
//   worldTranslate@ cb2[7]      — model→world translation (.xyz only).
//   worldViewProj @ cb2[8..11]  — model→clip 4×4 for SV_Position.
//   _padReserved  @ cb2[12]     — present in the no-vertex-color layout,
//                                 never read.
//   tintColor     @ cb2[13]     — RGBA constant tint, used only when the
//                                 vertex format does not carry COLOR.
//
// fxc's CB declaration shrinks based on the highest accessed index, so
// the vertex-color-feeding perms (which never read cb2[12..13]) emit
// `dcl_constantbuffer CB2[12]` while the constant-tint perms emit
// `CB2[14]` — even though the slang struct is fixed at 14 float4s.
public struct TerrainVSPerDraw
{
    public float4x4 shadowWorld;     // cb2[0..3]
    public float4   worldRow0;       // cb2[4]
    public float4   worldRow1;       // cb2[5]
    public float4   worldRow2;       // cb2[6]
    public float4   worldTranslate;  // cb2[7]
    public float4x4 worldViewProj;   // cb2[8..11]
    public float4   _padReserved;    // cb2[12]
    public float4   tintColor;       // cb2[13]
};

public [[vk::binding(2, 0)]] ConstantBuffer<TerrainVSPerDraw> terrainVsCB2 : register(b2);

// Terrain pixel-shader splat textures. Slot ordering matches the
// engine bindings: t0 splat color array, t1 splat normal+gloss array
// (rg = nx/ny, w = gloss), t2 splat mask array (.yz = mask UV), t3
// global lightmap / AO (.w = AO factor). The terrain PS shares t10..t15
// (cascade shadows + IBL probes + BRDF LUT) with the HD pipeline via
// the existing aliases declared above.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2DArray<float4> t_splatColor  : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2DArray<float4> t_splatNormal : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2DArray<float4> t_splatMask   : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4>      t_lightmap    : register(t3);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_splatColor  : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_splatNormal : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_splatMask   : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_lightmap    : register(s3);

// Per-draw constants for the PopcornFX vertex shader (b2). Aliases
// the same buffer as `vsCB2` (the engine binds them at the same
// register slot) but exposes only the fields the popcorn pipeline
// actually consumes:
//
//   world         @ 0x040 — particle emitter's object → world transform.
//                           Lives at the same offset as VSPerDraw.worldView,
//                           because the engine binds the world matrix here
//                           when running the particle pipeline (the HD
//                           pipeline binds the worldView product instead).
//   worldViewProj @ 0x080 — particle emitter's object → clip transform.
//   popcornScale  @ 0x0C4 — scalar emitter scale applied to the local-
//                           space position before any matrix transform
//                           (i.e. at the .y slot of cb2[12]).
public struct PopcornVSPerDraw
{
    public float4x4 _padCB0;          // cb2[0..3] — unused by the popcorn VS
    public float4x4 world;            // cb2[4..7]
    public float4x4 worldViewProj;    // cb2[8..11]
    public float    _padTime;         // cb2[12].x  (the HD pipeline's `effectTime`)
    public float    popcornScale;     // cb2[12].y
    public float2   _padHeight;       // cb2[12].zw (HD's clipHeight / underWater)
};

public [[vk::binding(2, 0)]] ConstantBuffer<PopcornVSPerDraw> popcornVsCB2 : register(b2);

// Per-draw constants for the PopcornFX pixel shader (b2). Aliases
// the same register slot as the HD `psCB2` (and `waterPsCB2`) — the
// engine reuses the same buffer slot for whichever pipeline is
// active, and slangc only emits the binding the live entry point
// actually references.
//
// Slot map (recovered from the original BLS PS perms; see
// re_shaders/popcornfx/popcorn_ps.hlsl for the per-feature comments):
//
//   cb2[0]          — unused by the popcorn PS
//   cb2[1].xyz      — fog start / end / density (FOG_*)
//   cb2[2].xyz      — fog color                  (FOG_*)
//   cb2[3..6]       — unused (HD's worldView slot)
//   cb2[7..10]      — per-particle world basis   (LIT IBL)
//   cb2[11..14]     — world → clip matrix        (SOFT_PARTICLES,
//                                                 MOTION_PASS, LIT IBL)
//   cb2[15]         — depth-buffer UV remap (.xy = scale, .zw = bias)
//   cb2[16].x       — depth-fade scale            (SOFT_PARTICLES,
//                                                 MOTION_PASS)
//   cb2[17..18]     — unused
//   cb2[19].x       — IBL `cubeFrom` roughness-to-mip multiplier
//   cb2[19].y       — IBL `cubeTo`   roughness-to-mip multiplier
//   cb2[19].z       — IBL cubemap blend (0 → cubeFrom, 1 → cubeTo)
//   cb2[20].z       — analytic light count       (LIT)
//   cb2[20].w       — "use smoothed normal" flag (LIT specular AA)
//   cb2[21..52]     — analytic light array (8 lights × 4 float4
//                     stride, sharing layout with HD's `ShaderLight`).
//                     lights[0] does double duty as the IBL ambient /
//                     base-material driver — its `.ambient` is added
//                     to the IBL diffuse contribution and its
//                     `.diffuse` is the IBL tint.
public struct PopcornPSPerDraw
{
    public float4   _pad0;                                  // cb2[0]
    public float    fogStart;       public float fogEnd;
    public float    fogDensity;     public float _p1;       // cb2[1]
    public float4   fogColor;                               // cb2[2]
    public float4x4 _padCB3;                                // cb2[3..6]

    // The following two "matrix" slots are declared as raw float4
    // arrays rather than `float4x4` because both are addressed with
    // non-contiguous component swizzles (.xyw / .xzy) and slang's
    // matrix-row accessors lower those to per-scalar loads instead
    // of a single vector load + swizzle. Storing them as raw arrays
    // matches the original engine's `float4 cb2[N]` access pattern.
    //
    //   particleBasis[0..2] — per-particle world basis used by the
    //                          LIT IBL block to rotate worldPos and
    //                          worldNormal into the cubemap-local
    //                          frame (.xzy swizzle).
    //   worldToClip[0..3]   — world → clip (3×4 affine, using the
    //                          .xyw lanes of each row; .z is unused).
    public float4   particleBasis[4];                       // cb2[7..10]
    public float4   worldToClip[4];                         // cb2[11..14]

    public float4   depthUVRemap;                           // cb2[15]
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float    depthFadeScale;
    public float    _p16_x;         public float _p16_y;
    public float    _p16_z;                                 // cb2[16]
#else
    public float    depthFadeScale; public float3 _p16;     // cb2[16]
#endif
    public float4   _pad17;                                 // cb2[17]
    public float4   _pad18;                                 // cb2[18]
    public float    iblMipFrom;     public float iblMipTo;
    public float    iblBlend;       public float _p19;      // cb2[19]
    public float2   _pad20_xy;
    public float    lightCount;     public float useSmoothedNormal; // cb2[20]
    public ShaderLight lights[8];                           // cb2[21..52]
};

public [[vk::binding(PsCbBindingOffset + 2, 0)]] ConstantBuffer<PopcornPSPerDraw> popcornPsCB2 : register(b2);

// Popcorn pixel-shader textures. Slot ordering matches the engine
// bindings recovered from the BLS perms:
//   t0  — diffuse / motion-source (sampled with the per-mode UV);
//         in MOTION_PASS its .xy is the encoded motion vector.
//   t1  — alpha-remap LUT (1D ramp in U, random scalar in V).
//   t2  — packed normal map (LIT only).
//   t3  — smoothness (.y) + metallic (.z) (LIT only).
//   t4  — scene depth (SOFT_PARTICLES color-pass fade and the
//         MOTION_PASS depth-discard test).
//   t13 — IBL diffuse-irradiance + spec cubemap "from" probe (LIT).
//   t14 — IBL spec cubemap "to" probe (LIT) — blended by iblBlend.
//   t15 — split-sum BRDF integration LUT (LIT).
//
// Several of these aliases share register slots with the HD bindings
// declared above (e.g. t13/t14/t15 are also used by the HD IBL path);
// slangc only emits the bindings the active entry actually
// references, so the duplicate declarations are harmless.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4>        t_popcornDiffuse  : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4>        t_popcornAlphaLut : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4>        t_popcornNormal   : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4>        t_popcornSmoothMet: register(t3);
public [[vk::binding(PsSrvBindingOffset + 4, 1)]] Texture2D<float4>        t_popcornDepth    : register(t4);
public [[vk::binding(PsSrvBindingOffset + 13, 1)]] TextureCubeArray<float4> t_popcornCubeFrom : register(t13);
public [[vk::binding(PsSrvBindingOffset + 14, 1)]] TextureCubeArray<float4> t_popcornCubeTo   : register(t14);
public [[vk::binding(PsSrvBindingOffset + 15, 1)]] Texture2D<float4>        t_popcornBrdfLut  : register(t15);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_popcornDiffuse  : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_popcornAlphaLut : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_popcornNormal   : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_popcornSmoothMet: register(s3);
public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_popcornDepth    : register(s4);
public [[vk::binding(PsSamplerBindingOffset + 13, 2)]] SamplerState s_popcornCubeFrom : register(s13);
public [[vk::binding(PsSamplerBindingOffset + 14, 2)]] SamplerState s_popcornCubeTo   : register(s14);
public [[vk::binding(PsSamplerBindingOffset + 15, 2)]] SamplerState s_popcornBrdfLut  : register(s15);

// Per-draw constants for the tonemap pixel shader (b1). The engine
// only uploads a single 16-byte slot — the linear exposure multiplier
// applied to the HDR scene color before the ACES filmic curve — but
// the CB is still dimensioned as a full float4 to match the wire
// layout fxc emits for `float4 cb1[1]`.
public struct TonemapPSPerDraw
{
    public float  exposure;
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float  _p0_x;
    public float  _p0_y;
    public float  _p0_z;
#else
    public float3 _p0;
#endif
};

public [[vk::binding(PsCbBindingOffset + 1, 0)]] ConstantBuffer<TonemapPSPerDraw> tonemapPsCB1 : register(b1);

// Tonemap PS texture bindings. Aliases the same D3D slots the HD mesh
// PS uses (t0 / s0) — the tonemap pass runs on its own pipeline object
// and slangc only emits bindings the active entry point references, so
// these declarations coexist with the HD material bindings above.
//   t0 = linear-HDR scene target produced by the preceding lighting pass
//   s0 = linear-clamp sampler paired with the scene target
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_sceneHdr : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState      s_sceneHdr : register(s0);

// Sprite PS texture bindings. Aliases the same D3D slots the HD mesh
// PS uses (t0 / s0) — sprite draws bind their own source texture here
// and slangc only emits the binding for the active entry point, so the
// declaration coexists with the HD material bindings above.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_sprite : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState      s_sprite : register(s0);

// Per-draw constants for the ImGui vertex shader (b2). 12 float4
// slots — the engine binds 192 bytes here, but the math only consumes
// the four-slot projection block at cb2[8..11]:
//
//   _pad        @ cb2[0..7]    — engine padding, never read.
//   projection  @ cb2[8..11]   — column-major 2D projection matrix.
//                                 Column 2 (cb2[10]) is unused by the
//                                 math, since input positions are 2D —
//                                 the .z lane of the transform is
//                                 elided. Stored as a raw float4 array
//                                 (rather than a `float4x4`) so the
//                                 per-column accesses lower as direct
//                                 cb2[i] loads, matching the shipped
//                                 engine's `cb2[8] / cb2[9] / cb2[11]`
//                                 reference pattern verbatim.
public struct ImGuiVSPerDraw
{
    public float4 _pad[8];          // cb2[0..7]
    public float4 projection[4];    // cb2[8..11]
};

public [[vk::binding(2, 0)]] ConstantBuffer<ImGuiVSPerDraw> imguiVsCB2 : register(b2);

// ImGui PS texture binding. Aliases the same D3D slot the HD mesh PS
// uses (t0 / s0) — ImGui draws bind their own font / texture atlas
// here and slangc only emits the binding for the active entry point,
// so the declaration coexists with the HD material bindings above.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_imgui : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState      s_imgui : register(s0);

// Distortion PS texture bindings. The full-screen distortion pass
// samples a previous-frame scene texture (t0) at four offset UVs
// driven by an offset map (t1) — see `distortion_ps.slang` for the
// per-channel chromatic blend. Both bindings reuse the engine's
// shared t0/t1 slot numbers; slangc only emits whichever entry-
// point references them, so they coexist with the HD aliases above.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_distortionScene : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_distortionMap   : register(t1);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_distortionScene : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_distortionMap   : register(s1);

// ---------------------------------------------------------------------------
// CMAA (Conservative Morphological Anti-Aliasing) post-process passes.
//
// Four single-permutation full-screen pixel shaders that together implement
// Intel's CMAA over the engine's resolved scene colour. Each pass is its own
// pipeline object, so the bindings below alias the shared t0/t3/s0/s3/b0 slot
// numbers — slangc only emits the bindings the active entry point references,
// so they coexist with the HD material aliases above. UAVs claim descriptor
// set 3 (no other family binds UAVs); their register(uN) slots are what the
// D3D11 / D3D12 BLS targets actually use.
//
// Pipeline data flow:
//   edge0   : reads t_cmaaColor, writes packed edges (SV_Target uint4) and
//             copies edge-adjacent source colours into u_cmaaWorkColor.
//   edge1   : reads packed edges (t_cmaaEdgesPacked, uint4), writes the
//             local-contrast-pruned edges into u_cmaaEdgesRefined (unorm8).
//   combine : reads refined edges (t_cmaaEdges, via Gather), writes the
//             combined 4-direction masks into u_cmaaCombined (unorm8).
//   process : reads combined masks (t_cmaaEdges) + source colour (t_cmaaColor)
//             and writes the anti-aliased colour into u_cmaaColor.
//
// Per-pass uniform: the inverse target size used to turn integer texel coords
// into Gather UVs. Matches `float4 cb0[1]` in the shipped DXBC (only .xy read).
public struct CmaaPSPerDraw
{
    public float2 invTargetSize;   // 1 / textureSize
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    public float  _p0_x;
    public float  _p0_y;
#else
    public float2 _p0;
#endif
};

public [[vk::binding(PsCbBindingOffset + 0, 0)]] ConstantBuffer<CmaaPSPerDraw> cmaaPsCB0 : register(b0);

// Sampled inputs. edge1 reads the packed edges as an integer texture (t3);
// combine / process read float-typed edges (t3) and the scene colour (t0).
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_cmaaColor       : register(t0);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<uint4>  t_cmaaEdgesPacked : register(t3);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4> t_cmaaEdges       : register(t3);

// Point sampler (s3) for integer edge gathers; linear sampler (s0) for the
// sub-texel colour re-sample along a traced edge in the process pass.
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_cmaaPoint  : register(s3);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_cmaaLinear : register(s0);

// UAV outputs (descriptor set 3). edge0's working colour buffer and process's
// AA output share the typed-float4 u1 slot; the two intermediate edge buffers
// are unorm8.
public [[vk::binding(1, 3)]] RWTexture2D<float4>            u_cmaaColor         : register(u1);
public [[vk::binding(0, 3)]] RWTexture2D<unorm float4>      u_cmaaEdgesRefined  : register(u0);
public [[vk::binding(2, 3)]] RWTexture2D<unorm float4>      u_cmaaCombined      : register(u2);

// ---------------------------------------------------------------------------
// Bloom post-process passes.
//
// Two single-/dual-permutation full-screen pixel shaders that bracket the
// (engine-driven) separable blur: `bloomextract` isolates the bright
// highlights of the scene, and `bloomcombine` grades and screen-composites
// the blurred highlights back over the scene. Each is its own pipeline
// object, so the bindings below alias the shared t0/t1/s0/s1/b1 slot numbers
// — slangc only emits the bindings the active entry point references, so they
// coexist with the HD material aliases above (same pattern as tonemap / cmaa).
//
// The two CBs both bind b1 and most likely view slices of one engine-side
// "bloom params" upload; each shader names only the lanes it reads:
//   bloomextract reads cb1[0].x         → CB1[1]
//   bloomcombine reads cb1[0].zw,1[1].xy → CB1[2]

// Per-draw constants for the bloom bright-pass (b1). Only the .x luminance
// cutoff is consumed; the rest pads out to `float4 cb1[1]`.
public struct BloomExtractPSPerDraw
{
    public float  threshold;        // cb1[0].x — luminance cutoff
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See PSPerDraw for the layout rationale behind the scalar split.
    public float  _p0_x;            public float _p0_y;
    public float  _p0_z;
#else
    public float3 _p0;              // cb1[0].yzw
#endif
};

// Per-draw constants for the bloom composite (b1). Two float4 slots holding
// the per-layer intensity (cb1[0].zw) and saturation (cb1[1].xy) knobs. All
// fields are float/float2 so the layout is identical across every target
// without the float3-alignment split the structs above need.
public struct BloomCombinePSPerDraw
{
    public float2 _p0_xy;           // cb1[0].xy — unused
    public float  intensityBloom;   // cb1[0].z  — gain for the blurred layer
    public float  intensityScene;   // cb1[0].w  — gain for the scene layer
    public float  saturationBloom;  // cb1[1].x  — saturation for the blur
    public float  saturationScene;  // cb1[1].y  — saturation for the scene
    public float2 _p1_zw;           // cb1[1].zw — unused
};

public [[vk::binding(PsCbBindingOffset + 1, 0)]] ConstantBuffer<BloomExtractPSPerDraw> bloomExtractPsCB1 : register(b1);
public [[vk::binding(PsCbBindingOffset + 1, 0)]] ConstantBuffer<BloomCombinePSPerDraw> bloomCombinePsCB1 : register(b1);

// Bloom bright-pass input: the resolved scene colour (t0).
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_bloomSource : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState   s_bloomSource : register(s0);

// Bloom composite inputs: the scene colour (t0, also the output alpha source)
// and the blurred bright-pass result (t1).
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_bloomScene : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_bloomBlur  : register(t1);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState   s_bloomScene : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState   s_bloomBlur  : register(s1);

// ---------------------------------------------------------------------------
// Gaussian blur post-process pass.
//
// Single-permutation full-screen separable blur (gaussianblur.bls). The engine
// runs the one shader for both the horizontal and the vertical pass, uploading
// a different tap set each pass: up to 15 taps in `float4 cb1[15]`, where tap i
// carries its UV offset in .xy and its weight in .z. The active tap count is
// packed into cb1[0].w (read once, truncated to int, before the loop).
//
// `taps` is a raw float4[15] rather than a named-field struct so each element
// occupies exactly one 16-byte slot on every target — matching the shipped
// `float4 cb1[15]` register packing — and the loop's dynamic index lowers to a
// single cb1[i] load (same rationale as the imgui / popcorn indexed CBs above).
public struct GaussianBlurPSPerDraw
{
    public float4 taps[15];   // [i].xy = UV offset, [i].z = weight; [0].w = tap count
};

public [[vk::binding(PsCbBindingOffset + 1, 0)]] ConstantBuffer<GaussianBlurPSPerDraw> gaussianBlurPsCB1 : register(b1);

// Gaussian blur input: the image being blurred (t0). Aliases the shared t0/s0
// slots like the other post-process passes; slangc only emits the binding the
// active entry references.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_gaussianSource : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState   s_gaussianSource : register(s0);
