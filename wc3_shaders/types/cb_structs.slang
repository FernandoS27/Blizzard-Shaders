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

// Scalar-split layout rule, cited by several structs below.
//
// WGSL's std140-style uniform layout and Slang's Metal natural-buffer layout
// both put a `float3` on the next 16-byte boundary. A struct written as
// `float alphaRef; float3 _p0;` therefore packs `_p0` at offset 16 instead of 4
// on those targets, and shifts every later field by 12 or 16 bytes relative to
// the HLSL register packing the engine writes. Splitting the float3 into three
// scalars keeps them in the same 16-byte register as the scalar before them on
// every target; the split lanes are padding no shader reads.

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

public [[vk::binding(1, 0)]] ConstantBuffer<ShadowCascades> vsCB1 : register(b1);
public [[vk::binding(2, 0)]] ConstantBuffer<VSPerDraw>      vsCB2 : register(b2);
public [[vk::binding(3, 0)]] ConstantBuffer<BonePalette>    vsCB3 : register(b3);

// `sd_lowspec_vs`'s palette: the same record, 72 bones (216 float4s) -- the
// lowspec pipeline targets feature level 9, whose constant buffers are small.
public struct LowspecBonePalette72
{
    public float4x3 matrices[72];
};

public [[vk::binding(3, 0)]] ConstantBuffer<LowspecBonePalette72> sdLowspecVsCB3 : register(b3);

// The two texture stages the SD classic pixel shader samples (t0 / t1). The
// rest of the 2.0.0 HD material set (ORM, emissive, team colour, the IBL pair
// and BRDF LUT at t13-t15) went when the last 2.0.0 lit family was ported.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4>         t_albedo    : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4>         t_normal    : register(t1);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_albedo    : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_normal    : register(s1);

// ===========================================================================
// Warcraft III 3.0.0 HD mesh pipeline
// ===========================================================================
//
// Everything above this point is what survives of the 2.0.0-era binding set:
// the vertex banks `sd_on_hd_vs` and `sd_highspec_vs` still read, and the two
// texture stages `sd_classic_ps` samples. Every 3.0.0 lit pixel shader -- hd,
// crystal, sd_on_hd, popcorn, foliage, terrain, water -- binds what follows.
// Declarations that claim the same register are fine: slang only emits the
// resources an entry point actually reaches, exactly as `t_albedo` and
// `t_waterScene` share t0.

// One bone, as both palettes store it: the three rows of an affine 3x4.
//
// Spelled as three explicit rows rather than a `float4x3` because the same
// type has to describe a constant-buffer palette AND a 48-byte structured
// buffer element, and only the row form has a layout that is obviously
// identical on both sides. Row `k` dotted with `float4(pos, 1)` gives
// component `k` of the transformed point.
public struct BoneTransform
{
    public float4 row0;
    public float4 row1;
    public float4 row2;
};

// Constant-buffer bone palette (b3): 256 bones x three rows == the 768
// float4s the shipped shader declares.
public struct HDBonePalette
{
    public BoneTransform bones[256];
};

// Per-draw vertex constants for the 3.0.0 HD mesh shader (b2).
//
// Register map, in the shipped order:
//   [ 0- 3]  world          — object -> world; .z feeds the water clip test
//                             and the whole vector goes out on TEXCOORD10.
//   [ 4- 7]  worldView      — object -> view; its 3x3 is also the basis the
//                             normal and tangent are rotated by.
//   [ 8-11]  worldViewProj  — object -> clip.
//   [12-15]  not read by this stage (the pixel shader's projection matrix
//            lands here; the vertex stage just skips over it).
//   [16].x   effect clock (foliage wind, water ripples)   .y popcorn scale
//   [16].zw  water clip height / under-water sign.
//   [17].x   bone-buffer base index, an int in float clothing.
//   [18]     diffuse tint.
//   [19-22]  the two 2x3 UV matrices, two float4 rows each.
public struct HDVSPerDraw
{
    public float4x4 world;
    public float4x4 worldView;
    public float4x4 worldViewProj;
    // [12-15] view -> clip. The HD mesh shader never reads it (it has the
    // concatenated worldViewProj); `cameraocclusion_vs` projects billboards
    // it builds in view space.
    public float4x4 projection;
    // `.x` is the shared effect clock: foliage takes its fraction as the wind
    // swing phase, water scales it by 0.0035 to scroll its ripples. `.y` is
    // the PopcornFX particle scale: every particle vertex
    // position is multiplied by it before any matrix. Named here rather than left as
    // padding because the HD mesh shader reads neither lane, so there is no
    // competing meaning — unlike the pixel bank's cb2[22].x, which really is
    // two different numbers in the two pipelines.
    public float   effectTime;      public float popcornScale;
    public float   clipHeight;      public float underWater;
    public float   boneBufferBase;  public float _p17_y;
    public float   _p17_z;          public float _p17_w;
    public float4  diffuseColor;
    public float4  texMtx0Row0;
    public float4  texMtx0Row1;
    public float4  texMtx1Row0;
    public float4  texMtx1Row1;
};

// Blight-map placement (b1). The vertex shader turns the world XY into a
// [0,1] lookup for the pixel shader's blight mask. `water_vs` also reads the
// second row.
public struct HDVSBlight
{
    // .xy = world-space origin of the blight rect, .zw = 1 / its extent.
    public float4 rect;
    // .x = the water wave height: how far `water_vs` displaces a vertex along
    // object Z per unit of its two ripple taps. Only water reads this row.
    public float4 waterWave;
};

public [[vk::binding(1, 0)]] ConstantBuffer<HDVSBlight>    hdVsCB1 : register(b1);
public [[vk::binding(2, 0)]] ConstantBuffer<HDVSPerDraw>   hdVsCB2 : register(b2);
public [[vk::binding(3, 0)]] ConstantBuffer<HDBonePalette> hdVsCB3 : register(b3);

// Alternative bone palette: one structured buffer shared by many draws,
// indexed from a per-draw base in `hdVsCB2.boneBufferBase`. Selected by the
// BONE_BUFFER permutation axis, which is only observable on skinned meshes.
//
// Vertex-stage structured buffers sit past both stages' texture slots in set
// 1 (binding = VsBufferBindingOffset + register): VS register t16 would
// otherwise land on the pixel stage's t0.
#ifdef WGSL_TARGET
public static const int VsBufferBindingOffset = 2 * PsSrvBindingOffset;
#else
public static const int VsBufferBindingOffset = 2 * PsBindingOffset;
#endif
public [[vk::binding(VsBufferBindingOffset + 16, 1)]] StructuredBuffer<BoneTransform> t_hdBones : register(t16);

// Per-draw pixel constants for the 3.0.0 HD mesh shader (b2).
//
// Nothing is a `float3` on purpose: Slang's Metal and WGSL buffer layouts give
// a `float3` 16-byte alignment, which would shift every field after it away
// from the offsets the engine writes. `.xyz + scalar` groups are therefore
// declared as one `float4`, and pure padding as scalar lanes.
//
// Register map, in the shipped order:
//   [ 0].x  alpha reference    .y  material blend mode (an int; picks how fog
//           is applied, so an additive material fades to black rather than
//           toward the fog colour)
//   [ 1]    .xyz linear fog colour, .w fog start
//   [ 2]    fog end / density / volumetric height band
//   [ 3]    volumetric radial band + the "fog everywhere" flag (an int)
//   [ 4- 7] worldView     — not read by this stage
//   [ 8-11] inverse view  — rows 8..10 rotate view space into IBL probe space
//   [12-15] — not read by any stage that binds this bank
//   [16-19] view → clip, the .xyw lanes only. Not read by the HD mesh shader,
//           which already receives its clip position; `popcorn_ps` projects its
//           own view position through it to find the depth buffer texel.
//   [20]    .xyz volumetric fog centre (the camera)
//   [21]    depth-buffer UV remap (.xy scale, .zw bias) — popcorn only
//   [22]    output alpha scale / cloak / fresnel team colour / blight enable.
//           `.x` is the SOFT_PARTICLES depth-fade scale in popcorn: the engine
//           fills this slot per pipeline, and the two are different numbers, so
//           the name below is HD's use and the comment is popcorn's.
//   [23].w  manual depth-test enable
//   [24]    .xyz fresnel tint, .w fresnel alpha
//   [25]    IBL "from" and "to" mip ends + the transition between them
//   [26].y  emissive gain  .z shadow depth bias  .w specular-AA enable
//   [27].x  normal-map strength  .y main light enable  .z fog mode (an int)
//   [28]    .xyz ambient add, .w IBL intensity
//   [29]    .xyz ambient colour
//   [30]    .xyz main light direction (world)
public struct HDPSPerDraw
{
    public float   alphaRef;         public float  blendMode;
    public float   _p0_z;            public float  _p0_w;
    public float4  fogColorStart;
    public float   fogEnd;           public float  fogDensity;
    public float   heightTop;        public float  heightBottom;
    public float   radialInner;      public float  radialOuter;
    public float   radialStrength;   public float  fogEverywhere;
    public float4x4 _padWorldView;
    public float4x4 invView;
    // [12-15] clip -> view: `volumetricfog_ps` unprojects the screen through it.
    public float4x4 invProjection;
    // Declared as a raw float4 array rather than a float4x4 because it is only
    // ever addressed as `.xyw` per row: slang lowers a matrix-row swizzle to
    // per-scalar loads, where the array gives back the single vector load and
    // swizzle the shipped bytecode uses.
    public float4  viewToClip[4];
    public float4  fogCentre;
    public float4  depthUVRemap;
    public float   outputAlphaScale; public float  cloakAmount;
    public float   fresnelTeamColor; public float  blightEnable;
    // [23].xy are water's depth-fade distances (shallow, deep).
    public float   waterShallowDepth; public float waterDeepDepth;
    public float   _p23_z;           public float  depthTestEnable;
    public float4  fresnelColor;
    public float   envFromMipEnd;    public float  envToMipEnd;
    public float   envTransitionT;   public float  _p25_w;
    // [26].x is the effect clock water scrolls its ripples by.
    public float   effectTime;       public float  emissiveGain;
    public float   shadowDepthBias;  public float  useNdf;
    public float   normalStrength;   public float  mainLightEnable;
    public float   fogMode;          public float  _p27_w;
    public float4  ambientAdd;
    public float4  ambientColor;
    public float4  mainLightDir;

    // `water_ps` reads [22].xyz -- HD's alpha-scale / cloak / fresnel-team
    // lanes -- as one colour: the clamp on the water probe's glow.
    public float3 waterGlowClamp() { return float3(outputAlphaScale, cloakAmount, fresnelTeamColor); }
};

// One cube-shadow record: 26 float4s, from cb1[43] on.
//
// Only `.zw` of each face row is ever read — the pair is the clip-space z and
// w the depth comparison needs, and the engine does not bother uploading the
// xy the projection would otherwise produce.
public struct HDCubeShadow
{
    public float4   position;       // +0   .xyz light position, world space
    public float4   range;          // +1   .x near, .y far, .z strength
    public float4x4 faces[6];       // +2   six faces x four rows
};

// Clustered-lighting constants for the 3.0.0 HD mesh shader (b1). Only the
// LIGHTING permutations bind it.
//
//   [ 0-35]  three cascade sets of three matrices. Set 0 is reserved and never
//            referenced; set 1 backs SHADOW_CASCADE2, set 2 the main cascade.
//            Held as one array so the cascade walk indexes it the way the
//            shipped shader does: one base plus the loop counter.
//   [36].x   cascade count     .y  shadow-casting light count
//   [37]-[39].z  water_ps's own parameters (named in the struct)
//   [39].w   light debug mode (0 off, >=1 sentinel colours, >=2 overlay)
//   [40].xy  inverse cluster grid dimensions
//   [40].zw  light-array base / light-index-list base
//   [41].x   cluster base      .yz cluster grid stride / rows
//   [42]     viewport rect (x0, y0, x1, y1)
//   [43+]    four cube-shadow records
public struct HDPSClustered
{
    public float4x4 cascadeSets[9];
    public float  cascadeCount;      public float shadowLightCount;
    // [36].zw are `cameraocclusion_ps`'s: the see-through disc's opacity at
    // its centre and the radius its fade starts at.
    public float  occlusionAlpha;     public float occlusionInnerRadius;
    // [37]-[39].z are water's: HD, crystal, foliage and terrain never read them.
    public float4 waterProbeColor;   // .xyz constant probe colour, .w > 0.5 selects it over t4
    public float  waterRefractMin;   public float waterRefractMax;
    public float  waterReflectStrength; public float waterGlowStrength;
    public float  waterFadeScale;    public float waterRippleStrength;
    public float  waterReflectScale; public float lightDebugMode;
    public float2 invClusterDims;
    public float  lightArrayBase;    public float lightIndexBase;
    public float  clusterBase;       public float gridStride;
    public float  gridRows;          public float _p41_w;
    public float4 viewportRect;
    public HDCubeShadow cubeShadows[4];
};

// One clustered light, as the engine packs it into t16 — stride 40 bytes.
//
// Ten SCALARS, not the `float4 + float4 + float2` the layout reads like, and
// not the `float3 colour; int shadowIndex;` it describes. Both of those give
// the struct a 16-byte alignment, and every backend except D3D then rounds the
// array stride from 40 up to 48 — after which every light but the first is
// read from the wrong offset. Concretely: SPIR-V is rejected outright (the
// array stride must be 16-aligned unless the device turns on
// `scalarBlockLayout`), and GLSL std430, WGSL and Metal all silently stride by
// 48. All-scalar members drop the alignment to 4 and every target lands on 40.
//
// It costs nothing on D3D: fxc coalesces the ten member reads straight back
// into the three `ld_structured stride=40` at offsets 0 / 16 / 32 that retail
// emits, byte for byte. The accessors below are the shape the shader thinks in.
public struct HDClusterLight
{
    // Linear radiance, and the shadow index reinterpreted as an int
    // (-1 = no shadow, -2 = a debug gizmo the overlay draws specially).
    public float colorR;    public float colorG;
    public float colorB;    public float shadowIdx;
    // View-space position, and the quadratic attenuation coefficient.
    public float posX;      public float posY;
    public float posZ;      public float quadAtten;
    // Linear attenuation, and the exponential (Gaussian) falloff.
    public float linAtten;  public float expAtten;

    public float3 color()       { return float3(colorR, colorG, colorB); }
    public int    shadowIndex() { return asint(shadowIdx); }
    public float3 position()    { return float3(posX, posY, posZ); }
    public float  attenQuad()   { return quadAtten; }
    public float  attenLinear() { return linAtten; }
    public float  attenExp()    { return expAtten; }
};

public [[vk::binding(PsCbBindingOffset + 1, 0)]] ConstantBuffer<HDPSClustered> hdPsCB1 : register(b1);
public [[vk::binding(PsCbBindingOffset + 2, 0)]] ConstantBuffer<HDPSPerDraw>   hdPsCB2 : register(b2);

// Material maps. t2 does triple duty: .yz are roughness / metalness, .w is the
// team-colour blend weight, and .x sampled at UV1 is the ambient-occlusion map.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_hdAlbedo     : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_hdNormal     : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4> t_hdOrm        : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4> t_hdEmissive   : register(t3);
public [[vk::binding(PsSrvBindingOffset + 4, 1)]] Texture2D<float4> t_hdTeamColor  : register(t4);

// Scene-wide inputs. t7 is the depth target the shader manually tests against
// (it is `Load`ed, never sampled, so it has no sampler); t6/t8 are the blight
// mask and the colour ramp its value looks up.
public [[vk::binding(PsSrvBindingOffset + 6, 1)]] Texture2D<float4> t_hdBlightMask : register(t6);
public [[vk::binding(PsSrvBindingOffset + 7, 1)]] Texture2D<float4> t_hdSceneDepth : register(t7);
public [[vk::binding(PsSrvBindingOffset + 8, 1)]] Texture2D<float4> t_hdBlightRamp : register(t8);

// Shadow maps: a cube array for the cluster lights, a 2D array for the main
// light's cascades.
public [[vk::binding(PsSrvBindingOffset + 9, 1)]]  TextureCubeArray<float4> t_hdCubeShadow    : register(t9);
public [[vk::binding(PsSrvBindingOffset + 10, 1)]] Texture2DArray<float4>   t_hdCascadeShadow : register(t10);

// IBL probes. Slice 0 of each cube array is the irradiance convolution, slice
// 1 the pre-filtered radiance; the pair is blended so the runtime can fade
// between environments.
public [[vk::binding(PsSrvBindingOffset + 11, 1)]] TextureCubeArray<float4> t_hdIblFrom : register(t11);
public [[vk::binding(PsSrvBindingOffset + 12, 1)]] TextureCubeArray<float4> t_hdIblTo   : register(t12);
public [[vk::binding(PsSrvBindingOffset + 13, 1)]] Texture2D<float4>        t_hdBrdfLut : register(t13);

// The clustered light set: the lights themselves, a packed list of 16-bit
// indices into them, and the screen-space grid that says which slice of that
// list a pixel's cluster owns.
//
// Carried through `PsSrvBindingOffset` like every other PS resource, NOT bound
// at a raw 16/17/18. On D3D the register is what counts and the offset is
// irrelevant, but Vulkan / OpenGL / WebGPU share one binding-index namespace
// per group across textures and storage buffers — and the offset is 16 there
// (12 under WGSL), so a raw 16 lands exactly on `t_hdAlbedo` / `t_hdTeamColor`
// and a raw 18 on `t_hdOrm` / `t_hdBlightMask`. Three resources, three
// collisions, in the same descriptor set as the textures they collide with.
public [[vk::binding(PsSrvBindingOffset + 16, 1)]] StructuredBuffer<HDClusterLight> t_hdLights       : register(t16);
public [[vk::binding(PsSrvBindingOffset + 17, 1)]] StructuredBuffer<uint>           t_hdLightIndices : register(t17);
public [[vk::binding(PsSrvBindingOffset + 18, 1)]] StructuredBuffer<uint>           t_hdClusters     : register(t18);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_hdAlbedo     : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_hdNormal     : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_hdOrm        : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_hdEmissive   : register(s3);
public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_hdTeamColor  : register(s4);
public [[vk::binding(PsSamplerBindingOffset + 6, 2)]] SamplerState s_hdBlightMask : register(s6);
public [[vk::binding(PsSamplerBindingOffset + 8, 2)]] SamplerState s_hdBlightRamp : register(s8);
public [[vk::binding(PsSamplerBindingOffset + 9, 2)]]  SamplerComparisonState s_hdCubeShadow    : register(s9);
public [[vk::binding(PsSamplerBindingOffset + 10, 2)]] SamplerComparisonState s_hdCascadeShadow : register(s10);
public [[vk::binding(PsSamplerBindingOffset + 11, 2)]] SamplerState s_hdIblFrom : register(s11);
public [[vk::binding(PsSamplerBindingOffset + 12, 2)]] SamplerState s_hdIblTo   : register(s12);
public [[vk::binding(PsSamplerBindingOffset + 13, 2)]] SamplerState s_hdBrdfLut : register(s13);

// Per-light record for the SD highspec VS (b0).
//
// The 2.0.0 per-light record (ambient, diffuse, position) minus its trailing
// padding row: 3.0.0 tightened THIS family's per-light stride from 4 rows to 3.
// Read off the shipped bytecode — at two active lights retail declares
// `dcl_constantbuffer CB0[19]` and reads ambient `cb0[16].xyz`, diffuse
// `cb0[17].xyz`, position `cb0[18].xyz` and type `cb0[18].w`; at the 2.0.0
// stride of 4 the same permutation declared CB0[20] and read cb0[17..19].
//
// (The 4-row record itself, `ShaderLight`, went with the last 2.0.0 lit family
// in P11; every other family's lights are now HD's clustered buffer.)
public struct SDHighspecLight
{
    public float4 ambient;       // .xyz = ambient color, .w = _pad0
    public float4 diffuse;       // .xyz = diffuse color, .w = _pad1
    public float4 position;      // .xyz = position/direction, .w = type
};

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
    public SDHighspecLight lights[8];
};

// Per-draw constants for the SD classic pixel shader (b0): the classic
// pipeline only needs fog and alpha-ref; everything else comes from the
// texture-stage ops and the interpolated vertex color.
//
// 3.0.0 RE-ORDERED this bank. 2.0.0 packed the three fog scalars together in
// cb0[1] and gave fogColor its own row at cb0[2]; 3.0.0 moved fogColor up into
// cb0[1].xyz and tucked fogStart into that row's spare w, which is the same
// (colour.xyz, start.w) + (end.x, density.y) shape the HD bank uses at cb2[1] /
// cb2[2]. Reading the old order against a 3.0.0 blob silently swaps fogStart
// for fogColor.x, so this is not a cosmetic rename.
public struct SDClassicPSPerDraw
{
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See the scalar-split layout rule at the top of this file.
    public float  alphaRef;
    public float  _p0_x;        public float  _p0_y;
    public float  _p0_z;
#else
    public float  alphaRef;     public float3 _p0;
#endif
    // xyz = fog colour, w = fogStart — named like HD's cb2[1] because it is
    // the same row, and kept as one float4 so no backend has to re-pack it.
    public float4 fogColorStart;
    public float  fogEnd;       public float  fogDensity;
    public float  _p2_z;        public float  _p2_w;
};

public [[vk::binding(0, 0)]] ConstantBuffer<SDHighspecVSPerDraw>  sdHighspecVsCB0 : register(b0);
public [[vk::binding(PsCbBindingOffset + 0, 0)]] ConstantBuffer<SDClassicPSPerDraw>   sdClassicPsCB0  : register(b0);

// Water pixel shader resources, 3.0.0. Water moved onto the HD banks
// (hdPsCB1 / hdPsCB2, t6 / t8, t11-t13, t16-t18, the cascade and cube shadow
// arrays) and binds four textures of its own at slots HD uses for its
// material:
//   t0 the scene colour behind the water, read with Load (refraction, and the
//      colour of a screen-space reflection hit)
//   t1 the scene depth, Load
//   t2 a 64x64-tile min/max depth pyramid (.x max, .y min) the reflection
//      march walks before stepping the full-resolution depth -- reached only by
//      the SSR permutations
//   t3 the tiling ripple normal map, s3
//   t4 the water colour probe, s4, read at mip 16 (its average)
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_waterScene   : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_waterDepth   : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4> t_waterDepthHiZ : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4> t_waterNormal  : register(t3);
public [[vk::binding(PsSrvBindingOffset + 4, 1)]] Texture2D<float4> t_waterProbe   : register(t4);

public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_waterNormal : register(s3);
public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_waterProbe  : register(s4);

// The 3.0.0 foliage vertex shader has no per-draw bank of its own: it reads
// hdVsCB1 (blight rect) and hdVsCB2 (matrices, tint, UV transform, wind
// time) at HD's offsets. Only the wind block below is foliage's.

// Wind-area parameters (b3, only bound on the WIND permutation).
//   .xy = world-space origin of the wind area (anchor for the gradient
//          texture mapping).
//   .zw = wind area size in world units (used as the UV scale).
// Unchanged from 2.0.0; binding 3 in set 0 is shared with hdVsCB3, which is
// fine because no entry point reaches both.
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

// Water VS ripple normal map: the vertex stage samples the same tiling normal
// map the water pixel shader does, to heave the surface with its ripples.
public [[vk::binding(0, 1)]] Texture2D<float4> t_waterVsNormal : register(t0);
public [[vk::binding(0, 2)]] SamplerState      s_waterVsNormal : register(s0);

// The 3.0.0 foliage pixel shader binds HD's resources outright (t_hd*,
// hdPsCB1 / hdPsCB2, the t16-t18 cluster buffers) -- see foliage_ps.slang.

// Terrain pixel-shader splat material, 3.0.0: three TEXTURE ARRAYS, one slice
// per ground layer, selected per cell by the layer indices on TEXCOORD8.
//   t0 albedo + opacity, t1 packed normal map (.xyw), t2 ORM (.yz = roughness,
//   metal). Everything else terrain binds is HD's (t_hd*, hdPsCB1 / hdPsCB2).
// The terrain vertex shader has no bank of its own: hdVsCB1 / hdVsCB2.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2DArray<float4> t_terrainAlbedo : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2DArray<float4> t_terrainNormal : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2DArray<float4> t_terrainOrm    : register(t2);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_terrainAlbedo : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_terrainNormal : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_terrainOrm    : register(s2);

// 3.0.0 moved the PopcornFX VERTEX shader onto the shared per-draw bank too.
//
// Its b2 is now `HDVSPerDraw` — the same struct `hd_vs` reads, at the same
// offsets — so there is no `PopcornVSPerDraw` any more, exactly as there is no
// `PopcornPSPerDraw`. What the 72 shipped 3.0.0 blobs read:
//
//   cb2[ 0.. 3]  world          -> TEXCOORD8, the world position
//   cb2[ 4.. 7]  worldView      -> TEXCOORD7, and the normal / tangent
//   cb2[ 8..11]  worldViewProj  -> SV_Position
//   cb2[16].y    the particle scale
//
// The 2.0.0 layout was the same block shifted: `cb2[0..3]` was declared but
// never read, what this file called `world` at `cb2[4..7]` was really
// worldView, and the scale sat at `cb2[12].y`. 3.0.0 did not move the matrices
// at all — it made `cb2[0..3]` live and pushed the scalar row from 12 to 16,
// which is where `HDVSPerDraw` has always had it.
//
// The relayout is PER-PIPELINE, not engine-wide: 3.0.0 `sd_on_hd_vs` still
// reads the legacy scalars at `cb2[12].z/.w`. Do not generalise it.

// 3.0.0 moved the PopcornFX pixel shader onto the SHARED per-draw bank.
//
// 2.0.0 gave popcorn its own b2 layout: eight analytical lights at cb2[21..52],
// its own fog block, its own IBL mip ends. 3.0.0 deleted all of that and pointed
// the family at the same buffer `hd_ps` reads — `hdPsCB2` above — plus the same
// clustered-lighting bank `hdPsCB1`. Every row popcorn touches in 3.0.0
// (fog at [1..3], inverse view at [8..10], the projection at [16..19], the fog
// centre at [20], the depth remap at [21], the IBL ends at [25], the enables at
// [26].w / [27].yz and the ambient set at [28..30]) sits at the offset
// `HDPSPerDraw` already declares it at. There is therefore no popcorn PS
// constant buffer any more, and no `PopcornPSPerDraw` struct.
//
// The same is true of its IBL textures: 2.0.0 bound them at t13/t14/t15, 3.0.0
// at t11/t12/t13 — which is exactly `t_hdIblFrom` / `t_hdIblTo` / `t_hdBrdfLut`.
// The clustered light set is likewise `t_hdLights` / `t_hdLightIndices` /
// `t_hdClusters` at t16/t17/t18, bit for bit the same records.
//
// What remains popcorn's own are the five material slots below, which collide by
// register with HD's but carry different content. That is safe for the same
// reason it always was: slangc emits only the bindings the live entry point
// actually references.


// Popcorn pixel-shader textures. Slot ordering matches the engine
// bindings recovered from the BLS perms:
//   t0  — diffuse / motion-source (sampled with the per-mode UV);
//         in MOTION_PASS its .xy is the encoded motion vector.
//   t1  — alpha-remap LUT (1D ramp in U, random scalar in V).
//   t2  — packed normal map (LIT only).
//   t3  — smoothness (.y) + metallic (.z) (LIT only).
//   t4  — scene depth (SOFT_PARTICLES color-pass fade and the
//         MOTION_PASS depth-discard test).
//
// The IBL probes are NOT here: 3.0.0 moved them to t11/t12/t13, where they are
// `t_hdIblFrom` / `t_hdIblTo` / `t_hdBrdfLut` — the same three resources the HD
// mesh shader samples, so popcorn reads those declarations directly rather than
// aliasing its own names onto them.
//
// The five below share register slots with HD's material set; slangc only emits
// the bindings the active entry actually references, so the duplicate
// declarations are harmless.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4>        t_popcornDiffuse  : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4>        t_popcornAlphaLut : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4>        t_popcornNormal   : register(t2);
public [[vk::binding(PsSrvBindingOffset + 3, 1)]] Texture2D<float4>        t_popcornSmoothMet: register(t3);
public [[vk::binding(PsSrvBindingOffset + 4, 1)]] Texture2D<float4>        t_popcornDepth    : register(t4);

public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState s_popcornDiffuse  : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState s_popcornAlphaLut : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState s_popcornNormal   : register(s2);
public [[vk::binding(PsSamplerBindingOffset + 3, 2)]] SamplerState s_popcornSmoothMet: register(s3);
public [[vk::binding(PsSamplerBindingOffset + 4, 2)]] SamplerState s_popcornDepth    : register(s4);

// Per-draw constants for the tonemap pixel shader (b3). The engine
// only uploads a single 16-byte slot — the linear exposure multiplier
// applied to the HDR scene color before the ACES filmic curve — but
// the CB is still dimensioned as a full float4 to match the wire
// layout fxc emits for `float4 cb3[1]`.
public struct TonemapPSPerDraw
{
    public float  exposure;
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See the scalar-split layout rule at the top of this file.
    public float  _p0_x;
    public float  _p0_y;
    public float  _p0_z;
#else
    public float3 _p0;
#endif
};

public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<TonemapPSPerDraw> tonemapPsCB3 : register(b3);

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
// object, so the bindings below alias the shared t0/t1/s0/s1/b3 slot numbers
// — slangc only emits the bindings the active entry point references, so they
// coexist with the HD material aliases above (same pattern as tonemap / cmaa).
//
// The two CBs both bind b3 (b1 in 2.0.0) and most likely view slices of one engine-side
// "bloom params" upload; each shader names only the lanes it reads:
//   bloomextract reads cb3[0].x         → CB3[1]
//   bloomcombine reads cb3[0].zw,3[1].xy → CB3[2]

// Per-draw constants for the bloom bright-pass (b3). Only the .x luminance
// cutoff is consumed; the rest pads out to `float4 cb3[1]`.
public struct BloomExtractPSPerDraw
{
    public float  threshold;        // cb3[0].x — luminance cutoff
#if defined(WGSL_TARGET) || defined(METAL_TARGET)
    // See the scalar-split layout rule at the top of this file.
    public float  _p0_x;            public float _p0_y;
    public float  _p0_z;
#else
    public float3 _p0;              // cb3[0].yzw
#endif
};

// Per-draw constants for the bloom composite (b3). Two float4 slots holding
// the per-layer intensity (cb3[0].zw) and saturation (cb3[1].xy) knobs. All
// fields are float/float2 so the layout is identical across every target
// without the float3-alignment split the structs above need.
public struct BloomCombinePSPerDraw
{
    public float2 _p0_xy;           // cb3[0].xy — unused
    public float  intensityBloom;   // cb3[0].z  — gain for the blurred layer
    public float  intensityScene;   // cb3[0].w  — gain for the scene layer
    public float  saturationBloom;  // cb3[1].x  — saturation for the blur
    public float  saturationScene;  // cb3[1].y  — saturation for the scene
    public float2 _p1_zw;           // cb3[1].zw — unused
};

public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<BloomExtractPSPerDraw> bloomExtractPsCB3 : register(b3);
public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<BloomCombinePSPerDraw> bloomCombinePsCB3 : register(b3);

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
// a different tap set each pass: up to 15 taps in `float4 cb3[15]`, where tap i
// carries its UV offset in .xy and its weight in .z. The active tap count is
// packed into cb3[0].w (read once, truncated to int, before the loop).
//
// `taps` is a raw float4[15] rather than a named-field struct so each element
// occupies exactly one 16-byte slot on every target — matching the shipped
// `float4 cb3[15]` register packing — and the loop's dynamic index lowers to a
// single cb3[i] load (same rationale as the imgui / popcorn indexed CBs above).
public struct GaussianBlurPSPerDraw
{
    public float4 taps[15];   // [i].xy = UV offset, [i].z = weight; [0].w = tap count
};

public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<GaussianBlurPSPerDraw> gaussianBlurPsCB3 : register(b3);

// Gaussian blur input: the image being blurred (t0). Aliases the shared t0/s0
// slots like the other post-process passes; slangc only emits the binding the
// active entry references.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_gaussianSource : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState   s_gaussianSource : register(s0);

// ---------------------------------------------------------------------------
// Depth of field post-process pass.
//
// Single-permutation full-screen bokeh DoF (depthoffield.bls). Three float4
// constant slots drive a golden-angle spiral gather over the scene colour,
// with the circle of confusion derived from a depth texture. cb3[0].xy and
// cb3[2].xyz are unused by the shipped shader.
//
// As with BloomCombinePSPerDraw, every field is float/float2 so the byte
// layout is identical on every target without a float3-alignment split.
public struct DepthOfFieldPSPerDraw
{
    public float2 _p0_xy;          // cb3[0].xy — unused
    public float2 invResolution;   // cb3[0].zw — texel size (1 / render-target resolution)

    public float  maxBlurSize;     // cb3[1].x  — max bokeh radius in pixels; also the loop bound
    public float  radiusScale;     // cb3[1].y  — spiral radius step / sample-density control
    public float  focusDistance;   // cb3[1].z  — linear depth of the focus plane
    public float  focusScale;      // cb3[1].w  — CoC strength (aperture / f-number term)

    public float  _p2_x;           // cb3[2].x  — unused
    public float  _p2_y;           // cb3[2].y  — unused
    public float  _p2_z;           // cb3[2].z  — unused
    public float  farFieldOnly;    // cb3[2].w  — 1.0 clamps CoC >= MIN_COC (no foreground blur)
};

public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<DepthOfFieldPSPerDraw> depthOfFieldPsCB3 : register(b3);

// Depth of field inputs: scene colour (t0) and scene depth (t1). Aliases the
// shared t0/t1 slots like the other post-process passes; slangc only emits the
// binding the active entry references.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4> t_dofColor : register(t0);
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_dofDepth : register(t1);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState   s_dofColor : register(s0);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState   s_dofDepth : register(s1);

// ---------------------------------------------------------------------------
// Small screen / world passes (P13): greyscale, ssaa, foliagepush,
// debugtexture, waterreflection, fog, volumetricfog, cameraocclusion,
// coneindicator, movie.
// ---------------------------------------------------------------------------

// The per-draw pixel bank (b2) as the small passes see it: the engine uploads
// the same 24-row block the HD mesh shader reads, but these passes only look at
// rows 22-23, and read them as their own parameters rather than HD's alpha /
// cloak / fresnel lanes:
//   ssaa          params.xy = source texel size, params.z = supersample factor
//   foliagepush   params.x  = push strength
//   debugtexture  params.x  = array slice
//   coneindicator params    = (startRadius, endRadius, length, sin angle),
//                 params2.x = cos angle
public struct ScreenPassPSPerDraw
{
    public float4 _pad[22];         // cb2[0..21]
    public float4 params;           // cb2[22]
    public float4 params2;          // cb2[23]
};

public [[vk::binding(PsCbBindingOffset + 2, 0)]] ConstantBuffer<ScreenPassPSPerDraw> screenPassPsCB2 : register(b2);

// `waterreflection`'s one row (b3): .zw is the output-to-source texel ratio of
// the depth-bounds downsample; .xy is unused.
public struct ScreenPassPSScale
{
    public float4 scale;            // cb3[0]
};

public [[vk::binding(PsCbBindingOffset + 3, 0)]] ConstantBuffer<ScreenPassPSScale> screenPassPsCB3 : register(b3);

// The one source every small pass reads (t0 / s0): the scene colour, the
// scene depth, a debug texture array or the movie's luma plane, depending on
// the pass.
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2D<float4>      t_screenSource      : register(t0);
public [[vk::binding(PsSrvBindingOffset + 0, 1)]] Texture2DArray<float4> t_screenSourceArray : register(t0);
public [[vk::binding(PsSamplerBindingOffset + 0, 2)]] SamplerState       s_screenSource      : register(s0);

// The movie's chroma planes (t1 / t2).
public [[vk::binding(PsSrvBindingOffset + 1, 1)]] Texture2D<float4> t_movieCb : register(t1);
public [[vk::binding(PsSrvBindingOffset + 2, 1)]] Texture2D<float4> t_movieCr : register(t2);
public [[vk::binding(PsSamplerBindingOffset + 1, 2)]] SamplerState  s_movieCb : register(s1);
public [[vk::binding(PsSamplerBindingOffset + 2, 2)]] SamplerState  s_movieCr : register(s2);
