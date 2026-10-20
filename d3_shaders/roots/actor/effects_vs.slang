// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Actor vertex policies for the one-off effects (plan M7 residue): the texture
// coordinates the ghost, revive, Thousand Pounder and elemental-death skins
// generate, the vertex-colour-tinted light, and the models whose interpolant
// lanes differ from the shared irradiance models (Morlu's glow overlay, the
// whirlwind's layers, the unlit simulacrum, the unfogged normal frame). Each
// plugs into roots/actor/actor_vs.slang beside roots/actor/irradiance_vs.slang.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Texture-coordinate generation
// ---------------------------------------------------------------------------

/// Mesh UV set `set` (0 or 1), decoded into its range.
public float2 d3DecodeUvSet(D3VertexIn i, int set)
{
    if (set != 0)
        return d3DecodeUv1(i.texcoord1Bits());
    return d3DecodeUv0(i.texcoord0Bits());
}

/// The first two rows of texture matrix MAT applied to a UV.
public float2 d3TextureMatrixUv(int index, float2 uv)
{
    return d3TexTransform(d3TextureMatrixRow(index, 0), d3TextureMatrixRow(index, 1), uv);
}

/// TEXCOORD1: UV set UV through texture matrix MAT.
public struct TexgenUvLayer<let MAT : int, let UV : int> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        o.setTexcoord1(float4(d3TextureMatrixUv(MAT, d3DecodeUvSet(i, UV)), 0.0, 0.0));
    }
};

/// UV set 0 through matrix MAT1 (TEXCOORD1) and through the first three rows of
/// matrix MAT2 (TEXCOORD2.xyz): the ghost's two alpha masks.
public struct TexgenUvLayerPair<let MAT1 : int, let MAT2 : int> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());
        o.setTexcoord1(float4(d3TextureMatrixUv(MAT1, uv0), 0.0, 0.0));
        o.setTexcoord2(float4(d3TextureMatrixTransform(MAT2, uv0).xyz, 0.0));
    }
};

/// Elemental character death: TEXCOORD0 is the rest position through matTex0
/// (in place of the mesh UV), TEXCOORD1 through matTex1, and TEXCOORD2.xy the
/// mirrored rest position through matTex1.
public struct TexgenRestProjections<TSource : ITexgenSource> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float3 rest = TSource.position(i);
        float4 rest4 = float4(rest, 1.0);
        float4 mirrored = float4(-rest, 1.0);
        o.setTexcoord0(float4(dot(matTex0[0], rest4), dot(matTex0[1], rest4), 0.0, 0.0));
        o.setTexcoord1(float4(dot(matTex1[0], rest4), dot(matTex1[1], rest4), 0.0, 0.0));
        o.setTexcoord2(float4(dot(matTex1[0], mirrored), dot(matTex1[1], mirrored), 0.0, 0.0));
    }
};

/// Necromancer pet revive: the rest position through matTex1 (TEXCOORD1); the
/// ramp row in TEXCOORD2.xy is matTex3's translation, and TEXCOORD2.zw the
/// revive gate's coordinate, matTex4's z column along the rest height. REVERSE
/// runs the gate down the mesh (height negated) and lifts its v by 0.8.
public struct TexgenReviveGate<let REVERSE : bool> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float4 rest = float4(i.position().xyz, 1.0);
        o.setTexcoord1(float4(dot(matTex1[0], rest), dot(matTex1[1], rest), 0.0, 0.0));
        float2 h = float2(REVERSE ? -rest.z : rest.z, 1.0);
        float2 gate = float2(dot(matTex4[0].zw, h), dot(matTex4[1].zw, h));
        if (REVERSE)
            gate = gate + float2(0.0, 0.8);
        o.setTexcoord2(float4(matTex3[0].w, matTex3[1].w, gate));
    }
};

// ---------------------------------------------------------------------------
// Lighting
// ---------------------------------------------------------------------------

/// The actor light rig with the vertex colour tinting the total: the diffuse
/// becomes whatever of `(ambient + diffuse) * COLOR0.rgb` rises above ambient.
public struct LightDiffuseVertexTinted : IVertexLighting
{
    public static D3ActorLight evaluate(D3VertexIn i, float3 viewPos, float3 viewNormal)
    {
        D3ActorLight l = LightDiffuse.evaluate(i, viewPos, viewNormal);
        l.diffuse = (l.ambient + l.diffuse) * i.color0().xyz - l.ambient;
        return l;
    }
};

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// Morlu: the split light (lit colour scaled by MeshLighting in COLOR0, ambient
/// in COLOR1, specular in TEXCOORD6, each halved) with the normal in world space
/// (TEXCOORD3), the rest position through matTex1 (TEXCOORD1), the sphere map
/// in TEXCOORD5 and the glow overlay's UV set 1 through matTex6 in TEXCOORD7.xy,
/// the fog in its z.
public struct SplitGlowOverlayVertex<TLight : IVertexLighting> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        float3 viewPos = mul(matWorldView, v.position).xyz;
        float3 viewNormal = normalize(mul((float3x3)matWorldView, v.normal));
        float fog = d3VertexFog(clipPos.z, mul(matWorld, v.position).z);
        D3ActorLight light = TLight.evaluate(i, viewPos, viewNormal);
        float alpha = i.color0().w;
        float4 rest = float4(i.position().xyz, 1.0);

        o.setPosition(clipPos);
        o.setColor0(float4(light.diffuse * MeshLighting.x * MeshLighting.w * 0.5, alpha));
        o.setColor1(float4(light.ambient, alpha) * 0.5);
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], d3DecodeUv0(i.texcoord0Bits())), 0.0, 0.0));
        o.setTexcoord1(float4(dot(matTex1[0], rest), dot(matTex1[1], rest), 0.0, 0.0));
        o.setTexcoord3(normalize(mul(matWorld, float4(v.normal, 0.0))));
        o.setTexcoord5(float4(d3SphereMapUv(viewNormal), 0.0, 0.0));
        o.setTexcoord6(float4(light.specular, alpha) * 0.5);
        o.setTexcoord7(float4(d3TexTransform(matTex6[0], matTex6[1], d3DecodeUv1(i.texcoord1Bits())), fog, 0.0));
        d3WriteClipPlanes(clipPos, o);
    }
};

/// The whirlwind: the diffuse light alone (MeshLighting-scaled, halved) in
/// COLOR0, UV set 0 through matTex0..2 (TEXCOORD0..2), UV set 1 through matTex3
/// (TEXCOORD3) and the irradiance normal in TEXCOORD4; no fog.
public struct SwirlLayersVertex<TLight : IVertexLighting> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        float3 viewPos = mul(matWorldView, v.position).xyz;
        float3 viewNormal = normalize(mul((float3x3)matWorldView, v.normal));
        D3ActorLight light = TLight.evaluate(i, viewPos, viewNormal);
        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());
        float2 uv1 = d3DecodeUv1(i.texcoord1Bits());

        o.setPosition(clipPos);
        o.setColor0(float4(light.diffuse * MeshLighting.x * MeshLighting.w * 0.5, i.color0().w));
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], uv0), 0.0, 0.0));
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], uv0), 0.0, 0.0));
        o.setTexcoord2(float4(d3TexTransform(matTex2[0], matTex2[1], uv0), 0.0, 0.0));
        o.setTexcoord3(float4(d3TexTransform(matTex3[0], matTex3[1], uv1), 0.0, 0.0));
        o.setTexcoord4(normalize(mul(matWorldIrrad, float4(v.normal, 0.0))));
        d3WriteClipPlanes(clipPos, o);
    }
};

/// The unlit split layout (the necromancer simulacrum): the vertex colour at
/// half intensity in COLOR0 with its alpha as is, no ambient or specular (their
/// lanes carry only the halved alpha), and the irradiance basis's normals and
/// sphere map; no fog.
public struct UnlitSplitVertex<TTexgen : IActorTexgen> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        D3IrradianceBasis b = d3IrradianceBasis(v.position, v.normal);
        float4 color = i.color0();
        float4 alphaOnly = float4(0.0, 0.0, 0.0, color.w) * 0.5;

        o.setPosition(b.clipPos);
        o.setColor0(color * float4(0.5, 0.5, 0.5, 1.0));
        o.setColor1(alphaOnly);
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], d3DecodeUv0(i.texcoord0Bits())), 0.0, 0.0));
        TTexgen.write(i, b, o);
        o.setTexcoord3(b.irradianceNormal);
        o.setTexcoord4(float4(b.viewNormal, 0.0));
        o.setTexcoord6(float4(d3SphereMapUv(b.viewNormal), 0.0, 0.0));
        o.setTexcoord7(alphaOnly);
        d3WriteClipPlanes(b.clipPos, o);
    }
};

/// The unfogged bump layout without a tangent frame (`bump_v11`): the combined
/// vertex light in COLOR0, UV set 0 and the object position through all four
/// rows of matTex0 and matTex1, and the world normal's components in the z and
/// w of TEXCOORD2..4.
public struct NormalFrameVertex<TLight : IVertexLighting> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        float3 viewPos = mul(matWorldView, v.position).xyz;
        float3 viewNormal = normalize(mul((float3x3)matWorldView, v.normal));
        float3 worldNormal = mul((float3x3)matWorld, v.normal);
        D3ActorLight light = TLight.evaluate(i, viewPos, viewNormal);
        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());

        o.setPosition(clipPos);
        o.setColor0(float4(((light.diffuse * MeshLighting.x) * MeshLighting.w + light.ambient) * 0.5, i.color0().w));
        o.setTexcoord0(d3TexProject(matTex0[0], matTex0[1], matTex0[2], matTex0[3], uv0));
        o.setTexcoord1(mul(matTex1, float4(i.position().xyz, 1.0)));
        o.setTexcoord2(float4(0.0, 0.0, worldNormal.x, worldNormal.x));
        o.setTexcoord3(float4(0.0, 0.0, worldNormal.y, worldNormal.y));
        o.setTexcoord4(float4(0.0, 0.0, worldNormal.z, worldNormal.z));
        d3WriteClipPlanes(clipPos, o);
    }
};
