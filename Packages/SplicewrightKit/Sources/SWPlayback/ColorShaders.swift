// Color correction, curves and LUT shaders. Compiled after `Shaders.source`, whose helpers
// (VertexOut, luma2020, the gamut conversions) they use.

extension Shaders {
    static let colorSource = """
    // --- Color correction ----------------------------------------------------------------
    // On the layer's premultiplied linear Rec.2020 pixels. Exposure and white balance work in
    // linear light; the tonal sliders in stops from mid grey (so SDR and HDR respond alike);
    // curves and LUTs on display-encoded Rec.709, where .cube files expect their input.

    struct ColorUniforms {
        float4 a;   // exposure (stops), contrast, highlights, shadows (-1...1)
        float4 b;   // whites, blacks, temperature, tint (-1...1)
        float4 c;   // saturation (1 = unchanged), vibrance (-1...1)
    };

    float3 gradeColor(float3 lin, constant ColorUniforms& u) {
        lin *= exp2(u.a.x);
        float3 balance = float3(1.0 + 0.3 * u.b.z + 0.1 * u.b.w, 1.0 - 0.2 * u.b.w, 1.0 - 0.3 * u.b.z + 0.1 * u.b.w);
        lin *= balance / max(dot(balance, luma2020), 1e-4);
        float y = dot(lin, luma2020);
        if (y > 1e-6) {
            float e = log2(y / 0.18);
            e *= 1.0 + 0.6 * u.a.y;
            e += 1.5 * u.a.z * smoothstep(0.0, 3.0, e);
            e += 1.5 * u.a.w * smoothstep(0.0, 3.0, -e);
            e += 1.5 * u.b.x * smoothstep(1.5, 4.0, e);
            e += 1.5 * u.b.y * smoothstep(2.5, 6.0, -e);
            lin *= (0.18 * exp2(e)) / y;
        }
        y = dot(lin, luma2020);
        float high = max(max(lin.r, lin.g), lin.b);
        float low = min(min(lin.r, lin.g), lin.b);
        float current = high > 1e-6 ? (high - low) / high : 0.0;
        float amount = u.c.x * (1.0 + u.c.y * (1.0 - current));
        return max(y + (lin - y) * amount, 0.0);
    }

    float3 rec709ToRec2020(float3 c) { return toRec2020(c, 0); }

    fragment float4 colorFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                  constant ColorUniforms& u [[buffer(0)]]) {
        float4 c = source.read(uint2(in.position.xy));
        if (c.a <= 0.0) { return c; }
        return float4(gradeColor(c.rgb / c.a, u) * c.a, c.a);
    }

    /// Rec.709 gamma 2.4 code values for the curves and LUTs (above 1.0 passes through).
    float3 toDisplay(float3 lin) { return pow(max(rec2020To709(lin), 0.0), 1.0 / 2.4); }
    float3 fromDisplay(float3 encoded) { return rec709ToRec2020(pow(max(encoded, 0.0), 2.4)); }

    /// table: 256 × 3, one row per channel. a.x: 1 to apply.
    fragment float4 curvesFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                   texture2d<float> table [[texture(1)]], constant EffectUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        float4 c = source.read(uint2(in.position.xy));
        if (c.a <= 0.0) { return c; }
        float3 display = toDisplay(c.rgb / c.a);
        float width = float(table.get_width());
        float3 x = (clamp(display, 0.0, 1.0) * (width - 1.0) + 0.5) / width;
        float3 curved = float3(table.sample(s, float2(x.r, 1.0 / 6.0)).r, table.sample(s, float2(x.g, 3.0 / 6.0)).r,
                               table.sample(s, float2(x.b, 5.0 / 6.0)).r);
        float3 result = select(curved, display, display > 1.0);
        return float4(fromDisplay(result) * c.a, c.a);
    }

    struct LUTUniforms {
        float4 domainMin;   // xyz; w: intensity
        float4 domainMax;   // xyz; w: entries per axis
    };

    float3 lutCoordinates(float3 display, constant LUTUniforms& u) {
        float3 normalized = clamp((display - u.domainMin.xyz) / max(u.domainMax.xyz - u.domainMin.xyz, 1e-6), 0.0, 1.0);
        float size = u.domainMax.w;
        return (normalized * (size - 1.0) + 0.5) / size;
    }

    fragment float4 lut3DFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]], constant LUTUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        float4 c = source.read(uint2(in.position.xy));
        if (c.a <= 0.0) { return c; }
        float3 display = toDisplay(c.rgb / c.a);
        float3 looked = lut.sample(s, lutCoordinates(display, u)).rgb;
        float3 mixed = mix(display, looked, u.domainMin.w);
        return float4(fromDisplay(mixed) * c.a, c.a);
    }

    fragment float4 lut1DFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                  texture2d<float> lut [[texture(1)]], constant LUTUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
        float4 c = source.read(uint2(in.position.xy));
        if (c.a <= 0.0) { return c; }
        float3 display = toDisplay(c.rgb / c.a);
        float3 x = lutCoordinates(display, u);
        float3 looked = float3(lut.sample(s, float2(x.r, 0.5)).r, lut.sample(s, float2(x.g, 0.5)).g,
                               lut.sample(s, float2(x.b, 0.5)).b);
        float3 mixed = mix(display, looked, u.domainMin.w);
        return float4(fromDisplay(mixed) * c.a, c.a);
    }
    """
}
