// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Surface vertex shaders: scenery and props, terrain, large water and rivers,
// interactive fog planes (Scene.fx, Prop.fx, Landscape.fx, Reflection.fx,
// InteractiveFog.fx).
//
// Every surface vertex program places the vertex (rigid, skinned or swayed),
// transforms it, fills the interpolants of its surface model and writes the
// six user clip planes. The placement and the surface model are the two
// policies the root is generic over.
//
// Surface models come in two families of pass. A forward pass lights the
// vertex here (math/surface_lights.slang) and hands the pixel shader finished
// colour terms; a deferred pass hands it the view-space tangent frame
// (math/surface.slang) in five consecutive texture coordinates whose first
// index depends on the material, and lights per pixel.

implementing d3_shaders;

public interface ISurfaceVertexModel
{
    static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o);
}

[shader("vertex")]
public D3Interpolants surface_vs_main<TPlace : ISurfacePlacement, TSurface : ISurfaceVertexModel>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    D3SurfaceVertex v = d3SurfaceVertex(TPlace.place(i));
    o.setPosition(v.clip);
    TSurface.shade(i, v, o);
    d3WriteClipPlanes(v.clip, o);
    return o;
}

float d3SurfaceFog(D3SurfaceVertex v)
{
    return d3VertexFog(v.clip.z, v.world.z);
}

// ===========================================================================
// Meshes: scenery, props, foliage, floors
//
// A mesh surface is a colour block -- COLOR0/COLOR1 and TEXCOORD0/1 when lit
// here, or the tangent frame when lit per pixel -- plus a texture-coordinate
// block from TEXCOORD2 on, and fog in FOG0.
// ===========================================================================

public interface IMeshShading
{
    static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o);
}

public interface IMeshTexgen
{
    static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o);
}

public struct MeshSurface<TShading : IMeshShading, TTexgen : IMeshTexgen> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        TShading.shade(i, v, o);
        TTexgen.texgen(i, v, o);
        o.setFog(float4(d3SurfaceFog(v), 0.0, 0.0, 0.0));
    }
};

/// Per-vertex lighting: COLOR0 is half of (twice the vertex colour plus ambient
/// and diffuse), COLOR1 half the specular, TEXCOORD0 twice the colour plus
/// ambient and TEXCOORD1 the sun's diffuse. TWO_SIDED lights the side facing
/// the camera.
public struct VertexLit<let SPOT : bool, let GLOSS : bool, let TWO_SIDED : bool, TAlpha : IVertexAlpha> : IMeshShading
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float3 normal = v.viewNormal;
        if (TWO_SIDED)
            normal = normal.z < 0.0 ? -normal : normal;
        D3SurfaceLighting light = SurfaceLightRig<SPOT, GLOSS>.evaluate(v.view.xyz, normal);
        float3 color = i.color0().xyz;
        o.setColor0(float4((color * 2.0 + (light.ambient + light.diffuse)) * 0.5, TAlpha.alpha(i, v)));
        o.setColor1(float4(light.specular * 0.5, 0.0));
        o.setTexcoord0(float4(color * 2.0 + light.ambient, 0.0));
        o.setTexcoord1(float4(light.sunDiffuse, 0.0));
    }
};

/// Unlit: a flat half-bright light term over the vertex colour.
public struct VertexUnlit<TAlpha : IVertexAlpha> : IMeshShading
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float3 color = i.color0().xyz;
        o.setColor0(float4(color + 0.5, TAlpha.alpha(i, v)));
        o.setTexcoord0(float4(color + color, 0.0));
    }
};

/// Lit per pixel: the tangent frame from TEXCOORD<FIRST>.
public struct TangentFrame<let FIRST : int, TAlpha : IVertexAlpha> : IMeshShading
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        d3WriteTangentFrame(o, FIRST, i, v, TAlpha.alpha(i, v));
    }
};

float2 d3MeshUv(D3VertexIn i)
{
    return d3DecodeUv0(i.texcoord0Bits());
}

/// The diffuse UV through matTex1, the detail UV, and a planar world
/// projection through matTex2.
public struct PlanarProjection : IMeshTexgen
{
    public static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        o.setTexcoord2(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], d3MeshUv(i)));
        o.setTexcoord3(d3DetailUv(i));
        o.setTexcoord4(mul(matTex2, v.world));
    }
};

/// Glossy props: the planar projection is replaced by the screen reflection
/// coordinate, and the world goes through matTex4 for the gloss map.
public struct ScreenReflection : IMeshTexgen
{
    public static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        o.setTexcoord2(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], d3MeshUv(i)));
        o.setTexcoord3(d3DetailUv(i));
        o.setTexcoord4(float4(d3ScreenReflection(v.viewNormal, v.clip), v.clip.zw));
        o.setTexcoord5(mul(matTex4, v.world));
    }
};

/// Glossy scenery: the screen reflection shifted by matTex3, the world through
/// matTex4, and the diffuse UV through matTex2 for the gloss map.
public struct ShiftedScreenReflection : IMeshTexgen
{
    public static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float2 uv = d3MeshUv(i);
        o.setTexcoord2(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], uv));
        o.setTexcoord3(d3DetailUv(i));
        o.setTexcoord4(float4(d3ScreenReflection(v.viewNormal, v.clip, matTex3[0], matTex3[1]), v.clip.zw));
        o.setTexcoord5(mul(matTex4, v.world));
        o.setTexcoord6(d3TexProject(matTex2[0], matTex2[1], matTex2[2], matTex2[3], uv));
    }
};

/// Two-texture glow floors: the detail UV first, the diffuse UV through
/// matTex1 and matTex2, and the world through matTex3.
public struct TwoTextureGlow : IMeshTexgen
{
    public static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float2 uv = d3MeshUv(i);
        o.setTexcoord2(d3DetailUv(i));
        o.setTexcoord3(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], uv));
        o.setTexcoord4(d3TexProject(matTex2[0], matTex2[1], matTex2[2], matTex2[3], uv));
        o.setTexcoord5(mul(matTex3, v.world));
    }
};

/// 1 - smoothstep over [start, start + width] of a distance.
float d3FadeOut(float distance, float start, float width)
{
    float t = saturate((distance - start) * (1.0 / width));
    return 1.0 - (3.0 - 2.0 * t) * (t * t);
}

/// Act 4 floors: the detail UV beside the diffuse UV through matTex1, matTex3,
/// the screen reflection shifted by matTex5, the world through matTex6, and two
/// smooth fades with horizontal distance from the player (5..50 and 15..50).
public struct PlayerFadeFloor : IMeshTexgen
{
    public static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float2 uv = d3MeshUv(i);
        float playerDistance = length(v.world.xy - wpPlayer.xy);
        o.setTexcoord2(float4(d3DecodeUv1(i.texcoord1Bits()), d3TexTransform(matTex1[0], matTex1[1], uv)));
        o.setTexcoord3(float4(d3TexTransform(matTex3[0], matTex3[1], uv), 0.0, 0.0));
        o.setTexcoord4(float4(d3ScreenReflection(v.viewNormal, v.clip, matTex5[0], matTex5[1]), v.clip.zw));
        o.setTexcoord5(mul(matTex6, v.world));
        o.setTexcoord6(float4(d3FadeOut(playerDistance, 5.0, 45.0), d3FadeOut(playerDistance, 15.0, 35.0), 0.0, 0.0));
    }
};

/// Overlay floors: the diffuse UV through matTex1 and matTex2, the detail UV
/// with fog beside it, a ground projection through matTex6 with a cubic fade
/// over 60% of the cylindrical light's radius from the player, the screen
/// reflection shifted by matTex3, and the world through matTex4.
public struct OverlayProjection : IMeshTexgen
{
    public static void texgen(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float2 uv = d3MeshUv(i);
        float fade = 1.0 - saturate(length(v.world.xyz - wpPlayer.xyz) / (lightCylindricals[0].radii.y * 0.6));
        float2 ground = mul(matTex6, float4(v.world.xyz, 1.0)).xy;
        o.setTexcoord2(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], uv));
        o.setTexcoord3(float4(d3DecodeUv1(i.texcoord1Bits()), 0.0, d3SurfaceFog(v)));
        o.setTexcoord4(float4(ground, fade * fade * fade, 0.0));
        o.setTexcoord5(float4(d3ScreenReflection(v.viewNormal, v.clip, matTex3[0], matTex3[1]), v.clip.zw));
        o.setTexcoord6(mul(matTex4, v.world));
        o.setTexcoord7(d3TexProject(matTex2[0], matTex2[1], matTex2[2], matTex2[3], uv));
    }
};

/// The depth prepass of props: material alpha and the diffuse UV only.
public struct DepthPrepass : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        o.setColor0(float4(0.0, 0.0, 0.0, Factor.w));
        o.setTexcoord0(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], d3MeshUv(i)));
    }
};

// ===========================================================================
// Terrain
//
// Terrain blends layers addressed by one packed UV through a texture matrix
// each (two per interpolant), plus a world projection. Forward passes pack the
// sun's diffuse (times twice the vertex colour) into the spare w lanes.
// ===========================================================================

public interface ITerrainLayers
{
    static void layers(float2 uv, D3SurfaceVertex v, inout D3Interpolants o);
    /// The glossy screen reflection coordinate of this terrain kind.
    static float2 reflection(D3SurfaceVertex v);
}

/// Five-layer ground: layers through matTex1..6, the world through matTex7,
/// the reflection shifted by matTex9.
public struct FiveLayerGround : ITerrainLayers
{
    public static void layers(float2 uv, D3SurfaceVertex v, inout D3Interpolants o)
    {
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], uv), d3TexTransform(matTex2[0], matTex2[1], uv)));
        o.setTexcoord2(float4(d3TexTransform(matTex3[0], matTex3[1], uv), d3TexTransform(matTex4[0], matTex4[1], uv)));
        o.setTexcoord3(float4(d3TexTransform(matTex5[0], matTex5[1], uv), d3TexTransform(matTex6[0], matTex6[1], uv)));
        o.setTexcoord4(mul(matTex7, v.world));
    }
    public static float2 reflection(D3SurfaceVertex v)
    {
        return d3ScreenReflection(v.viewNormal, v.clip, matTex9[0], matTex9[1]);
    }
};

/// Transparent five-layer water: four layers through matTex1..4, the fifth
/// (matTex5) twice, the world through matTex6, the reflection shifted by matTex8.
public struct FiveLayerWater : ITerrainLayers
{
    public static void layers(float2 uv, D3SurfaceVertex v, inout D3Interpolants o)
    {
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], uv), d3TexTransform(matTex2[0], matTex2[1], uv)));
        o.setTexcoord2(float4(d3TexTransform(matTex3[0], matTex3[1], uv), d3TexTransform(matTex4[0], matTex4[1], uv)));
        o.setTexcoord3(d3TexTransform(matTex5[0], matTex5[1], uv).xyxy);
        o.setTexcoord4(mul(matTex6, v.world));
    }
    public static float2 reflection(D3SurfaceVertex v)
    {
        return d3ScreenReflection(v.viewNormal, v.clip, matTex8[0], matTex8[1]);
    }
};

/// Two-layer floor: layers through matTex1..2, a third through matTex3 in
/// TEXCOORD3.zw, the world through matTex4. It has no glossy variant; its
/// reflection coordinate is the unshifted one.
public struct TwoLayerFloor : ITerrainLayers
{
    public static void layers(float2 uv, D3SurfaceVertex v, inout D3Interpolants o)
    {
        o.setTexcoord1(float4(d3TexTransform(matTex1[0], matTex1[1], uv), d3TexTransform(matTex2[0], matTex2[1], uv)));
        o.setTexcoord3(float4(0.0, 0.0, d3TexTransform(matTex3[0], matTex3[1], uv)));
        o.setTexcoord4(mul(matTex4, v.world));
    }
    public static float2 reflection(D3SurfaceVertex v)
    {
        return d3ScreenReflection(v.viewNormal, v.clip);
    }
};

/// Forward-lit terrain.
public struct Terrain<TLayers : ITerrainLayers, let SPOT : bool, let GLOSS : bool> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        D3SurfaceLighting light = SurfaceLightRig<SPOT, GLOSS>.evaluate(v.view.xyz, v.viewNormal);
        float4 color = i.color0();
        float3 color2 = color.xyz + color.xyz;
        float3 sun = color2 * light.sunDiffuse;
        float2 reflection = float2(0.0, 0.0);
        if (GLOSS)
            reflection = TLayers.reflection(v);
        o.setColor0(float4(((light.ambient + light.diffuse) * color2) * 0.5, color.w * Factor.w));
        o.setColor1(float4(light.specular * 0.5, sun.x));
        o.setTexcoord0(float4(light.ambient * color2, sun.y));
        TLayers.layers(d3MeshUv(i), v, o);
        o.setTexcoord5(float4(reflection, v.clip.w, sun.z));
        o.setTexcoord6(d3DetailUv(i));
        o.setFog(float4(d3SurfaceFog(v), 0.0, 0.0, 0.0));
    }
};

/// Terrain lit per pixel: the tangent frame from TEXCOORD<FIRST>, the raw
/// vertex colour, and the reflection coordinate (glossy) with clip w.
public struct TerrainPrepass<TLayers : ITerrainLayers, let GLOSS : bool, let FIRST : int> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        TLayers.layers(d3MeshUv(i), v, o);
        if (GLOSS)
            o.setTexcoord5(float4(TLayers.reflection(v), v.clip.w, v.clip.w));
        else
            o.setTexcoord5(float4(0.0, 0.0, v.clip.w, 0.0));
        o.setTexcoord6(d3DetailUv(i));
        d3WriteTangentFrame(o, FIRST, i, v, i.color0().w);
        o.setFog(float4(d3SurfaceFog(v), 0.0, 0.0, 0.0));
    }
};

/// The side projection of cliff terrain: blend weights from the world normal
/// against the two diagonals beside the detail UV, and the world position
/// rotated 45 degrees about Z and scaled by matTex9._m00, with the world
/// normal's z.
void d3WriteSideProjection(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
{
    float2 diagonal = float2(0.707, 0.707);
    float2 antiDiagonal = float2(-0.707, 0.707);
    float scale = matTex9[0].x;
    o.setTexcoord6(float4(d3DecodeUv1(i.texcoord1Bits()), abs(dot(v.worldNormal.xy, diagonal)),
                          abs(dot(v.worldNormal.xy, antiDiagonal))));
    o.setTexcoord7(float4(-dot(v.world.xy, diagonal) * scale, dot(v.world.xy, antiDiagonal) * scale,
                          -v.world.z * scale, v.worldNormal.z));
}

/// Forward-lit side-projected cliff terrain. The glossy material moves fog
/// beside the specular in COLOR1 and the reflection (shifted by matTex11) into
/// TEXCOORD5; the plain one keeps fog in TEXCOORD5 and vertex alpha in COLOR0.
public struct SideProjectedTerrain<let GLOSS : bool> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        D3SurfaceLighting light = SurfaceLightRig<false, GLOSS>.evaluate(v.view.xyz, v.viewNormal);
        float4 color = i.color0();
        float3 color2 = color.xyz + color.xyz;
        float3 sun = color2 * light.sunDiffuse;
        float3 lit = ((light.ambient + light.diffuse) * color2) * 0.5;
        float fog = d3SurfaceFog(v);
        if (GLOSS)
        {
            o.setColor0(float4(lit, sun.x));
            o.setColor1(float4(light.specular * 0.5, fog));
            o.setTexcoord5(float4(d3ScreenReflection(v.viewNormal, v.clip, matTex11[0], matTex11[1]), v.clip.w, sun.z));
        }
        else
        {
            o.setColor0(float4(lit, color.w * Factor.w));
            o.setTexcoord5(float4(sun.x, fog, v.clip.w, sun.z));
        }
        o.setTexcoord0(float4(light.ambient * color2, sun.y));
        FiveLayerGround.layers(d3MeshUv(i), v, o);
        d3WriteSideProjection(i, v, o);
    }
};

/// Side-projected cliff terrain lit per pixel.
public struct SideProjectedTerrainPrepass<let GLOSS : bool, let FIRST : int> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float fog = d3SurfaceFog(v);
        FiveLayerGround.layers(d3MeshUv(i), v, o);
        if (GLOSS)
        {
            o.setTexcoord5(float4(d3ScreenReflection(v.viewNormal, v.clip, matTex11[0], matTex11[1]), v.clip.w, v.clip.w));
            o.setFog(float4(fog, 0.0, 0.0, 0.0));
        }
        else
        {
            o.setTexcoord5(float4(0.0, fog, v.clip.w, 0.0));
        }
        d3WriteSideProjection(i, v, o);
        d3WriteTangentFrame(o, FIRST, i, v, i.color0().w);
    }
};

// ===========================================================================
// Reflective water
// ===========================================================================

/// Large water and rivers: lit or flat white, with the frames the pixel stage
/// reflects and refracts through -- the base UV beside the view position
/// through matTex7, the UV through matTex0, matTex5 and matTex3 (rows
/// swapped), the projected screen position, the eye direction with fog, the UV
/// through matTex6, the detail UV (after a matTex10 flow UV on rivers) and
/// the view position.
public struct ReflectiveWater<let LIT : bool, let FLOW : bool> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float alpha = i.color0().w;
        if (LIT)
        {
            D3SurfaceLighting light = SurfaceLightRig<false, false>.evaluate(v.view.xyz, v.viewNormal);
            o.setColor0(float4(light.ambient + light.diffuse, alpha));
            o.setColor1(float4(light.ambient, 0.0));
        }
        else
        {
            o.setColor0(float4(1.0, 1.0, 1.0, alpha));
        }
        float2 uv = d3MeshUv(i);
        float2 flow = float2(0.0, 0.0);
        if (FLOW)
            flow = d3TexTransform(matTex10[0], matTex10[1], uv);
        o.setTexcoord0(float4(uv, dot(matTex7[0], v.view), dot(matTex7[1], v.view)));
        o.setTexcoord1(d3TexProject(matTex0[0], matTex0[1], matTex0[2], matTex0[3], uv));
        o.setTexcoord2(float4(d3TexTransform(matTex5[0], matTex5[1], uv), d3TexTransform(matTex3[1], matTex3[0], uv)));
        o.setTexcoord3(float4((v.clip.xy + v.clip.w) * 0.5, v.clip.zw));
        o.setTexcoord4(float4(normalize(wpViewPos.xyz - v.world.xyz), d3SurfaceFog(v)));
        o.setTexcoord5(d3TexProject(matTex6[0], matTex6[1], matTex6[2], matTex6[3], uv));
        o.setTexcoord6(float4(flow, d3DecodeUv1(i.texcoord1Bits())));
        o.setTexcoord7(float4(v.view.xyz, 0.0));
    }
};

// ===========================================================================
// Interactive fog planes
// ===========================================================================

/// Fog planes: lit or fullbright colour with the alpha repeated in COLOR1 and
/// TEXCOORD0, the plane UV through matTex0..2 and the view position through
/// matTex3.
public struct FogPlane<let LIT : bool, TAlpha : IVertexAlpha> : ISurfaceVertexModel
{
    public static void shade(D3VertexIn i, D3SurfaceVertex v, inout D3Interpolants o)
    {
        float alpha = TAlpha.alpha(i, v);
        float3 color = i.color0().xyz;
        if (LIT)
        {
            D3SurfaceLighting light = SurfaceLightRig<false, false>.evaluate(v.view.xyz, v.viewNormal);
            o.setColor0(float4((color * 2.0 + (light.ambient + light.diffuse)) * 0.5, alpha));
            o.setTexcoord0(float4((color * 2.0 + light.ambient) * 0.5, alpha));
        }
        else
        {
            o.setColor0(float4(color + 0.5, alpha));
            o.setTexcoord0(float4(color, alpha));
        }
        float2 uv = d3MeshUv(i);
        o.setColor1(float4(0.0, 0.0, 0.0, alpha));
        o.setTexcoord1(d3TexProject(matTex0[0], matTex0[1], matTex0[2], matTex0[3], uv));
        o.setTexcoord2(d3TexProject(matTex1[0], matTex1[1], matTex1[2], matTex1[3], uv));
        o.setTexcoord3(d3TexProject(matTex2[0], matTex2[1], matTex2[2], matTex2[3], uv));
        o.setTexcoord4(mul(matTex3, v.view));
        o.setFog(float4(d3SurfaceFog(v), 0.0, 0.0, 0.0));
    }
};
