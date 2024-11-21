# libpd_zig

This is [libpd](https://github.com/libpd/libpd),
packaged for [Zig](https://ziglang.org/).

## How to use it

First, update your `build.zig.zon`:

```
zig fetch --save https://github.com/myQwil/libpd_zig/archive/refs/tags/v0.1.1.tar.gz
```

Next, add this snippet to your `build.zig` script:

```zig
const libpd_dep = b.dependency("libpd_zig", .{
    .target = target,
    .optimize = optimize,
});
```

From here, you can add it to your project, either as a library or a module.

### As a library
```zig
your_compilation.linkLibrary(libpd_dep.artifact("pd"));
```

### As a module
```zig
your_compilation.root_module.addImport("pd", libpd_dep.module("pd")),
```
