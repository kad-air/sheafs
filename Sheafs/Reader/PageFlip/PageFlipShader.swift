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
    float pageTop, pageHeight;                   // where the printed page sits on the leaf (the leaf is the whole sheet)
    float baseY, baseOn;                         // tabletop: the surface below the page, from baseY down (texture 4)
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
    float y = (s.y - u.pageTop) / u.pageHeight;
    if (x < 0 || x > 1 || y < 0 || y > 1) return paper;
    return front.sample(pageSampler, float2(x, y)).rgb;
}

// The back of the leaf: the page that lands face up on the other side, or, for a single page
// (a pad of sheets printed on one side), blank paper with the front showing through faintly.
static half3 sampleBack(texture2d<half> front, texture2d<half> back, float2 s, half3 paper, constant FlipUniforms &u) {
    if (u.hasBack > 1.5) return paper;
    if (u.hasBack > 0.5) {
        float t = (s.x - u.inset) / (u.leafWidth - u.inset);
        float x = u.flip > 0 ? 1 - t : t;
        float y = (s.y - u.pageTop) / u.pageHeight;
        if (x < 0 || x > 1 || y < 0 || y > 1) return paper;
        return back.sample(pageSampler, float2(x, y)).rgb;
    }
    half3 through = sampleFront(front, s, paper, u);
    return mix(paper, through, half(0.11));
}

// The shadow the lifted leaf throws on the page beneath, beyond its silhouette, at a sheet point
// (x = shade 0…1, y = the silhouette's height off the page). Seen from above, the silhouette in
// this row is the crest of the bend if the sheet gets that far, and otherwise its free edge,
// still rising; the shadow deepens and widens with that point's height off the page, so it grows
// smoothly along the edge and through the turn. (Casting it only from the crest made it fill in
// row by row while a corner led, like a progress bar.) z is the row's full strength, the shade
// right at the silhouette; `beneath` also shades the ground between the axis and the silhouette
// (rising with the near side), which the leaf itself covers everywhere except below its bottom edge.
static float3 castShadow(float2 sheet, float2 pivot, float2 n, float2 t, float w, float h, float R, bool beneath) {
    if (R <= 0.01) return float3(0);
    float2 rel = sheet - pivot;
    float xi = dot(rel, n);
    float eta = dot(rel, t);
    // The stretch of sheet past the axis in this row: from the axis (or, near a corner, the
    // leaf's top or bottom edge) to the free edge (or the top or bottom edge).
    float2 axis = pivot + t * eta;
    float enter = 0, leave = n.x > 1e-4 ? (w - axis.x) / n.x : 1e6;
    if (abs(n.y) > 1e-4) {
        float top = -axis.y / n.y, bottom = (h - axis.y) / n.y;
        enter = max(enter, min(top, bottom));
        leave = min(leave, max(top, bottom));
    } else if (axis.y < 0 || axis.y > h) {
        leave = 0;
    }
    float rise = clamp(leave, 0.0, R * M_PI_F / 2) / R;
    float reach = R * sin(rise);              // the silhouette's distance past the axis
    float height = R * (1 - cos(rise));       // and its height off the page
    float there = clamp(R * rise - enter, 0.0, 1.0);
    float d = xi - reach;
    float strength = 0.38 * there * min(1.0, height / 16.0);
    if (xi <= 0 || strength <= 0) return float3(0, height, strength);
    if (d > 0) {
        float fall = 1 - smoothstep(0.0, height * 0.9 + 8.0, d);
        return float3(strength * fall * fall, height, strength);
    }
    // Beneath the near side of the bend, as deep as that side is high: none at the axis, where
    // the sheet still touches down, the full strength at the silhouette.
    return float3(beneath ? strength * smoothstep(0.0, max(reach, 1e-3), xi) : 0.0, height, strength);
}

// Like `coverage`, but feathered over `k` points each side: a shadow's soft outline.
static float softCoverage(float2 s, float w, float h, float k) {
    float d = min(min(s.x, w - s.x), min(s.y, h - s.y));
    return smoothstep(-k, k, d);
}

// Lighting on the near side of the bend: matte paper turning away from an overhead light, so
// it simply darkens toward the crest (on dark paper the bend catches a little light instead).
static float shadeFront(float theta, float isDark) {
    float grazing = 1 - 0.26 * (1 - cos(theta));
    float dark = 1 + 0.18 * sin(theta);
    return mix(grazing, dark, isDark);
}

// The far side of the bend, seen from inside the curl: lit from above, so darkest at the crest
// where it faces away and brightening steadily as it turns up, with the concave corner where it
// meets the turned-over part kept a little in shadow (the same tone as the crease on that part).
static float shadeBack(float theta, float isDark) {
    float k = clamp(-cos(theta), 0.0, 1.0);
    float corner = 1 - 0.07 * smoothstep(0.55, 1.0, k);
    float light = (0.72 + 0.28 * k) * corner;
    float dark = 1.14 - 0.14 * k;
    return mix(light, dark, isDark);
}

fragment half4 flipFragment(FlipVertexOut in [[stage_in]],
                            constant FlipUniforms &u [[buffer(0)]],
                            texture2d<half> front [[texture(0)]],
                            texture2d<half> back [[texture(1)]],
                            texture2d<half> under0 [[texture(2)]],
                            texture2d<half> under1 [[texture(3)]],
                            texture2d<half> base [[texture(4)]]) {
    float2 p = in.position.xy / u.scale;
    half3 paper = half3(u.paperR, u.paperG, u.paperB);

    // What lies beneath the leaf.
    half3 color = paper;
    bool onBase = u.baseOn > 0.5 && p.y >= u.baseY;
    if (onBase) {
        color = base.sample(pageSampler, float2(p.x / u.viewWidth, (p.y - u.baseY) / max(1.0, u.viewHeight - u.baseY))).rgb;
    } else if (u.under0On > 0.5 && p.x >= u.under0X && p.x < u.under0X + u.under0Width &&
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
    if (xi <= 0 && !onBase) {
        float cov = coverage(sheet, w, h);
        if (cov > 0) color = mix(color, sampleFront(front, sheet, paper, u), half(cov));
    }

    // The shadow the lifted leaf throws on the page beneath, beyond its silhouette.
    // (Below the page in tabletop the surface gets its own, next: with a tilted axis this one
    // reaches below the leaf too, and the two stacked into a hard-edged band.)
    float3 cast = onBase ? float3(0) : castShadow(sheet, pivot, n, t, w, h, R, false);
    if (cast.x > 0) color *= half(1 - mix(cast.x, cast.x * 0.35, u.isDark));

    // Tabletop: the page stands on the surface at its bottom edge, and the leaf ends there (it
    // never dips through the surface, even where a leading corner swings below the edge). Below
    // the edge the lifted part shades the surface: the row at the edge's full strength under the
    // whole lifted stretch (the part turned over, the bend, up to the silhouette), falling off
    // beyond it as on the page, with a soft outline, and fading over a few points below the
    // edge (a little further for a higher sheet). Without this the turn ended in a hard line.
    if (onBase) {
        if (R > 0.01) {
            float2 edge = float2(sheet.x, h - 1.0);
            float3 under = castShadow(edge, pivot, n, t, w, h, R, true);
            float shade = under.x;
            float2 relEdge = edge - pivot;
            float xiEdge = dot(relEdge, n), etaEdge = dot(relEdge, t);
            // Wherever paper hangs overhead (the far side of the bend, the part turned over),
            // the full strength, with a soft outline; the two meet at the axis.
            if (xiEdge <= 0) {
                float2 turned = pivot + n * (R * M_PI_F - xiEdge) + t * etaEdge;
                shade = max(shade, under.z * softCoverage(turned, w, h, 6.0));
            } else if (xiEdge <= R) {
                float theta = asin(clamp(xiEdge / R, 0.0, 1.0));
                float2 far = pivot + n * (R * (M_PI_F - theta)) + t * etaEdge;
                shade = max(shade, under.z * softCoverage(far, w, h, 6.0));
            }
            float below = max(0.0, sheet.y - h);
            shade *= 1 - smoothstep(0.0, 3.0 + min(under.y, 30.0) * 0.35, below);
            if (shade > 0) color *= half(1 - mix(shade, shade * 0.35, u.isDark));
        }
        return half4(color, 1);
    }

    // The bend: near side (front) and far side (back) at the same screen column.
    if (R > 0.01 && xi > 0 && xi <= R) {
        float theta = asin(clamp(xi / R, 0.0, 1.0));
        float2 near = pivot + n * (R * theta) + t * eta;
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
            float crease = R > 0.01 ? 1 - 0.07 * (1 - smoothstep(0.0, R * 0.9, -xi)) : 1;
            half3 b = sampleBack(front, back, turned, paper, u) * half(mix(crease, 1.0, u.isDark));
            color = mix(color, b, half(cov));
        }
    }

    return half4(color, 1);
}
"""
}
