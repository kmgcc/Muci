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
    // The camera's turn (rotationX, rotationY with perspective, then rotation) as a plane
    // homography in layer points, by columns: (x, y, 1) -> (x', y', w).
    float4 turn0, turn1, turn2;
};

struct SkinGPUGlyph {
    float4 affine0;     // a, b, c, d: glyph points (baseline origin, y down) to layer points
    float4 affine1;     // tx, ty
    float4 rect;        // the texture's rectangle in glyph points: origin, size
    float4 color;       // premultiplied ink
    float4 motion;      // split (uv), smear x, smear y (uv), blur mip level
    float4 extra;       // quad expansion (uv), opacity, texel size x, texel size y
};

struct SkinGPUPost {
    float2 size;        // surface pixels
    float distortion;
    float chromatic;    // pixels
    float blur;         // pixels
    float start;
    float2 axis;
    float grain;
    float time;
    float pointScale;   // surface pixels per point
    float pad;
};

struct SkinGPUQuad {
    float2 origin;      // layer point of the node's top-left corner
    float2 localSize;   // node size in points
    float scale;        // camera scale of the node
    int kind;           // 0 solid, 1 gradient, 2 fog, 3 ellipse outline
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
    float2 edge;        // signed distance from a stroke's centre line, the stroke's half width (0: solid)
    float4 color;
    float4 blur;        // the stroke's blur (standard deviation), all in layer points
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
    float distance;
    float halfWidth [[flat]];
    float blur [[flat]];
};

static float skinGPUErf(float x) {
    float x2 = x * x;
    float t = sqrt(1.0 - exp(-x2 * (1.27323954 + 0.147 * x2) / (1.0 + 0.147 * x2)));
    return x < 0 ? -t : t;
}

/// Coverage at signed distance `d` from the centre of a band `2 * halfWidth` wide under a
/// Gaussian blur of `sigma`; `aa` (one pixel) keeps a sharp band's edge smooth.
static float skinGPUBand(float d, float halfWidth, float sigma, float aa) {
    float s = sqrt(sigma * sigma + 0.16 * aa * aa);
    float k = 0.70710678 / max(s, 1e-4);
    return clamp(0.5 * (skinGPUErf((d + halfWidth) * k) - skinGPUErf((d - halfWidth) * k)), 0.0, 1.0);
}

struct SkinPresentOut {
    float4 position [[position]];
    float2 uv;
};

/// A layer point through the camera's turn, as a clip position. The homogeneous w is kept, so
/// textures and gradients stay perspective-correct across a tilted quad.
static float4 skinGPUClip(float2 point, constant SkinGPUFrame &frame) {
    float3 h = frame.turn0.xyz * point.x + frame.turn1.xyz * point.y + frame.turn2.xyz;
    float w = max(h.z, 1e-3);
    float2 size = max(frame.size, float2(1));
    return float4(2 * h.x / size.x - w, w - 2 * h.y / size.y, 0, w);
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
    out.position = skinGPUClip(quad.origin + corner * quad.scale, frame);
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
    } else if (quad.kind == 3) {
        // An ellipse's outline (`color`) and optional fill (`color2`): params hold the stroke's
        // half width, blur, and the radii; params2 the centre, in the quad's local points.
        float2 p = in.local - quad.params2.xy;
        float2 r = max(quad.params.zw, float2(1e-3));
        float k = length(p / r);
        float g = max(length(p / (r * r)), 1e-5);
        float d = (k - 1.0) * k / g;
        float aa = max(fwidth(d), 1e-3);
        float ring = skinGPUBand(d, quad.params.x, quad.params.y, aa);
        float inside = clamp(0.5 - d / aa, 0.0, 1.0);
        color = quad.color * ring + quad.color2 * inside * (1.0 - quad.color.a * ring);
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
    out.position = skinGPUClip(dot.centre + offset, frame);
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
    out.position = skinGPUClip(vertices[vid].position, frame);
    out.color = vertices[vid].color;
    out.distance = vertices[vid].edge.x;
    out.halfWidth = vertices[vid].edge.y;
    out.blur = vertices[vid].blur.x;
    return out;
}

fragment float4 skinGPURibbonFragment(SkinColorOut in [[stage_in]]) {
    // A comet tail is solid; a stroke fades across its width.
    if (in.halfWidth <= 0) { return in.color; }
    return in.color * skinGPUBand(in.distance, in.halfWidth, in.blur, fwidth(in.distance));
}

vertex SkinPresentOut skinGPUPresentVertex(uint vid [[vertex_id]]) {
    float2 corner = float2(float((vid << 1) & 2), float(vid & 2));
    SkinPresentOut out;
    out.position = float4(corner * 2.0 - 1.0, 0, 1);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 skinGPUPresentFragment(SkinPresentOut in [[stage_in]],
                                       constant SkinGPUPost &post [[buffer(0)]],
                                       texture2d<float> scene [[texture(0)]],
                                       sampler linear [[sampler(0)]]) {
    float4 color = scene.sample(linear, in.uv);
    if (post.grain > 0) {
        // Film grain per point, as the `grain` filter draws it.
        float2 point = floor(in.position.xy / max(1.0, post.pointScale));
        float grain = skinGPUHash(point + fract(post.time * 13.7) * 431.0) - 0.5;
        color.rgb = clamp(color.rgb + grain * post.grain * color.a, float3(0), float3(1));
    }
    return color;
}

// MARK: Glyphs

struct SkinGlyphOut {
    float4 position [[position]];
    float2 uv;
};

vertex SkinGlyphOut skinGPUGlyphVertex(uint vid [[vertex_id]],
                                       constant SkinGPUFrame &frame [[buffer(0)]],
                                       constant SkinGPUGlyph &glyph [[buffer(1)]]) {
    float expand = glyph.extra.x;
    float2 uv = float2(float(vid & 1), float(vid >> 1)) * (1 + 2 * expand) - expand;
    float2 local = glyph.rect.xy + uv * glyph.rect.zw;
    float2 point = float2(glyph.affine0.x * local.x + glyph.affine0.z * local.y + glyph.affine1.x,
                          glyph.affine0.y * local.x + glyph.affine0.w * local.y + glyph.affine1.y);
    SkinGlyphOut out;
    out.position = skinGPUClip(point, frame);
    out.uv = uv;
    return out;
}

/// A disc of taps on a golden-angle spiral, evenly spread over the unit circle.
constant float2 skinBlurDisc[16] = {
    float2(0.1768, 0.0000), float2(-0.2258, 0.2068), float2(0.0346, -0.3938), float2(0.2846, 0.3712),
    float2(-0.5222, -0.0924), float2(0.4947, -0.3147), float2(-0.1655, 0.6155), float2(-0.3156, -0.6076),
    float2(0.6846, 0.2500), float2(-0.7123, 0.2940), float2(0.3434, -0.7337), float2(0.2537, 0.8089),
    float2(-0.7647, -0.4432), float2(0.8971, -0.1972), float2(-0.5475, 0.7788), float2(-0.1265, -0.9761)
};

/// Coverage at `uv`, blurred like a Gaussian of `sigma` mask texels. A mip level carries part
/// of the blur, kept fine enough that the mask stays at least two texels across; a weighted
/// disc of taps carries the rest. `fine` false trades the disc for four taps, for the copies a
/// smear or split multiplies.
static float skinGlyphCoverage(texture2d<float> mask, sampler s, float2 uv, float sigma, float screenLod, float2 texel, bool fine) {
    if (sigma < 0.35) { return mask.sample(s, uv, level(screenLod)).r; }
    float shortest = float(min(mask.get_width(), mask.get_height()));
    float lod = max(screenLod, min(log2(1.5 * sigma), max(0.0, log2(shortest) - 1.0)));
    float box = exp2(lod) * 0.2887;
    float spread = sqrt(max(sigma * sigma - box * box, 0.0));
    if (spread < 0.5) { return mask.sample(s, uv, level(lod)).r; }
    if (!fine) {
        // Half a level texel apart at most, so the four taps blend rather than show as copies.
        float2 step = texel * min(spread, exp2(lod)) * 0.5;
        float sum = mask.sample(s, uv + float2(step.x, step.y), level(lod)).r
                  + mask.sample(s, uv + float2(-step.x, step.y), level(lod)).r
                  + mask.sample(s, uv + float2(step.x, -step.y), level(lod)).r
                  + mask.sample(s, uv + float2(-step.x, -step.y), level(lod)).r;
        return sum * 0.25;
    }
    // Taps out to two deviations, weighted by the Gaussian at their distance.
    float2 reach = texel * spread * 2.0;
    float sum = mask.sample(s, uv, level(lod)).r, weight = 1.0;
    for (int i = 0; i < 16; i++) {
        float2 d = skinBlurDisc[i];
        float w = exp(-2.0 * dot(d, d));
        sum += w * mask.sample(s, uv + d * reach, level(lod)).r;
        weight += w;
    }
    return sum / weight;
}

fragment float4 skinGPUGlyphFragment(SkinGlyphOut in [[stage_in]],
                                     constant SkinGPUGlyph &glyph [[buffer(1)]],
                                     texture2d<float> mask [[texture(0)]],
                                     sampler s [[sampler(0)]]) {
    float split = glyph.motion.x;
    float2 smear = glyph.motion.yz;
    // The blur (a deviation in mask texels), over the level the glyph's on-screen size reads anyway.
    float sigma = glyph.motion.w;
    float screenLod = mask.calculate_clamped_lod(s, in.uv);
    float2 texel = glyph.extra.zw;
    // A smear averages copies along its vector; a split draws red and blue apart, as the view
    // renderer's channel copies do.
    int copies = (abs(smear.x) + abs(smear.y)) > 1e-4 ? 6 : 1;
    bool fine = copies == 1 && abs(split) <= 1e-5;
    float3 coverage = float3(0);
    for (int i = 0; i < copies; i++) {
        float t = copies > 1 ? float(i) / float(copies - 1) - 0.5 : 0.0;
        float2 uv = in.uv - smear * t;
        float g = skinGlyphCoverage(mask, s, uv, sigma, screenLod, texel, fine);
        if (abs(split) > 1e-5) {
            coverage += float3(skinGlyphCoverage(mask, s, uv - float2(split, 0), sigma, screenLod, texel, false), g,
                               skinGlyphCoverage(mask, s, uv + float2(split, 0), sigma, screenLod, texel, false));
        } else {
            coverage += float3(g);
        }
    }
    coverage /= float(copies);
    float4 ink = glyph.color;
    float alpha = abs(split) > 1e-5 ? min(1.0, ink.a * (coverage.r + coverage.g + coverage.b)) : ink.a * coverage.g;
    return float4(ink.rgb * coverage, alpha) * glyph.extra.y;
}

// MARK: Lens (`fov`)

static float skinGPUEdge(float2 position, float2 size, float edgeStart) {
    float2 half_ = max(size * 0.5, float2(1.0));
    float2 c = (position - size * 0.5) / half_;
    float r = length(c) * 0.70710678;
    return smoothstep(clamp(edgeStart, 0.0, 0.98), 1.0, r);
}

fragment float4 skinGPULensFragment(SkinPresentOut in [[stage_in]],
                                    constant SkinGPUPost &post [[buffer(0)]],
                                    texture2d<float> scene [[texture(0)]],
                                    sampler linear [[sampler(0)]]) {
    float2 size = post.size, position = in.position.xy;
    float2 centre = size * 0.5;
    float2 c = (position - centre) / max(centre, float2(1));
    float r2 = dot(c, c) * 0.5;
    float2 source = centre + (position - centre) * (1.0 - clamp(post.distortion, -0.6, 0.6) * 0.35 * r2);
    float edge = skinGPUEdge(position, size, post.start);
    float2 radial = length(c) > 1e-4 ? normalize(position - centre) : float2(0.0);
    float2 split = radial * max(0.0, post.chromatic) * edge;
    float4 g = scene.sample(linear, clamp(source, float2(0), size) / size);
    if (post.chromatic <= 0.0 || edge <= 0.0) { return g; }
    float4 r = scene.sample(linear, clamp(source + split, float2(0), size) / size);
    float4 b = scene.sample(linear, clamp(source - split, float2(0), size) / size);
    return float4(r.r, g.g, b.b, max(g.a, max(r.a, b.a)));
}

fragment float4 skinGPUEdgeBlurFragment(SkinPresentOut in [[stage_in]],
                                        constant SkinGPUPost &post [[buffer(0)]],
                                        texture2d<float> scene [[texture(0)]],
                                        sampler linear [[sampler(0)]]) {
    float2 size = post.size, position = in.position.xy;
    float edge = skinGPUEdge(position, size, post.start);
    float reach = max(0.0, post.blur) * edge * edge;
    if (reach < 0.4) { return scene.sample(linear, position / size); }
    int taps = int(min(8.0, max(ceil(reach * 0.5), min(4.0, ceil(reach)))));
    float spacing = reach / float(taps);
    float sigma = reach * 0.5;
    float falloff = 1.0 / (2.0 * sigma * sigma);
    float4 sum = scene.sample(linear, position / size);
    float weight = 1.0;
    for (int i = 1; i <= taps; i++) {
        float d = spacing * float(i);
        float w = exp(-d * d * falloff);
        sum += w * scene.sample(linear, clamp(position + post.axis * d, float2(0), size) / size);
        sum += w * scene.sample(linear, clamp(position - post.axis * d, float2(0), size) / size);
        weight += 2.0 * w;
    }
    return sum / weight;
}
