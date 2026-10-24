import Foundation

/// The page flip's Metal shader, compiled on the device the first time a flip view is made.
/// It lives as source so the project builds without the Metal toolchain (an optional Xcode
/// component) and on any Mac; the runtime compiler is part of every iOS. See `PageFlipView`.
enum PageFlipShader {
    static let source = """
#include <metal_stdlib>
using namespace metal;

// The page flip, drawn by inverse mapping: for every pixel, which point of the flat leaf (if
// any) is lying over it, given the leaf's shape from `PageCurl` (flat to `flat`, bent around a
// cylinder of `radius`, the rest turned over on top). Candidates are tested nearest-first: the
// part already turned over, the far side of the bend (the leaf's back), the near side (its
// front), then the part still lying flat; whatever is left shows the page underneath. All
// lengths are points. Field order must match `FlipUniforms` in PageFlipView.swift.
struct FlipUniforms {
    float viewWidth, viewHeight, scale;
    float leafX, leafY, leafWidth, leafHeight;   // the leaf's frame when flat, window points
    float hinge, flip;                           // hinge x; +1 the leaf extends right of it, -1 left
    float flat, radius, tilt, grabY;             // the curl (sheet units), axis tilt, the held row
    float inset, hasBack;                        // blank margin from the hinge to the printed page (half the gutter); 0 = ghost back, 1 = a page, 2 = blank paper
    float under0X, under0Y, under0Width, under0Height, under0On;
    float under1X, under1Y, under1Width, under1Height, under1On;
    float paperR, paperG, paperB, isDark;
};

struct FlipVertexOut {
    float4 position [[position]];
};

vertex FlipVertexOut flipVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the view.
    float2 p = float2(vid == 2 ? 3.0 : -1.0, vid == 1 ? 3.0 : -1.0);
    FlipVertexOut out;
    out.position = float4(p, 0, 1);
    return out;
}

constexpr sampler pageSampler(address::clamp_to_edge, filter::linear);

// Soft inside test for a sheet point: 1 well inside the leaf, 0 outside, feathered over ~1 pt.
static float coverage(float2 s, float w, float h) {
    float d = min(min(s.x, w - s.x), min(s.y, h - s.y));
    return smoothstep(-0.6, 0.6, d);
}

// How far outside the leaf a sheet point is (0 inside).
static float overhang(float2 s, float w, float h) {
    return max(0.0, -min(min(s.x, w - s.x), min(s.y, h - s.y)));
}

// The leaf runs from the spine to the page's outer edge; the printed page starts `inset` in.
static half3 sampleFront(texture2d<half> front, float2 s, half3 paper, constant FlipUniforms &u) {
    float t = (s.x - u.inset) / (u.leafWidth - u.inset);
    float x = u.flip > 0 ? t : 1 - t;
    if (x < 0 || x > 1) return paper;
    return front.sample(pageSampler, float2(x, s.y / u.leafHeight)).rgb;
}

// The back of the leaf: the page that lands face up on the other side, or, for a single page
// (a pad of sheets printed on one side), blank paper with the front showing through faintly.
static half3 sampleBack(texture2d<half> front, texture2d<half> back, float2 s, half3 paper, constant FlipUniforms &u) {
    if (u.hasBack > 1.5) return paper;
    if (u.hasBack > 0.5) {
        float t = (s.x - u.inset) / (u.leafWidth - u.inset);
        float x = u.flip > 0 ? 1 - t : t;
        if (x < 0 || x > 1) return paper;
        return back.sample(pageSampler, float2(x, s.y / u.leafHeight)).rgb;
    }
    half3 through = sampleFront(front, s, paper, u);
    return mix(paper, through, half(0.11));
}

// Lighting on the near side of the bend: the paper turns away from the light toward the crest,
// with a soft sheen just before it, the way a glossy-ish page catches the room.
static float shadeFront(float theta, float isDark) {
    float grazing = 1 - 0.30 * (1 - cos(theta));
    float sheen = 0.08 * exp(-pow((theta - 1.05) / 0.32, 2.0));
    float dark = 1 + 0.22 * sin(theta);
    return mix(grazing + sheen, dark, isDark);
}

// The far side of the bend, seen from inside the curl: darkest at the crest, opening up to the
// plain lit back as it flattens out on top.
static float shadeBack(float theta, float isDark) {
    float k = clamp(-cos(theta), 0.0, 1.0);
    float light = 0.70 + 0.30 * pow(k, 0.6);
    float dark = 1.16 - 0.16 * pow(k, 0.6);
    return mix(light, dark, isDark);
}

fragment half4 flipFragment(FlipVertexOut in [[stage_in]],
                            constant FlipUniforms &u [[buffer(0)]],
                            texture2d<half> front [[texture(0)]],
                            texture2d<half> back [[texture(1)]],
                            texture2d<half> under0 [[texture(2)]],
                            texture2d<half> under1 [[texture(3)]]) {
    float2 p = in.position.xy / u.scale;
    half3 paper = half3(u.paperR, u.paperG, u.paperB);

    // What lies beneath the leaf.
    half3 color = paper;
    if (u.under0On > 0.5 && p.x >= u.under0X && p.x < u.under0X + u.under0Width &&
        p.y >= u.under0Y && p.y < u.under0Y + u.under0Height) {
        color = under0.sample(pageSampler, (p - float2(u.under0X, u.under0Y)) / float2(u.under0Width, u.under0Height)).rgb;
    } else if (u.under1On > 0.5 && p.x >= u.under1X && p.x < u.under1X + u.under1Width &&
               p.y >= u.under1Y && p.y < u.under1Y + u.under1Height) {
        color = under1.sample(pageSampler, (p - float2(u.under1X, u.under1Y)) / float2(u.under1Width, u.under1Height)).rgb;
    }

    // This pixel in sheet coordinates (x along the sheet from the hinge, y down the page), then
    // relative to the curl's axis, which passes through (flat, grabY) tilted by `tilt`.
    float w = u.leafWidth, h = u.leafHeight, R = u.radius, a = u.flat;
    float2 sheet = float2(u.flip * (p.x - u.hinge), p.y - u.leafY);
    float2 pivot = float2(a, u.grabY - u.leafY);
    float2 n = float2(cos(u.tilt), sin(u.tilt));
    float2 t = float2(-n.y, n.x);
    float2 rel = sheet - pivot;
    float xi = dot(rel, n);    // distance past the axis, toward the free edge
    float eta = dot(rel, t);   // position along the axis
    float lift = min(1.0, 2 * R / 12.0); // how high the turned-over part floats: fades the shadows as it lands

    // The part still lying flat, this side of the axis.
    if (xi <= 0) {
        float cov = coverage(sheet, w, h);
        if (cov > 0) color = mix(color, sampleFront(front, sheet, paper, u), half(cov));
    }

    // The shadow the lifted bend throws on the page beneath, beyond its silhouette.
    if (R > 0.01 && xi > R) {
        float2 silhouette = pivot + n * (R * M_PI_F / 2) + t * eta;
        float there = coverage(silhouette, w, h);
        float d = xi - R;
        float fall = 1 - smoothstep(0.0, R * 0.9 + 8.0, d);
        float shade = 0.38 * fall * fall * there * min(1.0, R / 16.0);
        color *= half(1 - mix(shade, shade * 0.35, u.isDark));
    }

    // The bend: near side (front) and far side (back) at the same screen column.
    if (R > 0.01 && xi > 0 && xi <= R) {
        float theta = asin(clamp(xi / R, 0.0, 1.0));
        float2 near = pivot + n * (R * theta) + t * eta;
        float nearOver = overhang(near, w, h);
        if (nearOver > 0 && nearOver < 14) {
            // The free edge, lifted but not yet over the crest, throws a shadow of its own.
            float height = min(1.0, R * (1 - cos(theta)) / 12.0);
            float edgeShade = 0.24 * (1 - smoothstep(0.0, 14.0, nearOver)) * height;
            color *= half(1 - mix(edgeShade, edgeShade * 0.3, u.isDark));
        }
        float cov = coverage(near, w, h);
        if (cov > 0) color = mix(color, sampleFront(front, near, paper, u) * half(shadeFront(theta, u.isDark)), half(cov));

        float theta2 = M_PI_F - theta;
        float2 far = pivot + n * (R * theta2) + t * eta;
        float over = overhang(far, w, h);
        if (over > 0 && over < 14) {
            float edgeShade = 0.26 * (1 - smoothstep(0.0, 14.0, over)) * lift;
            color *= half(1 - mix(edgeShade, edgeShade * 0.3, u.isDark));
        }
        float cov2 = coverage(far, w, h);
        if (cov2 > 0) {
            half3 b = sampleBack(front, back, far, paper, u) * half(shadeBack(theta2, u.isDark));
            color = mix(color, b, half(cov2));
        }
    }

    // The part already turned over, lying on top and heading back toward the hinge.
    if (xi <= 0) {
        float2 turned = pivot + n * (R * M_PI_F - xi) + t * eta;
        float over = overhang(turned, w, h);
        if (over > 0 && over < 14) {
            float edgeShade = 0.26 * (1 - smoothstep(0.0, 14.0, over)) * lift;
            color *= half(1 - mix(edgeShade, edgeShade * 0.3, u.isDark));
        }
        float cov = coverage(turned, w, h);
        if (cov > 0) {
            // A hint of the crease where the turned part meets the bend.
            float crease = R > 0.01 ? 1 - 0.10 * (1 - smoothstep(0.0, R * 0.9, -xi)) : 1;
            half3 b = sampleBack(front, back, turned, paper, u) * half(mix(crease, 1.0, u.isDark));
            color = mix(color, b, half(cov));
        }
    }

    return half4(color, 1);
}
"""
}
