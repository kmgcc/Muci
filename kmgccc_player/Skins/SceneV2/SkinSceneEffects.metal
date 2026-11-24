// Built-in skin effects: node `filter` presets, `bloom` and the `fog` node.
// SwiftUI draws them through layerEffect, colorEffect and distortionEffect; colours are premultiplied.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float skinHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float skinNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(skinHash(i), skinHash(i + float2(1, 0)), u.x),
               mix(skinHash(i + float2(0, 1)), skinHash(i + float2(1, 1)), u.x), u.y);
}

static float skinFbm(float2 p) {
    float value = 0.0, amplitude = 0.5;
    for (int octave = 0; octave < 4; octave++) {
        value += amplitude * skinNoise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        amplitude *= 0.5;
    }
    return value;
}

/// Red and blue sampled `amount` points apart along `angle` (radians).
[[stitchable]] half4 skinFxChromatic(float2 position, SwiftUI::Layer layer, float amount, float angle) {
    float2 shift = float2(cos(angle), sin(angle)) * amount;
    half4 centre = layer.sample(position);
    half4 red = layer.sample(position + shift);
    half4 blue = layer.sample(position - shift);
    return half4(red.r, centre.g, blue.b, max(max(red.a, centre.a), blue.a));
}

/// Horizontal bands of `slice` points jump sideways by up to `amount` on random ticks.
/// `rate` is ticks per second; `intensity` is the share of ticks that glitch.
[[stitchable]] half4 skinFxGlitch(float2 position, SwiftUI::Layer layer, float time, float amount, float slice, float rate, float intensity) {
    float tick = floor(time * max(0.1, rate));
    float active = step(1.0 - intensity, skinHash(float2(tick, 7.0)));
    float band = floor(position.y / max(1.0, slice));
    float coarse = floor(position.y / max(1.0, slice * 5.0));
    float moves = step(0.55, skinHash(float2(band, tick + 3.0))) * step(0.3, skinHash(float2(coarse, tick)));
    float shift = (skinHash(float2(band, tick)) - 0.5) * 2.0 * amount * active * moves;
    half4 base = layer.sample(position + float2(shift, 0));
    half4 red = layer.sample(position + float2(shift + amount * 0.2 * active, 0));
    return half4(red.r, base.g, base.b, max(base.a, red.a));
}

/// Averages `samples` taps along `vector`, centred on the pixel.
[[stitchable]] half4 skinFxMotionBlur(float2 position, SwiftUI::Layer layer, float2 vector, float samples) {
    int count = clamp(int(samples), 2, 24);
    half4 sum = half4(0);
    for (int index = 0; index < count; index++) {
        float t = float(index) / float(count - 1) - 0.5;
        sum += layer.sample(position + vector * t);
    }
    return sum / half(count);
}

/// Bright parts spread a glow of `radius`; it adds onto the source like plusLighter.
[[stitchable]] half4 skinFxBloom(float2 position, SwiftUI::Layer layer, float radius, float intensity, float threshold) {
    half4 base = layer.sample(position);
    float4 sum = float4(0);
    float total = 0.0;
    float turn = skinHash(position) * 6.2831853;
    const int count = 24;
    for (int index = 0; index < count; index++) {
        float f = (float(index) + 0.5) / float(count);
        float angle = float(index) * 2.39996323 + turn;
        float4 tap = float4(layer.sample(position + float2(cos(angle), sin(angle)) * radius * sqrt(f)));
        float light = dot(tap.rgb, float3(0.299, 0.587, 0.114));
        float weight = 1.0 - f * 0.7;
        sum += tap * weight * smoothstep(threshold, threshold + 0.15, light);
        total += weight;
    }
    float4 glow = sum / total * intensity;
    return half4(min(float4(base) + glow, float4(1)));
}

/// Dark horizontal lines every `spacing` points, scrolling at `speed` points per second.
[[stitchable]] half4 skinFxScanlines(float2 position, half4 color, float time, float spacing, float intensity, float speed) {
    float line = 0.5 + 0.5 * cos(6.2831853 * (position.y + time * speed) / max(1.0, spacing));
    return color * half(1.0 - intensity * line);
}

/// Film grain of `amount`, held by the caller's tick, as a GPU layer draws it: one grain per
/// point from three uniform draws (close to a Gaussian), no clumps; highlights keep about half.
[[stitchable]] half4 skinFxGrain(float2 position, half4 color, float time, float amount) {
    float2 point = floor(position);
    float seed = fract(time * 13.7) * 431.0;
    float grain = (skinHash(point + seed) + skinHash(point.yx * 1.31 + seed * 0.71)
                   + skinHash(point + float2(17.3, 5.9) + seed * 1.37) - 1.5) * 0.55;
    float alpha = float(color.a);
    float luma = clamp(dot(float3(color.rgb), float3(0.299, 0.587, 0.114)) / max(alpha, 0.001), 0.0, 1.0);
    float weight = mix(1.0, 0.5, smoothstep(0.35, 1.0, luma));
    return half4(clamp(color.rgb + half(grain * amount * weight) * color.a, half3(0), half3(color.a)), color.a);
}

/// The `lut` filter: a 3D colour grade stored as a strip of blue slices (`n` slices of `n` × `n`,
/// red across, green down), read with two bilinear taps and a blend between slices, mixed in by
/// `amount`. Colours are unpremultiplied for the lookup.
[[stitchable]] half4 skinFxLUT(float2 position, half4 color, texture2d<half> lut, float amount) {
    float alpha = float(color.a);
    if (alpha <= 0.0005) { return color; }
    constexpr sampler strip(filter::linear, address::clamp_to_edge);
    float3 rgb = clamp(float3(color.rgb) / alpha, float3(0), float3(1));
    float n = float(lut.get_height());
    float blue = rgb.b * (n - 1.0);
    float b0 = floor(blue), b1 = min(b0 + 1.0, n - 1.0);
    float x = rgb.r * (n - 1.0) + 0.5, y = (rgb.g * (n - 1.0) + 0.5) / n;
    float3 low = float3(lut.sample(strip, float2((x + b0 * n) / (n * n), y)).rgb);
    float3 high = float3(lut.sample(strip, float2((x + b1 * n) / (n * n), y)).rgb);
    float3 graded = mix(low, high, blue - b0);
    return half4(half3(mix(rgb, graded, amount) * alpha), color.a);
}

/// A slow liquid sway of `amplitude` points.
[[stitchable]] float2 skinFxWave(float2 position, float time, float amplitude, float wavelength, float speed) {
    float k = 6.2831853 / max(1.0, wavelength);
    return position + float2(sin(position.y * k + time * speed) * amplitude,
                             cos(position.x * k * 0.7 + time * speed * 0.8) * amplitude * 0.5);
}

/// Domain-warped fbm between `low` and `high`. `feature` is the size of one fog bank in points;
/// `scroll` slides the field under the frame, so it reaches on without end.
[[stitchable]] half4 skinFxFog(float2 position, half4 color, float time, float feature, float speed, float warp, float gain, half4 low, half4 high, float2 scroll) {
    float2 p = (position + scroll) / max(1.0, feature);
    float t = time * speed;
    float2 q = float2(skinFbm(p + float2(0.0, t * 0.6)), skinFbm(p + float2(5.2, 1.3) - float2(t * 0.4, 0.0)));
    float n = skinFbm(p + warp * q + float2(t * 0.25, -t * 0.15));
    n = clamp((n - 0.5) * gain + 0.5, 0.0, 1.0);
    return mix(low, high, half(n)) * color.a;
}

/// The `light` gradient, as a GPU layer draws it: inverse-square falloff softened inside `core`
/// (a share of the half size), encoded for the display, windowed to zero at the frame's edge,
/// whitened at the core and dithered so the long ramp never bands. `light` is premultiplied.
[[stitchable]] half4 skinFxLight(float2 position, half4 color, float2 size, half4 light, float core, float2 centre) {
    float2 q = (position / max(size, float2(1)) - centre) * 2.0;
    float d = length(q);
    if (d >= 1.0) { return half4(0); }
    float k = max(core, 1e-3);
    float intensity = 1.0 / (1.0 + (d / k) * (d / k));
    float encoded = intensity <= 0.0031308 ? intensity * 12.92 : 1.055 * pow(intensity, 1.0 / 2.4) - 0.055;
    float window = 1.0 - d * d * d * d;
    float4 lit = float4(light) * encoded * window * window;
    lit.rgb = mix(lit.rgb, float3(lit.a), 0.5 * intensity * intensity * intensity * intensity);
    float dither = (skinHash(position + 0.37) + skinHash(position.yx + 11.3) - 1.0) / 255.0;
    lit.rgb += dither * lit.a;
    return half4(lit * float(color.a));
}
