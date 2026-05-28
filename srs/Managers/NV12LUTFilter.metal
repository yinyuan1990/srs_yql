#include <metal_stdlib>
using namespace metal;

// BT.709 full range (与相机 NV12 FullRange 一致)
inline float3 yuvToRgb(float y, float2 uv) {
    float u = uv.x - 0.5;
    float v = uv.y - 0.5;
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;
    return clamp(float3(r, g, b), 0.0, 1.0);
}

inline float rgbToY(float3 rgb) {
    return clamp(dot(rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
}

inline float2 rgbToUV(float3 rgb) {
    float y = rgbToY(rgb);
    float u = (rgb.b - y) / 1.8556 + 0.5;
    float v = (rgb.r - y) / 1.5748 + 0.5;
    return clamp(float2(u, v), 0.0, 1.0);
}

// GPUImage LookupFilter 同款 512×512 3D LUT 查表
inline float3 gpuImageLookup(float3 textureColor, texture2d<float, access::sample> lookupTex, sampler s) {
    float blueColor = textureColor.b * 63.0;

    float2 quad1;
    quad1.y = floor(floor(blueColor) / 8.0);
    quad1.x = floor(blueColor) - (quad1.y * 8.0);

    float2 quad2;
    quad2.y = floor(ceil(blueColor) / 8.0);
    quad2.x = ceil(blueColor) - (quad2.y * 8.0);

    float2 texPos1;
    texPos1.x = (quad1.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
    texPos1.y = (quad1.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);

    float2 texPos2;
    texPos2.x = (quad2.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.r);
    texPos2.y = (quad2.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * textureColor.g);

    float3 newColor1 = lookupTex.sample(s, texPos1).rgb;
    float3 newColor2 = lookupTex.sample(s, texPos2).rgb;
    float3 newColor = mix(newColor1, newColor2, fract(blueColor));
    return newColor;
}

struct LUTParams {
    float intensity;    // LUT 混合 0~1
    float exposure;     // 亮度（高光保护，白桌布不泛黄）
    float temperature;  // 负=偏冷去黄，正=偏暖
    float redLift;      // 暗红抬升（远处牌）
    float redSat;       // 红色饱和度（对手更红主要靠这个）
};

// 检测 ♥♦ 类红色像素（含远处发暗的红）
inline float cardRedWeight(float3 rgb) {
    float maxGB = max(rgb.g, rgb.b);
    float redness = max(0.0, rgb.r - maxGB);
    return smoothstep(0.012, 0.07, redness);
}

// LUT 前：先把暗红抬出 LUT 查表的"黑色死区"
inline float3 preLiftCardRed(float3 rgb, float lift, float redHue) {
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    // 远处牌落在 0.05~0.45 luma，必须覆盖
    float shadowMask = (1.0 - smoothstep(0.40, 0.82, luma)) * redHue;
    float boost = lift * (1.2 + (0.35 - min(luma, 0.35)) * 2.0);
    rgb.r += boost * shadowMask;
    rgb.g -= boost * 0.12 * shadowMask;
    rgb.b -= boost * 0.12 * shadowMask;
    return clamp(rgb, 0.0, 1.0);
}

inline float3 applyPokerLutGrade(float3 rgb, float3 mapped, constant LUTParams& p) {
    float redHue = cardRedWeight(rgb);

    // ① LUT 前先抬暗红，避免查表进死黑区
    rgb = preLiftCardRed(rgb, p.redLift, redHue);

    float3 outRgb = mix(rgb, mapped, p.intensity);
    float luma = dot(outRgb, float3(0.2126, 0.7152, 0.0722));
    float outRedHue = max(cardRedWeight(outRgb), redHue);

    // ② LUT 后再抬红 + 加饱和（只作用于红色像素，白桌不动）
    float shadowMask = (1.0 - smoothstep(0.38, 0.85, luma)) * outRedHue;
    float hiCap = 1.0 - smoothstep(0.90, 0.98, luma);
    float redBoost = p.redLift * (0.8 + (0.40 - min(luma, 0.40))) * shadowMask * hiCap;
    outRgb.r += redBoost;
    outRgb.g -= redBoost * 0.10;
    outRgb.b -= redBoost * 0.10;

    // ③ 红色饱和：对手更红，主要是 Cr/V 方向拉满
    float gray = luma;
    outRgb = mix(float3(gray), outRgb, 1.0 + p.redSat * outRedHue);

    // 色温：主要作用在中低亮（背景桌布），高光少动保持白
    float tempMask = (1.0 - smoothstep(0.50, 0.92, luma)) * (1.0 - outRedHue * 0.85);
    outRgb.r += p.temperature * 0.55 * tempMask;
    outRgb.g += p.temperature * 0.25 * tempMask;
    outRgb.b -= p.temperature * tempMask;

    // 亮度配合快门：只在中低亮抬曝光，高光区保护
    float hiProtect = 1.0 - smoothstep(0.68, 0.97, luma);
    outRgb = outRgb * (1.0 + p.exposure * hiProtect);

    return clamp(outRgb, 0.0, 1.0);
}

// Pass1: 全分辨率 Y（使用对应 UV 采样）
kernel void lutProcessY(
    texture2d<float, access::read>  yIn      [[texture(0)]],
    texture2d<float, access::read>  uvIn     [[texture(1)]],
    texture2d<float, access::write> yOut     [[texture(2)]],
    texture2d<float, access::sample> lookup  [[texture(3)]],
    constant LUTParams& p                  [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    uint w = yIn.get_width();
    uint h = yIn.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float y = yIn.read(gid).r;
    uint2 uvGid = uint2(gid.x >> 1, gid.y >> 1);
    float2 uv = uvIn.read(uvGid).rg;

    float3 rgb = yuvToRgb(y, uv);
    float3 mapped = gpuImageLookup(rgb, lookup, sampler(filter::linear, address::clamp_to_edge));
    float3 outRgb = applyPokerLutGrade(rgb, mapped, p);

    yOut.write(float4(rgbToY(outRgb), 0, 0, 1), gid);
}

// Pass2: 半分辨率 UV（每块 2×2 共享 chroma）
kernel void lutProcessUV(
    texture2d<float, access::read>  yIn      [[texture(0)]],
    texture2d<float, access::read>  uvIn     [[texture(1)]],
    texture2d<float, access::write> uvOut    [[texture(2)]],
    texture2d<float, access::sample> lookup [[texture(3)]],
    constant LUTParams& p                  [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    uint uvW = uvIn.get_width();
    uint uvH = uvIn.get_height();
    if (gid.x >= uvW || gid.y >= uvH) return;

    float2 uv = uvIn.read(gid).rg;
    uint2 yGid = gid * 2;
    float y = yIn.read(yGid).r;

    float3 rgb = yuvToRgb(y, uv);
    float3 mapped = gpuImageLookup(rgb, lookup, sampler(filter::linear, address::clamp_to_edge));
    float3 outRgb = applyPokerLutGrade(rgb, mapped, p);

    uvOut.write(float4(rgbToUV(outRgb), 0, 1), gid);
}
