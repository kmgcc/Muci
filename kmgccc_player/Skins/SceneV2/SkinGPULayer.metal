// A `render: "gpu"` layer: its shapes, gradients, fog and particles drawn in one Metal pass at a
// reduced resolution, then scaled up to the window with film grain in a second pass.
// Colours are premultiplied, in the drawable's colour space.

#include <metal_stdlib>
#include "SkinLensDispersion.h"
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
    float2 size;        // destination pixels
    float distortion;
    float chromatic;    // pixels
    float blur;         // pixels
    float start;
    float2 axis;
    float grain;
    float time;
    float pointScale;   // surface pixels per point
    float lut;          // colour lookup strength, last pass only
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
    float4 params;      // gradient: radius, centre x, centre y, mode (0 linear, 1 radial, 2 elliptical, 3 light); fog: time, feature, speed, warp
    float4 params2;     // gradient: start x, start y, end x, end y (points); fog: gain, scroll x, scroll y
    float4 velocity;    // layer points travelled this frame, for motion blur (xy)
    float4 brush;       // ellipse outline: brush amount, dry, wobble, seed; amount 0 is smooth; fog zones: share, scroll x, scroll y
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
    float4 brush;       // a painted stroke: place across (±1 at the edges), along, dry threshold, amount
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

// MARK: Brush (the flat brush of the brush art plan, drawn in one pass)

/// Painted-brush coverage at `v` across a stroke (±1 at its edges) and `a` along it, in stroke
/// widths and fixed to where the paint was laid. `need` is the dry-brush threshold: 0 lays solid
/// paint; towards 1 only the densest bristles still leave ink. `amount` (0…1) scales the
/// texture: torn edges, bristle streaks and the tone between them. `aa` is one pixel in `v`,
/// widened by any blur; `px` is the stroke's full width in pixels.
/// Returns the coverage times the paint's tone.
static float skinGPUBrushDetail(float n, float wavelength) {
    // Noise finer than a few pixels would alias into burrs and specks, so it settles to its mean.
    return mix(0.5, n, smoothstep(1.0, 3.0, wavelength));
}

static float skinGPUBrush(float v, float a, float need, float seed, float amount, float aa, float px) {
    px = max(px, 1e-3);
    // Out of focus, the texture melts away with the edge.
    float pixel = 2.0 / px;
    float defocus = sqrt(max(0.0, aa * aa - pixel * pixel));
    amount *= 1.0 / (1.0 + 2.0 * defocus * defocus);
    float s = fract(seed * 0.618034) * 97.0;
    // Every stroke takes its own brush: four to eight stiff hairs, some rougher than others.
    float hairs = 4.0 + floor(5.0 * fract(s * 0.37));
    float rough = 0.7 + 0.7 * fract(s * 0.71);
    // A dry, stiff brush loaded with oil paint: the outline wavers slowly and is ragged where
    // hairs end at different places (`a` is in stroke widths, so a noise of frequency f along it
    // spans px / f pixels).
    float side = v < 0.0 ? 0.0 : 31.7;
    float waver = 0.65 * skinGPUBrushDetail(skinGPUNoise(float2(a * 0.6 + side, s)), px / 0.6)
                + 0.35 * skinGPUBrushDetail(skinGPUNoise(float2(a * 1.8 + side, s + 5.0)), px / 1.8);
    float ragged = skinGPUBrushDetail(skinGPUNoise(float2(a * 4.5 + side, s + 9.0)), px / 4.5);
    float edge = 1.0 - amount * rough * (0.28 * waver + 0.3 * ragged);
    float body = clamp((edge - abs(v)) / max(aa, 1e-4) + 0.5, 0.0, 1.0);
    if (body <= 0.0) { return 0.0; }
    // The hairs across, each with its own load of paint, dragging long streaks along the
    // stroke that break off where that hair runs dry.
    float b = (v * 0.5 + 0.5) * hairs;
    float resolved = smoothstep(1.0, 2.5, px / hairs);
    float hair = skinGPUBrushDetail(skinGPUNoise(float2(b, s * 1.7)), px / hairs);
    float drag = skinGPUBrushDetail(skinGPUNoise(float2(b * 1.3 + 13.0, a * 0.22 + s)), px / (hairs * 1.3));
    float density = mix(0.55, 0.55 * hair + 0.45 * drag, amount);
    // The edges hold the least paint, so they break into streaks first.
    density -= amount * rough * 0.35 * smoothstep(0.3, 1.0, abs(v));
    // Oil paint either covers or skips, with a crisp edge to each gap; where the hairs are too
    // fine to draw, a dry brush thins the paint evenly instead of breaking it up.
    float threshold = need + 0.12 * amount;
    float spread = 0.03 + 0.3 * (1.0 - resolved);
    float ink = smoothstep(threshold - spread, threshold + spread, density);
    // Dragged dry over the canvas, the paint catches only on the weave's tops.
    float dryness = smoothstep(0.15, 0.6, threshold);
    float tooth = skinGPUBrushDetail(skinGPUNoise(float2(b * 2.0 + 5.0, a * 1.2 + s)), min(px / 12.0, px / 1.2));
    ink *= mix(1.0, smoothstep(0.3, 0.5, tooth), amount * dryness);
    // Ridges of paint along the hairs catch a little more light than the furrows.
    float tone = 1.0 + amount * 0.28 * (hair - 0.5);
    return body * ink * tone;
}

/// A ring painted the way a wide band is filled in by hand: many short strokes laid along it,
/// three lanes across, each landing blunt and lifting off thin, a little slanted, with its own
/// torn edges and bristle streaks, overlapping its neighbours. The band keeps the ring's shape;
/// only its edges come out ragged. `d` is the distance from the outline, `p` the point from the
/// centre, `r` the radii; `brush` holds amount, dry, wobble and seed.
static float skinGPUBrushRing(float d, float2 p, float2 r, float halfWidth, float sigma, float aa, float4 brush) {
    float amount = min(brush.x, 1.0), dry = brush.y, wobble = brush.z;
    float seed = fract(brush.w * 0.618034) * 89.0;
    float hw = max(halfWidth, 1e-3);
    float mean = 0.5 * (r.x + r.y);
    float turn = atan2(p.y / r.y, p.x / r.x) / 6.2831853 + 0.5;
    // The outline itself barely wavers.
    float drift = wobble * 0.12 * hw * (skinGPUNoise(float2(turn * 11.0, seed)) - 0.5);
    float w = (d - drift) / hw;
    float soft = sqrt(aa * aa + 6.25 * sigma * sigma) / hw;
    // Places along the ring in band widths, cut into a whole number of cells so the strokes meet
    // across the seam.
    float around = 6.2831853 * mean / (2.0 * hw);
    float cells = max(3.0, floor(around / 1.4));
    float cell = around / cells;
    float a = turn * around;
    float coverage = 0.0;
    for (int lane = 0; lane < 3; lane++) {
        float l = float(lane);
        float phase = skinGPUHash(float2(l * 17.0 + 3.0, seed));
        float k0 = floor(a / cell + phase);
        // A stroke starts in its own cell and runs on into the next, so each place is reached
        // by the stroke of its cell and of the one before.
        for (int back = 0; back < 2; back++) {
            float k = k0 - float(back);
            float key = fmod(k + cells, cells);
            float2 id = float2(key + l * 131.0, seed);
            float start = (k - phase + 0.25 * skinGPUHash(id + 3.1)) * cell;
            float length = cell * (1.3 + 0.8 * skinGPUHash(id + 7.7));
            float u = (a - start) / length;
            if (u <= 0.0 || u >= 1.0) { continue; }
            float centre = (l - 1.0) * 0.55 + wobble * 0.35 * (skinGPUHash(id + 1.3) - 0.5);
            float slope = wobble * 0.5 * (skinGPUHash(id + 5.9) - 0.5);
            float thick = (0.42 + 0.2 * skinGPUHash(id + 9.4)) * sqrt(smoothstep(0.0, 0.08, u)) * (1.0 - 0.75 * smoothstep(0.55, 1.0, u));
            thick = max(thick, 1e-3);
            float v = (w - centre - slope * (u - 0.5)) / thick;
            float paint = skinGPUBrush(v, (a - start) / thick, dry * 0.6 * u * u, key + l * 7.0 + seed, amount, soft / thick,
                                       2.0 * thick * hw / max(aa, 1e-4));
            paint *= 0.82 + 0.18 * skinGPUHash(id + 2.2);
            coverage = coverage + paint - coverage * paint;
        }
    }
    return coverage;
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

static float4 skinGPUQuadColor(constant SkinGPUQuad &quad, constant float4 *stops, float2 local);

/// The display's transfer curve (sRGB's, which Display P3 shares), from linear light.
static float3 skinGPUEncode(float3 v) {
    v = max(v, float3(0));
    return select(1.055 * pow(v, float3(1.0 / 2.4)) - 0.055, v * 12.92, v <= 0.0031308);
}

/// Triangular noise of one 8-bit step, so a slow ramp of light dithers instead of banding.
static float skinGPUDither(float2 position) {
    return (skinGPUHash(position + 0.37) + skinGPUHash(position.yx + 11.3) - 1.0) / 255.0;
}

/// OKLab to the drawable's encoded Display P3.
static float3 skinGPUOKLabToP3(float3 lab) {
    float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    float3 srgb = float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                         -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                         -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    float3 p3 = float3(0.8224621 * srgb.r + 0.1775380 * srgb.g,
                       0.0331941 * srgb.r + 0.9668058 * srgb.g,
                       0.0170827 * srgb.r + 0.0723974 * srgb.g + 0.9105199 * srgb.b);
    return skinGPUEncode(clamp(p3, 0.0, 1.0));
}

/// Two OKLab colours mixed at one lightness, keeping their chroma when their hues are close.
static float3 skinGPUMixLab(float3 a, float3 b, float w) {
    float ca = length(a.yz), cb = length(b.yz);
    float agree = dot(a.yz, b.yz) / max(ca * cb, 1e-6);
    float3 lab = mix(a, b, w);
    float c = length(lab.yz);
    float keep = mix(c, mix(ca, cb, w), smoothstep(-0.2, 0.6, agree));
    lab.yz *= c > 1e-6 ? keep / c : 0.0;
    return lab;
}

/// The colour at `pos` along `count` OKLab colours from `stops[first]`, ordered round the hue
/// circle and read as a ring, so each colour passes only into its nearest hues.
static float3 skinGPURing(float pos, constant float4 *stops, int first, int count) {
    if (count <= 1) { return stops[first].xyz; }
    float place = floor(pos);
    int i = clamp(int(place - float(count) * floor(place / float(count))), 0, count - 1);
    return skinGPUMixLab(stops[first + i].xyz, stops[first + (i + 1) % count].xyz, smoothstep(0.0, 1.0, pos - place));
}

/// Two octaves of value noise, scaled to 0…1.
static float skinGPUSoftNoise(float2 z) {
    return (0.5 * skinGPUNoise(z) + 0.25 * skinGPUNoise(z * 2.03 + float2(17.1, 9.2))) / 0.75;
}

/// A `light` gradient: a point of light seen through haze. Intensity falls with the inverse
/// square of the distance, softened inside the core (`params.x`, a share of the frame's half
/// size); `d` runs to 1 at the frame's edge, where a smooth window takes the last of it to zero.
/// The profile is light, so it is encoded for the display; the core whitens as it saturates.
static float4 skinGPULight(constant SkinGPUQuad &quad, constant float4 *stops, float2 local, float2 position) {
    float2 size = max(quad.localSize, float2(1));
    float2 q = (local / size - quad.params.yz) * 2.0;
    float d = length(q);
    if (d >= 1.0 || quad.stopCount <= 0) { return float4(0); }
    float core = max(quad.params.x, 1e-3);
    float intensity = 1.0 / (1.0 + (d / core) * (d / core));
    float window = 1.0 - d * d * d * d;
    float level = skinGPUEncode(float3(intensity)).x * window * window;
    float4 color = stops[0] * level;
    color.rgb = mix(color.rgb, float3(color.a), 0.5 * intensity * intensity * intensity * intensity);
    color *= quad.opacity;
    if (color.a < 1e-4) { return float4(0); }
    color.rgb += skinGPUDither(position) * color.a;
    return color;
}

fragment float4 skinGPUQuadFragment(SkinQuadOut in [[stage_in]],
                                    constant SkinGPUQuad &quad [[buffer(1)]],
                                    constant float4 *stops [[buffer(2)]]) {
    if (quad.kind == 1 && int(quad.params.w) == 3) { return skinGPULight(quad, stops, in.local, in.position.xy); }
    // An ellipse that travelled this frame integrates its own coverage along the move, once,
    // here: no second pass, no velocity buffer. Its quad is padded by half the travel when it is
    // built. Gradients, fog and solid rectangles are smooth or plain enough that a blur would not
    // show, so they keep the single tap.
    float2 motion = quad.velocity.xy / max(quad.scale, 1e-3);
    if (length(motion) > 0.5 && quad.kind == 3) {
        int taps = clamp(int(ceil(length(motion) / 1.5)), 2, 16);
        float jitter = skinGPUHash(in.position.xy + 0.5);
        float4 sum = float4(0);
        for (int i = 0; i < taps; i++) {
            float t = (float(i) + jitter) / float(taps) - 0.5;
            sum += skinGPUQuadColor(quad, stops, in.local - motion * t);
        }
        return sum / float(taps) * quad.opacity;
    }
    return skinGPUQuadColor(quad, stops, in.local) * quad.opacity;
}
static float4 skinGPUQuadColor(constant SkinGPUQuad &quad, constant float4 *stops, float2 local) {
    float4 color;
    if (quad.kind == 0) {
        // A solid rectangle, its edge kept smooth so a swept shape fades instead of stepping.
        float2 edge = min(local, quad.localSize - local);
        float aa = max(fwidth(local.x) + fwidth(local.y), 1e-4) * 0.5;
        color = quad.color * clamp(min(edge.x, edge.y) / aa + 0.5, 0.0, 1.0);
    } else if (quad.kind == 1) {
        float2 size = max(quad.localSize, float2(1));
        float t;
        int mode = int(quad.params.w);
        if (mode == 1) {
            float2 centre = quad.params.yz * size;
            t = length(local - centre) / max(1.0, quad.params.x * max(size.x, size.y));
        } else if (mode == 2) {
            t = length(local / size - quad.params.yz) / max(1e-4, quad.params.x);
        } else {
            float2 a = quad.params2.xy, b = quad.params2.zw;
            float2 axis = b - a;
            t = dot(local - a, axis) / max(1e-4, dot(axis, axis));
        }
        color = skinGPUStops(clamp(t, 0.0, 1.0), stops, quad.stopCount);
    } else if (quad.kind == 3) {
        // An ellipse's outline (`color`) and optional fill (`color2`): params hold the stroke's
        // half width, blur, and the radii; params2 the centre, in the quad's local points.
        float2 p = local - quad.params2.xy;
        float2 r = max(quad.params.zw, float2(1e-3));
        float k = length(p / r);
        float g = max(length(p / (r * r)), 1e-5);
        float d = (k - 1.0) * k / g;
        float aa = max(fwidth(d), 1e-3);
        float ring = quad.brush.x > 0.0 ? skinGPUBrushRing(d, p, r, quad.params.x, quad.params.y, aa, quad.brush)
                                        : skinGPUBand(d, quad.params.x, quad.params.y, aa);
        float inside = clamp(0.5 - d / aa, 0.0, 1.0);
        color = quad.color * ring + quad.color2 * inside * (1.0 - quad.color.a * ring);
    } else {
        float2 p = (local + quad.params2.yz) / max(1.0, quad.params.y);
        float t = quad.params.x * quad.params.z;
        float warp = quad.params.w, gain = quad.params2.x;
        float2 q = float2(skinGPUFbm(p + float2(0.0, t * 0.6)), skinGPUFbm(p + float2(5.2, 1.3) - float2(t * 0.4, 0.0)));
        float n = skinGPUFbm(p + warp * q + float2(t * 0.25, -t * 0.15));
        n = clamp((n - 0.5) * gain + 0.5, 0.0, 1.0);
        float4 high = quad.color2;
        if (quad.stopCount > 0) {
            // The fog is the lead colour (stops[0]). The other colours tint it only in small
            // spots, `size` points across in the zone field (scrolled by brush.yz), where a slow
            // noise rises past a threshold set by the share (brush.x); the fog's own density
            // ruffles the spot's edge, and its heart keeps a little of the lead.
            float3 lab = stops[0].xyz;
            if (quad.stopCount > 1) {
                float2 z = (local + quad.brush.yz) / max(quad.params2.w, 1.0);
                float spot = skinGPUSoftNoise(z * 1.6 + float2(31.7, 4.1)) + 0.12 * (n - 0.5);
                float from = 0.92 - 0.45 * clamp(quad.brush.x, 0.0, 1.0);
                float s = smoothstep(from, from + 0.2, spot);
                if (s > 0.0) {
                    float which = skinGPUSoftNoise(z * 0.55 + float2(71.3, 12.9)) * float(quad.stopCount - 1) * 1.5;
                    lab = skinGPUMixLab(lab, skinGPURing(which, stops, 1, quad.stopCount - 1), 0.8 * s);
                }
            }
            high = float4(skinGPUOKLabToP3(lab) * high.a, high.a);
        }
        color = mix(quad.color, high, n);
    }
    return color;
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
    out.brush = float4(vertices[vid].edge.x, vertices[vid].blur.yzw);
    return out;
}

fragment float4 skinGPURibbonFragment(SkinColorOut in [[stage_in]]) {
    // A painted stroke reads its brush coordinates (its seed rides in `blur`, its blur across
    // the stroke in `halfWidth`); a comet tail is solid; a stroke fades across its width.
    float across = fwidth(in.brush.x);
    if (in.brush.w > 0.0) {
        float soft = sqrt(across * across + in.halfWidth * in.halfWidth);
        return in.color * skinGPUBrush(in.brush.x, in.brush.y, in.brush.z, in.blur, min(in.brush.w, 1.0), soft,
                                       2.0 / max(across, 1e-4));
    }
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

/// Film grain, one grain per drawable pixel (the drawable is kept at full render quality while a
/// layer has grain): three uniform draws summed come close to the Gaussian spread of silver
/// grains, with no clumps to coarsen it. Highlights and glows keep about half of it, as film
/// keeps grain in its bright areas; the surface's alpha lets the ground beneath show its own grain.
static float4 skinGPUGrain(float4 color, float2 position, constant SkinGPUPost &post) {
    if (post.grain <= 0) { return color; }
    float2 pixel = floor(position);
    float seed = fract(post.time * 13.7) * 431.0;
    float grain = (skinGPUHash(pixel + seed) + skinGPUHash(pixel.yx * 1.31 + seed * 0.71)
                   + skinGPUHash(pixel + float2(17.3, 5.9) + seed * 1.37) - 1.5) * 0.55;
    float luma = clamp(dot(color.rgb, float3(0.299, 0.587, 0.114)) / max(color.a, 0.001), 0.0, 1.0);
    float weight = mix(1.0, 0.5, smoothstep(0.35, 1.0, luma));
    color.rgb = clamp(color.rgb + grain * post.grain * weight * color.a, float3(0), float3(color.a));
    return color;
}

static float skinGPUEdge(float2 position, float2 size, float edgeStart) {
    float2 half_ = max(size * 0.5, float2(1.0));
    float2 c = (position - size * 0.5) / half_;
    float r = length(c) * 0.70710678;
    return smoothstep(clamp(edgeStart, 0.0, 0.98), 1.0, r);
}

fragment float4 skinGPUPresentFragment(SkinPresentOut in [[stage_in]],
                                       constant SkinGPUPost &post [[buffer(0)]],
                                       texture2d<float> scene [[texture(0)]],
                                       sampler linear [[sampler(0)]]) {
    return skinGPUGrain(scene.sample(linear, in.uv), in.position.xy, post);
}

/// The last pass with the `lut` filter: the finished surface through a 3D colour lookup (already
/// baked for the drawable's Display P3 encoding), mixed in by `post.lut`, then grain.
/// Dither at the final 8-bit write.
fragment float4 skinGPUPresentGradedFragment(SkinPresentOut in [[stage_in]],
                                             constant SkinGPUPost &post [[buffer(0)]],
                                             texture2d<float> scene [[texture(0)]],
                                             texture3d<float> lut [[texture(1)]],
                                             sampler linear [[sampler(0)]]) {
    constexpr sampler cube(filter::linear, address::clamp_to_edge);
    float4 color = scene.sample(linear, in.uv);
    if (color.a > 0.0005) {
        float3 rgb = clamp(color.rgb / color.a, float3(0), float3(1));
        float n = float(lut.get_width());
        float3 graded = lut.sample(cube, rgb * ((n - 1.0) / n) + 0.5 / n).rgb;
        color.rgb = mix(rgb, graded, post.lut) * color.a;
    }
    color = skinGPUGrain(color, in.position.xy, post);
    float dither = skinGPUDither(floor(in.position.xy)) * color.a;
    color.rgb = clamp(color.rgb + dither, float3(0), float3(color.a));
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

/// Coverage at `uv`, blurred like a Gaussian of `sigma` mask texels. A mip level well finer
/// than the deviation carries a little of it, so its texels never show as blocks; `taps` taps
/// on a golden-angle spiral carry the rest. The spiral turns by `turn` (an angle per pixel), so
/// what sampling error is left reads as fine grain instead of a pattern.
static float skinGlyphCoverage(texture2d<float> mask, sampler s, float2 uv, float sigma, float screenLod, float2 texel,
                               int taps, float turn) {
    if (sigma < 0.35) { return mask.sample(s, uv, level(screenLod)).r; }
    float shortest = float(min(mask.get_width(), mask.get_height()));
    float lod = max(screenLod, min(log2(max(1.0, 0.7 * sigma)), max(0.0, log2(shortest) - 2.0)));
    // A trilinear level L spreads about half of its 2^L texels.
    float own = exp2(lod) * 0.5;
    float spread = sqrt(max(sigma * sigma - own * own, 0.0));
    if (spread < 0.35) { return mask.sample(s, uv, level(lod)).r; }
    // Taps out to two and a half deviations, weighted by the Gaussian at their distance.
    float2 reach = texel * spread * 2.5;
    float2 way = float2(cos(turn), sin(turn));
    const float2 golden = float2(-0.7373688, 0.6754903);
    float sum = 0.0, weight = 0.0;
    for (int i = 0; i < taps; i++) {
        float r2 = (float(i) + 0.5) / float(taps);
        float w = exp(-3.125 * r2);
        sum += w * mask.sample(s, uv + way * sqrt(r2) * reach, level(lod)).r;
        weight += w;
        way = float2(way.x * golden.x - way.y * golden.y, way.x * golden.y + way.y * golden.x);
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
    // A smear integrates the mask along its vector. The taps sit about a texel apart and each
    // reads a mip that covers the gap, so the trail stays continuous instead of reading as a row
    // of copies, and a per-pixel jitter hides what stepping is left.
    float2 smearTexels = smear / max(texel, float2(1e-6));
    float smearLength = length(smearTexels);
    bool trail = smearLength > 1.5;
    int copies = trail ? clamp(int(ceil(smearLength * 0.8)), 2, 16) : 1;
    bool splits = abs(split) > 1e-5;
    float jitter = skinGPUHash(in.position.xy + 0.5);
    // A sharp trail reads a mip that covers the gap between its taps. A soft one blurs each tap
    // by its own deviation plus half the gap, so a moving glyph stays as soft as a still one;
    // the copies a smear or split multiplies take fewer taps each.
    float gap = smearLength / float(max(1, copies));
    float trailLod = screenLod + log2(max(1.0, gap));
    bool soft = sigma >= 0.35;
    float tapSigma = trail ? sqrt(sigma * sigma + 0.25 * gap * gap) : sigma;
    int taps = copies == 1 && !splits ? 24 : (trail ? 6 : 8);
    float3 coverage = float3(0);
    for (int i = 0; i < copies; i++) {
        float t = copies > 1 ? (float(i) + jitter) / float(copies) - 0.5 : 0.0;
        float2 uv = in.uv - smear * t;
        float turn = 6.2831853 * jitter + 2.3999632 * float(i);
        float g = trail && !soft ? mask.sample(s, uv, level(trailLod)).r
                                 : skinGlyphCoverage(mask, s, uv, tapSigma, screenLod, texel, taps, turn);
        if (splits) {
            float2 shift = float2(split, 0);
            float left = trail && !soft ? mask.sample(s, uv - shift, level(trailLod)).r
                                        : skinGlyphCoverage(mask, s, uv - shift, tapSigma, screenLod, texel, taps, turn + 1.0);
            float right = trail && !soft ? mask.sample(s, uv + shift, level(trailLod)).r
                                         : skinGlyphCoverage(mask, s, uv + shift, tapSigma, screenLod, texel, taps, turn + 2.0);
            coverage += float3(left, g, right);
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

fragment float4 skinGPULensFragment(SkinPresentOut in [[stage_in]],
                                    constant SkinGPUPost &post [[buffer(0)]],
                                    texture2d<float> scene [[texture(0)]],
                                    sampler linear [[sampler(0)]]) {
    float2 size = post.size, position = in.position.xy;
    float2 centre = size * 0.5;
    float2 c = (position - centre) / max(centre, float2(1));
    float r2 = dot(c, c) * 0.5;
    float2 source = centre + (position - centre) * (1.0 - clamp(post.distortion, -0.6, 0.6) * 0.35 * r2);
    float2 uv = source / size;
    float4 base = scene.sample(linear, uv);
    float edge = skinGPUEdge(position, size, post.start);
    if (post.chromatic <= 0.0 || edge <= 0.0) { return base; }
    float2 offset = normalize(position - centre) * (post.chromatic * edge) / size;
    return skinLensDispersion(scene.sample(linear, uv + offset),
                              scene.sample(linear, uv + 0.5 * offset),
                              base,
                              scene.sample(linear, uv - 0.5 * offset),
                              scene.sample(linear, uv - offset));
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

// MARK: Bloom (`glow` on text)
//
// Lit glyphs are drawn, in linear light and brighter than white, into a half-resolution float
// surface. A pyramid halves it level by level with a 13-tap filter, then climbs back up adding
// each level to the one below through a tent filter. Each level is a Gaussian about twice as
// wide as the one before; summed with equal weight per octave they make the inverse-square
// falloff of light scattered in air and in the lens (the sum of Gaussians a Deep Glow pass
// builds), so the light hugs the glyph's shape up close and opens into a wide, faint veil.

// Each octave carries its own colour: the fainter and wider the light, the more saturated it
// is and the further its hue drifts (`PerceptualToneLadder.glowFalloffTone`). The emission is
// grey luminance, and every level's blend multiplies in its colour and weight.
struct SkinGPUBloomPass {
    float2 texel;       // the source's texel size, in uv
    float2 pad;
    float4 tint;        // up: what the source sample is multiplied by; composite: exposure
};

fragment float4 skinGPUBloomDownFragment(SkinPresentOut in [[stage_in]],
                                         constant SkinGPUBloomPass &pass [[buffer(0)]],
                                         texture2d<float> source [[texture(0)]],
                                         sampler s [[sampler(0)]]) {
    float2 uv = in.uv, t = pass.texel;
    float3 a = source.sample(s, uv + t * float2(-2, -2)).rgb, b = source.sample(s, uv + t * float2(0, -2)).rgb;
    float3 c = source.sample(s, uv + t * float2(2, -2)).rgb, d = source.sample(s, uv + t * float2(-1, -1)).rgb;
    float3 e = source.sample(s, uv + t * float2(1, -1)).rgb, f = source.sample(s, uv + t * float2(-2, 0)).rgb;
    float3 g = source.sample(s, uv).rgb, h = source.sample(s, uv + t * float2(2, 0)).rgb;
    float3 i = source.sample(s, uv + t * float2(-1, 1)).rgb, j = source.sample(s, uv + t * float2(1, 1)).rgb;
    float3 k = source.sample(s, uv + t * float2(-2, 2)).rgb, l = source.sample(s, uv + t * float2(0, 2)).rgb;
    float3 m = source.sample(s, uv + t * float2(2, 2)).rgb;
    float3 sum = (d + e + i + j) * 0.125 + (b + f + h + l) * 0.0625 + g * 0.125 + (a + c + k + m) * 0.03125;
    return float4(sum, 0);
}

/// Added onto the level below, which the blend keeps at its own octave's weight.
fragment float4 skinGPUBloomUpFragment(SkinPresentOut in [[stage_in]],
                                       constant SkinGPUBloomPass &pass [[buffer(0)]],
                                       texture2d<float> source [[texture(0)]],
                                       sampler s [[sampler(0)]]) {
    float2 uv = in.uv, t = pass.texel;
    float3 sum = source.sample(s, uv).rgb * 4.0;
    sum += (source.sample(s, uv + float2(t.x, 0)).rgb + source.sample(s, uv - float2(t.x, 0)).rgb
          + source.sample(s, uv + float2(0, t.y)).rgb + source.sample(s, uv - float2(0, t.y)).rgb) * 2.0;
    sum += source.sample(s, uv + t).rgb + source.sample(s, uv - t).rgb
         + source.sample(s, uv + float2(t.x, -t.y)).rgb + source.sample(s, uv + float2(-t.x, t.y)).rgb;
    return float4(sum * pass.tint.rgb / 16.0, 0);
}

/// The light, encoded for the display and added onto the layer. Its alpha is its brightest
/// channel, so over the layers beneath it acts as a screen: dark ground takes all of it, a
/// bright one saturates instead of clipping in colour.
fragment float4 skinGPUBloomCompositeFragment(SkinPresentOut in [[stage_in]],
                                              constant SkinGPUBloomPass &pass [[buffer(0)]],
                                              texture2d<float> source [[texture(0)]],
                                              sampler s [[sampler(0)]]) {
    float3 light = source.sample(s, in.uv).rgb * pass.tint.rgb;
    float3 color = skinGPUEncode(light);
    float peak = max(color.r, max(color.g, color.b));
    if (peak < 0.5 / 255.0) { return float4(0); }
    color = clamp(color + skinGPUDither(in.position.xy), float3(0), float3(1));
    return float4(color, min(1.0, max(color.r, max(color.g, color.b))));
}
