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
    float preContrast;  // LUT 前降对比（绕中点 0.5，<1 降对比，1=不变）
    float preGamma;     // LUT 前抬中间调（>1 提亮暗部/中间调，1=不变）
};

// LUT 之前的"采集级"tone 调整：降对比 + 抬中间调
// 仅预处理喂给 LUT 的画面，红白黑查表逻辑不受影响
inline float3 applyPreGrade(float3 rgb, constant LUTParams& p) {
    rgb = (rgb - 0.5) * max(p.preContrast, 0.0) + 0.5;          // 降对比
    rgb = pow(max(rgb, 0.0), 1.0 / max(p.preGamma, 0.01));       // 抬中间调（提亮）
    return clamp(rgb, 0.0, 1.0);
}

// 玉麒麟 GPUImage LookupFilter：mix(原色, 查表色, intensity)，无额外抬红
inline float3 applyPokerLutGrade(float3 rgb, float3 mapped, constant LUTParams& p) {
    float3 outRgb = mix(rgb, mapped, clamp(p.intensity, 0.0, 1.0));
    float redDominance = outRgb.r - max(outRgb.g, outRgb.b);
    float redMask = smoothstep(0.06, 0.22, redDominance) * smoothstep(0.10, 0.35, outRgb.r);
    float darkRedMask = redMask * (1.0 - smoothstep(0.22, 0.55, rgbToY(outRgb)));
    float lift = darkRedMask * max(p.redLift, 0.0);
    outRgb.r = outRgb.r + lift * (1.0 - outRgb.r);
    outRgb.g = outRgb.g * (1.0 - darkRedMask * 0.10);
    outRgb.b = outRgb.b * (1.0 - darkRedMask * 0.10);

    float sat = 1.0 + redMask * max(p.redSat, 0.0);
    float y = rgbToY(outRgb);
    outRgb = mix(float3(y), outRgb, sat);
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

    float3 rgb = applyPreGrade(yuvToRgb(y, uv), p);
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
    uint yW = yIn.get_width();
    uint yH = yIn.get_height();
    uint2 y00 = uint2(min(yGid.x, yW - 1), min(yGid.y, yH - 1));
    uint2 y10 = uint2(min(yGid.x + 1, yW - 1), y00.y);
    uint2 y01 = uint2(y00.x, min(yGid.y + 1, yH - 1));
    uint2 y11 = uint2(y10.x, y01.y);
    float y = (yIn.read(y00).r + yIn.read(y10).r + yIn.read(y01).r + yIn.read(y11).r) * 0.25;

    float3 rgb = applyPreGrade(yuvToRgb(y, uv), p);
    float3 mapped = gpuImageLookup(rgb, lookup, sampler(filter::linear, address::clamp_to_edge));
    float3 outRgb = applyPokerLutGrade(rgb, mapped, p);

    uvOut.write(float4(rgbToUV(outRgb), 0, 1), gid);
}
