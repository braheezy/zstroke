const std = @import("std");
const builtin = @import("builtin");
const zstroke = @import("zstroke");

const App = @import("App.zig");

fn toVertex(point: zstroke.Vec2) App.Vertex {
    return .{ point[0], point[1] };
}

fn buildStrokeMesh(
    allocator: std.mem.Allocator,
    points: []const [2]f32,
    is_complete: bool,
) !App.StrokeMesh {
    const stroke_points = try zstroke.getStrokePoints(allocator, points, .{
        .size = 24,
        .thinning = 0.6,
        .smoothing = 0.5,
        .streamline = 0.5,
        .simulate_pressure = true,
        .last = is_complete,
    });
    defer allocator.free(stroke_points);

    const outline = try zstroke.getStrokeOutlinePoints(allocator, stroke_points, .{
        .size = 24,
        .thinning = 0.6,
        .smoothing = 0.5,
        .streamline = 0.5,
        .simulate_pressure = true,
        .last = is_complete,
    });
    defer allocator.free(outline);

    if (outline.len < 3) {
        return App.StrokeMesh.empty(allocator);
    }

    var outline_vertices = try allocator.alloc(App.Vertex, outline.len * 3);
    errdefer allocator.free(outline_vertices);

    var min_x = outline[0][0];
    var min_y = outline[0][1];
    var max_x = outline[0][0];
    var max_y = outline[0][1];

    for (outline) |point| {
        min_x = @min(min_x, point[0]);
        min_y = @min(min_y, point[1]);
        max_x = @max(max_x, point[0]);
        max_y = @max(max_y, point[1]);
    }

    const anchor: App.Vertex = .{ (min_x + max_x) * 0.5, (min_y + max_y) * 0.5 };
    for (outline, 0..) |point, i| {
        const base = i * 3;
        outline_vertices[base + 0] = anchor;
        outline_vertices[base + 1] = toVertex(point);
        outline_vertices[base + 2] = toVertex(outline[(i + 1) % outline.len]);
    }

    var fill_vertices = try allocator.alloc(App.Vertex, 6);
    errdefer allocator.free(fill_vertices);
    fill_vertices[0] = .{ min_x, min_y };
    fill_vertices[1] = .{ max_x, min_y };
    fill_vertices[2] = .{ max_x, max_y };
    fill_vertices[3] = .{ min_x, min_y };
    fill_vertices[4] = .{ max_x, max_y };
    fill_vertices[5] = .{ min_x, max_y };

    return .{
        .outline_vertices = outline_vertices,
        .fill_vertices = fill_vertices,
    };
}

pub fn main() !void {
    // Memory allocation setup
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    // Memory allocation setup
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) {
            std.process.exit(1);
        }
    };

    const app = try App.init(allocator, &buildStrokeMesh);
    defer app.deinit();

    while (app.isRunning()) {
        try app.update();
        try app.draw();
    }
}
