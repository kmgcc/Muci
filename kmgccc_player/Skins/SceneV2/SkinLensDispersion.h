#pragma once

#include <metal_stdlib>
using namespace metal;

// Overlapping wavelength bands. Each RGB column sums to one, preserving flat colours.
static inline float4 skinLensDispersion(float4 red, float4 yellow, float4 centre, float4 cyan, float4 blue) {
    const float3 longWave = float3(0.37, 0.02, 0.00);
    const float3 yellowGreen = float3(0.24, 0.27, 0.03);
    const float3 middle = float3(0.36, 0.42, 0.36);
    const float3 greenCyan = float3(0.03, 0.27, 0.24);
    const float3 shortWave = float3(0.00, 0.02, 0.37);
    float3 rgb = longWave * red.rgb + yellowGreen * yellow.rgb + middle * centre.rgb
               + greenCyan * cyan.rgb + shortWave * blue.rgb;
    float3 coverage = longWave * red.a + yellowGreen * yellow.a + middle * centre.a
                    + greenCyan * cyan.a + shortWave * blue.a;
    // Only the common coverage occludes the backdrop. The extra coverage carries the fringe's light.
    float shared = min(coverage.r, min(coverage.g, coverage.b));
    return float4(rgb, saturate(max(shared, max(rgb.r, max(rgb.g, rgb.b)))));
}
