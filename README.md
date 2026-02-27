# Zig OpenAPI Generator

Not meant to be general purpose, built for [Gainz](https://www.github.com/xydone/gainz-server) and [Xoby](https://www.github.com/xydone/xoby).

# Building

```zig
const openapi_zenerator = b.dependency("openapi_zenerator", .{
        .target = target,
        .optimize = optimize,
    });
    openapi_module.addImport("openapi_zenerator", openapi_zenerator.module("openapi_zenerator"));
```

# Usage

```zig
pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    try OpenAPI.generate(
        allocator,
        Routes.endpoint_data,
        .{
            .title = "Project Name",
            .out_file_path = "docs/openapi.json",
            .version = "0.0.0",
        },
    );
}

const Routes = @import("routes/routes.zig");

const OpenAPI = @import("openapi_zenerator");
const std = @import("std");
```
