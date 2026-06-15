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
    float pixelLevel;
    float chroma;       // 色度：黄色拉白强度 0=关 1=黄色完全中性化（保留红色）
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

    y = y * pow(2.0, p.exposure);
    float px = clamp(p.pixelLevel, -2.0, 8.0);
    float hiMask = smoothstep(0.32, 0.92, y);
    if (px >= 0.0) {
        float lift = px / 8.0;
        y = y + lift * 0.70 * hiMask * (1.0 - y);
        y = mix(y, min(y * (1.0 + lift * 0.12), 1.0), hiMask * 0.25);
    } else {
        float down = (-px) / 2.0;
        y = y - down * 0.55 * hiMask * y;
    }
    y = clamp(y, 0.0, 1.0);
    y = max(y - p.blackPoint, 0.0) / max(1.0 - p.blackPoint, 0.001);
    y = y + p.brightness * y * (1.0 - y);
    y = pow(max(y, 0.001), 1.0 / max(p.gamma, 0.01));
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

    // 1) 全局饱和度：整体缩放色度向量（U=Cb, V=Cr 绕中性点 0.5）
    float2 c = (uv - 0.5) * p.saturation;

    // 2) 色度（黄色拉白，保留红色）：只把"黄色色相"那一段的色度往中性(白/灰)拉。
    //    NV12(BT.709 满范围)下色度平面 (Cb-0.5, Cr-0.5) 的色相角：黄≈175°、红≈103°，
    //    相差约 72°。用以黄色为中心的 ±45° 窗口加权，红色落在窗口外权重为 0 → 不受影响。
    if (p.chroma > 0.001) {
        if (length(c) > 0.0001) {
            float ang = atan2(c.y, c.x);              // c.x=Cb-0.5, c.y=Cr-0.5
            float d = fabs(ang - 3.054);              // 175° 对应弧度
            d = min(d, 2.0 * M_PI_F - d);             // 环绕到 [0, π]
            float w = clamp(1.0 - d / 0.785, 0.0, 1.0); // 45° 半窗 → 红色处 w=0
            w = w * w * (3.0 - 2.0 * w);              // smoothstep 平滑过渡
            c *= (1.0 - p.chroma * w);                // 黄色方向去色，拉向中性
        }
    }

    uv = clamp(0.5 + c, 0.0, 1.0);

    uvOut.write(float4(uv.r, uv.g, 0, 1), gid);
}
