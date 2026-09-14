// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Cone indicator -- Warcraft III Reforged 3.0.0.
//
// New coverage (P13). The ground decal that shows an ability's cone of effect:
// a textured quad whose alpha is cut to a capsule-swept cone -- a disc of
// radius `startRadius` at the origin, widening linearly to `endRadius` at
// `length` along the quad's rotated X axis.
//
// The VS rides HD's per-draw vertex bank (b2); the PS reads the screen-pass
// per-draw rows 22-23.

implementing wc3_shaders;

public struct ConeIndicatorVSInput
{
    public [[vk::location(0)]] float3 position : ATTR0;
    // Bound by the layout, never read.
    public [[vk::location(1)]] float3 normal   : ATTR1;
    public [[vk::location(3)]] float2 uv       : ATTR3;
};

public struct ConeIndicatorVSOutput
{
    public float4 position : SV_Position;
    public float4 uv       : TEXCOORD0;
    public float3 viewPos  : TEXCOORD1;
};

public struct ConeIndicatorPSInput
{
    public float4 svPosition : SV_Position;
    public float4 uv         : TEXCOORD0;
    public float3 viewPos    : TEXCOORD1;
};

[shader("vertex")]
public ConeIndicatorVSOutput coneindicator_vs_main(ConeIndicatorVSInput input)
{
    ConeIndicatorVSOutput output;
    output.position = mul(hdVsCB2.worldViewProj, float4(input.position, 1.0));
    output.uv = float4(transformUV(input.uv, hdVsCB2.texMtx0Row0, hdVsCB2.texMtx0Row1), 0, 0);
    output.viewPos = transformByWorldView(input.position, hdVsCB2.worldView);
    return output;
}

// Inside the cone: the nearest disc on the axis (t in [0, length], radius
// growing linearly from startRadius) contains the point. The unclamped
// nearest t minimises |p - (t, 0)|^2 - r(t)^2, which has a stationary point
// only while the slope stays under 1; past that, or for a zero length, the
// shape is tested as the single disc of the larger radius at the far end.
bool coneIndicatorInside(float x, float y, float r0, float r1, float len)
{
    float rMax = max(r1, r0);
    float px = x - r0;
    float slope = (r1 - r0) / len;
    bool degenerate = (0 >= len) || (abs(slope) >= 1);

    float capX = (r1 < r0) ? px : (len - px);
    bool outsideCap = rMax * rMax < (capX * capX + abs(y) * abs(y));

    float t = (slope * r0 * -2 - (px + px)) / (slope * slope + slope * slope - 2);
    float tc = t;
    float rc = t * slope + r0;
    if (t >= len) { tc = len; rc = r1; }
    if (0 >= t)   { tc = 0;   rc = r0; }
    float dx = tc - px;
    bool outsideCone = rc * rc < dx * dx + abs(y) * abs(y);

    return !(degenerate ? outsideCap : outsideCone);
}

[shader("fragment")]
public float4 coneindicator_ps_main(ConeIndicatorPSInput input) : SV_Target0
{
    float4 c = t_screenSource.Sample(s_screenSource, input.uv.xy);
    float2 p = float2(0.5 - input.uv.y, input.uv.x - 0.5);
    p = p + p;
    float s = screenPassPsCB2.params.w;
    float co = screenPassPsCB2.params2.x;
    float y = p.y * co - p.x * -s;
    float x = p.x * co + p.y * -s;
    float yc = y + 0.5;

    float alpha = 0;
    if (!((x < 0) || (yc < 0) || (1 < yc)))
    {
        if (coneIndicatorInside(x, y, screenPassPsCB2.params.x, screenPassPsCB2.params.y,
                                screenPassPsCB2.params.z))
            alpha = c.w;
    }
    return float4(c.xyz, alpha);
}
