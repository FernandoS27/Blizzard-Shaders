// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Clustered-forward shading for the 3.0.0 HD mesh pixel shader.
//
// This is the change that reshaped the HD pipeline. 2.0.0 uploaded up to eight
// analytical lights into the per-draw constant buffer and looped over them;
// 3.0.0 puts every light in the scene in a structured buffer, bins them into a
// screen-space cluster grid, and has each pixel read only the slice of the
// index list its own cluster owns. The per-draw light array is gone, and with
// it the idea that a draw knows which lights affect it.
//
// The main directional light is still special-cased: it is the one that
// carries the IBL probe blend and the ambient mix, because those have to agree
// with it for the pre-baked probes to sit correctly under dynamic light.

implementing wc3_shaders;

// Everything about the shaded point that both the main light and the cluster
// loop need. Hoisted into a struct so the roughness-derived BRDF constants are
// computed once rather than per light.
public struct HDSurface
{
    public float3 N;          // shading normal
    public float3 V;          // normalised direction to the eye
    public float3 albedo;
    public float  metal;
    public float3 F0;         // metal * albedo
    public float3 diffColor;  // (1 - metal) * albedo / PI
    public float  rough;      // after the specular-AA choice
    public float  a2;         // (rough^2)^2 — the GGX alpha^4
    public float  kDirect;    // Schlick k = (1 + rough)^2 / 8
    public float  kInv;       // 1 - k
};

// GGX with the denominator clamped. The clamp is 3.0.0's, and it is what keeps
// a mirror-smooth surface from dividing by zero at the exact specular peak.
static float hdGGX(float ndh, float a2)
{
    float dterm = ndh * ndh * a2 + (-ndh * ndh + 1);
    dterm = max(HD_GGX_MIN_DENOM, dterm);
    dterm = PI * (dterm * dterm);
    return a2 / dterm;
}

// Schlick-GGX visibility, with both k terms already folded into the surface.
static float hdVisibility(HDSurface s, float ndl, float ndv)
{
    return saturate(1.0 / (4.0 * ((ndl * s.kInv + s.kDirect) * (ndv * s.kInv + s.kDirect))));
}

// Schlick Fresnel against the surface's F0.
static float3 hdFresnel(HDSurface s, float vdh)
{
    float t = 1 - vdh;
    float t5 = (t * t) * (t * t) * t;
    return (s.metal * -s.albedo + float3(1, 1, 1)) * t5 + s.F0;
}

// ---------------------------------------------------------------------------
// IBL probe
// ---------------------------------------------------------------------------

public struct HDIBLSample
{
    public float3 irradiance;
    public float3 radiance;
    public float2 brdf;     // split-sum LUT: .x Fresnel scale, .y bias
    public float  weight;   // 0 when no probe is bound, 1 otherwise
};

// Sample both probes and blend them.
//
// The probe basis is the non-obvious part. The cube maps are not stored in
// world orientation: they are baked around the MAIN LIGHT direction, so the
// shader builds an orthonormal frame with that direction as the "up" axis and
// rotates the normal and reflection vectors into it before sampling. The
// `(x, z, -y)` shuffles are the engine's Z-up world to the cube map's Y-up
// convention. A probe baked this way stays correct when the sun moves.
public HDIBLSample sampleHDIBL(float3 viewPos, HDSurface s)
{
    HDIBLSample ibl;

    // A probe pair is "bound" only when both mip ends are non-zero; the
    // product is the engine's two-tests-in-one.
    if (hdPsCB2.envFromMipEnd * hdPsCB2.envToMipEnd != 0.0)
    {
        float3x3 toWorld = (float3x3)hdPsCB2.invView;
        float3 Pw = normalize(mul(toWorld, viewPos));
        float3 Nw = normalize(mul(toWorld, s.N));
        float3 Rw = normalize(Nw * -(dot(Pw, Nw) + dot(Pw, Nw)) + Pw);
        float3 Lw = normalize(mul(toWorld, hdPsCB2.mainLightDir.xyz));

        float3 axis = normalize(float3(Lw.x, Lw.z, -Lw.y));
        float3 tangentA = cross(float3(0, 1, 0), axis);
        float lenSq = dot(tangentA.xz, tangentA.xz);

        // When the light points straight up the cross product collapses, so a
        // reference axis is picked in the XZ plane and Gram-Schmidt'd instead.
        float3 fallback = (0.999000013 < abs(axis.x)) ? float3(0, 0, 1)
                                                     : float3(1, 0, 0);
        fallback = -axis * dot(fallback.xz, axis.xz) + fallback;
        fallback = normalize(fallback);
        tangentA = tangentA * rsqrt(lenSq);
        tangentA = (lenSq < 9.99999975e-05) ? fallback : tangentA;
        float3 bitangentA = normalize(cross(axis, tangentA));

        float3 nProbe = float3(Nw.x, Nw.z, -Nw.y);
        nProbe = float3(dot(nProbe, tangentA), dot(nProbe, bitangentA), dot(nProbe, axis));
        float3 rProbe = float3(Rw.x, Rw.z, -Rw.y);
        rProbe = float3(dot(rProbe, tangentA), dot(rProbe, bitangentA), dot(rProbe, axis));

        // Slice 0 is the irradiance convolution, slice 1 the pre-filtered
        // radiance; each probe gets its own mip end so the two can differ in
        // resolution while still lining up across the transition.
        float3 irrA = t_hdIblFrom.Sample(s_hdIblFrom, float4(nProbe, 0)).xyz;
        float3 irrB = t_hdIblTo.Sample(s_hdIblTo, float4(nProbe, 0)).xyz;
        ibl.irradiance = hdPsCB2.envTransitionT * (irrB - irrA) + irrA;

        float2 mip = float2(hdPsCB2.envFromMipEnd, hdPsCB2.envToMipEnd) * s.rough;
        float3 radA = t_hdIblFrom.SampleLevel(s_hdIblFrom, float4(rProbe, 1), mip.x).xyz;
        float3 radB = t_hdIblTo.SampleLevel(s_hdIblTo, float4(rProbe, 1), mip.y).xyz;
        ibl.radiance = hdPsCB2.envTransitionT * (radB - radA) + radA;

        ibl.brdf = t_hdBrdfLut.Sample(s_hdBrdfLut, float2(dot(s.N, s.V), s.rough)).xy;
        ibl.weight = 1;
    }
    else
    {
        ibl.irradiance = float3(0, 0, 0);
        ibl.radiance = float3(0, 0, 0);
        ibl.brdf = float2(0, 0);
        ibl.weight = 0;
    }
    return ibl;
}

// ---------------------------------------------------------------------------
// Main directional light + ambient
// ---------------------------------------------------------------------------

// The main light, the probe, and the ambient mix — they are one block because
// they share `shadowedNdl`, which is what ties the pre-baked ambient to the
// dynamic light and to the cascade shadow.
//
// Two quirks carried over verbatim from the shipped shader, both of which look
// like bugs and are load-bearing for matching it:
//   * the direct specular is multiplied by `radiance` along with the indirect
//     term, so the main light's highlight is tinted by the environment;
//   * the ambient is split into an "upper" and a "lower" half and interpolated
//     by NdotL, so the shadow side keeps a fraction of the probe rather than
//     going black.
public float3 hdMainLight(HDSurface s, float3 viewPos, float mainShadow)
{
    float3 L = hdPsCB2.mainLightDir.xyz;
    float3 H = normalize(s.V + L);
    float vdh = dot(H, s.V);
    float ndh = dot(s.N, H);
    float ndl = dot(s.N, L);
    float ndv = dot(s.N, s.V);

    float3 directSpec = hdFresnel(s, vdh) * hdGGX(ndh, s.a2);
    directSpec = directSpec * hdVisibility(s, ndl, ndv);
    float shadowedNdl = max(0, ndl) * mainShadow;

    HDIBLSample ibl = sampleHDIBL(viewPos, s);

    float3 ambientColor = hdPsCB2.ambientColor.xyz;
    float maxAmb = max(ambientColor.x, max(ambientColor.y, ambientColor.z));
    float invAmb = 1.0 / (SAFE_EPS + maxAmb);
    float ambPlusIbl = maxAmb + ibl.weight;
    float iblScale = hdPsCB2.ambientAdd.w * (ambPlusIbl * ibl.weight);

    // Hue-separate the probe irradiance and the analytical ambient before
    // mixing, so the blend preserves saturation instead of washing out.
    float maxIrr = max(ibl.irradiance.x, max(ibl.irradiance.y, ibl.irradiance.z));
    float3 irrN = ibl.irradiance * (1.0 / (SAFE_EPS + maxIrr));
    float3 ambDelta = ambientColor * invAmb - irrN;

    float3 upper = ambDelta * HD_IBL_SPLIT_UPPER + irrN;
    upper = upper * maxIrr;
    upper = upper * ambPlusIbl - ambientColor;
    upper = ibl.weight * upper + ambientColor;

    float3 lower = ambDelta * HD_IBL_SPLIT_LOWER + irrN;
    lower = lower * maxIrr;
    float3 lowerScaled = lower * iblScale;

    float3 ambient = -lower * iblScale + upper;
    ambient = shadowedNdl * ambient + lowerScaled;
    ambient = hdPsCB2.ambientAdd.xyz + ambient;

    directSpec = directSpec * ambPlusIbl;
    directSpec = directSpec * shadowedNdl;
    float3 iblSpec = (s.F0 * ibl.brdf.x + ibl.brdf.y) * iblScale;
    float3 lit = directSpec * ambientColor + iblSpec;
    lit = lit * ibl.radiance;
    return ambient * s.diffColor + lit;
}

// ---------------------------------------------------------------------------
// Cluster lookup + light loop
// ---------------------------------------------------------------------------

// The pixel's cluster record: `.x` is the offset into the packed index list,
// `.y` how many lights it holds, and `.z` the tile coordinate the debug
// overlay keys its checkerboard off.
struct HDCluster
{
    uint listOffset;
    uint lightCount;
    uint2 tile;
};

static HDCluster hdLookupCluster(float2 svPositionXY)
{
    // Screen position normalised to the viewport rect, then quantised to the
    // grid. The rect is not the render target: a split-screen or editor
    // viewport shades into the same cluster grid as the main view.
    float2 tile01 = saturate((svPositionXY - hdPsCB1.viewportRect.xy)
                             / (hdPsCB1.viewportRect.zw - hdPsCB1.viewportRect.xy));

    HDCluster c;
    c.tile = (uint2)(tile01 / hdPsCB1.invClusterDims);

    int stride = asint(hdPsCB1.gridStride);
    int index = (int)c.tile.y * stride + (int)c.tile.x;
    int maxIndex = stride * asint(hdPsCB1.gridRows) - 1;
    // Clamped as UNSIGNED, so a negative index wraps to huge and clamps to the
    // last cluster rather than reading before the grid.
    index = (int)min((uint)index, (uint)maxIndex);
    index = index + asint(hdPsCB1.clusterBase);

    uint record = t_hdClusters[(uint)index];
    c.listOffset = record >> 10;
    c.lightCount = record & 1023;
    return c;
}

// Accumulate every cluster light into `lit`.
//
// `HAS_POINT_SHADOWS` adds the cube-shadow lookup; `HAS_LIGHT_DEBUG` adds the
// light-complexity overlay and the sentinel-colour path, in which lights whose
// radiance magnitude falls in specific 1/255 brackets are gizmos the editor
// draws rather than lights it shades with.
public float3 hdClusterLights<
    let HAS_POINT_SHADOWS : bool,
    let HAS_LIGHT_DEBUG : bool>(
    HDSurface s, float3 viewPos, float3 worldPos, float2 svPositionXY, float3 lit)
{
    HDCluster cluster = hdLookupCluster(svPositionXY);

    float stripe = 0;
    uint debugMode = 0;
    if (HAS_LIGHT_DEBUG)
    {
        // Light-complexity overlay: the count is added to G or B depending on
        // a per-tile checkerboard, so neighbouring clusters stay legible.
        uint2 parity = cluster.tile & 1;
        float amount = HD_DBG_LIGHT_COUNT_SCALE * (float)cluster.lightCount;
        uint checker = parity.x ^ parity.y;
        float2 mask = float2((float)(checker ^ 1), (float)checker);
        lit.yz = (asuint(hdPsCB1.lightDebugMode) >= 2) ? (amount * mask + lit.yz)
                                                       : lit.yz;

        // Diagonal stripes in world space, used to hatch the shadowed shell of
        // a shadow-casting light.
        stripe = dot(worldPos.xy, float2(0.707099974, 0.707099974));
        stripe = HD_DBG_STRIPE_FREQ * stripe;
        stripe = frac(stripe);
        stripe = -0.5 + stripe;
        stripe = (HD_DBG_STRIPE_DUTY >= abs(stripe)) ? 1.0 : 0.0;
        debugMode = asuint(hdPsCB1.lightDebugMode);
    }

    uint shadowLightCount = 0;
    if (HAS_POINT_SHADOWS || HAS_LIGHT_DEBUG)
        shadowLightCount = asuint(hdPsCB1.shadowLightCount);

    float ndv = dot(s.N, s.V);
    float gvLoop = ndv * s.kInv + s.kDirect;

    [loop] for (uint li = 0; li < cluster.lightCount; li++)
    {
        // Two 16-bit indices per uint, so the list is half the size a plain
        // uint array would be.
        uint slot = cluster.listOffset + li;
        uint packed = t_hdLightIndices[(slot >> 1) + asuint(hdPsCB1.lightIndexBase)];
        uint lightIdx = (slot & 1) != 0 ? (packed >> 16) : (packed & 0x0000ffff);
        lightIdx = lightIdx + asuint(hdPsCB1.lightArrayBase);

        HDClusterLight lgt = t_hdLights[lightIdx];
        float3 toLight = lgt.position() - viewPos;
        float distSq = dot(toLight, toLight);
        float dist = sqrt(distSq);
        float falloff = exp(-lgt.attenExp() * distSq);
        float denom = dot(float3(dist, 1, distSq),
                          float3(lgt.attenLinear(), 1, lgt.attenQuad()));
        float atten = falloff / denom;
        float3 lightRadiance = lgt.color() * atten;
        float mag = sqrt(dot(lightRadiance, lightRadiance));

        // Anything dimmer than one 8-bit step cannot change the frame buffer.
        if (mag < HD_DBG_MIN_RADIANCE)
            continue;

        float3 Ldir = toLight / dist;

        float lightShadow = 1;
        float cubeDist = 0;
        bool shadowValid = false;
        if (HAS_POINT_SHADOWS || HAS_LIGHT_DEBUG)
            shadowValid = (lgt.shadowIndex() >= 0)
                       && ((uint)lgt.shadowIndex() < shadowLightCount);
        // A light with no shadow map carries -1, and a debug gizmo -2. Those
        // are sentinels, not indices, so the record lookup is clamped: the
        // compiler is free to flatten the `shadowValid` branch and evaluate
        // the address anyway, and a negative one would read before the array.
        int shadowSlot = max(0, lgt.shadowIndex());
        if (HAS_POINT_SHADOWS && shadowValid)
            lightShadow = hdCubeShadow(shadowSlot, worldPos, cubeDist);

        float3 H = normalize(s.V + Ldir);
        float vdh = dot(H, s.V);
        float ndh = dot(s.N, H);
        float ndl = dot(s.N, Ldir);

        float3 spec = hdFresnel(s, vdh) * hdGGX(ndh, s.a2);
        float G = saturate(1.0 / (4.0 * ((ndl * s.kInv + s.kDirect) * gvLoop)));

        float weight = atten * max(0, ndl);
        float lightWeight = weight * lightShadow;
        float3 lightColor = lgt.color();

        if (HAS_LIGHT_DEBUG && debugMode >= 1 && HD_DBG_MIN_RADIANCE < mag)
        {
            if (mag < HD_DBG_FULLBRIGHT_MAX)
            {
                // A gizmo marker: draw it at full strength regardless of the
                // geometry it lands on.
                lightWeight = 1;
            }
            else
            {
                float4 dbg = float4(lightColor, lightWeight);
                if (shadowValid)
                {
                    HDCubeShadow rec = hdPsCB1.cubeShadows[shadowSlot];
                    // White out the near and far shells, hatch the shadowed
                    // volume between them.
                    bool2 onShell = abs(cubeDist - rec.range.xy) < float2(2, 2);
                    bool inShell = (rec.range.y >= cubeDist) ? (cubeDist >= rec.range.x)
                                                             : false;
                    float4 striped;
                    striped.xyz = stripe * (float3(1, 1, 1) - lightColor) + lightColor;
                    striped.w = stripe * (-weight * lightShadow + lightShadow) + lightWeight;
                    dbg = inShell ? striped : dbg;
                    dbg = (onShell.x || onShell.y) ? float4(5, 5, 5, 1) : dbg;
                }
                bool hot = (mag < HD_DBG_HILIGHT_MAX) ? (HD_DBG_HILIGHT_MIN < mag) : false;
                bool gizmo = (lgt.shadowIndex() >= 0) || (lgt.shadowIndex() == -2);
                dbg = (gizmo ? hot : false) ? float4(50, 50, 50, 1) : dbg;
                lightColor = dbg.xyz;
                lightWeight = dbg.w;
            }
        }

        float3 contrib = spec * G + s.diffColor;
        contrib = contrib * lightColor;
        lit = contrib * lightWeight + lit;
    }
    return lit;
}
