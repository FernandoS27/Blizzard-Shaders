"""Mutation test for the Wc3 uber-shader gates: does a wrong shader FAIL them?

A green validation means nothing on its own. The first run of
``tools/wc3_uber_validate.py`` against ``wc3_re_shaders/hd/uber.hlsl`` passed
immediately -- and mutation testing then showed 15 of 29 deliberate breakages
went unnoticed, because the driver never drove the cluster light loop, the cube
shadows or the debug overlay. Every entry below breaks exactly one behaviour
and must come back "caught"; anything MISSED is a hole in the driver (or a
mutation that is secretly a no-op -- check which before touching the shader).

    python tools/wc3_uber_mutate.py                    # the hd pixel shader
    python tools/wc3_uber_mutate.py --family=hd_vs     # the hd vertex shader
    python tools/wc3_uber_mutate.py light-atten ao     # named subset
    MUT_TRIALS=120 python tools/wc3_uber_mutate.py     # thin ones need more draws

Run it from the repo root. It edits uber.hlsl in place and restores it in a
finally-block, so an interrupt mid-run is safe but a kill -9 is not.
"""
import subprocess
import sys
import pathlib

MUTS_HD = [
    ('cascade-shadow-pcf', 'shadow = saturate(sum / taps);', 'shadow = saturate(sum / taps) * 0.5;', '0192'),
    ('cascade-inside-test', '&& (1 >= c.x) && (1 >= c.y) && (c.z < 1);', '&& (1 >= c.x) && (1 >= c.y);', '0192'),
    ('cascade-slice', 'float slice = (float)(uint)(i * 3 + sliceBase);', 'float slice = (float)(uint)(i * 3 + sliceBase + 1);', '0192'),
    ('cascade2-matbase', 'mainShadow = CascadeShadow(worldPos, 12, 1, texel);', 'mainShadow = CascadeShadow(worldPos, 16, 1, texel);', '0194'),
    ('cascade2-earlyout', 'if (mainShadow >= CASCADE_EARLY_OUT)', 'if (mainShadow >= 0.5)', '0194'),
    ('cube-shadow-strength', 'lightShadow = -(occl / max(1, taps)) * cb1[base + 44].z + 1;', 'lightShadow = -(occl / max(1, taps)) * cb1[base + 44].z + 0.9;', '0160'),
    ('cube-face-select', 'face = yMajor ? ((0 < dir.y) ? 2 : 3) : face;', 'face = yMajor ? ((0 < dir.y) ? 3 : 2) : face;', '0160'),
    ('cube-in-range', 'if ((cubeDist < cb1[base + 44].y) && (cb1[base + 44].x < cubeDist))', 'if (cubeDist < cb1[base + 44].y)', '0160'),
    ('cube-bias', 'float ref = zw.x / zw.y + -cb2[26].z;', 'float ref = zw.x / zw.y + -cb2[26].z * 50;', '0160'),
    ('cube-rows', 'float2 zw = cb1[fbase + 46].zw * worldPos.yy;', 'float2 zw = cb1[fbase + 46].xy * worldPos.yy;', '0160'),
    ('cube-shadow-valid', '&& ((uint)lgt.shadowIndex < shadowLightCount);', ';', '0160'),
    ('light-loop-accum', 'lit = contrib * lightWeight.xxx + lit;', 'lit = contrib * lightWeight.xxx * 0.5 + lit;', '0128'),
    ('light-atten', 'float atten = falloff / denom;', 'float atten = falloff / denom * 1.05;', '0128'),
    ('light-cull', 'if (mag < DBG_MIN_RADIANCE) continue;', 'if (mag < 0.01) continue;', '0144'),
    ('light-index-half', 'uint lightIdx = upperHalf ? (packed >> 16) : (packed & 0x0000ffff);', 'uint lightIdx = upperHalf ? (packed & 0x0000ffff) : (packed >> 16);', '0128'),
    ('light-falloff-exp', 'float falloff = exp(-lgt.attenExp * distSq);', 'float falloff = exp(-lgt.attenExp * dist);', '0128'),
    ('light-denom', 'float3(lgt.attenLinear, 1, lgt.attenQuad));', 'float3(lgt.attenQuad, 1, lgt.attenLinear));', '0128'),
    ('cluster-index', 'int clusterIdx = (int)tileI.y * asint(cb1[41].y) + (int)tileI.x;', 'int clusterIdx = (int)tileI.x * asint(cb1[41].y) + (int)tileI.y;', '0128'),
    ('cluster-count-mask', 'uint lightCount = clusterRec & 1023;', 'uint lightCount = clusterRec & 1022;', '0128'),
    ('cluster-offset-shift', 'uint listOffset = clusterRec >> 10;', 'uint listOffset = clusterRec >> 11;', '0128'),
    ('ibl-radiance', 'radiance = cb2[25].zzz * (radB + -radA) + radA;', 'radiance = cb2[25].zzz * (radB + -radA) + radA * 0.9;', '0128'),
    ('ibl-basis', 'float3 tangentA = cross(float3(0, 1, 0), axis);', 'float3 tangentA = cross(axis, float3(0, 1, 0));', '0128'),
    ('ibl-mip', 'float2 mip = cb2[25].xy * rough.xx;', 'float2 mip = cb2[25].yx * rough.xx;', '0128'),
    ('ibl-slice', 'float3 radA = t11.SampleLevel(s11_s, float4(rProbe, 1), mip.x).xyz;', 'float3 radA = t11.SampleLevel(s11_s, float4(rProbe, 0), mip.x).xyz;', '0128'),
    ('ibl-probe-swizzle', 'float3 nProbe = float3(Nw.x, Nw.z, -Nw.y);', 'float3 nProbe = float3(Nw.x, Nw.y, -Nw.z);', '0128'),
    ('ambient-split', 'float3 upper = ambDelta * IBL_SPLIT_UPPER.xxx + irrN;', 'float3 upper = ambDelta * IBL_SPLIT_LOWER.xxx + irrN;', '0128'),
    ('spec-times-radiance', 'lit = lit * radiance;', 'lit = lit;', '0128'),
    ('dbg-overlay', 'lit.yz = (asuint(cb1[39].w) >= 2) ? (amount.xx * mask + lit.yz) : lit.yz;', 'lit.yz = (asuint(cb1[39].w) >= 3) ? (amount.xx * mask + lit.yz) : lit.yz;', '0144'),
    ('dbg-checker', 'uint checker = parity.x ^ parity.y;', 'uint checker = parity.x;', '0144'),
    ('dbg-fullbright', 'lightWeight = 1;                        // gizmo: draw at full strength', 'lightWeight = 100;', '0144'),
    ('dbg-stripe', 'stripe = (DBG_STRIPE_DUTY >= abs(stripe)) ? 1.0 : 0.0;', 'stripe = (DBG_STRIPE_DUTY >= abs(stripe)) ? 0.5 : 0.0;', '0176'),
    ('dbg-hot', 'dbg = (gizmo ? hot : false) ? float4(50, 50, 50, 1) : dbg;', 'dbg = (gizmo ? hot : false) ? float4(49, 50, 50, 1) : dbg;', '0144'),
    ('dbg-shell', 'dbg = (onShell.x || onShell.y) ? float4(5, 5, 5, 1) : dbg;', 'dbg = (onShell.x || onShell.y) ? float4(4, 5, 5, 1) : dbg;', '0176'),
    ('dbg-inshell', 'dbg = inShell ? striped : dbg;', 'dbg = inShell ? dbg : striped;', '0176'),
    ('dbg-gizmo-test', 'bool gizmo = (lgt.shadowIndex >= 0) || (lgt.shadowIndex == -2);', 'bool gizmo = (lgt.shadowIndex >= 0);', '0144'),
    ('ao', 'shadedRGB = lit * ao.xxx;', 'shadedRGB = lit * ao.xxx * 0.9;', '0129'),
    ('ao-uv', 'float ao = t2.Sample(s2_s, uv.zw).x;', 'float ao = t2.Sample(s2_s, uv.xy).x;', '0129'),
    ('multilayer', 'albedo.xyz = albedo.xyz * lum.xxx;', 'albedo.xyz = albedo.xyz * lum.xxx * 0.9;', '0512'),
    ('ml-emissive', 'emissive = teamW.xxx * (emissive * teamRGB + -emissive) + emissive;', 'emissive = emissive * teamRGB;', '0512'),
    ('ml-sqrt-weight', 'float sqrtW = 1.0 / rsqrt(teamW);', 'float sqrtW = teamW;', '0512'),
    ('fog-volumetric', 'float fogNear = -outer * outer + 1;', 'float fogNear = -outer * outer + 0.9;', '0000'),
    ('fog-height', 'hereH = nearEnough ? hereH : 0;', 'hereH = hereH;', '0000'),
    ('fog-exp', 'fogFactor = 1.0 / exp(cb2[2].y * viewPos.z);', 'fogFactor = 1.0 / exp(cb2[2].y * viewPos.z * 1.01);', '0000'),
    ('fog-mode35', 'fogFactor = pick.y ? expT : fogFactor;', 'fogFactor = pick.y ? expT2 : fogFactor;', '0000'),
    ('fog-smooth', 'fogFactor = -fogFactor * fogFactor + (fogFactor + fogFactor);', 'fogFactor = fogFactor;', '0000'),
    ('fog-mode0', 'if (asint(cb2[27].z) == 0)', 'if (asint(cb2[27].z) == 1)', '0000'),
    ('blendmode-switch', 'case 0: case 1: case 2: case 10:', 'case 0: case 1: case 2:', '0000'),
    ('blendmode-6', 'result = fogFactor.xxxx * result;', 'result.xyz = fogFactor.xxx * result.xyz;', '0000'),
    ('color-matrix', 'result.y = dot(COLOR_MATRIX_G, shaded.xyz);', 'result.y = dot(COLOR_MATRIX_R, shaded.xyz);', '0000'),
    ('mrt-discard', 'if (-(1 + -cb2[22].x) * MRT_SOFTNESS_FACTOR + albedo.w < 0) discard;', 'if (-(1 + -cb2[22].x) * MRT_SOFTNESS_FACTOR + albedo.w < -0.3) discard;', '0004'),
    ('mrt-normal', 'outNormal.xyz = N * NORMAL_PACK.xxx + NORMAL_PACK.xxx;', 'outNormal.xyz = N * NORMAL_PACK.xxx;', '0004'),
    ('mrt-alpha', 'outNormal.w = shaded.w;', 'outNormal.w = result.w;', '0004'),
    ('alpha-test', 'if (-cb2[0].x + shaded.w < 0) discard;', 'if (-cb2[0].x + shaded.w < -0.05) discard;', '0256'),
    ('clip-discard', 'if (viewPos.w < 0) discard;', 'if (viewPos.w < -0.15) discard;', '0000'),
    ('depth-test', 'if ((0 < _sceneDepth) && (viewPos.z + -_sceneDepth < 0)) discard;', 'if (viewPos.z + -_sceneDepth < 0) discard;', '0008'),
    ('depth-enable', 'if (0.5 < cb2[23].w)', 'if (-0.5 < cb2[23].w)', '0008'),
    ('normal-strength', 'float2 xy = cb2[27].xx * n.xy;', 'float2 xy = cb2[27].xx * n.xy * 1.01;', '0000'),
    ('normal-decode-y', 'float g = enc.y * 2 + -1;', 'float g = enc.y * 2 + -1.0001;', '0000'),
    ('tbn-handedness', '* tangentWS.www;', '* 1.0;', '0000'),
    ('frontface-flip', 'return frontFace ? n : -n;', 'return n;', '0000'),
    ('cloak', 'float cloakAlpha = edge * ramp + CLOAK_ALPHA_BIAS;', 'float cloakAlpha = edge * ramp + 0.21;', '0000'),
    ('cloak-tint', 'float3 cloakRGB = cb2[22].yyy * ((CLOAK_TINT + -plainRGB) * tintT.xxx) + plainRGB;', 'float3 cloakRGB = cb2[22].yyy * ((float3(0.41, 0.4, 0.4) + -plainRGB) * tintT.xxx) + plainRGB;', '0000'),
    ('ml-tint-falloff', 'float tintT = (rim2 * teamW) * ML_TINT_FALLOFF + rim2;', 'float tintT = rim2;', '0512'),
    ('blight', 'float3 blight = t8.Sample(s8_s, float2(mask, 0.75)).xyz;', 'float3 blight = t8.Sample(s8_s, float2(mask, 0.7)).xyz;', '0000'),
    ('blight-enable', 'bool blightOn = 0.5 < cb2[22].w;', 'bool blightOn = 0.4 < cb2[22].w;', '0000'),
    ('ml-fresnel-target', 'float fresnelClamp = min(maxF, maxTeam);', 'float fresnelClamp = min(1, maxF);', '0512'),
    ('fresnel-intensity', 'float fresnelInt = teamF2 * (fresnelClamp + -maxF) + maxF;', 'float fresnelInt = maxF;', '0000'),
    ('prepass-alpha', 'float alpha = (0 < cb2[22].y) ? cloakAlpha : plainAlpha;', 'float alpha = (0 < cb2[22].y) ? plainAlpha : cloakAlpha;', '0264'),
    ('prepass-ml-ramp', 'float ramp = t2.Sample(s2_s, uv.xy).w * ML_ALPHA_RAMP_SCALE + ML_ALPHA_RAMP_BIAS;', 'float ramp = CLOAK_EDGE_SCALE;', '0776'),
    ('spec-aa-toggle', 'float rough = (asuint(cb2[26].w) != 0) ? roughAA : roughness;', 'float rough = roughness;', '0128'),
    ('roughness-remap', 'roughness = roughness * ROUGHNESS_SCALE + ROUGHNESS_BIAS;', 'roughness = roughness;', '0128'),
    ('main-light-gate', 'if (asint(cb2[27].y) != 0)', 'if (true)', '0128'),
    ('srgb-vertcolor', 'return c * (c * (c * SRGB_C2 + SRGB_C1) + SRGB_C0);', 'return c * c;', '0000'),
    ('emissive-gain', 'shadedRGB = emissive * cb2[26].yyy + albedo.xyz;', 'shadedRGB = emissive + albedo.xyz;', '0000'),
]


# ==========================================================================
# hd_vs -- the HD mesh VERTEX shader
# ==========================================================================
#
# The vertex shader has no loops and no textures, so the coverage question is
# narrower than the pixel shader's: four branches that random inputs never
# reach (the unskinned fall-through, the two zero-length fallbacks, and the
# reference-axis pick for the generated tangent frame) plus a saturate that
# hides its own transform if the rect is not placed against the world-position
# range. Each of those has at least one mutation below aimed squarely at it.

MUTS_HD_VS = [
    # --- transforms ---------------------------------------------------------
    ('clip-matrix', 'oPosition = position.x * cb2[8] + position.y * cb2[9]', 'oPosition = position.x * cb2[8] + position.y * cb2[10]', '000'),
    ('clip-translate', '+ position.z * cb2[10] + cb2[11];', '+ position.z * cb2[10] + cb2[7];', '000'),
    ('viewpos-basis', 'oViewPos.xyz = position.x * cb2[4].xyz + position.y * cb2[5].xyz', 'oViewPos.xyz = position.x * cb2[5].xyz + position.y * cb2[4].xyz', '000'),
    ('viewpos-translate', '+ position.z * cb2[6].xyz + cb2[7].xyz;', '+ position.z * cb2[6].xyz + cb2[3].xyz;', '000'),
    ('worldpos-matrix', 'float4 worldPos = position.x * cb2[0] + position.y * cb2[1]', 'float4 worldPos = position.x * cb2[0] + position.y * cb2[2]', '000'),
    ('worldpos-translate', '+ position.z * cb2[2] + cb2[3];', '+ position.z * cb2[2] + cb2[11];', '000'),
    ('worldpos-out', 'oWorldPos = worldPos;', 'oWorldPos = float4(worldPos.xyz, 1);', '000'),

    # --- water clip depth ---------------------------------------------------
    ('clipdepth-axis', 'oViewPos.w = (worldPos.z - cb2[16].z) * cb2[16].w;', 'oViewPos.w = (worldPos.y - cb2[16].z) * cb2[16].w;', '000'),
    ('clipdepth-height', 'oViewPos.w = (worldPos.z - cb2[16].z) * cb2[16].w;', 'oViewPos.w = (worldPos.z + cb2[16].z) * cb2[16].w;', '000'),
    ('clipdepth-scale', 'oViewPos.w = (worldPos.z - cb2[16].z) * cb2[16].w;', 'oViewPos.w = (worldPos.z - cb2[16].z) * cb2[16].z;', '000'),

    # --- colour -------------------------------------------------------------
    ('color-tint-reg', '  oColor = cb2[18];', '  oColor = cb2[17];', '000'),
    ('color-vertex', 'oColor = cb2[18] * iColor;', 'oColor = cb2[18] + iColor;', '036'),

    # --- UV transforms ------------------------------------------------------
    ('uv0-row-swizzle', 'float2 t0 = float2(dot(cb2[19].xyw, uv0), dot(cb2[20].xyw, uv0));', 'float2 t0 = float2(dot(cb2[19].xyz, uv0), dot(cb2[20].xyw, uv0));', '024'),
    ('uv0-row-index', 'float2 t0 = float2(dot(cb2[19].xyw, uv0), dot(cb2[20].xyw, uv0));', 'float2 t0 = float2(dot(cb2[20].xyw, uv0), dot(cb2[19].xyw, uv0));', '024'),
    ('uv0-affine-one', 'float3 uv0 = float3(iTexCoord0, 1);', 'float3 uv0 = float3(iTexCoord0, 0);', '024'),
    ('uv1-row-index', 'float2 t1 = float2(dot(cb2[21].xyw, uv1), dot(cb2[22].xyw, uv1));', 'float2 t1 = float2(dot(cb2[19].xyw, uv1), dot(cb2[22].xyw, uv1));', '060'),
    ('uv1-stream', 'float3 uv1 = float3(iTexCoord1, 1);', 'float3 uv1 = float3(iTexCoord0, 1);', '060'),
    ('uv1-duplicate', '  float2 t1 = t0;', '  float2 t1 = float2(0, 0);', '024'),
    ('uv-none-zero', 'oTexCoord = float4(0, 0, 0, 0);', 'oTexCoord = float4(1, 0, 0, 0);', '000'),
    ('uv-pack-order', 'oTexCoord = float4(t0, t1);', 'oTexCoord = float4(t1, t0);', '060'),

    # --- normal -------------------------------------------------------------
    ('normal-basis', 'float3 n = normal.x * cb2[4].xyz + normal.y * cb2[5].xyz', 'float3 n = normal.x * cb2[5].xyz + normal.y * cb2[4].xyz', '000'),
    ('normal-affine', 'float3 n = normal.x * cb2[4].xyz + normal.y * cb2[5].xyz\n           + normal.z * cb2[6].xyz;', 'float3 n = normal.x * cb2[4].xyz + normal.y * cb2[5].xyz\n           + normal.z * cb2[6].xyz + cb2[7].xyz;', '000'),
    ('normal-fallback', 'n = (sqrt(nlen2) > 0) ? (n * rsqrt(nlen2)) : float3(0, 1, 0);', 'n = (sqrt(nlen2) > 0) ? (n * rsqrt(nlen2)) : float3(0, 0, 1);', '000'),
    ('normal-guard', 'n = (sqrt(nlen2) > 0) ? (n * rsqrt(nlen2)) : float3(0, 1, 0);', 'n = (sqrt(nlen2) > 0.001) ? (n * rsqrt(nlen2)) : float3(0, 1, 0);', '000'),
    ('normal-normalize', 'n = (sqrt(nlen2) > 0) ? (n * rsqrt(nlen2)) : float3(0, 1, 0);', 'n = (sqrt(nlen2) > 0) ? n : float3(0, 1, 0);', '000'),

    # --- generated tangent frame --------------------------------------------
    ('tangent-axis-threshold', 'float3 up = (abs(n.z) < 0.999) ? float3(0, 0, 1) : float3(0, 1, 0);', 'float3 up = (abs(n.z) < 0.95) ? float3(0, 0, 1) : float3(0, 1, 0);', '000'),
    ('tangent-axis-pick', 'float3 up = (abs(n.z) < 0.999) ? float3(0, 0, 1) : float3(0, 1, 0);', 'float3 up = (abs(n.z) < 0.999) ? float3(0, 1, 0) : float3(0, 0, 1);', '000'),
    ('tangent-axis-component', 'float3 up = (abs(n.z) < 0.999) ? float3(0, 0, 1) : float3(0, 1, 0);', 'float3 up = (abs(n.y) < 0.999) ? float3(0, 0, 1) : float3(0, 1, 0);', '000'),
    ('tangent-cross-order', 'float3 genTangent = normalize(cross(up, n));', 'float3 genTangent = normalize(cross(n, up));', '000'),
    ('tangent-normalize', 'float3 genTangent = normalize(cross(up, n));', 'float3 genTangent = cross(up, n);', '000'),
    ('tangent-w-default', '  oTangent.w = 1;', '  oTangent.w = 0;', '000'),

    # --- supplied tangent ---------------------------------------------------
    ('tangent-basis', 'float3 t = tangent.x * cb2[4].xyz + tangent.y * cb2[5].xyz', 'float3 t = tangent.x * cb2[5].xyz + tangent.y * cb2[4].xyz', '002'),
    ('tangent-guard', 'oTangent.xyz = (sqrt(tlen2) > 0) ? (t * rsqrt(tlen2)) : genTangent;', 'oTangent.xyz = (sqrt(tlen2) > 0) ? (t * rsqrt(tlen2)) : float3(1, 0, 0);', '002'),
    ('tangent-fallback-arm', 'oTangent.xyz = (sqrt(tlen2) > 0) ? (t * rsqrt(tlen2)) : genTangent;', 'oTangent.xyz = (sqrt(tlen2) > 0) ? genTangent : (t * rsqrt(tlen2));', '002'),
    ('tangent-guard-threshold', 'oTangent.xyz = (sqrt(tlen2) > 0) ? (t * rsqrt(tlen2)) : genTangent;', 'oTangent.xyz = (sqrt(tlen2) > 0.001) ? (t * rsqrt(tlen2)) : genTangent;', '002'),
    ('tangent-handedness', '  oTangent.w = iTangent.w;', '  oTangent.w = 1;', '002'),

    # --- blight-map UV ------------------------------------------------------
    ('blight-origin', 'oBlightUV.xy = saturate((worldPos.xy - cb1[0].xy) * cb1[0].zw);', 'oBlightUV.xy = saturate((worldPos.xy + cb1[0].xy) * cb1[0].zw);', '000'),
    ('blight-scale', 'oBlightUV.xy = saturate((worldPos.xy - cb1[0].xy) * cb1[0].zw);', 'oBlightUV.xy = saturate((worldPos.xy - cb1[0].xy) * cb1[0].xy);', '000'),
    ('blight-saturate', 'oBlightUV.xy = saturate((worldPos.xy - cb1[0].xy) * cb1[0].zw);', 'oBlightUV.xy = ((worldPos.xy - cb1[0].xy) * cb1[0].zw);', '000'),
    ('blight-source', 'oBlightUV.xy = saturate((worldPos.xy - cb1[0].xy) * cb1[0].zw);', 'oBlightUV.xy = saturate((oViewPos.xy - cb1[0].xy) * cb1[0].zw);', '000'),
    ('blight-zw', 'oBlightUV.zw = float2(0, 0);', 'oBlightUV.zw = float2(0, 1);', '000'),

    # --- skinning -----------------------------------------------------------
    ('skin-weight-test', 'if (dot(iBoneWeight, float4(1, 1, 1, 1)) != 0)', 'if (true)', '008'),
    ('skin-weight-sign', 'if (dot(iBoneWeight, float4(1, 1, 1, 1)) != 0)', 'if (dot(iBoneWeight, float4(1, 1, 1, 1)) > 0)', '008'),
    ('skin-weight-lane', 'float4 m0 = BONE(x).row0 * iBoneWeight.x + BONE(y).row0 * iBoneWeight.y', 'float4 m0 = BONE(x).row0 * iBoneWeight.y + BONE(y).row0 * iBoneWeight.x', '008'),
    ('skin-bone-lane', 'int4 b = int4(iBoneIndex);', 'int4 b = int4(iBoneIndex).yxzw;', '008'),
    ('skin-row-pairing', 'float4 m1 = BONE(x).row1 * iBoneWeight.x + BONE(y).row1 * iBoneWeight.y', 'float4 m1 = BONE(x).row2 * iBoneWeight.x + BONE(y).row1 * iBoneWeight.y', '008'),
    ('skin-pos-affine', 'float4 p = float4(iPosition, 1);', 'float4 p = float4(iPosition, 0);', '008'),
    ('skin-pos-rows', 'position = float3(dot(m0, p), dot(m1, p), dot(m2, p));', 'position = float3(dot(m1, p), dot(m0, p), dot(m2, p));', '008'),
    ('skin-normal-rows', 'normal = float3(dot(m0.xyz, iNormal), dot(m1.xyz, iNormal),', 'normal = float3(dot(m1.xyz, iNormal), dot(m0.xyz, iNormal),', '008'),
    ('skin-normal-affine', 'normal = float3(dot(m0.xyz, iNormal), dot(m1.xyz, iNormal),', 'normal = float3(dot(m0, float4(iNormal, 1)), dot(m1.xyz, iNormal),', '008'),
    ('skin-tangent-source', 'tangent = float3(dot(m0.xyz, iTangent.xyz), dot(m1.xyz, iTangent.xyz),', 'tangent = float3(dot(m0.xyz, iNormal.xyz), dot(m1.xyz, iTangent.xyz),', '010'),

    # --- bone palette source ------------------------------------------------
    ('bone-buffer-base', 'int4 b = int4(iBoneIndex) + asint(cb2[17].x);', 'int4 b = int4(iBoneIndex);', '009'),
    ('bone-buffer-base-type', 'int4 b = int4(iBoneIndex) + asint(cb2[17].x);', 'int4 b = int4(iBoneIndex) + (int)cb2[17].x;', '009'),
    ('bone-buffer-row', '    #define BONE(c) t16[b.c]', '    #define BONE(c) t16[b.c + 1]', '009'),
]


FAMILIES = {
    'hd': ('wc3_re_shaders/hd/uber.hlsl', MUTS_HD),
    'hd_vs': ('wc3_re_shaders/hd_vs/uber.hlsl', MUTS_HD_VS),
}

TRIALS = int(__import__('os').environ.get('MUT_TRIALS', '24'))


def run(folder, slot, trials):
    r = subprocess.run([sys.executable, 'tools/wc3_uber_validate.py',
                        folder, '--slots', slot, '--trials', str(trials)],
                       capture_output=True, text=True)
    return r.returncode != 0, (r.stdout or '') + (r.stderr or '')


def main():
    args = sys.argv[1:]
    family = 'hd'
    for a in list(args):
        if a.startswith('--family='):
            family = a.split('=', 1)[1]
            args.remove(a)
    if family not in FAMILIES:
        print(f"unknown family {family!r}; know {sorted(FAMILIES)}")
        return 2
    src_path, muts = FAMILIES[family]
    src = pathlib.Path(src_path)
    folder = str(src.parent).replace('\\', '/')
    orig = src.read_text(encoding='utf-8')

    only = args or None
    fails = []
    checked = 0
    try:
        for name, find, repl, slot in muts:
            if only and name not in only:
                continue
            checked += 1
            if find not in orig:
                print(f"  !! {name}: pattern not found in {src}")
                fails.append(name)
                continue
            src.write_text(orig.replace(find, repl), encoding='utf-8')
            caught, out = run(folder, slot, TRIALS)
            print(f"  [{'caught' if caught else 'MISSED'}] {name} (perm_{slot})",
                  flush=True)
            if not caught:
                fails.append(name)
    finally:
        src.write_text(orig, encoding='utf-8')
    print()
    print(f"{checked - len(fails)}/{checked} mutations caught")
    if fails:
        print("NOT CAUGHT:", ", ".join(fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
