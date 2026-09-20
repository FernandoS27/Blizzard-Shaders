// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Diablo III's three global constant buffers. One layout, byte-identical in
// every one of the 6,984 shipped programs (transcribed from their RDEF), so
// every offset below is fixed data; D2 compares the flattened layout of each
// slot against retail.
//
// Two layout rules the transcription depends on:
//   * Matrices are `row_major` per member, as the engine stores them.
//   * `CBBones` is NOT a matrix array: slang leaves matrix arrays column-major
//     whatever the member modifier says, so the 45 `float3x4` bones are three
//     float4 rows each -- 48 bytes per bone, the same bytes retail declares.
//     Never copy one of these structs by value (a row_major member in a copied
//     cbuffer struct crashes slang's GLSL emitter); read rows in place.
//
// Non-D3D bindings share one space, so the three banks take bindings 0-2 and
// textures/samplers start at 16 (types/textures.slang).

implementing d3_shaders;

public struct D3LightDirectional   // 48 bytes
{
    public float3 wv;
    public float4 colDiffuse;
    public float4 colSpecular;
};

public struct D3LightPoint   // 80 bytes
{
    public float4 wp;
    public float4 atten;
    public float4 colAmbient;
    public float4 colDiffuse;
    public float4 colSpecular;
};

public struct D3LightSpot   // 96 bytes
{
    public float3 wp;
    public float3 wv;
    public float4 radii;
    public float4 colAmbient;
    public float4 colDiffuse;
    public float4 colSpecular;
};

public struct D3LightCylindrical   // 96 bytes
{
    public float3 wp;
    public float3 wv;
    public float4 radii;
    public float4 colAmbient;
    public float4 colDiffuse;
    public float4 colSpecular;
};

public struct D3LightPointLinear   // 64 bytes
{
    public float3 wp;
    public float4 colAmbient_radiiA;
    public float4 colDiffuse_radiiB;
    public float4 colSpecular;
};

/// One skinning bone: the three rows of a row-major float3x4.
public struct D3BoneRows
{
    public float4 row0;
    public float4 row1;
    public float4 row2;
};

[[vk::binding(0, 0)]]
cbuffer CBMain : register(b0)   // 2384 bytes
{
    float4 Constant0;
    float4 Constant1;
    row_major float4x4 matWorld;
    row_major float4x4 matView;
    row_major float4x4 matWorldView;
    row_major float4x4 matWorldViewProj;
    float4 fogParams;
    row_major float4x4 matTex0;
    row_major float4x4 matTex1;
    row_major float4x4 matTex2;
    row_major float4x4 matTex3;
    row_major float4x4 matTex4;
    row_major float4x4 matTex5;
    row_major float4x4 matTex6;
    row_major float4x4 matTex7;
    row_major float4x4 matTex8;
    row_major float4x4 matTex9;
    row_major float4x4 matTex10;
    row_major float4x4 matTex11;
    float4 viewport;
    float4 windowResolution;
    float4 waveParams;
    float4 edgealphaParams;
    float4 wpPlayer;
    float4 wvScreenZAxis;
    float4 wpViewPos;
    float4 Time;
    float4 MeshLighting;
    float4 Factor;
    float4 ShadowColor;
    float4 SpecularPower;
    float4 colLight;
    float4 Weights1;
    float4 Weights2;
    float4 Weights3;
    float4 Weights4;
    float4 WaveConstants;
    float4 fogColor;
    float4 diffuseOverlay;
    float4 appearanceFX;
    float4 depthOfFieldParams;
    float4 cameraParams;
    float4 depthReconstruction;
    float4 edgeFilter;
    float4 blurConstants;
    float4 waterTextureConstants;
    float4 hitFlashColorAdd;
    float4 hitFlashColorMul;
    float4 tintRampUV;
    float4 heroTintColorB;
    float4 weatherIntensity;
    float4 numBatches;
    float4 randFloat;
    float4 bUseDyeType;
    float4 deformationScale;
    float4 colorCorrectionBlend;
    float4 targetDimensions;
    float4 normalMapScale;
    float4 bannerTintRampUV;
    float4 bannerPatternTint;
    float4 bannerSigilTint;
    float4 bannerPatternDuotoneTint;
    float4 dbgReg0;
    float4 lightMapVScale;
    float4 vecFixedPointPosScale;
    float4 vecFixedPointPosOffset;
    row_major float4x4 matWorldIrrad;
    float4 alphaTestRef;
    float4 qCameraBillboard;
    float4 billboardParams;
    row_major float4x4 matProjection;
    float4 vecClipPlane[6];
    float4 vecReflectionPlane[2];
    row_major float4x4 matEffect1;
    row_major float4x4 matEffect2;
    row_major float4x4 matSSAOViewProj;
    row_major float4x4 matColorTransform;
};

[[vk::binding(1, 0)]]
cbuffer CBBones : register(b1)   // 2160 bytes
{
    D3BoneRows matBones[45];
};

[[vk::binding(2, 0)]]
cbuffer CBLights : register(b2)   // 6192 bytes
{
    float4 colAmbient;
    D3LightDirectional lightDirectionals[16];
    D3LightPoint lightPoints[16];
    D3LightSpot lightSpots[16];
    D3LightCylindrical lightCylindricals[16];
    D3LightPointLinear lightPointLinears[16];
    uint4 numLights;
    float4 numLightsFloat;
};
