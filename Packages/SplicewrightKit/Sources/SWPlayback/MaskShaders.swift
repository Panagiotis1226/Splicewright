// Mask shaders. Compiled after `Shaders.source`, whose VertexOut and EffectUniforms they use.

extension Shaders {
    static let maskSource = """
    // --- Masks ---------------------------------------------------------------------------
    // A mask is rasterized (and feathered) into its own texture, then folded into one
    // coverage texture: add masks with "screen" blending, subtract masks multiply by what's
    // left. a.x: inverted, a.y: mask opacity.
    fragment float4 maskCombineFragment(VertexOut in [[stage_in]], texture2d<float> mask [[texture(0)]],
                                        constant EffectUniforms& u [[buffer(0)]]) {
        float m = clamp(mask.read(uint2(in.position.xy)).r, 0.0, 1.0);
        if (u.a.x > 0.5) { m = 1.0 - m; }
        return float4(m * u.a.y);
    }

    /// Opacity masks: the premultiplied layer times its coverage.
    fragment float4 maskApplyFragment(VertexOut in [[stage_in]], texture2d<float> layer [[texture(0)]],
                                      texture2d<float> coverage [[texture(1)]]) {
        uint2 p = uint2(in.position.xy);
        return layer.read(p) * clamp(coverage.read(p).r, 0.0, 1.0);
    }

    /// Effect masks: the effect's result inside, the picture before it outside.
    fragment float4 maskMixFragment(VertexOut in [[stage_in]], texture2d<float> before [[texture(0)]],
                                    texture2d<float> after [[texture(1)]], texture2d<float> coverage [[texture(2)]]) {
        uint2 p = uint2(in.position.xy);
        return mix(before.read(p), after.read(p), clamp(coverage.read(p).r, 0.0, 1.0));
    }
    """
}
