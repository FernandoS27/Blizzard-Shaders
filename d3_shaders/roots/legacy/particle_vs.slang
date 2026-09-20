// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Particle billboard vertex shaders (Billboard.fx, SoftBillboard.fx).
//
// Every particle vertex is one corner of a quad. The stream carries the corner
// offset (POSITION), the vertex colours, up to four packed UV sets
// (TEXCOORD0-3), a packed per-particle orientation quaternion (TEXCOORD4) and
// the particle centre with its spin angle (TEXCOORD5). The shader orients the
// corner -- by the particle's own quaternion or the shared camera-facing one --
// spins it about its local Z, places it at the centre and projects it.
//
// What differs between programs is how the vertex colour is lit and what each
// texture-coordinate interpolant carries; those are the root's policies. Fog is
// written whenever the slot's interpolant layout declares FOG0.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// placement
// ---------------------------------------------------------------------------

/// A placed particle corner.
public struct D3ParticleVertex
{
    /// The composed orientation (xyz vector part, w scalar). Decoded from bytes,
    /// it is generally not of unit length.
    public float4 rotation;
    /// World position, w = 1.
    public float4 worldPos;
};

/// `q * (0, 0, s, c)`: the orientation followed by a spin about local Z whose
/// half-angle has sine s and cosine c.
public float4 d3QuatSpinZ(float4 q, float s, float c)
{
    return float4(q.x * c + q.y * s, q.y * c - q.x * s, q.w * s + q.z * c, q.w * c - q.z * s);
}

/// `q * (p, 0) * conj(q)` in its general form, which scales by |q|^2 when q is
/// not a unit quaternion (retail relies on that form, not the unit shortcut).
public float3 d3QuatRotate(float4 q, float3 p)
{
    float3 t = q.w * p + cross(q.xyz, p);
    return q.w * t + (dot(q.xyz, p) * q.xyz + cross(q.xyz, t));
}

/// Orient, spin and place one corner.
///
/// billboardParams.y selects the per-particle quaternion over the camera
/// billboard; billboardParams.z folds the corner onto its positive-Y half
/// (`|y| + y`) for ground-anchored sprites.
public D3ParticleVertex d3PlaceParticle(D3VertexIn i)
{
    float4 packedRotation = float4(i.texcoord4Bits()) * (2.0 / 255.0) - 1.0;
    float4 orientation = billboardParams.y > 0.0 ? packedRotation : qCameraBillboard;
    float4 center = i.texcoord5();
    float halfSpin = center.w * -0.5;
    float3 corner = i.position().xyz;
    float foldedY = billboardParams.z > 0.0 ? abs(corner.y) + corner.y : corner.y;

    D3ParticleVertex p;
    p.rotation = d3QuatSpinZ(orientation, sin(halfSpin), cos(halfSpin));
    p.worldPos = float4(d3QuatRotate(p.rotation, float3(corner.x, foldedY, corner.z)) + center.xyz, 1.0);
    return p;
}

/// The view-space facing normal: the rotated local Z axis, taken from the
/// unit-quaternion rotation matrix (so, unlike the position, it ignores |q|),
/// or plain +Z when billboardParams.x does not ask for oriented shading.
public float3 d3ParticleViewNormal(D3ParticleVertex p)
{
    float4 q = p.rotation;
    float3 rotatedZ = float3(2.0 * (q.x * q.z + q.y * q.w), 2.0 * (q.y * q.z - q.x * q.w),
                             1.0 - 2.0 * (q.x * q.x + q.y * q.y));
    float3 facing = billboardParams.x > 0.0 ? rotatedZ : float3(0.0, 0.0, 1.0);
    return normalize(mul((float3x3)matWorldView, facing));
}

// ---------------------------------------------------------------------------
// vertex colour
// ---------------------------------------------------------------------------

public interface IParticleColor
{
    static float4 shade(D3VertexIn i, D3ParticleVertex p);
}

/// The vertex colour as is.
public struct ColorPassthrough : IParticleColor
{
    public static float4 shade(D3VertexIn i, D3ParticleVertex p) { return i.color0(); }
};

/// The vertex colour squared (a cheap gamma-to-linear), alpha as is.
public struct ColorSquared : IParticleColor
{
    public static float4 shade(D3VertexIn i, D3ParticleVertex p)
    {
        float4 c = i.color0();
        return float4(c.rgb * c.rgb, c.a);
    }
};

/// The vertex colour blended toward the scene ambient as its alpha falls.
public struct ColorAmbientBlend : IParticleColor
{
    public static float4 shade(D3VertexIn i, D3ParticleVertex p)
    {
        float4 c = i.color0();
        return float4(lerp(colAmbient.rgb, c.rgb, c.a), c.a);
    }
};

/// Ambient-blended colour with a rim alpha: the particle fades where it turns
/// edge-on to the viewer, sharpened by edgealphaParams.x and scaled by Factor.w.
public struct ColorEdgeAlpha : IParticleColor
{
    public static float4 shade(D3VertexIn i, D3ParticleVertex p)
    {
        float4 c = i.color0();
        float3 viewNormal = d3ParticleViewNormal(p);
        float3 toVertex = normalize(mul(matWorldView, p.worldPos).xyz);
        float rim = pow(saturate(dot(-toVertex, viewNormal)), 2.0 * edgealphaParams.x);
        return float4(lerp(colAmbient.rgb, c.rgb, c.a), rim * Factor.w);
    }
};

/// How lit particles combine the accumulated light with the vertex colour.
public interface ILitCombine
{
    static float3 combine(D3VertexLight light, float4 vertexColor);
}

/// Light modulates the vertex colour.
public struct LitModulate : ILitCombine
{
    public static float3 combine(D3VertexLight light, float4 vertexColor)
    {
        return (light.ambient + light.diffuse) * vertexColor.rgb;
    }
};

/// Light replaces the vertex colour.
public struct LitReplace : ILitCombine
{
    public static float3 combine(D3VertexLight light, float4 vertexColor)
    {
        return light.ambient + light.diffuse;
    }
};

/// Clutter: only the diffuse term is scaled, by the colour's red and green
/// channels (two artist masks); ambient is added unscaled.
public struct LitClutter : ILitCombine
{
    public static float3 combine(D3VertexLight light, float4 vertexColor)
    {
        return light.diffuse * vertexColor.x * vertexColor.y + light.ambient;
    }
};

/// Per-vertex lighting in view space (primary point, linear points, one
/// cylindrical light) against the facing normal; alpha passes through.
public struct ColorLit<TCombine : ILitCombine> : IParticleColor
{
    public static float4 shade(D3VertexIn i, D3ParticleVertex p)
    {
        float4 c = i.color0();
        float3 viewNormal = d3ParticleViewNormal(p);
        float3 viewPos = mul(matWorldView, p.worldPos).xyz;
        D3VertexLight light;
        d3AddPrimaryPointLight(viewPos, viewNormal, light);
        d3AddLinearPointLights(viewPos, viewNormal, light);
        d3AddCylindricalLight(viewPos, viewNormal, light);
        return float4(TCombine.combine(light, c), c.a);
    }
};

// ---------------------------------------------------------------------------
// texture-coordinate interpolants
// ---------------------------------------------------------------------------

/// Packed particle UV set `set` (TEXCOORD0-3 of the stream), decoded onto
/// [-64, 64).
public float2 d3ParticleUv(D3VertexIn i, int set)
{
    if (set == 0) return d3DecodeUv0(i.texcoord0Bits());
    if (set == 1) return d3DecodeUv0(i.texcoord1Bits());
    if (set == 2) return d3DecodeUv0(i.texcoord2Bits());
    return d3DecodeUv0(i.texcoord3Bits());
}

/// What one texture-coordinate interpolant of the pass carries.
public interface IParticleTexcoord
{
    static void write(D3VertexIn i, D3ParticleVertex p, inout D3Interpolants o);
}

/// Nothing: the interpolant, if declared, stays zero.
public struct TexcoordUnused : IParticleTexcoord
{
    public static void write(D3VertexIn i, D3ParticleVertex p, inout D3Interpolants o) {}
};

/// TEXCOORD<SEM> = UV set UV through texture matrix MATRIX.
public struct TexcoordMatrix<let SEM : int, let UV : int, let MATRIX : int> : IParticleTexcoord
{
    public static void write(D3VertexIn i, D3ParticleVertex p, inout D3Interpolants o)
    {
        d3SetTexcoord(o, SEM, d3TextureMatrixTransform(MATRIX, d3ParticleUv(i, UV)));
    }
};

/// TEXCOORD<SEM> = UV set UV untransformed, as (u, v, 0, 1).
public struct TexcoordRaw<let SEM : int, let UV : int> : IParticleTexcoord
{
    public static void write(D3VertexIn i, D3ParticleVertex p, inout D3Interpolants o)
    {
        d3SetTexcoord(o, SEM, float4(d3ParticleUv(i, UV), 0.0, 1.0));
    }
};

/// TEXCOORD<SEM>.x = the corner's distance in front of the camera (-view z),
/// which soft particles fade against the scene depth.
public struct TexcoordViewDepth<let SEM : int> : IParticleTexcoord
{
    public static void write(D3VertexIn i, D3ParticleVertex p, inout D3Interpolants o)
    {
        d3SetTexcoord(o, SEM, float4(-dot(matWorldView[2], p.worldPos), 0.0, 0.0, 0.0));
    }
};

// ---------------------------------------------------------------------------
// root
// ---------------------------------------------------------------------------

[shader("vertex")]
public D3Interpolants particle_vs_main<TColor : IParticleColor, TTex0 : IParticleTexcoord,
                                       TTex1 : IParticleTexcoord, TTex2 : IParticleTexcoord,
                                       TTex3 : IParticleTexcoord>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    D3ParticleVertex p = d3PlaceParticle(i);
    float4 clipPos = mul(matWorldViewProj, p.worldPos);
    o.setPosition(clipPos);
    o.setColor0(TColor.shade(i, p));
    o.setColor1(i.color1());
    TTex0.write(i, p, o);
    TTex1.write(i, p, o);
    TTex2.write(i, p, o);
    TTex3.write(i, p, o);
    o.setFog(float4(d3VertexFog(clipPos.z, mul(matWorld, p.worldPos).z), 0.0, 0.0, 0.0));
    d3WriteClipPlanes(clipPos, o);
    return o;
}
