# zstroke

A port and demo of [perfect-freehand](https://github.com/steveruizok/perfect-freehand).

## Use as a dependency

Add to your project

```zig
zig fetch --save git+https://github.com/braheezy/zstroke
```

## Add to `build.zig`

```zig
const zstroke = b.dependency("zstroke", .{}).module("zstroke");

const exe = b.addExecutable(.{
    .name = "your-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zstroke", .module = zstroke },
        },
    }),
});
```

Then in code:

```zig
const zstroke = @import("zstroke");
```

## Usage example

See [src/main.zig](src/main.zig) for a minimal example.

This demo renders with WebGPU (`zgpu`), any renderer is valid with `zstroke`.
