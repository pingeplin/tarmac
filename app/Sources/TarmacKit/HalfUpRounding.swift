extension BinaryFloatingPoint {
    /// ECMAScript `Math.round`: ties go toward +∞, so -2.5 → -2 where `rounded()`
    /// gives -3. The wire layer and the desktop board that wrote the persisted
    /// state round this way. Subtracting the floor keeps the largest double below
    /// one half rounding down, which adding 0.5 first would not.
    var roundedHalfUp: Self {
        let floor = rounded(.down)
        return self - floor >= 0.5 ? floor + 1 : floor
    }
}
