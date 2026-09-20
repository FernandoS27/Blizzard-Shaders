// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// ActorIrrad.fx and banner.fx vertex shading models for the actor root.
//
// Every ActorIrrad vertex program shares one skeleton: decode and skin the
// object frame (the root's IFrameSkin), transform it into clip and view space,
// light it per vertex, and hand the pixel stage an irradiance-space normal, a
// view-space normal, texture coordinates, fog and the clip planes. The models
// below differ in how they pack the light (split into diffuse and ambient, or
// combined), which texture coordinates they generate, and whether they carry a
// tangent frame for normal mapping. Everything a model writes to a semantic the
// slot does not declare is dropped by the measured layout.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// Lighting
// ---------------------------------------------------------------------------

/// The per-vertex light a model packs: ambient, diffuse and specular.
public struct D3ActorLight
{
    public float3 ambient;
    public float3 diffuse;
    public float3 specular;
};

public interface IVertexLighting
{
    static D3ActorLight evaluate(D3VertexIn i, float3 viewPos, float3 viewNormal);
}

/// Unlit: the vertex colour is the diffuse term, with no ambient or specular.
public struct LightVertexColor : IVertexLighting
{
    public static D3ActorLight evaluate(D3VertexIn i, float3 viewPos, float3 viewNormal)
    {
        D3ActorLight l;
        l.ambient = float3(0.0, 0.0, 0.0);
        l.diffuse = i.color0().xyz;
        l.specular = float3(0.0, 0.0, 0.0);
        return l;
    }
};

/// The actor light rig -- primary point light, linear point lights, one
/// cylindrical light -- as ambient and diffuse.
public struct LightDiffuse : IVertexLighting
{
    public static D3ActorLight evaluate(D3VertexIn i, float3 viewPos, float3 viewNormal)
    {
        D3VertexLight acc;
        d3AddPrimaryPointLight(viewPos, viewNormal, acc);
        d3AddLinearPointLights(viewPos, viewNormal, acc);
        d3AddCylindricalLight(viewPos, viewNormal, acc);
        D3ActorLight l;
        l.ambient = acc.ambient;
        l.diffuse = acc.diffuse;
        l.specular = float3(0.0, 0.0, 0.0);
        return l;
    }
};

/// The actor light rig with the Phong specular of the point lights.
public struct LightSpecular : IVertexLighting
{
    public static D3ActorLight evaluate(D3VertexIn i, float3 viewPos, float3 viewNormal)
    {
        float3 reflection = d3ViewReflection(viewPos, viewNormal);
        D3VertexLightSpecular acc;
        d3AddPrimaryPointLightSpecular(viewPos, viewNormal, reflection, acc);
        d3AddLinearPointLightsSpecular(viewPos, viewNormal, reflection, acc);
        D3VertexLight rest;
        rest.ambient = acc.ambient;
        rest.diffuse = acc.diffuse;
        d3AddCylindricalLight(viewPos, viewNormal, rest);
        D3ActorLight l;
        l.ambient = rest.ambient;
        l.diffuse = rest.diffuse;
        l.specular = acc.specular;
        return l;
    }
};

/// How a split-light model divides the light between its two colours.
public interface ILightSplit
{
    /// `lit` goes out scaled by MeshLighting, `ambient` as it is.
    static void split(D3ActorLight l, out float3 lit, out float3 ambient);
}

/// Diffuse in the lit colour, ambient in the ambient colour.
public struct SplitDiffuseAmbient : ILightSplit
{
    public static void split(D3ActorLight l, out float3 lit, out float3 ambient)
    {
        lit = l.diffuse;
        ambient = l.ambient;
    }
};

/// The necromancer-pet ambient floor: ambient below `appearanceFX.x` is lifted
/// toward it with slope `appearanceFX.y`, and only the light rising above that
/// floored ambient is kept as lit.
public struct SplitAmbientFloor : ILightSplit
{
    public static void split(D3ActorLight l, out float3 lit, out float3 ambient)
    {
        float3 total = l.ambient + l.diffuse;
        float3 floored = max(l.ambient, appearanceFX.x);
        ambient = appearanceFX.y * (l.ambient - floored) + floored;
        lit = max(total, ambient) - ambient;
    }
};

/// How a combined-light model scales the diffuse light by MeshLighting.
public interface IMeshLightingScale
{
    static float3 scale(float3 diffuse);
}

/// A grey intensity: `MeshLighting.x`.
public struct MeshLightingIntensity : IMeshLightingScale
{
    public static float3 scale(float3 diffuse) { return diffuse * MeshLighting.x; }
};

/// A colour: `MeshLighting.rgb`.
public struct MeshLightingColor : IMeshLightingScale
{
    public static float3 scale(float3 diffuse) { return diffuse * MeshLighting.xyz; }
};

// ---------------------------------------------------------------------------
// Frame and alpha policies
// ---------------------------------------------------------------------------

public interface INormalFacing
{
    static float3 apply(float3 normal);
}

/// The normal as authored.
public struct FacingAuthored : INormalFacing
{
    public static float3 apply(float3 normal) { return normal; }
};

/// The back-face pass of a two-sided mesh: the normal reversed.
public struct FacingReversed : INormalFacing
{
    public static float3 apply(float3 normal) { return -normal; }
};

/// A two-sided mesh in one pass: the normal turned toward the viewer.
public struct FacingViewer : INormalFacing
{
    public static float3 apply(float3 normal)
    {
        return dot(matWorldView[2].xyz, normal) < 0.0 ? -normal : normal;
    }
};

public interface IActorVertexAlpha
{
    static float alpha(D3VertexIn i, float3 viewPos, float3 viewNormal);
}

/// The vertex colour's alpha.
public struct AlphaFromVertex : IActorVertexAlpha
{
    public static float alpha(D3VertexIn i, float3 viewPos, float3 viewNormal) { return i.color0().w; }
};

/// A Fresnel rim: `pow(saturate(N . -V), 2 * edgealphaParams.x)`.
public struct AlphaEdgeFresnel : IActorVertexAlpha
{
    public static float alpha(D3VertexIn i, float3 viewPos, float3 viewNormal)
    {
        float facing = saturate(dot(-normalize(viewPos), viewNormal));
        return pow(facing, edgealphaParams.x + edgealphaParams.x);
    }
};

// ---------------------------------------------------------------------------
// Shared geometry
// ---------------------------------------------------------------------------

/// The spaces every irradiance-lit vertex is taken into.
public struct D3IrradianceBasis
{
    public float4 clipPos;
    public float3 viewPos;
    public float3 viewNormal;
    /// The normal in the irradiance volume's frame, normalized as a 4-vector.
    public float4 irradianceNormal;
    public float fog;
};

public D3IrradianceBasis d3IrradianceBasis(float4 position, float3 normal)
{
    D3IrradianceBasis b;
    b.clipPos = mul(matWorldViewProj, position);
    b.viewPos = mul(matWorldView, position).xyz;
    b.viewNormal = normalize(mul((float3x3)matWorldView, normal));
    b.irradianceNormal = normalize(mul(matWorldIrrad, float4(normal, 0.0)));
    b.fog = d3VertexFog(b.clipPos.z, mul(matWorld, position).z);
    return b;
}

/// A view normal folded into a [0, 1] sphere-map coordinate.
public float2 d3SphereMapUv(float3 viewNormal)
{
    return viewNormal.xy * -0.5 + 0.5;
}

// ---------------------------------------------------------------------------
// Texture-coordinate generation
// ---------------------------------------------------------------------------

/// Where a projected texgen reads its object position.
public interface ITexgenSource
{
    static float3 position(D3VertexIn i);
}

/// The unskinned stream position.
public struct RestFromPosition : ITexgenSource
{
    public static float3 position(D3VertexIn i) { return i.position().xyz; }
};

/// A cloth mesh's rest position, carried in its own TEXCOORD2 stream.
public struct RestFromStream : ITexgenSource
{
    public static float3 position(D3VertexIn i) { return i.texcoord2().xyz; }
};

/// The texture coordinates beyond TEXCOORD0 a model generates.
public interface IActorTexgen
{
    static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o);
}

/// Nothing beyond TEXCOORD0: any other declared coordinate stays zero.
public struct TexgenNone : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o) {}
};

/// TEXCOORD1: the rest position through matTex1.
public struct TexgenProjection<TSource : ITexgenSource> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float4 rest = float4(TSource.position(i), 1.0);
        o.setTexcoord1(float4(dot(matTex1[0], rest), dot(matTex1[1], rest), 0.0, 0.0));
    }
};

/// UV set 1 through matTex1 (TEXCOORD1), matTex2 and matTex4 (TEXCOORD2).
public struct TexgenSecondUv : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float2 uv1 = d3DecodeUv1(i.texcoord1Bits());
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], uv1), 0.0, 0.0));
        o.setTexcoord2(float4(d3TexTransform(matTex2[0], matTex2[1], uv1),
                              d3TexTransform(matTex4[0], matTex4[1], uv1)));
    }
};

/// TEXCOORD1: UV set 0 through the animated layer's matTex4.
public struct TexgenAnimatedLayer : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());
        o.setTexcoord1(float4(d3TexTransform(matTex4[0], matTex4[1], uv0), 0.0, 0.0));
    }
};

/// Crystal: the view normal (TEXCOORD1), the clip position's x, y, w
/// (TEXCOORD2) and the sphere-map reflection coordinate (TEXCOORD5).
public struct TexgenCrystal : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        o.setTexcoord1(float4(b.viewNormal, 0.0));
        o.setTexcoord2(float4(b.clipPos.xyw, 0.0));
        o.setTexcoord5(float4(d3SphereMapUv(b.viewNormal), 0.0, 0.0));
    }
};

/// Disintegrate death: the rest position through matTex1 (TEXCOORD1) and a
/// dissolve coordinate (TEXCOORD2) whose z is matTex2's first translation.
public struct TexgenDisintegrate<TSource : ITexgenSource> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float3 rest = TSource.position(i);
        float4 rest4 = float4(rest, 1.0);
        o.setTexcoord1(float4(dot(matTex1[0], rest4), dot(matTex1[1], rest4), 0.0, 0.0));
        o.setTexcoord2(float4(dot(matTex2[0].xyz, rest), dot(matTex2[1], rest4), matTex2[0].w, 0.0));
    }
};

/// Pulverize death: like disintegrate, with z the distance of the rest x
/// behind a front at `16 * matTex2[0].w - 8`.
public struct TexgenPulverize<TSource : ITexgenSource> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float3 rest = TSource.position(i);
        float4 rest4 = float4(rest, 1.0);
        o.setTexcoord1(float4(dot(matTex1[0], rest4), dot(matTex1[1], rest4), 0.0, 0.0));
        o.setTexcoord2(float4(dot(matTex2[0].xyz, rest), dot(matTex2[1], rest4),
                              (matTex2[0].w * 16.0 - 8.0) - rest.x, 0.0));
    }
};

/// Elemental wipe death: the rest position through matTex1 (TEXCOORD1) and
/// matTex2 (TEXCOORD2), whose second row adds its translation twice.
public struct TexgenWipe<TSource : ITexgenSource> : IActorTexgen
{
    public static void write(D3VertexIn i, D3IrradianceBasis b, inout D3Interpolants o)
    {
        float4 rest = float4(TSource.position(i), 1.0);
        o.setTexcoord1(float4(dot(matTex1[0], rest), dot(matTex1[1], rest), 0.0, 0.0));
        o.setTexcoord2(float4(dot(matTex2[0], rest), dot(matTex2[1], rest) + matTex2[1].w,
                              dot(matTex2[2], rest), 0.0));
    }
};

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// ActorIrrad `pvdo`: the lit colour (MeshLighting-scaled) in COLOR0, the
/// ambient in COLOR1 and the specular in TEXCOORD7, each halved, for a pixel
/// stage that relights them against the irradiance cube.
public struct IrradianceSplitVertex<TLight : IVertexLighting, TSplit : ILightSplit, TFacing : INormalFacing,
                                    TTexgen : IActorTexgen, TAlpha : IActorVertexAlpha> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        D3IrradianceBasis b = d3IrradianceBasis(v.position, TFacing.apply(v.normal));
        D3ActorLight light = TLight.evaluate(i, b.viewPos, b.viewNormal);
        float alpha = TAlpha.alpha(i, b.viewPos, b.viewNormal);
        float3 lit;
        float3 ambient;
        TSplit.split(light, lit, ambient);

        o.setPosition(b.clipPos);
        o.setColor0(float4(lit * MeshLighting.x * MeshLighting.w * 0.5, alpha));
        o.setColor1(float4(ambient, alpha) * 0.5);
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], d3DecodeUv0(i.texcoord0Bits())), 0.0, 0.0));
        TTexgen.write(i, b, o);
        o.setTexcoord3(b.irradianceNormal);
        o.setTexcoord4(float4(b.viewNormal, 0.0));
        o.setTexcoord6(float4(d3SphereMapUv(b.viewNormal), 0.0, 0.0));
        o.setTexcoord7(float4(light.specular, alpha) * 0.5);
        o.setFog(float4(b.fog, 0.0, 0.0, 0.0));
        d3WriteClipPlanes(b.clipPos, o);
    }
};

/// ActorIrrad per-vertex lit (`pv`, animated, crystal, the deaths): diffuse
/// scaled by MeshLighting plus ambient, halved, in COLOR0; the specular,
/// halved, in COLOR1.
public struct IrradianceCombinedVertex<TLight : IVertexLighting, TScale : IMeshLightingScale,
                                       TTexgen : IActorTexgen, TAlpha : IActorVertexAlpha> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        D3IrradianceBasis b = d3IrradianceBasis(v.position, v.normal);
        D3ActorLight light = TLight.evaluate(i, b.viewPos, b.viewNormal);
        float alpha = TAlpha.alpha(i, b.viewPos, b.viewNormal);

        o.setPosition(b.clipPos);
        o.setColor0(float4((TScale.scale(light.diffuse) * MeshLighting.w + light.ambient) * 0.5, alpha));
        o.setColor1(float4(light.specular, alpha) * 0.5);
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], d3DecodeUv0(i.texcoord0Bits())), 0.0, 0.0));
        TTexgen.write(i, b, o);
        o.setTexcoord3(b.irradianceNormal);
        o.setTexcoord4(float4(b.viewNormal, 0.0));
        o.setTexcoord6(float4(d3SphereMapUv(b.viewNormal), 0.0, 0.0));
        o.setFog(float4(b.fog, 0.0, 0.0, 0.0));
        d3WriteClipPlanes(b.clipPos, o);
    }
};

/// The irradiance coverage prepass: clip position, vertex alpha, UV set 0.
public struct IrradiancePrepassVertex : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        o.setPosition(clipPos);
        o.setColor0(float4(0.0, 0.0, 0.0, i.color0().w));
        o.setTexcoord0(float4(d3TexTransform(matTex0[0], matTex0[1], d3DecodeUv0(i.texcoord0Bits())), 0.0, 0.0));
        d3WriteClipPlanes(clipPos, o);
    }
};

/// What a bump-mapped model writes to TEXCOORD5 and COLOR1.
public interface IBumpExtra
{
    static void write(float2 uv0, float4 worldPos, float3 ambient, float alpha, inout D3Interpolants o);
}

/// Nothing.
public struct BumpExtraNone : IBumpExtra
{
    public static void write(float2 uv0, float4 worldPos, float3 ambient, float alpha, inout D3Interpolants o) {}
};

/// The fade pass: the world position through matTex6 and the halved ambient.
public struct BumpExtraFade : IBumpExtra
{
    public static void write(float2 uv0, float4 worldPos, float3 ambient, float alpha, inout D3Interpolants o)
    {
        o.setTexcoord5(mul(matTex6, worldPos));
        o.setColor1(float4(ambient, alpha) * 0.5);
    }
};

/// Two normal maps: UV set 0 through matTex2 and matTex3.
public struct BumpExtraDetailUv : IBumpExtra
{
    public static void write(float2 uv0, float4 worldPos, float3 ambient, float alpha, inout D3Interpolants o)
    {
        o.setTexcoord5(d3TexProject(matTex2[0], matTex2[1], matTex2[2], matTex2[3], uv0));
        o.setColor1(d3TexProject(matTex3[0], matTex3[1], matTex3[2], matTex3[3], uv0));
    }
};

/// ActorIrrad bump (`bump_pp`, `bump2_pp`): the vertex light combined in
/// COLOR0, the world tangent frame packed one row per interpolant with the fog
/// in TEXCOORD2.w, and the world eye direction and specular for the pixel
/// stage's reflection. Without TANGENT_FRAME only the normal column is set.
public struct IrradianceBumpVertex<TLight : IVertexLighting, TAlpha : IActorVertexAlpha, TExtra : IBumpExtra,
                                   let TANGENT_FRAME : bool> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        float4 worldPos = mul(matWorld, v.position);
        float3 viewPos = mul(matWorldView, v.position).xyz;
        float3 viewNormal = normalize(mul((float3x3)matWorldView, v.normal));

        float3 worldNormal = mul((float3x3)matWorld, v.normal);
        float3 worldTangent = float3(0.0, 0.0, 0.0);
        float3 worldBinormal = float3(0.0, 0.0, 0.0);
        if (TANGENT_FRAME)
        {
            worldTangent = mul((float3x3)matWorld, v.tangent);
            worldBinormal = mul((float3x3)matWorld, v.binormal);
        }

        D3ActorLight light = TLight.evaluate(i, viewPos, viewNormal);
        float alpha = TAlpha.alpha(i, viewPos, viewNormal);
        float fog = d3VertexFog(clipPos.z, worldPos.z);
        float2 uv0 = d3DecodeUv0(i.texcoord0Bits());

        o.setPosition(clipPos);
        o.setColor0(float4(((light.diffuse * MeshLighting.x) * MeshLighting.w + light.ambient) * 0.5, alpha));
        o.setTexcoord0(d3TexProject(matTex0[0], matTex0[1], matTex0[2], matTex0[3], uv0));
        o.setTexcoord1(mul(matTex1, float4(i.position().xyz, 1.0)));
        o.setTexcoord2(float4(worldTangent.x, worldBinormal.x, worldNormal.x, fog));
        o.setTexcoord3(float4(worldTangent.y, worldBinormal.y, worldNormal.y, worldNormal.y));
        o.setTexcoord4(float4(worldTangent.z, worldBinormal.z, worldNormal.z, worldNormal.z));
        TExtra.write(uv0, worldPos, light.ambient, alpha, o);
        o.setTexcoord6(float4(normalize(worldPos.xyz - wpViewPos.xyz), 0.0));
        o.setTexcoord7(float4(light.specular, alpha) * 0.5);
        d3WriteClipPlanes(clipPos, o);
    }
};

/// banner.fx: the vertex colour (or the light it receives, keeping its alpha)
/// at half intensity, the two raw UV sets, fog and clip planes.
public struct BannerVertex<TLight : IVertexLighting> : IActorVertexModel
{
    public static void shade(D3VertexIn i, D3ObjectFrame v, inout D3Interpolants o)
    {
        float4 clipPos = mul(matWorldViewProj, v.position);
        float3 viewPos = mul(matWorldView, v.position).xyz;
        float3 viewNormal = normalize(mul((float3x3)matWorldView, v.normal));
        D3ActorLight light = TLight.evaluate(i, viewPos, viewNormal);

        o.setPosition(clipPos);
        o.setColor0(float4((light.ambient + light.diffuse) * 0.5, i.color0().w));
        o.setTexcoord0(float4(d3DecodeUv0(i.texcoord0Bits()), 0.0, 0.0));
        o.setTexcoord1(float4(d3DecodeUv1(i.texcoord1Bits()), 0.0, 0.0));
        o.setFog(float4(d3VertexFog(clipPos.z, mul(matWorld, v.position).z), 0.0, 0.0, 0.0));
        d3WriteClipPlanes(clipPos, o);
    }
};
