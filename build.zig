const std = @import("std");
const emsdk = @import("raylib_zig").emsdk;

const Dependency = enum {
	raylib,
};

const Example = struct {
	name: []const u8,
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

	const libpd_dep = b.dependency("pd", .{
		.target = target,
		.optimize = optimize,
	});
	const libpd_mod = libpd_dep.module("libpd");
	const libpd_lib = libpd_dep.artifact("pd");

	//---------------------------------------------------------------------------
	// Examples
	const examples = [_]Example{
		.{ .name = "fm", .deps = &.{ .raylib } },
	};

	for (examples) |x| {
		const exe_mod = b.createModule(.{
			.root_source_file = b.path(b.fmt("src/{s}.zig", .{ x.name })),
			.target = target,
			.optimize = optimize,
			.imports = &.{.{ .name = "libpd", .module = libpd_mod }},
		});
		for (x.deps) |dep| switch (dep) {
			.raylib => { exe_mod.addImport("raylib", raylib_mod); },
		};

		const run_step = b.step(
			b.fmt("run_{s}", .{ x.name }),
			b.fmt("Build and run {s}", .{ x.name }),
		);

		if (target.result.os.tag == .emscripten) {
			const wasm = b.addLibrary(.{
				.name = x.name,
				.root_module = exe_mod,
			});
			const install_dir: std.Build.InstallDir = .{ .custom = "web" };
			const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
				.optimize = optimize,
			});
			const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
				.optimize = optimize,
			});

			const html_filename = b.fmt("{s}.html", .{ x.name });
			const emcc_step = emsdk.emccStep(b, raylib_lib, wasm, .{
				.optimize = optimize,
				.flags = emcc_flags,
				.settings = emcc_settings,
				.shell_file_path = emsdk.shell(raylib_dep.builder),
				.install_dir = install_dir,
				.preload_paths = &.{.{ .src_path = .{ .cwd_relative = "pd" } }},
				.out_file_name = html_filename,
			});

			const emsdk_dep = b.dependency("emsdk", .{});
			libpd_lib.root_module.addIncludePath(
				emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));

			const emrun_step = emsdk.emrunStep(
				b,
				b.getInstallPath(install_dir, html_filename),
				&.{},
			);

			emrun_step.dependOn(emcc_step);
			run_step.dependOn(emrun_step);
		} else {
			const exe = b.addExecutable(.{
				.name = x.name,
				.root_module = exe_mod,
			});

			const install_cmd = b.addInstallArtifact(exe, .{});
			const install_step = b.step(
				x.name,
				b.fmt("Build {s}", .{ x.name }),
			);
			install_step.dependOn(&install_cmd.step);
			b.getInstallStep().dependOn(&install_cmd.step);

			const run_cmd = b.addRunArtifact(exe);
			run_cmd.step.dependOn(&install_cmd.step);
			run_step.dependOn(&run_cmd.step);
		}
	}
}
