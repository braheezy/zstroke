const std = @import("std");

pub const Vec2 = @Vector(2, f32);

pub const RATE_OF_PRESSURE_CHANGE = 0.275;
pub const FIXED_PI = std.math.pi + 0.0001;
pub const START_CAP_SEGMENTS = 13;
pub const END_CAP_SEGMENTS = 29;
pub const CORNER_CAP_SEGMENTS = 13;
pub const END_NOISE_THRESHOLD = 3;
pub const MIN_STREAMLINE_T = 0.15;
pub const STREAMLINE_T_RANGE = 0.85;
pub const MIN_RADIUS = 0.01;
pub const DEFAULT_FIRST_PRESSURE = 0.25;
pub const DEFAULT_PRESSURE = 0.5;
pub const UNIT_OFFSET = Vec2{ 1, 1 };

pub fn add(a: Vec2, b: Vec2) Vec2 {
    return a + b;
}

pub fn neg(a: Vec2) Vec2 {
    return -a;
}

pub fn sub(a: Vec2, b: Vec2) Vec2 {
    return a - b;
}

pub fn mul(a: Vec2, scalar: f32) Vec2 {
    return a * @as(Vec2, @splat(scalar));
}

pub fn len(a: Vec2) f32 {
    return @sqrt(a[0] * a[0] + a[1] * a[1]);
}

pub fn dist(a: Vec2, b: Vec2) f32 {
    return len(a - b);
}

pub fn dist2(a: Vec2, b: Vec2) f32 {
    const delta = a - b;
    return delta[0] * delta[0] + delta[1] * delta[1];
}

pub fn uni(a: Vec2) Vec2 {
    const magnitude = len(a);
    if (magnitude == 0) return @splat(0);
    return a / @as(Vec2, @splat(magnitude));
}

pub fn per(a: Vec2) Vec2 {
    return .{ a[1], -a[0] };
}

pub fn dpr(a: Vec2, b: Vec2) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

pub fn isEqual(a: Vec2, b: Vec2) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub fn lrp(a: Vec2, b: Vec2, t: f32) Vec2 {
    return add(a, mul(sub(b, a), t));
}

pub fn prj(a: Vec2, b: Vec2, c: f32) Vec2 {
    return add(a, mul(b, c));
}

pub fn rotAround(a: Vec2, center: Vec2, radians: f32) Vec2 {
    const s = @sin(radians);
    const c = @cos(radians);
    const px = a[0] - center[0];
    const py = a[1] - center[1];
    const nx = px * c - py * s;
    const ny = px * s + py * c;
    return .{ nx + center[0], ny + center[1] };
}
