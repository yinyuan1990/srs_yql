#include <metal_stdlib>
using namespace metal;

struct NV12Params {
    float exposure;
    float blackPoint;
    float brightness;
    float gamma;
    float contrast;
    float saturation;
    float sharpen;
    float redGlow;
};

// Y 平面：亮度 + 锐化（全分辨率）
kernel void processY(
    texture2d<float, access::read>  yIn  [[texture(0)]],
    texture2d<float, access::write> yOut [[texture(1)]],
    constant NV12Params& p              [[buffer(0)]],
    uint2 gid                           [[thread_position_in_grid]])
{
    uint w = yIn.get_width();
    uint h = yIn.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float y = yIn.read(gid).r;

    // 锐化（Unsharp Mask，仅采样4邻居，与 CISharpenLuminance 等价）
    if (p.sharpen > 0.001) {
        uint x0 = gid.x > 0     ? gid.x - 1 : 0;
        uint x1 = gid.x < w - 1 ? gid.x + 1 : w - 1;
        uint y0 = gid.y > 0     ? gid.y - 1 : 0;
        uint y1 = gid.y < h - 1 ? gid.y + 1 : h - 1;
        float blur = (yIn.read(uint2(gid.x, y0)).r +
                      yIn.read(uint2(gid.x, y1)).r +
                      yIn.read(uint2(x0, gid.y)).r +
                      yIn.read(uint2(x1, gid.y)).r) * 0.25;
        y = y + p.sharpen * (y - blur);
        y = clamp(y, 0.0, 1.0);
    }

    // 曝光
    y = y * pow(2.0, p.exposure);
    // 黑场
    y = max(y - p.blackPoint, 0.0) / max(1.0 - p.blackPoint, 0.001);
    // 亮度（中调弯曲，保端点）
    y = y + p.brightness * y * (1.0 - y);
    // 伽马
    y = pow(max(y, 0.001), 1.0 / max(p.gamma, 0.01));
    // 对比度
    y = (y - 0.5) * p.contrast + 0.5;
    y = clamp(y, 0.0, 1.0);

    yOut.write(float4(y, 0, 0, 1), gid);
}

// UV 平面：饱和度（半分辨率）
kernel void processUV(
    texture2d<float, access::read>  uvIn  [[texture(0)]],
    texture2d<float, access::write> uvOut [[texture(1)]],
    constant NV12Params& p               [[buffer(0)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    uint w = uvIn.get_width();
    uint h = uvIn.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = uvIn.read(gid).rg;
    // 饱和度：UV 偏移量缩放（0.5 是中性色）
    uv = 0.5 + (uv - 0.5) * p.saturation;
    uv = clamp(uv, 0.0, 1.0);

    uvOut.write(float4(uv.r, uv.g, 0, 1), gid);
}
