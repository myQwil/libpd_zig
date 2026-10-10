const std = @import("std");
const emsdk = @import("raylib_zig").emsdk;

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	//---------------------------------------------------------------------------
	// Dependencies
	const rlz_dep = b.dependency("raylib_zig", .{
		.target = target,
		.optimize = optimize,
	});
	const rlz_mod = rlz_dep.module("raylib");
	const rlz_lib = rlz_dep.artifact("raylib");
	const em_dep = rlz_dep.builder.dependency("emsdk", .{});
	const rl_dep = rlz_dep.builder.dependency("raylib", .{});

	const os = target.result.os.tag;
	const pd_dep = b.dependency("pd", .{
		.target = target,
		.optimize = optimize,
		.emsdk_inc = if (os == .emscripten)
			em_dep.path("upstream/emscripten/cache/sysroot/include")
		else null,
	});
	const libpd_mod = pd_dep.module("libpd");
	const pd_lib = pd_dep.artifact("pd");
	const activate_emsdk_step = try emsdk.activateEmsdkStep(b);
	pd_lib.step.dependOn(activate_emsdk_step);

	//---------------------------------------------------------------------------
	// Examples
	const examples = [_][]const u8{ "fm" };

	for (examples) |name| {
		const mod = b.createModule(.{
			.root_source_file = b.path(b.fmt("src/{s}.zig", .{ name })),
			.target = target,
			.optimize = optimize,
			.imports = &.{
				.{ .name = "libpd", .module = libpd_mod },
				.{ .name = "raylib", .module = rlz_mod },
			},
		});

		const install_step = b.step(name, b.fmt("Build {s}", .{ name }));
		const run_step = b.step(
			b.fmt("run_{s}", .{ name }),
			b.fmt("Build and run {s}", .{ name }),
		);

		if (os == .emscripten) {
			const wasm = b.addLibrary(.{
				.name = name,
				.root_module = mod,
			});
			const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
				.optimize = optimize,
			});
			const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
				.optimize = optimize,
			});

			const html_filename = b.fmt("{s}.html", .{ name });
			const emcc_step = try emsdk.emccStep(b, &.{}, &.{ rlz_lib, wasm }, .{
				.optimize = optimize,
				.flags = emcc_flags,
				.settings = emcc_settings,
				.shell_file_path = rl_dep.path("src/shell.html"),
				.install_dir = .{ .custom = "web" },
				.preload_paths = &.{.{ .src_path = .{ .cwd_relative = "pd" } }},
				.out_file_name = html_filename,
			});

			const emrun_step = try emsdk.emrunStep(
				b,
				b.graph.path(.install_prefix, b.fmt("web/{s}", .{ html_filename })),
				&.{},
			);
			emrun_step.dependOn(emcc_step);

			install_step.dependOn(emcc_step);
			run_step.dependOn(emrun_step);
		} else {
			const exe = b.addExecutable(.{
				.name = name,
				.root_module = mod,
			});

			const install_cmd = b.addInstallArtifact(exe, .{});
			install_step.dependOn(&install_cmd.step);
			b.getInstallStep().dependOn(&install_cmd.step);

			const run_cmd = b.addRunArtifact(exe);
			run_cmd.step.dependOn(&install_cmd.step);
			run_step.dependOn(&run_cmd.step);
		}
	}
}
