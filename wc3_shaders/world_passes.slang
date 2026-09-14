// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Fog, camera-occlusion and movie passes — Warcraft III Reforged 3.0.0.
//
// New coverage (P13). What these share is that each is built out of machinery
// the module already verified:
//
//   fog_ps               HD's seven runtime fog modes, one per permutation
//                        (the IFogMode30 policies sd_classic_ps uses), applied
//                        as a full-screen alpha over the scene depth
//   volumetricfog_vs/ps  HD's volumetric fog, over a world position rebuilt
//                        from the scene depth through the inverse projection
//   cameraocclusion_vs/ps  camera-facing billboards over units the camera is
//                        looking through, dither-discarded to a soft hole
//   movie_ps             YUV -> RGB video decode (sprite's program, called,
//                        for an RGB source), with the IEC sRGB decode sprite uses

implementing wc3_shaders;

// ---------------------------------------------------------------------------
// fog.bls
// ---------------------------------------------------------------------------

// Past this, the depth buffer holds the sky box.
static const float SCREEN_SKY_DEPTH = 32768.0;

// 7 permutations, one per HD fog mode. Mode 4 is the volumetric fog, which
// ships as its own shader, so this pass draws nothing for it -- retail's
// permutation 4 is byte-identical to the no-fog permutation 0.
[shader("fragment")]
public float4 fog_ps_main<TFog : IFogMode30>(SpritePSInput input) : SV_Target0
{
    float depth = t_screenSource.Sample(s_screenSource, input.uv).x;
    float survive = TFog.factor(depth, hdPsCB2.fogColorStart.w, hdPsCB2.fogEnd,
                                hdPsCB2.fogDensity);
    float strength = min(1.0, hdPsCB2.radialStrength * hdPsCB2.radialStrength);
    float alpha = strength * (1.0 - survive);
    // The sky is left unfogged unless the draw fogs everything.
    bool sky = SCREEN_SKY_DEPTH < depth;
    alpha = (sky && asint(hdPsCB2.fogEverywhere) == 0) ? 0.0 : alpha;
    return float4(hdPsCB2.fogColorStart.xyz, alpha);
}

// ---------------------------------------------------------------------------
// volumetricfog.bls
// ---------------------------------------------------------------------------

public struct VolumetricFogVSInput
{
    public [[vk::location(0)]] float3 position : ATTR0;
};

// The full-screen triangle arrives in clip space; its XY doubles as the
// normalised device coordinate the pixel shader unprojects.
[shader("vertex")]
public SpriteVSOutput volumetricfog_vs_main(VolumetricFogVSInput input)
{
    SpriteVSOutput output;
    output.position = float4(input.position, 1.0);
    output.uv = input.position.xy;
    return output;
}

[shader("fragment")]
public float4 volumetricfog_ps_main(SpritePSInput input) : SV_Target0
{
    // The view ray through this pixel at unit depth, scaled out to the scene.
    float4 ray = mul(hdPsCB2.invProjection, float4(input.uv, 1.0, 1.0));
    float3 rayPos = ray.xyz / ray.w;
    float depth = t_screenSource.Load(int3(int2(input.svPosition.xy), 0)).x;
    float3 viewPos = rayPos * (depth / max(rayPos.z, 9.99999997e-07));
    float3 worldPos = mul(hdPsCB2.invView, float4(viewPos, 1.0)).xyz;
    return float4(hdPsCB2.fogColorStart.xyz, 1.0 - hdVolumetricFog(depth, worldPos));
}

// ---------------------------------------------------------------------------
// cameraocclusion.bls
// ---------------------------------------------------------------------------

public struct CameraOcclusionVSInput
{
    public uint vertexId : SV_VertexID;
    public [[vk::location(0)]] float3 position : ATTR0;
    public [[vk::location(10)]] float size     : ATTR10;
    public [[vk::location(1)]] float3 normal   : ATTR1;
    public [[vk::location(7)]] float  pullIn   : ATTR7;
};

public struct CameraOcclusionVSOutput
{
    public float4 position : SV_Position;
    public float2 corner   : TEXCOORD0;
    public float  viewZ    : TEXCOORD1;
};

public struct CameraOcclusionPSInput
{
    public float4 svPosition : SV_Position;
    public float2 corner     : TEXCOORD0;
    public float  viewZ      : TEXCOORD1;
};

static const float2 CAMERA_OCCLUSION_CORNERS[4] = {
    float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5)
};

// A camera-facing quad per unit, built from the vertex index: the unit's view
// position, pulled toward the eye by ATTR7, spread by ATTR10 at the corner.
[shader("vertex")]
public CameraOcclusionVSOutput cameraocclusion_vs_main(CameraOcclusionVSInput input)
{
    CameraOcclusionVSOutput output;
    float3 viewPos = transformByWorldView(input.position, hdVsCB2.worldView);
    viewPos = -normalize(viewPos) * input.pullIn + viewPos;
    float2 corner = CAMERA_OCCLUSION_CORNERS[input.vertexId];
    viewPos = viewPos + float3(input.size * corner, 0);
    output.corner = 2.0 * corner;
    output.viewZ = viewPos.z;
    output.position = mul(hdVsCB2.projection, float4(viewPos, 1.0));
    return output;
}

// 8x8 Bayer thresholds, row major.
static const uint CAMERA_OCCLUSION_BAYER[64] = {
     0, 48, 12, 60,  3, 51, 15, 63,
    32, 16, 44, 28, 35, 19, 47, 31,
     8, 56,  4, 52, 11, 59,  7, 55,
    40, 24, 36, 20, 43, 27, 39, 23,
     2, 50, 14, 62,  1, 49, 13, 61,
    34, 18, 46, 30, 33, 17, 45, 29,
    10, 58,  6, 54,  9, 57,  5, 53,
    42, 26, 38, 22, 41, 25, 37, 21
};

// A disc that fades from `occlusionAlpha` at the centre to nothing at the rim,
// realised by ordered dithering rather than blending. The output is the view
// depth, into a depth-only target.
[shader("fragment")]
public float4 cameraocclusion_ps_main(CameraOcclusionPSInput input) : SV_Target0
{
    float r = sqrt(dot(input.corner, input.corner));
    if (-r + 1.0 < 0)
        discard;
    float inner = hdPsCB1.occlusionInnerRadius;
    float t = saturate((r - inner) / max(-inner + 1.0, 9.99999997e-07));
    t = (t * t) * (t * -2.0 + 3.0);
    float alpha = t * -hdPsCB1.occlusionAlpha + hdPsCB1.occlusionAlpha;

    uint2 texel = (uint2)input.svPosition.xy;
    uint cell = ((texel.y & 7) << 3) | (texel.x & 7);
    float threshold = ((float)CAMERA_OCCLUSION_BAYER[cell] + 0.5) * 0.015625;
    if (alpha - threshold < 0)
        discard;
    return input.viewZ.xxxx;
}

// ---------------------------------------------------------------------------
// movie.bls
// ---------------------------------------------------------------------------

// The green row's two coefficients per matrix (Cb, Cr): BT.601 first.
static const float2 MOVIE_GREEN[3] = {
    float2(0.344136268, 0.714136243),
    float2(0.178884789, 0.416757822),
    float2(0.154984668, 0.543223262)
};
// Video range: 16/255 black, and the luma / chroma expansions to full scale.
static const float MOVIE_BLACK = 0.0627451017;
static const float MOVIE_LUMA_SCALE = 1.16438353;
static const float MOVIE_CHROMA_SCALE = 1.13839281;

[shader("fragment")]
public float4 movie_ps_main<
    let RGB_SOURCE : bool,
    let SRGB_DECODE : bool,
    let MATRIX : int,
    let FULL_RANGE : bool
>(SpritePSInput input) : SV_Target0
{
    // An RGB source is the sprite program -- retail ships those permutations
    // byte-identical to sprite's passthrough and decode.
    if (RGB_SOURCE)
        return spriteColor<false, SRGB_DECODE>(input.uv);

    float cr = t_movieCr.Sample(s_movieCr, input.uv).x;
    float cb = t_movieCb.Sample(s_movieCb, input.uv).x;
    float y = t_screenSource.Sample(s_screenSource, input.uv).x;
    float2 green = MOVIE_GREEN[MATRIX];

    float3 rgb;
    if (FULL_RANGE)
    {
        cr = cr - 0.5;
        cb = cb - 0.5;
        float gy = -cb * green.x + y;
        rgb = float3(saturate(cr * 1.402 + y),
                     saturate(-cr * green.y + gy),
                     saturate(cb * 1.772 + y));
    }
    else
    {
        cr = (cr - MOVIE_BLACK) * MOVIE_CHROMA_SCALE - 0.5;
        cb = (cb - MOVIE_BLACK) * MOVIE_CHROMA_SCALE - 0.5;
        float yv = y - MOVIE_BLACK;
        float gy = yv * MOVIE_LUMA_SCALE - cb * green.x;
        rgb = float3(saturate(yv * MOVIE_LUMA_SCALE + cr * 1.402),
                     saturate(-cr * green.y + gy),
                     saturate(yv * MOVIE_LUMA_SCALE + cb * 1.772));
    }
    if (SRGB_DECODE)
        rgb = srgbToLinearIEC(rgb);
    return float4(rgb, 1.0);
}
