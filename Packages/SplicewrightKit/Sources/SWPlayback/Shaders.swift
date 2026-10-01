// Metal shaders for the compositor, compiled at runtime so the package needs no Metal
// build step. The transfer functions mirror SWCore's `TransferFunctions`, whose tests pin
// the reference values.
//
// Working space: linear-light Rec.2020, 1.0 = SDR reference white (203 cd/m², BT.2408).
//
// Uniform layouts must match `LayerUniforms` / `OutputUniforms` in MetalRenderer.swift:
// every field is a float4, so Swift and MSL agree on alignment.

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4 row0;    // a, c, tx: x' = a*x + c*y + tx (source px -> render px)
        float4 row1;    // b, d, ty: y' = b*x + d*y + ty
        float4 sizes;   // source width, source height, render width, render height
        float4 ycbcr;   // code scale, max code, full range (0/1), matrix (0 709, 1 601, 2 2020)
        // transfer (0 sdr, 1 srgb, 2 linear, 3 pq, 4 hlg), primaries (0 709, 1 2020, 2 p3),
        // opacity, tone map (0/1)
        float4 color;
        float4 tone;    // source peak (relative to ref white), unused...
        float4 crop;    // left, top, right, bottom as fractions of the layer (Crop effect)
        float4 feather; // feather in uv (x, y), flip horizontal (0/1), flip vertical (0/1)
        float4 mirror;  // enabled (0/1), reflection center (uv x), angle (radians), unused
    };

    struct EffectUniforms {
        float4 a;       // per pass: see each fragment
        float4 b;
    };

    struct OutputUniforms {
        float4 params;  // output space (0 rec709, 1 hlg, 2 pq), clipping overlay (0/1)
    };

    struct TransitionUniforms {
        // kind (0 dissolve, 1 dip to black, 2 dip to white, 3 film dissolve,
        // 4 wipe right, 5 wipe left, 6 wipe down, 7 wipe up), progress 0...1
        float4 params;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    constant float refWhite = 203.0;

    // --- Transfer functions -------------------------------------------------------

    float3 pqToNits(float3 e) {
        const float m1 = 2610.0 / 16384.0;
        const float m2 = 2523.0 / 4096.0 * 128.0;
        const float c1 = 3424.0 / 4096.0;
        const float c2 = 2413.0 / 4096.0 * 32.0;
        const float c3 = 2392.0 / 4096.0 * 32.0;
        float3 p = pow(max(e, 0.0), 1.0 / m2);
        return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    }

    float3 nitsToPQ(float3 nits) {
        const float m1 = 2610.0 / 16384.0;
        const float m2 = 2523.0 / 4096.0 * 128.0;
        const float c1 = 3424.0 / 4096.0;
        const float c2 = 2413.0 / 4096.0 * 32.0;
        const float c3 = 2392.0 / 4096.0 * 32.0;
        float3 y = pow(clamp(nits / 10000.0, 0.0, 1.0), m1);
        return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
    }

    constant float hlgA = 0.17883277;
    constant float hlgB = 0.28466892;   // 1 - 4a
    constant float hlgC = 0.55991073;   // 0.5 - a * ln(4a)
    constant float3 luma2020 = float3(0.2627, 0.6780, 0.0593);

    float3 hlgToScene(float3 e) {
        e = max(e, 0.0);
        float3 low = e * e / 3.0;
        float3 high = (exp((e - hlgC) / hlgA) + hlgB) / 12.0;
        return select(high, low, e <= 0.5);
    }

    float3 sceneToHLG(float3 s) {
        s = max(s, 0.0);
        float3 low = sqrt(3.0 * s);
        float3 high = hlgA * log(max(12.0 * s - hlgB, 1e-6)) + hlgC;
        return select(high, low, s <= 1.0 / 12.0);
    }

    float3 srgbToLinear(float3 v) {
        float3 low = v / 12.92;
        float3 high = pow((v + 0.055) / 1.055, 2.4);
        return select(high, low, v <= 0.04045);
    }

    /// Encoded R'G'B' -> linear light relative to reference white.
    float3 toLinear(float3 rgb, int transfer) {
        switch (transfer) {
        case 1: return srgbToLinear(max(rgb, 0.0));
        case 2: return rgb;
        case 3: return pqToNits(rgb) / refWhite;
        case 4: {
            // HLG OOTF for a 1000 cd/m² display (system gamma 1.2).
            float3 scene = hlgToScene(rgb);
            float ys = max(dot(scene, luma2020), 1e-6);
            return 1000.0 * pow(ys, 0.2) * scene / refWhite;
        }
        default: return pow(max(rgb, 0.0), 2.4);
        }
    }

    // --- Gamut ----------------------------------------------------------------------

    float3 toRec2020(float3 c, int primaries) {
        if (primaries == 1) { return c; }
        if (primaries == 2) {
            return float3(dot(c, float3(0.7539, 0.1986, 0.0476)),
                          dot(c, float3(0.0457, 0.9418, 0.0125)),
                          dot(c, float3(-0.0012, 0.0176, 0.9836)));
        }
        return float3(dot(c, float3(0.6274, 0.3293, 0.0433)),
                      dot(c, float3(0.0691, 0.9195, 0.0114)),
                      dot(c, float3(0.0164, 0.0880, 0.8956)));
    }

    float3 rec2020To709(float3 c) {
        return float3(dot(c, float3(1.6605, -0.5876, -0.0728)),
                      dot(c, float3(-0.1246, 1.1329, -0.0083)),
                      dot(c, float3(-0.0182, -0.1006, 1.1187)));
    }

    // --- Tone mapping (BT.2390 EETF on max(RGB), HDR source -> SDR) ------------------

    float3 toneMapToSDR(float3 lin, float sourcePeak) {
        float m = max(max(lin.r, lin.g), lin.b);
        if (m <= 0.0) { return lin; }
        float srcPQ = nitsToPQ(float3(sourcePeak * refWhite)).x;
        float e = min(nitsToPQ(float3(m * refWhite)).x / srcPQ, 1.0);
        float maxLum = nitsToPQ(float3(refWhite)).x / srcPQ;
        float ks = 1.5 * maxLum - 0.5;
        if (e > ks) {
            float t = (e - ks) / (1.0 - ks);
            float t2 = t * t;
            float t3 = t2 * t;
            e = (2.0 * t3 - 3.0 * t2 + 1.0) * ks + (t3 - 2.0 * t2 + t) * (1.0 - ks) + (-2.0 * t3 + 3.0 * t2) * maxLum;
        }
        float mapped = pqToNits(float3(e * srcPQ)).x / refWhite;
        return lin * (mapped / m);
    }

    // --- YCbCr ------------------------------------------------------------------------

    float3 ycbcrToRGB(float y, float cb, float cr, int matrix) {
        if (matrix == 1) {
            return float3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb);
        }
        if (matrix == 2) {
            return float3(y + 1.4746 * cr, y - 0.16455 * cb - 0.57135 * cr, y + 1.8814 * cb);
        }
        return float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb);
    }

    // --- Geometric effects (Crop, Flip, Mirror), applied while a layer is drawn ------------

    /// Flip and mirror move where a layer samples its own pixels.
    float2 effectUV(float2 uv, constant LayerUniforms& u, float aspect) {
        if (u.feather.z > 0.5) { uv.x = 1.0 - uv.x; }
        if (u.feather.w > 0.5) { uv.y = 1.0 - uv.y; }
        if (u.mirror.x > 0.5) {
            // Reflect across a line through (center, 0.5) at the angle (0 = vertical; the
            // left side is reflected onto the right), in square pixels.
            float2 p = float2(uv.x * aspect, uv.y);
            float2 c = float2(u.mirror.y * aspect, 0.5);
            float2 n = float2(cos(u.mirror.z), sin(u.mirror.z));
            float d = dot(p - c, n);
            if (d > 0.0) { p -= 2.0 * d * n; }
            uv = float2(p.x / aspect, p.y);
        }
        return uv;
    }

    /// 1 inside the crop, 0 outside, soft across the feather.
    float cropMask(float2 uv, constant LayerUniforms& u) {
        float2 low = u.crop.xy;
        float2 high = 1.0 - u.crop.zw;
        if (high.x <= low.x || high.y <= low.y) { return 0.0; }
        float2 f = max(u.feather.xy, float2(1e-5));
        float2 inside = smoothstep(low, low + f, uv) * (1.0 - smoothstep(high - f, high, uv));
        return inside.x * inside.y;
    }

    // --- Layer pass ---------------------------------------------------------------------

    vertex VertexOut layerVertex(uint vid [[vertex_id]], constant LayerUniforms& u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 source = corner * u.sizes.xy;
        float x = u.row0.x * source.x + u.row0.y * source.y + u.row0.z;
        float y = u.row1.x * source.x + u.row1.y * source.y + u.row1.z;
        VertexOut out;
        out.position = float4(2.0 * x / u.sizes.z - 1.0, 1.0 - 2.0 * y / u.sizes.w, 0.0, 1.0);
        out.uv = corner;
        return out;
    }

    fragment float4 layerFragment(VertexOut in [[stage_in]],
                                  texture2d<float> lumaTexture [[texture(0)]],
                                  texture2d<float> chromaTexture [[texture(1)]],
                                  constant LayerUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float codeScale = u.ycbcr.x;
        float maxCode = u.ycbcr.y;
        float depthScale = (maxCode + 1.0) / 256.0;
        float2 uv = effectUV(in.uv, u, u.sizes.x / max(u.sizes.y, 1.0));
        float yCode = lumaTexture.sample(s, uv).r * codeScale;
        float2 cCode = chromaTexture.sample(s, uv).rg * codeScale;
        float y, cb, cr;
        if (u.ycbcr.z > 0.5) {
            y = yCode / maxCode;
            cb = (cCode.x - 128.0 * depthScale) / maxCode;
            cr = (cCode.y - 128.0 * depthScale) / maxCode;
        } else {
            y = (yCode - 16.0 * depthScale) / (219.0 * depthScale);
            cb = (cCode.x - 128.0 * depthScale) / (224.0 * depthScale);
            cr = (cCode.y - 128.0 * depthScale) / (224.0 * depthScale);
        }
        float3 rgb = ycbcrToRGB(y, cb, cr, int(u.ycbcr.w));
        float3 lin = toRec2020(toLinear(rgb, int(u.color.x)), int(u.color.y));
        if (u.color.w > 0.5) { lin = toneMapToSDR(lin, u.tone.x); }
        return float4(lin, u.color.z * cropMask(in.uv, u));
    }

    // --- Titles ----------------------------------------------------------------------------
    // A premultiplied sRGB texture the size of the frame. White maps to 1.0, reference white.

    fragment float4 titleFragment(VertexOut in [[stage_in]],
                                  texture2d<float> title [[texture(0)]],
                                  constant LayerUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = title.sample(s, effectUV(in.uv, u, u.sizes.x / max(u.sizes.y, 1.0)));
        if (c.a <= 0.0) { return float4(0.0); }
        float3 lin = toRec2020(srgbToLinear(clamp(c.rgb / c.a, 0.0, 1.0)), 0);
        return float4(lin, c.a * u.color.z * cropMask(in.uv, u));
    }

    // --- Pixel effects (premultiplied textures, one full-screen pass each) ----------------

    /// Separable Gaussian. a: direction (x, y) in pixels per tap, sigma in taps, taps each side.
    /// b: offset (x, y) in pixels to sample from (drop shadow), alpha only (0/1).
    fragment float4 blurFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                 constant EffectUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_zero, coord::pixel);
        float2 center = in.position.xy - u.b.xy;
        int taps = int(u.a.w);
        float sigma = max(u.a.z, 1e-3);
        float4 sum = float4(0.0);
        float weights = 0.0;
        for (int i = -taps; i <= taps; i++) {
            float w = exp(-0.5 * float(i * i) / (sigma * sigma));
            sum += source.sample(s, center + u.a.xy * float(i)) * w;
            weights += w;
        }
        float4 c = sum / max(weights, 1e-6);
        return u.b.z > 0.5 ? float4(0.0, 0.0, 0.0, c.a) : c;
    }

    /// Unsharp mask: original + amount × (original − blurred). a.x: amount.
    fragment float4 sharpenFragment(VertexOut in [[stage_in]], texture2d<float> original [[texture(0)]],
                                    texture2d<float> blurred [[texture(1)]], constant EffectUniforms& u [[buffer(0)]]) {
        uint2 p = uint2(in.position.xy);
        float4 o = original.read(p);
        float4 b = blurred.read(p);
        float4 c = o + u.a.x * (o - b);
        c.a = clamp(c.a, 0.0, 1.0);
        c.rgb = max(c.rgb, 0.0);
        return c;
    }

    /// The layer over its (blurred, offset) shadow. a: shadow color rgb (linear), opacity.
    fragment float4 shadowFragment(VertexOut in [[stage_in]], texture2d<float> layer [[texture(0)]],
                                   texture2d<float> shadow [[texture(1)]], constant EffectUniforms& u [[buffer(0)]]) {
        uint2 p = uint2(in.position.xy);
        float4 l = layer.read(p);
        float alpha = shadow.read(p).a * u.a.w;
        float4 s = float4(u.a.rgb * alpha, alpha);
        return l + (1.0 - l.a) * s;
    }

    /// Copies a texture through Crop, Flip and Mirror (adjustment layers apply them to the
    /// picture below). Uses the LayerUniforms crop/feather/mirror fields; sizes.zw is the size.
    fragment float4 geometryFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                     constant LayerUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = effectUV(in.uv, u, u.sizes.z / max(u.sizes.w, 1.0));
        return source.sample(s, uv) * cropMask(in.uv, u);
    }

    /// A premultiplied texture composited over the target. a.x: opacity.
    fragment float4 overFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                 constant EffectUniforms& u [[buffer(0)]]) {
        return source.read(uint2(in.position.xy)) * u.a.x;
    }

    // --- Transition pass ----------------------------------------------------------------
    // Both sides arrive premultiplied (drawn over transparent); the result is premultiplied
    // and composited over the layers below.

    float4 filmMix(float4 a, float4 b, float p) {
        // Mix in gamma-encoded space, like an optical dissolve: midtones dip less than in linear.
        float3 ga = pow(max(a.rgb / max(a.a, 1e-5), 0.0), 1.0 / 2.4);
        float3 gb = pow(max(b.rgb / max(b.a, 1e-5), 0.0), 1.0 / 2.4);
        float alpha = mix(a.a, b.a, p);
        float3 g = mix(ga * step(1e-5, a.a), gb * step(1e-5, b.a), p);
        return float4(pow(g, 2.4) * alpha, alpha);
    }

    fragment float4 transitionFragment(VertexOut in [[stage_in]],
                                       texture2d<float> outgoing [[texture(0)]],
                                       texture2d<float> incoming [[texture(1)]],
                                       constant TransitionUniforms& u [[buffer(0)]]) {
        uint2 position = uint2(in.position.xy);
        float4 a = outgoing.read(position);
        float4 b = incoming.read(position);
        int kind = int(u.params.x);
        float p = clamp(u.params.y, 0.0, 1.0);
        const float edge = 0.004;
        switch (kind) {
        case 1:
        case 2: {
            float4 color = kind == 1 ? float4(0.0, 0.0, 0.0, 1.0) : float4(1.0, 1.0, 1.0, 1.0);
            return p < 0.5 ? mix(a, color, p * 2.0) : mix(color, b, p * 2.0 - 1.0);
        }
        case 3: return filmMix(a, b, p);
        case 4: return mix(a, b, 1.0 - smoothstep(p - edge, p + edge, in.uv.x));
        case 5: return mix(a, b, smoothstep(1.0 - p - edge, 1.0 - p + edge, in.uv.x));
        case 6: return mix(a, b, 1.0 - smoothstep(p - edge, p + edge, in.uv.y));
        case 7: return mix(a, b, smoothstep(1.0 - p - edge, 1.0 - p + edge, in.uv.y));
        default: return mix(a, b, p);
        }
    }

    // --- Output pass --------------------------------------------------------------------

    vertex VertexOut fullScreenVertex(uint vid [[vertex_id]]) {
        float2 position = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
        VertexOut out;
        out.position = float4(position, 0.0, 1.0);
        out.uv = float2((position.x + 1.0) * 0.5, (1.0 - position.y) * 0.5);
        return out;
    }

    fragment float4 outputFragment(VertexOut in [[stage_in]],
                                   texture2d<float> working [[texture(0)]],
                                   constant OutputUniforms& u [[buffer(0)]]) {
        float3 lin = working.read(uint2(in.position.xy)).rgb;
        int space = int(u.params.x);
        bool overlay = u.params.y > 0.5;
        const float4 over = float4(1.0, 0.0, 1.0, 1.0);
        const float4 under = float4(0.0, 0.35, 1.0, 1.0);
        if (overlay && space != 0) {
            float peakNits = max(max(lin.r, lin.g), lin.b) * refWhite;
            if (peakNits > 1000.5) { return over; }
            if (min(min(lin.r, lin.g), lin.b) < -0.001) { return under; }
        }
        if (space == 1) {
            // Inverse HLG OOTF for a 1000 cd/m² display, then the OETF.
            float3 display = clamp(lin * refWhite / 1000.0, 0.0, 1.0);
            float yd = max(dot(display, luma2020), 1e-6);
            float3 scene = display * pow(yd, -0.2 / 1.2);
            return float4(sceneToHLG(scene), 1.0);
        }
        if (space == 2) {
            return float4(nitsToPQ(max(lin, 0.0) * refWhite), 1.0);
        }
        float3 unclamped = rec2020To709(lin);
        if (overlay) {
            if (max(max(unclamped.r, unclamped.g), unclamped.b) > 1.001) { return over; }
            if (min(min(unclamped.r, unclamped.g), unclamped.b) < -0.001) { return under; }
        }
        float3 sdr = clamp(unclamped, 0.0, 1.0);
        return float4(pow(sdr, 1.0 / 2.4), 1.0);
    }
    """
}
