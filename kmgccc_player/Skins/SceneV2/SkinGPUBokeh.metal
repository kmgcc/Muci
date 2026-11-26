// `bokeh` on a `render: "gpu"` layer: the lens loses focus for a moment and hunts for it again.
// The app's optional runtime library may carry its own source and gather passes for this filter;
// these are the defaults the layer falls back to.
//
// Every point of the layer spreads into the lens's aperture: a flat disc with a hard edge. The disc is a plain average
// in linear light, so text and shapes keep their outlines as rounded silhouettes. Highlights are
// lifted into scene light before the average and folded back after it by the exact inverse, so a
// bright point keeps its brightness as a clear disc while untouched areas return to their colour.
//
// The source has mip levels. The gather reads the level at which the disc spans a fixed number of
// texels, so its edge stays crisp at any radius and its cost stays bounded; it writes into the
// blur's level of the same size. The composite enlarges that level with a cubic B-spline and mixes
// it over the sharp surface by a weight that depends on the radius alone, so the lens can open and
// close any number of times without a step between the two images.

#include <metal_stdlib>
using namespace metal;

struct SkinBokehOut {
    float4 position [[position]];
    float2 uv;
};

struct SkinGPUBokehPost {
    float2 sourceSize;  // linear source pixels at level 0
    float2 surfaceSize; // the layer surface's pixels
    float radius;       // disc radius in source pixels at level 0
    float weight;       // share of the defocused image in the composite
    float breathing;    // the frame's scale about the centre, minus one
    float lift;         // highlight lift, 0 to below 1: white becomes 1 / (1 - lift)
    float lod;          // the source level the disc is read from
    float taps;         // taps over the disc
    float blurLevel;    // the blur level written by the gather and read by the composite
    float rings;        // used by the runtime gather when the app carries one
    float importance;   // used by the runtime gather
    float threshold;    // used by the runtime gather
    float swirl;        // used by the runtime gather
    float squash;       // used by the runtime gather
    float gain;         // unused
    float pad0;
    float pad1;
    float pad2;
};

/// The display's transfer curve (sRGB's, which Display P3 shares).
static float3 skinBokehEncode(float3 v) {
    v = max(v, float3(0));
    return select(1.055 * pow(v, float3(1.0 / 2.4)) - 0.055, v * 12.92, v <= 0.0031308);
}

static float3 skinBokehDecode(float3 v) {
    v = clamp(v, float3(0), float3(1));
    return select(pow((v + 0.055) / 1.055, float3(2.4)), v / 12.92, v <= 0.04045);
}

/// An encoded premultiplied texel as premultiplied scene light: the colour is scaled by
/// 1 / (1 - lift * m), m its brightest channel, so only what is near white is lifted much.
static float4 skinBokehSource(float4 c, float lift) {
    if (c.a <= 1e-4) { return float4(0); }
    float3 light = skinBokehDecode(c.rgb / c.a);
    float m = max(light.r, max(light.g, light.b));
    return float4(light * (c.a / (1.0 - lift * m)), c.a);
}

/// The surface reduced to the source: four bilinear taps over each source texel's footprint,
/// each lifted before they are averaged, so a moving scene does not shimmer.
fragment float4 skinGPUBokehSourceFragment(SkinBokehOut in [[stage_in]],
                                           constant SkinGPUBokehPost &post [[buffer(0)]],
                                           texture2d<float> surface [[texture(0)]],
                                           sampler linear [[sampler(0)]]) {
    float2 step = 0.25 / post.sourceSize;
    float4 sum = skinBokehSource(surface.sample(linear, in.uv + float2(-step.x, -step.y)), post.lift)
               + skinBokehSource(surface.sample(linear, in.uv + float2( step.x, -step.y)), post.lift)
               + skinBokehSource(surface.sample(linear, in.uv + float2(-step.x,  step.y)), post.lift)
               + skinBokehSource(surface.sample(linear, in.uv + float2( step.x,  step.y)), post.lift);
    return sum * 0.25;
}

/// The aperture: taps on a golden-angle spiral, evenly covering the disc at about one and a half
/// texels apart on the level they read, each tap's bilinear footprint closing the gaps between
/// them. The spiral turns by a fixed amount per pixel, so what remains of its pattern becomes a
/// fine grain the upscale smooths away.
fragment float4 skinGPUBokehGatherFragment(SkinBokehOut in [[stage_in]],
                                           constant SkinGPUBokehPost &post [[buffer(0)]],
                                           texture2d<float> source [[texture(0)]],
                                           sampler levels [[sampler(0)]]) {
    int count = int(post.taps);
    float radius = max(post.radius, 0.0);
    float2 scale = radius / post.sourceSize;
    // Interleaved gradient noise: a fixed turn per pixel.
    float noise = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
    float turn = noise * 6.28318531;
    float4 sum = float4(0);
    for (int index = 0; index < count; index++) {
        float r = sqrt((float(index) + 0.5) / float(count));
        float angle = float(index) * 2.39996323 + turn;
        sum += source.sample(levels, in.uv + float2(cos(angle), sin(angle)) * r * scale, level(post.lod));
    }
    return count > 0 ? sum / float(count) : float4(0);
}

/// A cubic B-spline lookup from four bilinear taps of one level.
static float4 skinBokehBSpline(texture2d<float> image, sampler levels, float2 uv, float2 size, float lod) {
    float2 position = uv * size - 0.5;
    float2 base = floor(position);
    float2 f = position - base;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 h0 = (base - 0.5 + w1 / g0) / size;
    float2 h1 = (base + 1.5 + w3 / g1) / size;
    return g0.x * g0.y * image.sample(levels, float2(h0.x, h0.y), level(lod))
         + g1.x * g0.y * image.sample(levels, float2(h1.x, h0.y), level(lod))
         + g0.x * g1.y * image.sample(levels, float2(h0.x, h1.y), level(lod))
         + g1.x * g1.y * image.sample(levels, float2(h1.x, h1.y), level(lod));
}

/// The defocused image over the sharp surface, both scaled about the centre by the focus
/// breathing. Scene light is folded back by the source's inverse, m / (1 + lift * m) on the
/// brightest channel, brought within white without changing its hue, and written in the
/// surface's encoding.
fragment float4 skinGPUBokehCompositeFragment(SkinBokehOut in [[stage_in]],
                                              constant SkinGPUBokehPost &post [[buffer(0)]],
                                              texture2d<float> surface [[texture(0)]],
                                              texture2d<float> blurred [[texture(1)]],
                                              sampler linear [[sampler(0)]],
                                              sampler levels [[sampler(1)]]) {
    float2 uv = 0.5 + (in.uv - 0.5) / (1.0 + post.breathing);
    float4 sharp = surface.sample(linear, uv);
    if (post.weight <= 0.0) { return sharp; }
    float2 size = max(floor(post.sourceSize / exp2(post.blurLevel)), float2(1));
    float4 soft = skinBokehBSpline(blurred, levels, uv, size, post.blurLevel);
    float alpha = clamp(soft.a, 0.0, 1.0);
    float4 encoded = float4(0);
    if (alpha > 1e-4) {
        float3 light = max(soft.rgb, float3(0)) / max(soft.a, 1e-4);
        light /= 1.0 + post.lift * max(light.r, max(light.g, light.b));
        // Light past white keeps its hue: the colour is scaled back as a whole.
        light /= max(1.0, max(light.r, max(light.g, light.b)));
        encoded = float4(skinBokehEncode(light) * alpha, alpha);
    }
    return mix(sharp, encoded, post.weight);
}
