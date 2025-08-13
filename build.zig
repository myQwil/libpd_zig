const std = @import("std");
const emcc = @import("raylib_zig").emcc;

const Dependency = enum {
	raylib,
};

const Example = struct {
	name: []const u8,
	desc: []const u8,
	deps: []const Dependency = &.{},
};

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	//---------------------------------------------------------------------------
	// Dependencies
	const raylib_dep = b.dependency("raylib_zig", .{
		.target = target,
		.optimize = optimize,
	});
	const raylib_mod = raylib_dep.module("raylib");
	const raylib_lib = raylib_dep.artifact("raylib");
	raylib_mod.linkLibrary(raylib_lib);

	const libpd_dep = b.dependency("pd", .{
		.target = target,
		.optimize = optimize,
	});
	const libpd_mod = libpd_dep.module("libpd");
	const libpd_lib = libpd_dep.artifact("pd");

	//---------------------------------------------------------------------------
	// Examples
	const examples = [_]Example{
		.{
			.name = "fm",
			.desc = "frequency modulator",
			.deps = &.{ .raylib },
		},
	};

	for (examples) |x| {
		const xmod = b.createModule(.{
			.target = target,
			.optimize = optimize,
			.root_source_file = b.path(b.fmt("src/{s}.zig", .{ x.name })),
			.imports = &.{.{ .name = "libpd", .module = libpd_mod }},
		});

		if (target.result.os.tag == .emscripten) {
			const exe_lib = b.addLibrary(.{
				.name = x.name,
				.linkage = .static,
				.root_module = xmod,
			});

			var libs: std.ArrayList(*std.Build.Step.Compile) = .init(b.allocator);
			defer libs.deinit();
			try libs.appendSlice(&.{ exe_lib, libpd_lib });
			for (x.deps) |dep| switch (dep) {
				.raylib => {
					xmod.addImport("raylib", raylib_mod);
					try libs.append(raylib_lib);
				},
			};
			const link = try emcc.linkWithEmscripten(b, libs.items);
			link.addArg("--preload-file=pd");

			b.getInstallStep().dependOn(&link.step);
			const run = try emcc.emscriptenRunStep(b);
			run.step.dependOn(&link.step);
			const step_run = b.step("run_fm", "Run the {s} example");
			step_run.dependOn(&run.step);
		} else {
			for (x.deps) |dep| switch (dep) {
				.raylib => {
					xmod.addImport("raylib", raylib_mod);
				},
			};
			const exe = b.addExecutable(.{
				.name = x.name,
				.root_module = xmod,
			});
			const install = b.addInstallArtifact(exe, .{});
			const step_install = b.step(
				x.name,
				b.fmt("Build the {s} example", .{ x.desc }),
			);
			step_install.dependOn(&install.step);

			const run = b.addRunArtifact(exe);
			run.step.dependOn(&install.step);
			const step_run = b.step(
				b.fmt("run_{s}", .{ x.name }),
				b.fmt("Build and run the {s} example", .{ x.desc }),
			);
			step_run.dependOn(&run.step);
			if (b.args) |args| {
				run.addArgs(args);
			}
		}
	}
}
