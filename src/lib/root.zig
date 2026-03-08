const std = @import("std");
const ArrayList = std.array_list.Managed;
const math = @import("math.zig");
const vendored_test_inputs_json = @embedFile("testdata/inputs.json");

pub const Vec2 = math.Vec2;
pub const RATE_OF_PRESSURE_CHANGE = math.RATE_OF_PRESSURE_CHANGE;
pub const FIXED_PI = math.FIXED_PI;
pub const START_CAP_SEGMENTS = math.START_CAP_SEGMENTS;
pub const END_CAP_SEGMENTS = math.END_CAP_SEGMENTS;
pub const CORNER_CAP_SEGMENTS = math.CORNER_CAP_SEGMENTS;
pub const END_NOISE_THRESHOLD = math.END_NOISE_THRESHOLD;
pub const MIN_STREAMLINE_T = math.MIN_STREAMLINE_T;
pub const STREAMLINE_T_RANGE = math.STREAMLINE_T_RANGE;
pub const MIN_RADIUS = math.MIN_RADIUS;
pub const DEFAULT_FIRST_PRESSURE = math.DEFAULT_FIRST_PRESSURE;
pub const DEFAULT_PRESSURE = math.DEFAULT_PRESSURE;
pub const UNIT_OFFSET = math.UNIT_OFFSET;

pub const EasingFn = *const fn (pressure: f32) f32;

pub const StrokeOptions = struct {
    size: ?f32 = null,
    thinning: ?f32 = null,
    smoothing: ?f32 = null,
    streamline: ?f32 = null,
    easing: ?EasingFn = null,
    simulate_pressure: ?bool = null,
    start: ?CapInfo = null,
    end: ?CapInfo = null,
    last: bool = false,
};

pub const CapInfo = struct {
    cap: ?bool = null,
    taper: ?Taper = null,
    easing: ?EasingFn = null,
};

pub const Taper = union(enum) {
    boolean: bool,
    number: f32,
};

pub const StrokePoint = struct {
    point: Vec2,
    pressure: f32,
    distance: f32,
    vector: Vec2,
    running_length: f32,
};

pub const InputPoint = struct {
    x: f32,
    y: f32,
    pressure: ?f32 = null,
};

pub fn isValidPressure(pressure: f32) bool {
    return pressure >= 0;
}

const add = math.add;
const neg = math.neg;
const sub = math.sub;
const mul = math.mul;
const len = math.len;
const dist = math.dist;
const dist2 = math.dist2;
const uni = math.uni;
const per = math.per;
const dpr = math.dpr;
const isEqual = math.isEqual;
const lrp = math.lrp;
const prj = math.prj;
const rotAround = math.rotAround;

fn pointVec2(point: InputPoint) Vec2 {
    return .{ point.x, point.y };
}

fn identityEasing(t: f32) f32 {
    return t;
}

fn taperStartEasing(t: f32) f32 {
    return t * (2 - t);
}

fn taperEndEasing(t: f32) f32 {
    const shifted = t - 1;
    return shifted * shifted * shifted + 1;
}

fn getStrokeRadius(size: f32, thinning: f32, pressure: f32, easing: EasingFn) f32 {
    return size * easing(0.5 - thinning * (0.5 - pressure));
}

fn simulatePressure(previous_pressure: f32, distance: f32, size: f32) f32 {
    const speed = @min(1, distance / size);
    const rate = @min(1, 1 - speed);
    return @min(
        1,
        previous_pressure + (rate - previous_pressure) * (speed * RATE_OF_PRESSURE_CHANGE),
    );
}

fn pointX(point: anytype) f32 {
    const T = @TypeOf(point);
    return switch (@typeInfo(T)) {
        .@"struct" => point.x,
        .array => point[0],
        else => @compileError("points must be InputPoint-like structs or [2]/[3] float arrays"),
    };
}

fn pointY(point: anytype) f32 {
    const T = @TypeOf(point);
    return switch (@typeInfo(T)) {
        .@"struct" => point.y,
        .array => point[1],
        else => @compileError("points must be InputPoint-like structs or [2]/[3] float arrays"),
    };
}

fn pointPressure(point: anytype) ?f32 {
    const T = @TypeOf(point);
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasField(T, "pressure")) point.pressure else null,
        .array => |info| if (info.len >= 3) point[2] else null,
        else => @compileError("points must be InputPoint-like structs or [2]/[3] float arrays"),
    };
}

fn normalizeInputPoint(point: anytype) InputPoint {
    return .{
        .x = pointX(point),
        .y = pointY(point),
        .pressure = pointPressure(point),
    };
}

fn drawDot(outline: *ArrayList(Vec2), center: Vec2, radius: f32) !void {
    const offset_point = add(center, UNIT_OFFSET);
    const start = prj(center, uni(per(sub(center, offset_point))), -radius);

    var segment: usize = 1;
    while (segment <= START_CAP_SEGMENTS) : (segment += 1) {
        const t = @as(f32, @floatFromInt(segment)) / @as(f32, START_CAP_SEGMENTS);
        try outline.append(rotAround(start, center, FIXED_PI * 2 * t));
    }
}

fn drawRoundStartCap(outline: *ArrayList(Vec2), center: Vec2, right_point: Vec2, segments: usize) !void {
    var segment: usize = 1;
    while (segment <= segments) : (segment += 1) {
        const t = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
        try outline.append(rotAround(right_point, center, FIXED_PI * t));
    }
}

fn drawFlatStartCap(outline: *ArrayList(Vec2), center: Vec2, left_point: Vec2, right_point: Vec2) !void {
    const corners_vector = sub(left_point, right_point);
    const offset_a = mul(corners_vector, 0.5);
    const offset_b = mul(corners_vector, 0.51);

    try outline.append(sub(center, offset_a));
    try outline.append(sub(center, offset_b));
    try outline.append(add(center, offset_b));
    try outline.append(add(center, offset_a));
}

fn drawRoundEndCap(
    outline: *ArrayList(Vec2),
    center: Vec2,
    direction: Vec2,
    radius: f32,
    segments: usize,
) !void {
    const start = prj(center, direction, radius);

    var segment: usize = 1;
    while (segment < segments) : (segment += 1) {
        const t = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
        try outline.append(rotAround(start, center, FIXED_PI * 3 * t));
    }
}

fn drawFlatEndCap(outline: *ArrayList(Vec2), center: Vec2, direction: Vec2, radius: f32) !void {
    try outline.append(add(center, mul(direction, radius)));
    try outline.append(add(center, mul(direction, radius * 0.99)));
    try outline.append(sub(center, mul(direction, radius * 0.99)));
    try outline.append(sub(center, mul(direction, radius)));
}

fn computeTaperDistance(taper: ?Taper, size: f32, total_length: f32) f32 {
    if (taper == null) return 0;
    return switch (taper.?) {
        .boolean => |enabled| if (enabled) @max(size, total_length) else 0,
        .number => |distance| distance,
    };
}

fn computeInitialPressure(points: []const StrokePoint, should_simulate_pressure: bool, size: f32) f32 {
    var acc = points[0].pressure;
    const limit = @min(points.len, 10);

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        var pressure = points[i].pressure;
        if (should_simulate_pressure) {
            pressure = simulatePressure(acc, points[i].distance, size);
        }
        acc = (acc + pressure) / 2;
    }

    return acc;
}

const CapMode = enum {
    none,
    round,
    flat,
    taper_point,
    dot,
};

const OutlineGeometry = struct {
    left_pts: ArrayList(Vec2),
    right_pts: ArrayList(Vec2),
    start_cap: ArrayList(Vec2),
    end_cap: ArrayList(Vec2),
    first_point: Vec2,
    last_point: Vec2,
    is_dot: bool,
    start_cap_mode: CapMode,
    end_cap_mode: CapMode,

    fn init(allocator: std.mem.Allocator) OutlineGeometry {
        return .{
            .left_pts = ArrayList(Vec2).init(allocator),
            .right_pts = ArrayList(Vec2).init(allocator),
            .start_cap = ArrayList(Vec2).init(allocator),
            .end_cap = ArrayList(Vec2).init(allocator),
            .first_point = @splat(0),
            .last_point = @splat(0),
            .is_dot = false,
            .start_cap_mode = .none,
            .end_cap_mode = .none,
        };
    }

    fn deinit(self: *OutlineGeometry) void {
        self.left_pts.deinit();
        self.right_pts.deinit();
        self.start_cap.deinit();
        self.end_cap.deinit();
    }
};

fn buildOutlineGeometry(
    allocator: std.mem.Allocator,
    points: []const StrokePoint,
    options: StrokeOptions,
) !OutlineGeometry {
    var geometry = OutlineGeometry.init(allocator);
    errdefer geometry.deinit();

    const size = options.size orelse 16;
    const smoothing = options.smoothing orelse 0.5;
    const thinning = options.thinning orelse 0.5;
    const should_simulate_pressure = options.simulate_pressure orelse true;
    const easing = options.easing orelse &identityEasing;
    const start = options.start orelse CapInfo{};
    const end = options.end orelse CapInfo{};
    const is_complete = options.last;

    const cap_start = start.cap orelse true;
    const taper_start_ease = start.easing orelse &taperStartEasing;
    const cap_end = end.cap orelse true;
    const taper_end_ease = end.easing orelse &taperEndEasing;

    const total_length = points[points.len - 1].running_length;
    const taper_start = computeTaperDistance(start.taper, size, total_length);
    const taper_end = computeTaperDistance(end.taper, size, total_length);
    const min_distance = std.math.pow(f32, size * smoothing, 2);

    var prev_pressure = computeInitialPressure(points, should_simulate_pressure, size);
    var radius = getStrokeRadius(size, thinning, points[points.len - 1].pressure, easing);
    var first_radius: ?f32 = null;
    var prev_vector = points[0].vector;
    var prev_left_point = points[0].point;
    var prev_right_point = prev_left_point;
    var temp_left_point = prev_left_point;
    var temp_right_point = prev_right_point;
    var is_prev_point_sharp_corner = false;

    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        var pressure = points[i].pressure;
        const point = points[i].point;
        const vector = points[i].vector;
        const distance = points[i].distance;
        const running_length = points[i].running_length;
        const is_last_point = i == points.len - 1;

        if (!is_last_point and total_length - running_length < END_NOISE_THRESHOLD) {
            continue;
        }

        if (thinning != 0) {
            if (should_simulate_pressure) {
                pressure = simulatePressure(prev_pressure, distance, size);
            }
            radius = getStrokeRadius(size, thinning, pressure, easing);
        } else {
            radius = size / 2;
        }

        if (first_radius == null) {
            first_radius = radius;
        }

        const taper_start_strength = if (running_length < taper_start)
            taper_start_ease(running_length / taper_start)
        else
            1;
        const taper_end_strength = if (total_length - running_length < taper_end)
            taper_end_ease((total_length - running_length) / taper_end)
        else
            1;

        radius = @max(
            MIN_RADIUS,
            radius * @min(taper_start_strength, taper_end_strength),
        );

        const next_vector = if (!is_last_point) points[i + 1].vector else points[i].vector;
        const next_dpr: f32 = if (!is_last_point) dpr(vector, next_vector) else 1.0;
        const prev_dpr = dpr(vector, prev_vector);

        const is_point_sharp_corner = prev_dpr < 0 and !is_prev_point_sharp_corner;
        const is_next_point_sharp_corner = next_dpr < 0;

        if (is_point_sharp_corner or is_next_point_sharp_corner) {
            const offset = mul(per(prev_vector), radius);

            var segment: usize = 0;
            while (segment <= CORNER_CAP_SEGMENTS) : (segment += 1) {
                const t = @as(f32, @floatFromInt(segment)) /
                    @as(f32, @floatFromInt(CORNER_CAP_SEGMENTS));

                temp_left_point = rotAround(sub(point, offset), point, FIXED_PI * t);
                try geometry.left_pts.append(temp_left_point);

                temp_right_point = rotAround(add(point, offset), point, FIXED_PI * -t);
                try geometry.right_pts.append(temp_right_point);
            }

            prev_left_point = temp_left_point;
            prev_right_point = temp_right_point;

            if (is_next_point_sharp_corner) {
                is_prev_point_sharp_corner = true;
            }
            continue;
        }

        is_prev_point_sharp_corner = false;

        if (is_last_point) {
            const offset = mul(per(vector), radius);
            try geometry.left_pts.append(sub(point, offset));
            try geometry.right_pts.append(add(point, offset));
            continue;
        }

        const offset = mul(per(lrp(next_vector, vector, next_dpr)), radius);
        temp_left_point = sub(point, offset);

        if (i <= 1 or dist2(prev_left_point, temp_left_point) > min_distance) {
            try geometry.left_pts.append(temp_left_point);
            prev_left_point = temp_left_point;
        }

        temp_right_point = add(point, offset);

        if (i <= 1 or dist2(prev_right_point, temp_right_point) > min_distance) {
            try geometry.right_pts.append(temp_right_point);
            prev_right_point = temp_right_point;
        }

        prev_pressure = pressure;
        prev_vector = vector;
    }

    geometry.first_point = points[0].point;
    geometry.last_point = if (points.len > 1)
        points[points.len - 1].point
    else
        add(points[0].point, UNIT_OFFSET);

    if (points.len == 1) {
        if (!(taper_start > 0 or taper_end > 0) or is_complete) {
            geometry.is_dot = true;
            geometry.start_cap_mode = .dot;
            try drawDot(&geometry.start_cap, geometry.first_point, first_radius orelse radius);
            return geometry;
        }
    } else {
        if (!(taper_start > 0 or (taper_end > 0 and points.len == 1))) {
            if (cap_start) {
                geometry.start_cap_mode = .round;
                try drawRoundStartCap(&geometry.start_cap, geometry.first_point, geometry.right_pts.items[0], START_CAP_SEGMENTS);
            } else {
                geometry.start_cap_mode = .flat;
                try drawFlatStartCap(&geometry.start_cap, geometry.first_point, geometry.left_pts.items[0], geometry.right_pts.items[0]);
            }
        }

        const direction = per(neg(points[points.len - 1].vector));

        if (taper_end > 0 or (taper_start > 0 and points.len == 1)) {
            geometry.end_cap_mode = .taper_point;
            try geometry.end_cap.append(geometry.last_point);
        } else if (cap_end) {
            geometry.end_cap_mode = .round;
            try drawRoundEndCap(&geometry.end_cap, geometry.last_point, direction, radius, END_CAP_SEGMENTS);
        } else {
            geometry.end_cap_mode = .flat;
            try drawFlatEndCap(&geometry.end_cap, geometry.last_point, direction, radius);
        }
    }

    return geometry;
}

fn appendTriangle(vertices: *ArrayList(Vec2), a: Vec2, b: Vec2, c: Vec2) !void {
    try vertices.append(a);
    try vertices.append(b);
    try vertices.append(c);
}

fn appendQuad(vertices: *ArrayList(Vec2), left0: Vec2, right0: Vec2, left1: Vec2, right1: Vec2) !void {
    try appendTriangle(vertices, left0, right0, left1);
    try appendTriangle(vertices, right0, right1, left1);
}

fn appendOpenFan(
    vertices: *ArrayList(Vec2),
    center: Vec2,
    first: Vec2,
    arc: []const Vec2,
    last: Vec2,
) !void {
    var prev = first;
    for (arc) |curr| {
        if (!isEqual(prev, curr)) {
            try appendTriangle(vertices, center, prev, curr);
        }
        prev = curr;
    }
    if (!isEqual(prev, last)) {
        try appendTriangle(vertices, center, prev, last);
    }
}

fn appendClosedFan(vertices: *ArrayList(Vec2), center: Vec2, ring: []const Vec2) !void {
    if (ring.len == 0) return;

    var prev = ring[ring.len - 1];
    for (ring) |curr| {
        if (!isEqual(prev, curr)) {
            try appendTriangle(vertices, center, prev, curr);
        }
        prev = curr;
    }
}

fn signedPolygonArea(points: []const Vec2) f32 {
    if (points.len < 3) return 0;

    var area: f32 = 0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const next = points[(i + 1) % points.len];
        area += points[i][0] * next[1] - next[0] * points[i][1];
    }
    return area * 0.5;
}

fn crossTriangle(a: Vec2, b: Vec2, c: Vec2) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn pointInTriangle(point: Vec2, a: Vec2, b: Vec2, c: Vec2, orientation_sign: f32) bool {
    const ab = orientation_sign * crossTriangle(a, b, point);
    const bc = orientation_sign * crossTriangle(b, c, point);
    const ca = orientation_sign * crossTriangle(c, a, point);
    const epsilon = 0.0001;
    return ab >= -epsilon and bc >= -epsilon and ca >= -epsilon;
}

fn triangulateOutline(
    allocator: std.mem.Allocator,
    outline: []const Vec2,
) ![]Vec2 {
    if (outline.len < 3) {
        return allocator.alloc(Vec2, 0);
    }

    var indices = try ArrayList(usize).initCapacity(allocator, outline.len);
    defer indices.deinit();
    for (0..outline.len) |i| {
        try indices.append(i);
    }

    var triangles = ArrayList(Vec2).init(allocator);
    errdefer triangles.deinit();

    const orientation_sign: f32 = if (signedPolygonArea(outline) >= 0) 1 else -1;
    const epsilon = 0.0001;

    while (indices.items.len > 3) {
        var ear_found = false;
        var i: usize = 0;
        while (i < indices.items.len) : (i += 1) {
            const prev_index = indices.items[(i + indices.items.len - 1) % indices.items.len];
            const curr_index = indices.items[i];
            const next_index = indices.items[(i + 1) % indices.items.len];

            const a = outline[prev_index];
            const b = outline[curr_index];
            const c = outline[next_index];

            if (orientation_sign * crossTriangle(a, b, c) <= epsilon) {
                continue;
            }

            var contains_point = false;
            for (indices.items) |test_index| {
                if (test_index == prev_index or test_index == curr_index or test_index == next_index) {
                    continue;
                }
                if (pointInTriangle(outline[test_index], a, b, c, orientation_sign)) {
                    contains_point = true;
                    break;
                }
            }
            if (contains_point) continue;

            if (orientation_sign > 0) {
                try appendTriangle(&triangles, a, b, c);
            } else {
                try appendTriangle(&triangles, a, c, b);
            }

            _ = indices.orderedRemove(i);
            ear_found = true;
            break;
        }

        if (!ear_found) {
            break;
        }
    }

    if (indices.items.len == 3) {
        const a = outline[indices.items[0]];
        const b = outline[indices.items[1]];
        const c = outline[indices.items[2]];
        if (orientation_sign > 0) {
            try appendTriangle(&triangles, a, b, c);
        } else {
            try appendTriangle(&triangles, a, c, b);
        }
    }

    return triangles.toOwnedSlice();
}

pub fn getStrokePoints(
    allocator: std.mem.Allocator,
    points: anytype,
    options: StrokeOptions,
) ![]StrokePoint {
    const points_type = @TypeOf(points);
    const points_info = @typeInfo(points_type);
    const point_slice = switch (points_info) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => points,
            .one => switch (@typeInfo(pointer.child)) {
                .array => points[0..],
                else => @compileError("getStrokePoints expects a slice or array of points"),
            },
            else => @compileError("getStrokePoints expects a slice or array of points"),
        },
        .array => points[0..],
        else => @compileError("getStrokePoints expects a slice or array of points"),
    };

    const streamline = options.streamline orelse 0.5;
    const size = options.size orelse 16;
    const is_complete = options.last;

    if (point_slice.len == 0) {
        return allocator.alloc(StrokePoint, 0);
    }

    const t = MIN_STREAMLINE_T + (1 - streamline) * STREAMLINE_T_RANGE;

    var pts = try ArrayList(InputPoint).initCapacity(allocator, point_slice.len + 4);
    defer pts.deinit();

    for (point_slice) |point| {
        try pts.append(normalizeInputPoint(point));
    }

    if (pts.items.len == 2) {
        const first = pts.items[0];
        const last = pts.items[1];
        pts.items.len = 1;

        var i: usize = 1;
        while (i < 5) : (i += 1) {
            const interpolated = lrp(
                pointVec2(first),
                pointVec2(last),
                @as(f32, @floatFromInt(i)) / 4.0,
            );
            try pts.append(.{
                .x = interpolated[0],
                .y = interpolated[1],
                .pressure = null,
            });
        }
    }

    if (pts.items.len == 1) {
        const point = pts.items[0];
        const offset = add(pointVec2(point), UNIT_OFFSET);
        try pts.append(.{
            .x = offset[0],
            .y = offset[1],
            .pressure = point.pressure,
        });
    }

    var stroke_points = ArrayList(StrokePoint).init(allocator);
    errdefer stroke_points.deinit();

    try stroke_points.append(.{
        .point = pointVec2(pts.items[0]),
        .pressure = if (pts.items[0].pressure) |pressure|
            if (isValidPressure(pressure)) pressure else DEFAULT_FIRST_PRESSURE
        else
            DEFAULT_FIRST_PRESSURE,
        .vector = UNIT_OFFSET,
        .distance = 0,
        .running_length = 0,
    });

    var has_reached_minimum_length = false;
    var running_length: f32 = 0;
    var prev = stroke_points.items[0];
    const max = pts.items.len - 1;

    var i: usize = 1;
    while (i < pts.items.len) : (i += 1) {
        const current = pts.items[i];
        const previous_point = prev.point;
        const point = if (is_complete and i == max)
            pointVec2(current)
        else
            lrp(previous_point, pointVec2(current), t);

        if (isEqual(previous_point, point)) continue;

        const distance = dist(point, previous_point);
        running_length += distance;

        if (i < max and !has_reached_minimum_length) {
            if (running_length < size) continue;
            has_reached_minimum_length = true;
            // TODO: Backfill the missing points so that tapering works correctly.
        }

        prev = .{
            .point = point,
            .pressure = if (current.pressure) |pressure|
                if (isValidPressure(pressure)) pressure else DEFAULT_PRESSURE
            else
                DEFAULT_PRESSURE,
            .vector = uni(sub(previous_point, point)),
            .distance = distance,
            .running_length = running_length,
        };

        try stroke_points.append(prev);
    }

    stroke_points.items[0].vector = if (stroke_points.items.len > 1)
        stroke_points.items[1].vector
    else
        @splat(0);

    return stroke_points.toOwnedSlice();
}

pub fn getStrokeOutlinePoints(
    allocator: std.mem.Allocator,
    points: []const StrokePoint,
    options: StrokeOptions,
) ![]Vec2 {
    if (points.len == 0 or (options.size orelse 16) <= 0) {
        return allocator.alloc(Vec2, 0);
    }

    var geometry = try buildOutlineGeometry(allocator, points, options);
    defer geometry.deinit();

    var outline = ArrayList(Vec2).init(allocator);
    errdefer outline.deinit();

    if (geometry.is_dot) {
        try outline.appendSlice(geometry.start_cap.items);
        return outline.toOwnedSlice();
    }

    try outline.appendSlice(geometry.left_pts.items);
    try outline.appendSlice(geometry.end_cap.items);

    var right_index = geometry.right_pts.items.len;
    while (right_index > 0) {
        right_index -= 1;
        try outline.append(geometry.right_pts.items[right_index]);
    }

    try outline.appendSlice(geometry.start_cap.items);
    return outline.toOwnedSlice();
}

pub fn getStrokeTriangles(
    allocator: std.mem.Allocator,
    points: []const StrokePoint,
    options: StrokeOptions,
) ![]Vec2 {
    if (points.len == 0 or (options.size orelse 16) <= 0) {
        return allocator.alloc(Vec2, 0);
    }
    const outline = try getStrokeOutlinePoints(allocator, points, options);
    defer allocator.free(outline);

    return triangulateOutline(allocator, outline);
}

pub fn getStroke(
    allocator: std.mem.Allocator,
    points: anytype,
    options: StrokeOptions,
) ![]Vec2 {
    const stroke_points = try getStrokePoints(allocator, points, options);
    defer allocator.free(stroke_points);

    return getStrokeTriangles(allocator, stroke_points, options);
}

const TestObjectPoint = struct {
    x: f32,
    y: f32,
    pressure: ?f32 = null,
};

fn squareEasing(t: f32) f32 {
    return t * t;
}

fn expectF32Approx(expected: f32, actual: f32, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

fn expectVec2Approx(expected: Vec2, actual: Vec2, tolerance: f32) !void {
    try expectF32Approx(expected[0], actual[0], tolerance);
    try expectF32Approx(expected[1], actual[1], tolerance);
}

fn expectStrokePointApprox(expected: StrokePoint, actual: StrokePoint, tolerance: f32) !void {
    try expectVec2Approx(expected.point, actual.point, tolerance);
    try expectF32Approx(expected.pressure, actual.pressure, tolerance);
    try expectF32Approx(expected.distance, actual.distance, tolerance);
    try expectVec2Approx(expected.vector, actual.vector, tolerance);
    try expectF32Approx(expected.running_length, actual.running_length, tolerance);
}

fn expectVec2SlicesApprox(expected: []const Vec2, actual: []const Vec2, tolerance: f32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_point, actual_point| {
        try expectVec2Approx(expected_point, actual_point, tolerance);
    }
}

fn isFinite(value: f32) bool {
    return !std.math.isNan(value) and !std.math.isInf(value);
}

fn expectStrokePointsFinite(points: []const StrokePoint) !void {
    for (points) |point| {
        try std.testing.expect(isFinite(point.point[0]));
        try std.testing.expect(isFinite(point.point[1]));
        try std.testing.expect(isFinite(point.pressure));
        try std.testing.expect(isFinite(point.distance));
        try std.testing.expect(isFinite(point.vector[0]));
        try std.testing.expect(isFinite(point.vector[1]));
        try std.testing.expect(isFinite(point.running_length));
    }
}

fn expectVec2SliceFinite(points: []const Vec2) !void {
    for (points) |point| {
        try std.testing.expect(isFinite(point[0]));
        try std.testing.expect(isFinite(point[1]));
    }
}

fn jsonNumber(value: std.json.Value) !f32 {
    return switch (value) {
        .float => |number| @floatCast(number),
        .integer => |number| @floatFromInt(number),
        else => error.InvalidTestInput,
    };
}

fn jsonOptionalNumber(value: ?std.json.Value) !?f32 {
    if (value == null) return null;
    return switch (value.?) {
        .null => null,
        else => try jsonNumber(value.?),
    };
}

fn inputPointsFromJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]InputPoint {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidTestInput,
    };

    var points = try ArrayList(InputPoint).initCapacity(allocator, items.len);
    errdefer points.deinit();

    for (items) |item| {
        switch (item) {
            .array => |point_array| {
                if (point_array.items.len < 2) return error.InvalidTestInput;
                try points.append(.{
                    .x = try jsonNumber(point_array.items[0]),
                    .y = try jsonNumber(point_array.items[1]),
                    .pressure = if (point_array.items.len >= 3)
                        try jsonOptionalNumber(point_array.items[2])
                    else
                        null,
                });
            },
            .object => |point_object| {
                try points.append(.{
                    .x = try jsonNumber(point_object.get("x") orelse return error.InvalidTestInput),
                    .y = try jsonNumber(point_object.get("y") orelse return error.InvalidTestInput),
                    .pressure = try jsonOptionalNumber(point_object.get("pressure")),
                });
            },
            else => return error.InvalidTestInput,
        }
    }

    return points.toOwnedSlice();
}

fn loadTestInputsJson(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, vendored_test_inputs_json);
}

test "getStrokeRadius matches TypeScript cases" {
    const tolerance = 0.0001;

    try expectF32Approx(50, getStrokeRadius(100, 0, 0, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, 0, 0.25, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, 0, 0.5, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, 0, 0.75, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, 0, 1, &identityEasing), tolerance);

    try expectF32Approx(25, getStrokeRadius(100, 0.5, 0, &identityEasing), tolerance);
    try expectF32Approx(37.5, getStrokeRadius(100, 0.5, 0.25, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, 0.5, 0.5, &identityEasing), tolerance);
    try expectF32Approx(62.5, getStrokeRadius(100, 0.5, 0.75, &identityEasing), tolerance);
    try expectF32Approx(75, getStrokeRadius(100, 0.5, 1, &identityEasing), tolerance);

    try expectF32Approx(0, getStrokeRadius(100, 1, 0, &identityEasing), tolerance);
    try expectF32Approx(25, getStrokeRadius(100, 1, 0.25, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, 1, 0.5, &identityEasing), tolerance);
    try expectF32Approx(75, getStrokeRadius(100, 1, 0.75, &identityEasing), tolerance);
    try expectF32Approx(100, getStrokeRadius(100, 1, 1, &identityEasing), tolerance);

    try expectF32Approx(75, getStrokeRadius(100, -0.5, 0, &identityEasing), tolerance);
    try expectF32Approx(62.5, getStrokeRadius(100, -0.5, 0.25, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, -0.5, 0.5, &identityEasing), tolerance);
    try expectF32Approx(37.5, getStrokeRadius(100, -0.5, 0.75, &identityEasing), tolerance);
    try expectF32Approx(25, getStrokeRadius(100, -0.5, 1, &identityEasing), tolerance);

    try expectF32Approx(100, getStrokeRadius(100, -1, 0, &identityEasing), tolerance);
    try expectF32Approx(75, getStrokeRadius(100, -1, 0.25, &identityEasing), tolerance);
    try expectF32Approx(50, getStrokeRadius(100, -1, 0.5, &identityEasing), tolerance);
    try expectF32Approx(25, getStrokeRadius(100, -1, 0.75, &identityEasing), tolerance);
    try expectF32Approx(0, getStrokeRadius(100, -1, 1, &identityEasing), tolerance);

    try expectF32Approx(0, getStrokeRadius(100, 1, 0, &squareEasing), tolerance);
    try expectF32Approx(6.25, getStrokeRadius(100, 1, 0.25, &squareEasing), tolerance);
    try expectF32Approx(25, getStrokeRadius(100, 1, 0.5, &squareEasing), tolerance);
    try expectF32Approx(56.25, getStrokeRadius(100, 1, 0.75, &squareEasing), tolerance);
    try expectF32Approx(100, getStrokeRadius(100, 1, 1, &squareEasing), tolerance);

    try expectF32Approx(100, getStrokeRadius(100, -1, 0, &squareEasing), tolerance);
    try expectF32Approx(56.25, getStrokeRadius(100, -1, 0.25, &squareEasing), tolerance);
    try expectF32Approx(25, getStrokeRadius(100, -1, 0.5, &squareEasing), tolerance);
    try expectF32Approx(6.25, getStrokeRadius(100, -1, 0.75, &squareEasing), tolerance);
    try expectF32Approx(0, getStrokeRadius(100, -1, 1, &squareEasing), tolerance);
}

test "getStrokePoints returns empty for no points" {
    const allocator = std.testing.allocator;
    const empty = [_][2]f32{};
    const stroke_points = try getStrokePoints(allocator, empty[0..], .{});
    defer allocator.free(stroke_points);

    try std.testing.expectEqual(@as(usize, 0), stroke_points.len);
}

test "getStrokePoints matches TypeScript snapshot for one point" {
    const allocator = std.testing.allocator;
    const one_point = [_][2]f32{.{ 464.91, 286.51 }};
    const stroke_points = try getStrokePoints(allocator, one_point[0..], .{});
    defer allocator.free(stroke_points);

    const expected = [_]StrokePoint{
        .{
            .point = .{ 464.91, 286.51 },
            .pressure = 0.25,
            .distance = 0,
            .vector = .{ -0.70710677, -0.70710677 },
            .running_length = 0,
        },
        .{
            .point = .{ 465.485, 287.085 },
            .pressure = 0.5,
            .distance = 0.8131728,
            .vector = .{ -0.70710677, -0.70710677 },
            .running_length = 0.8131728,
        },
    };

    try std.testing.expectEqual(expected.len, stroke_points.len);
    for (expected, stroke_points) |expected_point, actual_point| {
        try expectStrokePointApprox(expected_point, actual_point, 0.001);
    }
}

test "getStrokePoints matches TypeScript snapshot for two points" {
    const allocator = std.testing.allocator;
    const two_points = [_][2]f32{ .{ 10, 200 }, .{ 10, 0 } };
    const stroke_points = try getStrokePoints(allocator, two_points[0..], .{});
    defer allocator.free(stroke_points);

    const expected = [_]StrokePoint{
        .{
            .point = .{ 10, 200 },
            .pressure = 0.25,
            .distance = 0,
            .vector = .{ 0, 1 },
            .running_length = 0,
        },
        .{
            .point = .{ 10, 171.25 },
            .pressure = 0.5,
            .distance = 28.75,
            .vector = .{ 0, 1 },
            .running_length = 28.75,
        },
        .{
            .point = .{ 10, 130.28125 },
            .pressure = 0.5,
            .distance = 40.96875,
            .vector = .{ 0, 1 },
            .running_length = 69.71875,
        },
        .{
            .point = .{ 10, 84.11953 },
            .pressure = 0.5,
            .distance = 46.16172,
            .vector = .{ 0, 1 },
            .running_length = 115.88047,
        },
        .{
            .point = .{ 10, 35.7508 },
            .pressure = 0.5,
            .distance = 48.36873,
            .vector = .{ 0, 1 },
            .running_length = 164.2492,
        },
    };

    try std.testing.expectEqual(expected.len, stroke_points.len);
    for (expected, stroke_points) |expected_point, actual_point| {
        try expectStrokePointApprox(expected_point, actual_point, 0.001);
    }
}

test "getStrokePoints matches TypeScript snapshot for two equal points" {
    const allocator = std.testing.allocator;
    const two_equal_points = [_][2]f32{ .{ 1, 1 }, .{ 1, 1 } };
    const stroke_points = try getStrokePoints(allocator, two_equal_points[0..], .{});
    defer allocator.free(stroke_points);

    const expected = [_]StrokePoint{.{
        .point = .{ 1, 1 },
        .pressure = 0.25,
        .distance = 0,
        .vector = .{ 0, 0 },
        .running_length = 0,
    }};

    try std.testing.expectEqual(expected.len, stroke_points.len);
    for (expected, stroke_points) |expected_point, actual_point| {
        try expectStrokePointApprox(expected_point, actual_point, 0.001);
    }
}

test "getStrokePoints computes the same result for array and object inputs" {
    const allocator = std.testing.allocator;
    const number_pairs = [_][2]f32{
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 20, 0 },
        .{ 25, 5 },
        .{ 30, 5 },
    };
    const object_pairs = [_]TestObjectPoint{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
        .{ .x = 25, .y = 5 },
        .{ .x = 30, .y = 5 },
    };

    const array_points = try getStrokePoints(allocator, number_pairs[0..], .{});
    defer allocator.free(array_points);

    const object_points = try getStrokePoints(allocator, object_pairs[0..], .{});
    defer allocator.free(object_points);

    try std.testing.expectEqual(array_points.len, object_points.len);
    for (array_points, object_points) |array_point, object_point| {
        try expectStrokePointApprox(array_point, object_point, 0.001);
    }
}

test "getStrokePoints does not generate NaNs for TypeScript fixtures" {
    const allocator = std.testing.allocator;
    const json_bytes = try loadTestInputsJson(allocator);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        const input_points = try inputPointsFromJsonValue(allocator, entry.value_ptr.*);
        defer allocator.free(input_points);

        const stroke_points = try getStrokePoints(allocator, input_points, .{});
        defer allocator.free(stroke_points);

        try expectStrokePointsFinite(stroke_points);
    }
}

test "getStrokeOutlinePoints returns empty for no points" {
    const allocator = std.testing.allocator;
    const empty = [_]StrokePoint{};
    const outline = try getStrokeOutlinePoints(allocator, empty[0..], .{});
    defer allocator.free(outline);

    try std.testing.expectEqual(@as(usize, 0), outline.len);
}

test "getStrokeOutlinePoints matches TypeScript snapshot shape for one point" {
    const allocator = std.testing.allocator;
    const one_point = [_][2]f32{.{ 464.91, 286.51 }};
    const stroke_points = try getStrokePoints(allocator, one_point[0..], .{});
    defer allocator.free(stroke_points);

    const outline = try getStrokeOutlinePoints(allocator, stroke_points, .{});
    defer allocator.free(outline);

    try std.testing.expect(outline.len > 40);
    try expectVec2Approx(.{ 469.81018, 282.75983 }, outline[0], 0.01);
    try expectVec2Approx(.{ 461.9173, 282.11652 }, outline[15], 0.01);
    try expectVec2Approx(.{ 461.15982, 291.4102 }, outline[29], 0.01);
    try expectVec2Approx(.{ 468.66067, 281.6102 }, outline[outline.len - 1], 0.01);
}

test "getStrokeOutlinePoints matches TypeScript snapshot shape for two points" {
    const allocator = std.testing.allocator;
    const two_points = [_][2]f32{ .{ 10, 200 }, .{ 10, 0 } };
    const stroke_points = try getStrokePoints(allocator, two_points[0..], .{});
    defer allocator.free(stroke_points);

    const outline = try getStrokeOutlinePoints(allocator, stroke_points, .{});
    defer allocator.free(outline);

    try std.testing.expect(outline.len > 40);
    try expectVec2Approx(.{ 4.893207, 200 }, outline[0], 0.01);
    try expectVec2Approx(.{ 5.6942134, 35.7508 }, outline[4], 0.01);
    try expectVec2Approx(.{ 14.305787, 35.7508 }, outline[outline.len - 18], 0.01);
    try expectVec2Approx(.{ 4.893207, 199.99948 }, outline[outline.len - 1], 0.01);
}

test "getStrokeOutlinePoints does not generate NaNs for TypeScript fixtures" {
    const allocator = std.testing.allocator;
    const json_bytes = try loadTestInputsJson(allocator);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        const input_points = try inputPointsFromJsonValue(allocator, entry.value_ptr.*);
        defer allocator.free(input_points);

        const stroke_points = try getStrokePoints(allocator, input_points, .{});
        defer allocator.free(stroke_points);

        const outline = try getStrokeOutlinePoints(allocator, stroke_points, .{});
        defer allocator.free(outline);

        try expectVec2SliceFinite(outline);
    }
}

test "getStrokeTriangles returns empty for no points" {
    const allocator = std.testing.allocator;
    const empty = [_]StrokePoint{};
    const triangles = try getStrokeTriangles(allocator, empty[0..], .{});
    defer allocator.free(triangles);

    try std.testing.expectEqual(@as(usize, 0), triangles.len);
}

test "getStrokeTriangles are finite and triangle-aligned for TypeScript fixtures" {
    const allocator = std.testing.allocator;
    const json_bytes = try loadTestInputsJson(allocator);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        const input_points = try inputPointsFromJsonValue(allocator, entry.value_ptr.*);
        defer allocator.free(input_points);

        const stroke_points = try getStrokePoints(allocator, input_points, .{});
        defer allocator.free(stroke_points);

        const triangles = try getStrokeTriangles(allocator, stroke_points, .{});
        defer allocator.free(triangles);

        try std.testing.expectEqual(@as(usize, 0), triangles.len % 3);
        try expectVec2SliceFinite(triangles);

        if (input_points.len > 0) {
            try std.testing.expect(triangles.len > 0);
        }
    }
}

test "getStroke wrapper matches explicit points to triangles pipeline" {
    const allocator = std.testing.allocator;
    const number_pairs = [_][2]f32{
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 20, 0 },
        .{ 25, 5 },
        .{ 30, 5 },
    };

    const direct = try getStroke(allocator, number_pairs[0..], .{});
    defer allocator.free(direct);

    const stroke_points = try getStrokePoints(allocator, number_pairs[0..], .{});
    defer allocator.free(stroke_points);

    const explicit = try getStrokeTriangles(allocator, stroke_points, .{});
    defer allocator.free(explicit);

    try expectVec2SlicesApprox(direct, explicit, 0.001);
}
