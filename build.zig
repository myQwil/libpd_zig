const std = @import("std");
const LinkMode = std.builtin.LinkMode;

pub const Options = struct {
	util: bool = true,
	extra: bool = true,
	multi: bool = false,
	double: bool = false,
	linkage: LinkMode = .static,
};

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const defaults = Options{};
	const opt = Options{
		.util = b.option(bool, "util", "compile utilities in `libpd_wrapper/util` (default)")
			orelse defaults.util,
		.extra = b.option(bool, "extra", "compile `pure-data/extra` externals which are then inited in libpd_init() (default)")
			orelse defaults.extra,
		.multi = b.option(bool, "multi", "compile with multiple instance support")
			orelse defaults.multi,
		.double = b.option(bool, "double", "compile with double-precision support")
			orelse defaults.double,
		.linkage = b.option(LinkMode, "linkage", "Library linking method")
			orelse defaults.linkage,
	};

	const lib = b.addLibrary(.{
		.name = "pd",
		.linkage = opt.linkage,
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});

	const pd_dep = b.dependency("pure_data", .{
		.target = target,
		.optimize = optimize,
	});
	lib.addIncludePath(pd_dep.path("src"));

	var files = std.ArrayList([]const u8).init(b.allocator);
	defer files.deinit();
	for ([_][]const u8{
		"d_arithmetic", "d_array", "d_ctl", "d_dac", "d_delay", "d_fft",
		"d_fft_fftsg", "d_filter", "d_global", "d_math", "d_misc", "d_osc",
		"d_resample", "d_soundfile", "d_soundfile_aiff", "d_soundfile_caf",
		"d_soundfile_next", "d_soundfile_wave", "d_ugen",
		"g_all_guis", "g_array", "g_bang", "g_canvas", "g_clone", "g_editor",
		"g_editor_extras", "g_graph", "g_guiconnect", "g_io", "g_mycanvas",
		"g_numbox", "g_radio", "g_readwrite", "g_rtext", "g_scalar",
		"g_slider", "g_template", "g_text", "g_toggle", "g_traversal",
		"g_undo", "g_vumeter",
		"m_atom", "m_binbuf", "m_class", "m_conf", "m_glob", "m_memory",
		"m_obj", "m_pd", "m_sched",
		"s_audio", "s_audio_dummy", "s_inter", "s_inter_gui", "s_loader",
		"s_main", "s_net", "s_path", "s_print", "s_utf8",
		"x_acoustics", "x_arithmetic", "x_array", "x_connective", "x_file",
		"x_gui", "x_interface", "x_list", "x_midi", "x_misc", "x_net",
		"x_scalar", "x_text", "x_time", "x_vexp", "x_vexp_if", "x_vexp_fun",
		"s_libpdmidi", "x_libpdreceive", "z_hooks", "z_libpd",
	}) |s| {
		try files.append(b.fmt("{s}{s}.c", .{ "src/", s }));
	}

	if (opt.extra) {
		for ([_][]const u8{
			"bob~", "bonk~", "choice", "fiddle~", "loop~", "lrshift~", "pique", "pd~",
			"sigmund~", "stdout",
		}) |s| {
			try files.append(b.fmt("{s}{s}/{s}.c", .{ "extra/", s, s }));
		}
		try files.append("extra/pd~/pdsched.c");
		lib.root_module.addCMacro("LIBPD_EXTRA", "1");
	}

	if (opt.util) {
		for ([_][]const u8{ "z_print_util", "z_queued", "z_ringbuffer" }) |s| {
			try files.append(b.fmt("{s}{s}.c", .{ "src/", s }));
		}
	}

	lib.root_module.addCMacro("PD", "1");
	lib.root_module.addCMacro("PD_INTERNAL", "1");
	lib.root_module.addCMacro("USEAPI_DUMMY", "1");
	lib.root_module.addCMacro("HAVE_UNISTD_H", "1");

	if (opt.multi) {
		lib.root_module.addCMacro("PDINSTANCE", "1");
		lib.root_module.addCMacro("PDTHREADS", "1");
	}

	if (opt.double) {
		lib.root_module.addCMacro("PD_FLOATSIZE", "64");
	}

	var flags = std.ArrayList([]const u8).init(b.allocator);
	defer flags.deinit();
	try flags.append("-fno-sanitize=undefined");
	if (optimize != .Debug) {
		try flags.appendSlice(&.{
			"-ffast-math", "-funroll-loops", "-fomit-frame-pointer", "-Wno-error=date-time",
		});
	}

	const os = target.result.os.tag;
	switch (os) {
		.windows => {
			lib.root_module.addCMacro("WINVER", "0x502");
			lib.root_module.addCMacro("WIN32", "1");
			lib.root_module.addCMacro("_WIN32", "1");
			lib.linkSystemLibrary("ws2_32");
			lib.linkSystemLibrary("kernel32");
		},
		.macos => {
			lib.root_module.addCMacro("HAVE_ALLOCA_H", "1");
			lib.root_module.addCMacro("HAVE_LIBDL", "1");
			lib.root_module.addCMacro("HAVE_MACHINE_ENDIAN_H", "1");
			lib.root_module.addCMacro("_DARWIN_C_SOURCE", "1");
			lib.root_module.addCMacro("_DARWIN_UNLIMITED_SELECT", "1");
			lib.root_module.addCMacro("FD_SETSIZE", "10240");
			lib.linkSystemLibrary("dl");
		},
		.emscripten, .wasi => {
			const sysroot = b.sysroot
				orelse @panic("Pass '--sysroot \"$EMSDK/upstream/emscripten\"'");
			const cache_include = std.fs.path.join(b.allocator, &.{
				sysroot, "cache", "sysroot", "include"
			}) catch @panic("Out of memory");

			var dir = std.fs.openDirAbsolute(cache_include, std.fs.Dir.OpenDirOptions{
				.access_sub_paths = true, .no_follow = true,
			}) catch @panic("No emscripten cache. Generate it!");
			dir.close();
			lib.addSystemIncludePath(.{ .cwd_relative = cache_include });
		},
		else => { // Linux and FreeBSD
			try flags.appendSlice(&.{
				"-Wno-int-to-pointer-cast", "-Wno-pointer-to-int-cast"
			});
			lib.root_module.addCMacro("HAVE_ENDIAN_H", "1");
			if (os == .linux) {
				lib.root_module.addCMacro("HAVE_ALLOCA_H", "1");
				lib.root_module.addCMacro("HAVE_LIBDL", "1");
				lib.linkSystemLibrary("dl");
			}
		}
	}

	if (os != .emscripten and os != .wasi and opt.linkage == .dynamic) {
		lib.linkSystemLibrary("pthread");
		lib.linkSystemLibrary("m");
	}

	lib.addCSourceFiles(.{
		.root = pd_dep.path("."),
		.files = files.items,
		.flags = flags.items,
	});

	b.installArtifact(lib);

	const pdmod_dep = b.dependency("pd_module", .{
		.target = target,
		.optimize = optimize,
		.float_size = @as(u8, if (opt.double) 64 else 32),
	});

	const mod = b.addModule("pd", .{
		.target = target,
		.optimize = optimize,
		.root_source_file = b.path("libpd.zig"),
		.imports = &.{.{ .name = "pd", .module = pdmod_dep.module("pd") }},
	});
	mod.linkLibrary(lib);
}
