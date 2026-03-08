const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const PointList = std.array_list.Managed([2]f32);

pub const Vertex = [2]f32;

const Uniforms = extern struct {
    viewport: [2]f32,
    zoom: f32,
    _pad0: f32 = 0.0,
    pan: [2]f32,
    _pad1: [2]f32 = .{ 0.0, 0.0 },
};

pub const StrokeMesh = struct {
    outline_vertices: []Vertex,
    fill_vertices: []Vertex,

    pub fn empty(allocator: std.mem.Allocator) !StrokeMesh {
        return .{
            .outline_vertices = try allocator.alloc(Vertex, 0),
            .fill_vertices = try allocator.alloc(Vertex, 0),
        };
    }

    pub fn deinit(self: StrokeMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.outline_vertices);
        allocator.free(self.fill_vertices);
    }
};

pub const BuildStrokeMeshFn = *const fn (
    allocator: std.mem.Allocator,
    points: []const [2]f32,
    is_complete: bool,
) anyerror!StrokeMesh;

const wgsl =
    \\struct Uniforms {
    \\    viewport: vec2<f32>,
    \\    zoom: f32,
    \\    _pad0: f32,
    \\    pan: vec2<f32>,
    \\    _pad1: vec2<f32>,
    \\}
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\
    \\@vertex fn vs_main(@location(0) pos: vec2<f32>) -> @builtin(position) vec4<f32> {
    \\    let screen_pos = pos * u.zoom + u.pan;
    \\    let ndc = (screen_pos / u.viewport) * 2.0 - 1.0;
    \\    return vec4<f32>(ndc.x, -ndc.y, 0.0, 1.0);
    \\}
    \\
    \\@fragment fn fs_main() -> @location(0) vec4<f32> {
    \\    return vec4<f32>(0.96, 0.48, 0.12, 1.0);
    \\}
;

const App = @This();
allocator: std.mem.Allocator,
window: *zglfw.Window,
gfx: *zgpu.GraphicsContext,
stencil_pipeline: zgpu.RenderPipelineHandle = .{},
fill_pipeline: zgpu.RenderPipelineHandle = .{},
bind_group: zgpu.BindGroupHandle = .{},
outline_buffer: zgpu.BufferHandle = .{},
outline_vertex_count: u32 = 0,
fill_buffer: zgpu.BufferHandle = .{},
fill_vertex_count: u32 = 0,
stencil_texture: zgpu.TextureHandle = .{},
stencil_view: zgpu.TextureViewHandle = .{},
input_points: PointList,
build_stroke_mesh: BuildStrokeMeshFn,
is_drawing: bool = false,
last_cursor_pos: ?[2]f32 = null,
uniform_offset: u32 = 0,
camera_zoom: f32 = 1.0,
camera_pan: [2]f32 = .{ 0.0, 0.0 },
pending_zoom_steps: f32 = 0.0,

pub fn init(allocator: std.mem.Allocator, build_stroke_mesh: BuildStrokeMeshFn) !*App {
    try zglfw.init();
    errdefer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.resizable, false);
    const window = try zglfw.createWindow(800, 600, "zstroke", null);
    errdefer zglfw.destroyWindow(window);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .allocator = allocator,
        .window = window,
        .gfx = undefined,
        .input_points = PointList.init(allocator),
        .build_stroke_mesh = build_stroke_mesh,
    };

    app.gfx = try zgpu.GraphicsContext.create(allocator, .{
        .window = window,
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
        .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
        .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
        .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
        .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
        .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
    }, .{});

    try app.createPipelines();
    try app.createStencilTarget();
    app.createCallbacks();

    return app;
}

pub fn deinit(self: *App) void {
    self.releaseStrokeBuffers();
    if (self.gfx.isResourceValid(self.stencil_view)) self.gfx.releaseResource(self.stencil_view);
    if (self.gfx.isResourceValid(self.stencil_texture)) self.gfx.destroyResource(self.stencil_texture);
    self.input_points.deinit();
    self.gfx.destroy(self.allocator);
    zglfw.destroyWindow(self.window);
    zglfw.terminate();
    self.allocator.destroy(self);
}

pub fn isRunning(self: *App) bool {
    return !self.window.shouldClose() and self.window.getKey(.escape) != .press;
}

pub fn update(self: *App) !void {
    zglfw.pollEvents();

    self.updateZoomFromScroll();
    try self.updateDrawing();

    const mem = self.gfx.uniformsAllocate(Uniforms, 1);
    mem.slice[0] = .{ .viewport = .{
        @floatFromInt(self.gfx.width),
        @floatFromInt(self.gfx.height),
    }, .zoom = self.camera_zoom, .pan = self.camera_pan };
    self.uniform_offset = mem.offset;
}

pub fn draw(self: *App) !void {
    const view = self.gfx.getCurrentTextureView();
    defer view.release();

    const encoder = self.gfx.device.createCommandEncoder(null);
    defer encoder.release();

    const color_attachment = [_]zgpu.wgpu.RenderPassColorAttachment{.{
        .view = view,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .r = 0.12, .g = 0.06, .b = 0.18, .a = 1.0 },
    }};

    const stencil_view = self.gfx.lookupResource(self.stencil_view).?;
    const depth_stencil_attachment = zgpu.wgpu.RenderPassDepthStencilAttachment{
        .view = stencil_view,
        .depth_load_op = .clear,
        .depth_store_op = .discard,
        .depth_clear_value = 1.0,
        .stencil_load_op = .clear,
        .stencil_store_op = .discard,
        .stencil_clear_value = 0,
    };

    const pass = encoder.beginRenderPass(.{
        .color_attachments = &color_attachment,
        .color_attachment_count = 1,
        .depth_stencil_attachment = &depth_stencil_attachment,
    });

    if (self.outline_vertex_count > 0 and self.fill_vertex_count > 0) {
        const stencil_pipeline = self.gfx.lookupResource(self.stencil_pipeline).?;
        const fill_pipeline = self.gfx.lookupResource(self.fill_pipeline).?;
        const bind_group = self.gfx.lookupResource(self.bind_group).?;
        const outline_buffer = self.gfx.lookupResource(self.outline_buffer).?;
        const fill_buffer = self.gfx.lookupResource(self.fill_buffer).?;
        const uniform_offsets = [_]u32{self.uniform_offset};

        pass.setPipeline(stencil_pipeline);
        pass.setBindGroup(0, bind_group, &uniform_offsets);
        pass.setVertexBuffer(0, outline_buffer, 0, @as(u64, self.outline_vertex_count) * @sizeOf(Vertex));
        pass.draw(self.outline_vertex_count, 1, 0, 0);

        pass.setPipeline(fill_pipeline);
        pass.setStencilReference(0);
        pass.setBindGroup(0, bind_group, &uniform_offsets);
        pass.setVertexBuffer(0, fill_buffer, 0, @as(u64, self.fill_vertex_count) * @sizeOf(Vertex));
        pass.draw(self.fill_vertex_count, 1, 0, 0);
    }

    zgpu.endReleasePass(pass);

    const command_buffer = encoder.finish(null);
    defer command_buffer.release();

    self.gfx.submit(&.{command_buffer});
    _ = self.gfx.present();
}

fn createPipelines(self: *App) !void {
    const shader = zgpu.createWgslShaderModule(self.gfx.device, wgsl, "stroke");
    defer shader.release();

    const uniform_bgl = zgpu.bufferEntry(
        0,
        zgpu.wgpu.combineShaderStages(
            zgpu.wgpu.ShaderStages.vertex,
            zgpu.wgpu.ShaderStages.fragment,
        ),
        .uniform,
        true,
        0,
    );

    const bind_group_layout = self.gfx.createBindGroupLayout(&.{uniform_bgl});
    defer self.gfx.releaseResource(bind_group_layout);

    const pipeline_layout = self.gfx.createPipelineLayout(&.{bind_group_layout});
    defer self.gfx.releaseResource(pipeline_layout);

    const color_targets = [_]zgpu.wgpu.ColorTargetState{.{
        .format = zgpu.GraphicsContext.swapchain_format,
        .blend = &zgpu.wgpu.BlendState{
            .color = .{
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
                .operation = .add,
            },
            .alpha = .{
                .src_factor = .zero,
                .dst_factor = .one,
                .operation = .add,
            },
        },
        .write_mask = zgpu.wgpu.ColorWriteMasks.all,
    }};
    const stencil_only_color_targets = [_]zgpu.wgpu.ColorTargetState{.{
        .format = zgpu.GraphicsContext.swapchain_format,
        .write_mask = 0,
    }};

    const vertex_attrs = [_]zgpu.wgpu.VertexAttribute{.{
        .shader_location = 0,
        .format = .float32x2,
        .offset = 0,
    }};

    const vertex_buffer_layout = zgpu.wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex),
        .attribute_count = 1,
        .attributes = &vertex_attrs,
    };

    const vs_entry = zgpu.wgpu.compat.shaderEntryPoint("vs_main");
    const fs_entry = zgpu.wgpu.compat.shaderEntryPoint("fs_main");

    const stencil_state_write = zgpu.wgpu.DepthStencilState{
        .format = .depth24_plus_stencil8,
        .depth_write_enabled = .false,
        .depth_compare = .always,
        .stencil_front = .{
            .compare = .always,
            .fail_op = .keep,
            .depth_fail_op = .keep,
            .pass_op = .increment_wrap,
        },
        .stencil_back = .{
            .compare = .always,
            .fail_op = .keep,
            .depth_fail_op = .keep,
            .pass_op = .decrement_wrap,
        },
        .stencil_read_mask = 0xffff_ffff,
        .stencil_write_mask = 0xffff_ffff,
    };

    const stencil_state_test = zgpu.wgpu.DepthStencilState{
        .format = .depth24_plus_stencil8,
        .depth_write_enabled = .false,
        .depth_compare = .always,
        .stencil_front = .{
            .compare = .not_equal,
            .fail_op = .keep,
            .depth_fail_op = .keep,
            .pass_op = .keep,
        },
        .stencil_back = .{
            .compare = .not_equal,
            .fail_op = .keep,
            .depth_fail_op = .keep,
            .pass_op = .keep,
        },
        .stencil_read_mask = 0xffff_ffff,
        .stencil_write_mask = 0,
    };

    self.stencil_pipeline = self.gfx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{
            .module = shader,
            .entry_point = vs_entry,
            .buffer_count = 1,
            .buffers = &[_]zgpu.wgpu.VertexBufferLayout{vertex_buffer_layout},
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .fragment = &zgpu.wgpu.FragmentState{
            .module = shader,
            .entry_point = fs_entry,
            .target_count = stencil_only_color_targets.len,
            .targets = &stencil_only_color_targets,
        },
        .depth_stencil = &stencil_state_write,
    });

    self.fill_pipeline = self.gfx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{
            .module = shader,
            .entry_point = vs_entry,
            .buffer_count = 1,
            .buffers = &[_]zgpu.wgpu.VertexBufferLayout{vertex_buffer_layout},
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .fragment = &zgpu.wgpu.FragmentState{
            .module = shader,
            .entry_point = fs_entry,
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
        .depth_stencil = &stencil_state_test,
    });

    self.bind_group = self.gfx.createBindGroup(bind_group_layout, &.{.{
        .binding = 0,
        .buffer_handle = self.gfx.uniforms.buffer,
        .offset = 0,
        .size = @sizeOf(Uniforms),
    }});
}

fn createStencilTarget(self: *App) !void {
    self.stencil_texture = self.gfx.createTexture(.{
        .usage = zgpu.wgpu.TextureUsages.render_attachment,
        .dimension = .tdim_2d,
        .size = .{
            .width = self.gfx.width,
            .height = self.gfx.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth24_plus_stencil8,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    self.stencil_view = self.gfx.createTextureView(self.stencil_texture, .{
        .format = .depth24_plus_stencil8,
        .dimension = .tvdim_2d,
    });
}

fn createCallbacks(self: *App) void {
    self.window.setUserPointer(@ptrCast(self));
    _ = self.window.setScrollCallback(struct {
        fn cb(window: *zglfw.Window, x_offset: f64, y_offset: f64) callconv(.c) void {
            _ = x_offset;
            const app = window.getUserPointer(App) orelse return;
            const modifier_pressed = window.getKey(.left_control) == .press or
                window.getKey(.right_control) == .press or
                window.getKey(.left_super) == .press or
                window.getKey(.right_super) == .press;
            if (!modifier_pressed) return;
            app.pending_zoom_steps += @as(f32, @floatCast(y_offset));
        }
    }.cb);
}

fn updateDrawing(self: *App) !void {
    const mouse_down = self.window.getMouseButton(.left) == .press;
    const cursor_pos = self.screenToWorld(self.getCursorPosInFramebuffer());

    if (mouse_down and !self.is_drawing) {
        self.is_drawing = true;
        self.input_points.items.len = 0;
        self.last_cursor_pos = null;
        try self.appendCursorPoint(cursor_pos);
        try self.rebuildStrokeGeometry(false);
    } else if (mouse_down and self.is_drawing) {
        if (self.shouldAppendPoint(cursor_pos)) {
            try self.appendCursorPoint(cursor_pos);
            try self.rebuildStrokeGeometry(false);
        }
    } else if (!mouse_down and self.is_drawing) {
        self.is_drawing = false;
        if (self.shouldAppendPoint(cursor_pos)) {
            try self.appendCursorPoint(cursor_pos);
        }
        try self.rebuildStrokeGeometry(true);
        self.last_cursor_pos = null;
    }
}

fn getCursorPosInFramebuffer(self: *const App) [2]f32 {
    const cursor_pos64 = self.window.getCursorPos();
    const window_size = self.window.getSize();
    const framebuffer_size = self.window.getFramebufferSize();
    const scale_x: f32 = if (window_size[0] > 0)
        @as(f32, @floatFromInt(framebuffer_size[0])) / @as(f32, @floatFromInt(window_size[0]))
    else
        1.0;
    const scale_y: f32 = if (window_size[1] > 0)
        @as(f32, @floatFromInt(framebuffer_size[1])) / @as(f32, @floatFromInt(window_size[1]))
    else
        1.0;
    return .{
        @as(f32, @floatCast(cursor_pos64[0])) * scale_x,
        @as(f32, @floatCast(cursor_pos64[1])) * scale_y,
    };
}

fn screenToWorld(self: *const App, screen_pos: [2]f32) [2]f32 {
    const inv_zoom = 1.0 / self.camera_zoom;
    return .{
        (screen_pos[0] - self.camera_pan[0]) * inv_zoom,
        (screen_pos[1] - self.camera_pan[1]) * inv_zoom,
    };
}

fn updateZoomFromScroll(self: *App) void {
    const scroll_steps = self.pending_zoom_steps;
    self.pending_zoom_steps = 0.0;
    if (scroll_steps == 0.0) return;

    const min_zoom: f32 = 0.2;
    const max_zoom: f32 = 10.0;
    const zoom_step: f32 = 1.12;
    const cursor_screen = self.getCursorPosInFramebuffer();
    const cursor_world = self.screenToWorld(cursor_screen);
    const next_zoom = std.math.clamp(
        self.camera_zoom * std.math.pow(f32, zoom_step, scroll_steps),
        min_zoom,
        max_zoom,
    );
    if (next_zoom == self.camera_zoom) return;

    self.camera_zoom = next_zoom;
    self.camera_pan = .{
        cursor_screen[0] - cursor_world[0] * next_zoom,
        cursor_screen[1] - cursor_world[1] * next_zoom,
    };
}

fn shouldAppendPoint(self: *App, point: [2]f32) bool {
    const last = self.last_cursor_pos orelse return true;
    const dx = point[0] - last[0];
    const dy = point[1] - last[1];
    return dx * dx + dy * dy >= 1.0;
}

fn appendCursorPoint(self: *App, point: [2]f32) !void {
    try self.input_points.append(point);
    self.last_cursor_pos = point;
}

fn releaseStrokeBuffers(self: *App) void {
    if (self.gfx.isResourceValid(self.outline_buffer)) {
        self.gfx.destroyResource(self.outline_buffer);
        self.outline_buffer = .{};
    }
    if (self.gfx.isResourceValid(self.fill_buffer)) {
        self.gfx.destroyResource(self.fill_buffer);
        self.fill_buffer = .{};
    }
    self.outline_vertex_count = 0;
    self.fill_vertex_count = 0;
}

fn rebuildStrokeGeometry(self: *App, is_complete: bool) !void {
    self.releaseStrokeBuffers();
    if (self.input_points.items.len == 0) return;

    const mesh = try self.build_stroke_mesh(self.allocator, self.input_points.items, is_complete);
    defer mesh.deinit(self.allocator);

    if (mesh.outline_vertices.len == 0 or mesh.fill_vertices.len == 0) return;

    self.outline_vertex_count = @intCast(mesh.outline_vertices.len);
    self.outline_buffer = self.gfx.createBuffer(.{
        .usage = zgpu.wgpu.combineBufferUsage(
            zgpu.wgpu.BufferUsages.copy_dst,
            zgpu.wgpu.BufferUsages.vertex,
        ),
        .size = mesh.outline_vertices.len * @sizeOf(Vertex),
    });
    const outline_buffer = self.gfx.lookupResource(self.outline_buffer).?;
    self.gfx.queue.writeBuffer(outline_buffer, 0, Vertex, mesh.outline_vertices);

    self.fill_vertex_count = @intCast(mesh.fill_vertices.len);
    self.fill_buffer = self.gfx.createBuffer(.{
        .usage = zgpu.wgpu.combineBufferUsage(
            zgpu.wgpu.BufferUsages.copy_dst,
            zgpu.wgpu.BufferUsages.vertex,
        ),
        .size = mesh.fill_vertices.len * @sizeOf(Vertex),
    });
    const fill_buffer = self.gfx.lookupResource(self.fill_buffer).?;
    self.gfx.queue.writeBuffer(fill_buffer, 0, Vertex, mesh.fill_vertices);
}
