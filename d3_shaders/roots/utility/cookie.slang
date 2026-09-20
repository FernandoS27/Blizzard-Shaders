// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Shadow cookies (Shadows.fx): a caster rasterised into the projected
// light/shadow "cookie" buffer that the lighting pass reads back as a coloured
// or shadowing gobo.
//
// The vertex stage projects the caster (rigid or one-bone skinned), forwards
// its texture coordinate through matTex0 and hands the pixel stage the
// projected position twice over: as SV_Position and as a projective
// coordinate whose xy/w is the screen UV and z/w the depth. The pixel stage
// keys coverage off a texture, writes one of three cookie kinds, and ends with
// the caster's alpha test. Banner cookies are the same program with the
// coverage key read from the banner pattern.

implementing d3_shaders;

// ---------------------------------------------------------------------------
// cookie_vs
// ---------------------------------------------------------------------------

[shader("vertex")]
public D3Interpolants cookie_vs_main<TSkin : ISkin>(D3VertexIn i)
{
    D3Interpolants o = D3Interpolants.zero();
    D3ObjectVertex v = TSkin.apply(i);
    float4 clipPos = mul(matWorldViewProj, v.position);
    o.setPosition(clipPos);
    o.setTexcoord0(d3TextureMatrixTransform(0, d3DecodeUv0(i.texcoord0Bits())));
    o.setTexcoord1(float4((clipPos.xy + clipPos.w) * 0.5, clipPos.zw));
    o.setColor0(Factor.wwww);
    d3WriteClipPlanes(clipPos, o);
    return o;
}

// ---------------------------------------------------------------------------
// cookie_ps
// ---------------------------------------------------------------------------

/// Which texel, if any, keys the caster's coverage on or off.
public interface ICookieKey
{
    static float coverage(D3Interpolants i);
}

/// No key: the whole caster covers.
public struct KeyNone : ICookieKey
{
    public static float coverage(D3Interpolants i) { return 1.0; }
};

/// A hard cutout on the diffuse map's alpha: covered from 0.5 up.
public struct KeyDiffuseAlpha : ICookieKey
{
    public static float coverage(D3Interpolants i)
    {
        return diffuseMap.Sample(diffuseMap_s, i.texcoord0().xy).a >= 0.5 ? 1.0 : 0.0;
    }
};

/// A one-bit mask off the banner pattern's blue channel: covered from 0.5 up.
public struct KeyBannerPattern : ICookieKey
{
    public static float coverage(D3Interpolants i)
    {
        return bannerMap.Sample(bannerMap_s, i.texcoord0().xy).b >= 0.5 ? 1.0 : 0.0;
    }
};

/// What the cookie stores for a covered texel.
public interface ICookieKind
{
    static float4 shade(D3Interpolants i, float coverage);
}

/// A plain occluder: opaque white.
public struct CookieOpaque : ICookieKind
{
    public static float4 shade(D3Interpolants i, float coverage) { return float4(1.0, 1.0, 1.0, 1.0); }
};

/// A coloured cookie: the vertex colour, masked by coverage and faded by the
/// alpha of the vignette projected at the fragment's screen position.
public struct CookieColor : ICookieKind
{
    public static float4 shade(D3Interpolants i, float coverage)
    {
        float4 projected = i.texcoord1();
        float4 cookie = coverage * i.color0();
        return cookie * vignetteMap.Sample(vignetteMap_s, projected.xy / projected.w).w;
    }
};

/// A variance-shadow cookie: the first two depth moments, with the masked
/// vertex alpha kept for the alpha test.
public struct CookieDepthMoments : ICookieKind
{
    public static float4 shade(D3Interpolants i, float coverage)
    {
        float4 projected = i.texcoord1();
        float depth = projected.z / projected.w;
        return float4(depth, depth * depth, 1.0, coverage * i.color0().w);
    }
};

[shader("fragment")]
public float4 cookie_ps_main<TKey : ICookieKey, TKind : ICookieKind, TAlpha : IAlphaTest>(D3Interpolants i)
    : SV_Target
{
    float4 cookie = TKind.shade(i, TKey.coverage(i));
    TAlpha.apply(cookie.w);
    return cookie;
}
