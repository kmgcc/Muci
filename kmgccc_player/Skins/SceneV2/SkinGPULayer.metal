// A `render: "gpu"` layer: its shapes, gradients, fog and particles drawn in one Metal pass at a
// reduced resolution, then scaled up to the window with film grain in a second pass.
// Colours are premultiplied, in the drawable's colour space.

#include <metal_stdlib>
using namespace metal;

struct SkinGPUFrame {
    float2 size;        // layer size in points
    float time;         // grain time in seconds
    float grain;        // grain amount
    float pointScale;   // drawable pixels per point
    float pad0, pad1, pad2;
};

struct SkinGPUQuad {
    float2 origin;      // layer point of the node's top-left corner
    float2 localSize;   // node size in points
    float scale;        // camera scale of the node
    int kind;           // 0 solid, 1 gradient, 2 fog
    int stopCount;
    float opacity;
    float4 color;       // solid colour; fog low
    float4 color2;      // fog high
    float4 params;      // gradient: radius, centre x, centre y, mode; fog: time, feature, speed, warp
    float4 params2;     // gradient: start x, start y, end x, end y (points); fog: gain, scroll x, scroll y
};

struct SkinGPUDot {
    float2 centre;
    float2 streak;      // motion blur vector, centred on the dot
    float radius;
    float soft;
    float2 pad;
    float4 color;
};

struct SkinGPUVertex {
    float2 position;
    float2 pad;
    float4 color;
};

struct SkinQuadOut {
    float4 position [[position]];
    float2 local;
};

struct SkinDotOut {
    float4 position [[position]];
    float2 offset;
    float2 streak [[flat]];
    float radius [[flat]];
    float soft [[flat]];
    float4 color [[flat]];
};

struct SkinColorOut {
    float4 position [[position]];
    float4 color;
};

struct SkinPresentOut {
    float4 position [[position]];
    float2 uv;
};

static float4 skinGPUClip(float2 point, float2 size) {
    float2 unit = point / max(size, float2(1));
    return float4(unit.x * 2 - 1, 1 - unit.y * 2, 0, 1);
}

static float skinGPUHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float skinGPUNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(skinGPUHash(i), skinGPUHash(i + float2(1, 0)), u.x),
               mix(skinGPUHash(i + float2(0, 1)), skinGPUHash(i + float2(1, 1)), u.x), u.y);
}

static float skinGPUFbm(float2 p) {
    float value = 0.0, amplitude = 0.5;
    for (int octave = 0; octave < 4; octave++) {
        value += amplitude * skinGPUNoise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        amplitude *= 0.5;
    }
    return value;
}

vertex SkinQuadOut skinGPUQuadVertex(uint vid [[vertex_id]],
                                     constant SkinGPUFrame &frame [[buffer(0)]],
                                     constant SkinGPUQuad &quad [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1)) * quad.localSize;
    SkinQuadOut out;
    out.position = skinGPUClip(quad.origin + corner * quad.scale, frame.size);
    out.local = corner;
    return out;
}

static float4 skinGPUStops(float t, constant float4 *stops, int count) {
    // stops[0..7] are colours, stops[8..9] hold the eight locations.
    if (count <= 0) return float4(0);
    constant float *at = (constant float *)(stops + 8);
    if (t <= at[0]) return stops[0];
    for (int index = 1; index < count; index++) {
        if (t <= at[index]) {
            float span = max(1e-4, at[index] - at[index - 1]);
            return mix(stops[index - 1], stops[index], (t - at[index - 1]) / span);
        }
    }
    return stops[count - 1];
}

fragment float4 skinGPUQuadFragment(SkinQuadOut in [[stage_in]],
                                    constant SkinGPUQuad &quad [[buffer(1)]],
                                    constant float4 *stops [[buffer(2)]]) {
    float4 color;
    if (quad.kind == 0) {
        color = quad.color;
    } else if (quad.kind == 1) {
        float2 size = max(quad.localSize, float2(1));
        float t;
        int mode = int(quad.params.w);
        if (mode == 1) {
            float2 centre = quad.params.yz * size;
            t = length(in.local - centre) / max(1.0, quad.params.x * max(size.x, size.y));
        } else if (mode == 2) {
            t = length(in.local / size - quad.params.yz) / max(1e-4, quad.params.x);
        } else {
            float2 a = quad.params2.xy, b = quad.params2.zw;
            float2 axis = b - a;
            t = dot(in.local - a, axis) / max(1e-4, dot(axis, axis));
        }
        color = skinGPUStops(clamp(t, 0.0, 1.0), stops, quad.stopCount);
    } else {
        float2 p = (in.local + quad.params2.yz) / max(1.0, quad.params.y);
        float t = quad.params.x * quad.params.z;
        float warp = quad.params.w, gain = quad.params2.x;
        float2 q = float2(skinGPUFbm(p + float2(0.0, t * 0.6)), skinGPUFbm(p + float2(5.2, 1.3) - float2(t * 0.4, 0.0)));
        float n = skinGPUFbm(p + warp * q + float2(t * 0.25, -t * 0.15));
        n = clamp((n - 0.5) * gain + 0.5, 0.0, 1.0);
        color = mix(quad.color, quad.color2, n);
    }
    return color * quad.opacity;
}

vertex SkinDotOut skinGPUDotVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant SkinGPUFrame &frame [[buffer(0)]],
                                   const device SkinGPUDot *dots [[buffer(1)]]) {
    SkinGPUDot dot = dots[iid];
    float reach = dot.radius + 2.0 * dot.soft + 1.0;
    float length2 = length(dot.streak);
    float2 along = length2 > 1e-3 ? dot.streak / length2 : float2(1, 0);
    float2 across = float2(-along.y, along.x);
    float2 sign = float2(float(vid & 1), float(vid >> 1)) * 2.0 - 1.0;
    float2 offset = along * sign.x * (reach + length2 * 0.5) + across * sign.y * reach;
    SkinDotOut out;
    out.position = skinGPUClip(dot.centre + offset, frame.size);
    out.offset = offset;
    out.streak = dot.streak;
    out.radius = dot.radius;
    out.soft = dot.soft;
    out.color = dot.color;
    return out;
}

fragment float4 skinGPUDotFragment(SkinDotOut in [[stage_in]]) {
    // Distance to the blur segment, so a moving dot draws as a short streak.
    float2 half_ = in.streak * 0.5;
    float h = dot(half_, half_) > 1e-6 ? clamp(dot(in.offset + half_, in.streak) / dot(in.streak, in.streak), 0.0, 1.0) : 0.5;
    float d = length(in.offset + half_ - in.streak * h);
    float r = in.radius, s = in.soft;
    float coverage;
    if (s <= 0.05) {
        coverage = clamp(r - d + 0.5, 0.0, 1.0);
    } else {
        // The same feathered edge the Canvas path draws as a radial gradient.
        if (d <= r - s) coverage = 1.0;
        else if (d <= r) coverage = mix(1.0, 0.5, (d - (r - s)) / max(1e-4, s));
        else if (d <= r + s) coverage = mix(0.5, 0.12, (d - r) / max(1e-4, s));
        else coverage = mix(0.12, 0.0, clamp((d - r - s) / max(1e-4, s), 0.0, 1.0));
    }
    // A blur spreads the same ink along its length.
    float body = 2.0 * (r + s);
    coverage *= body / (body + length(in.streak));
    return in.color * coverage;
}

vertex SkinColorOut skinGPURibbonVertex(uint vid [[vertex_id]],
                                        constant SkinGPUFrame &frame [[buffer(0)]],
                                        const device SkinGPUVertex *vertices [[buffer(1)]]) {
    SkinColorOut out;
    out.position = skinGPUClip(vertices[vid].position, frame.size);
    out.color = vertices[vid].color;
    return out;
}

fragment float4 skinGPURibbonFragment(SkinColorOut in [[stage_in]]) {
    return in.color;
}

vertex SkinPresentOut skinGPUPresentVertex(uint vid [[vertex_id]]) {
    float2 corner = float2(float((vid << 1) & 2), float(vid & 2));
    SkinPresentOut out;
    out.position = float4(corner * 2.0 - 1.0, 0, 1);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 skinGPUPresentFragment(SkinPresentOut in [[stage_in]],
                                       constant SkinGPUFrame &frame [[buffer(0)]],
                                       texture2d<float> scene [[texture(0)]],
                                       sampler linear [[sampler(0)]]) {
    float4 color = scene.sample(linear, in.uv);
    if (frame.grain > 0) {
        // Film grain per point, as the `grain` filter draws it.
        float2 point = floor(in.position.xy / max(1.0, frame.pointScale));
        float grain = skinGPUHash(point + fract(frame.time * 13.7) * 431.0) - 0.5;
        color.rgb = clamp(color.rgb + grain * frame.grain * color.a, float3(0), float3(1));
    }
    return color;
}
