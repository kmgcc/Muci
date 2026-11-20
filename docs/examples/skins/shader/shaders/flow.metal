// The full signature: uniforms plus SkinInputs (artwork, previous frame, spectrum, waveform,
// args and package images). The short form `skinColor(float2 uv, constant SkinUniforms& u,
// texture2d<float> artwork)` still works when only the artwork is needed.
float4 skinColor(float2 uv, constant SkinUniforms& u, SkinInputs in) {
    float2 drift = float2(sin(uv.y * 6.0 + u.time * 0.3), cos(uv.x * 5.0 - u.time * 0.2));
    float2 p = clamp(uv + drift * (0.025 + u.bass * 0.045), 0.0, 1.0);
    float3 cover = skinArtwork(in, p, 2.0).rgb;
    float glow = 0.5 + 0.5 * sin((p.x + p.y) * 4.0 + u.time * 0.15);
    float3 tint = skinArg(in, 0).rgb;
    float3 color = mix(cover * 0.38, tint * 0.55, glow * 0.35);

    // A soft band of light along the bottom follows the spectrum.
    float level = skinSpectrum(in, uv.x);
    color += tint * smoothstep(0.0, 0.35, level - (1.0 - uv.y) * 1.6) * 0.25;

    // The previous frame, drawn slightly upward and dimmed, leaves a slow trail.
    float3 trail = skinPrevious(in, uv + float2(0.0, 0.0015)).rgb;
    return float4(max(color, trail * 0.965), 1.0);
}
