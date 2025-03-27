const std = @import("std");
const LinkMode = std.builtin.LinkMode;

const Options = struct {
	util: bool = true,
	extra: bool = true,
	multi: bool = false,
	double: bool = false,
	linkage: LinkMode = .static,
};

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const default: Options = .{};
	const opt: Options = .{
		.util = b.option(bool, "util", "compile utilities in `libpd_wrapper/util` (default)")
			orelse default.util,
		.extra = b.option(bool, "extra", "compile `pure-data/extra` externals which are then inited in libpd_init() (default)")
			orelse default.extra,
		.multi = b.option(bool, "multi", "compile with multiple instance support")
			orelse default.multi,
		.double = b.option(bool, "double", "compile with double-precision support")
			orelse default.double,
		.linkage = b.option(LinkMode, "linkage", "Library linking method")
			orelse default.linkage,
	};

	const lib_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	const lib = b.addLibrary(.{
		.name = "pd",
		.linkage = opt.linkage,
		.root_module = lib_mod,
	});

	const pd_dep = b.dependency("pure_data", .{
		.target = target,
		.optimize = optimize,
	});
	lib.addIncludePath(pd_dep.path("src"));

	var files: std.ArrayList([]const u8) = .init(b.allocator);
	defer files.deinit();
	try files.appendSlice(&sources);
	if (opt.extra) {
		try files.appendSlice(&extra_sources);
	}
	if (opt.util) {
		try files.appendSlice(&util_sources);
	}

	var flags: std.ArrayList([]const u8) = .init(b.allocator);
	defer flags.deinit();
	try flags.append("-fno-sanitize=undefined");
	if (optimize != .Debug) {
		try flags.appendSlice(&.{
			"-ffast-math",
			"-funroll-loops",
			"-fomit-frame-pointer",
			"-Wno-error=date-time",
		});
	}

	lib_mod.addCMacro("PD", "1");
	lib_mod.addCMacro("PD_INTERNAL", "1");
	lib_mod.addCMacro("USEAPI_DUMMY", "1");
	lib_mod.addCMacro("HAVE_UNISTD_H", "1");

	if (opt.multi) {
		lib_mod.addCMacro("PDINSTANCE", "1");
		lib_mod.addCMacro("PDTHREADS", "1");
	}

	if (opt.double) {
		lib_mod.addCMacro("PD_FLOATSIZE", "64");
	}

	const os = target.result.os.tag;
	switch (os) {
		.windows => {
			lib_mod.addCMacro("WINVER", "0x502");
			lib_mod.addCMacro("WIN32", "1");
			lib_mod.addCMacro("_WIN32", "1");
			lib.linkSystemLibrary("ws2_32");
			lib.linkSystemLibrary("kernel32");
		},
		.macos => {
			lib_mod.addCMacro("HAVE_ALLOCA_H", "1");
			lib_mod.addCMacro("HAVE_LIBDL", "1");
			lib_mod.addCMacro("HAVE_MACHINE_ENDIAN_H", "1");
			lib_mod.addCMacro("_DARWIN_C_SOURCE", "1");
			lib_mod.addCMacro("_DARWIN_UNLIMITED_SELECT", "1");
			lib_mod.addCMacro("FD_SETSIZE", "10240");
			lib.linkSystemLibrary("dl");
		},
		.emscripten, .wasi => {
			const sysroot = b.sysroot
				orelse @panic("Pass '--sysroot \"$EMSDK/upstream/emscripten\"'");
			const cache_include = std.fs.path.join(b.allocator, &.{
				sysroot, "cache", "sysroot", "include",
			}) catch @panic("Out of memory");

			var dir = std.fs.openDirAbsolute(cache_include, std.fs.Dir.OpenDirOptions{
				.access_sub_paths = true,
				.no_follow = true,
			}) catch @panic("No emscripten cache. Generate it!");
			dir.close();
			lib.addSystemIncludePath(.{ .cwd_relative = cache_include });
		},
		else => { // Linux and FreeBSD
			try flags.appendSlice(&.{
				"-Wno-int-to-pointer-cast",
				"-Wno-pointer-to-int-cast",
			});
			lib_mod.addCMacro("HAVE_ENDIAN_H", "1");
			if (os == .linux) {
				lib_mod.addCMacro("HAVE_ALLOCA_H", "1");
				lib_mod.addCMacro("HAVE_LIBDL", "1");
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

	const mod = b.addModule("libpd", .{
		.target = target,
		.optimize = optimize,
		.root_source_file = b.path("libpd.zig"),
		.imports = &.{.{ .name = "pd", .module = pdmod_dep.module("pd") }},
	});
	mod.linkLibrary(lib);
}

const sources = [_][]const u8{
	"src/d_arithmetic.c",
	"src/d_array.c",
	"src/d_ctl.c",
	"src/d_dac.c",
	"src/d_delay.c",
	"src/d_fft.c",
	"src/d_fft_fftsg.c",
	"src/d_filter.c",
	"src/d_global.c",
	"src/d_math.c",
	"src/d_misc.c",
	"src/d_osc.c",
	"src/d_resample.c",
	"src/d_soundfile.c",
	"src/d_soundfile_aiff.c",
	"src/d_soundfile_caf.c",
	"src/d_soundfile_next.c",
	"src/d_soundfile_wave.c",
	"src/d_ugen.c",
	"src/g_all_guis.c",
	"src/g_array.c",
	"src/g_bang.c",
	"src/g_canvas.c",
	"src/g_clone.c",
	"src/g_editor.c",
	"src/g_editor_extras.c",
	"src/g_graph.c",
	"src/g_guiconnect.c",
	"src/g_io.c",
	"src/g_mycanvas.c",
	"src/g_numbox.c",
	"src/g_radio.c",
	"src/g_readwrite.c",
	"src/g_rtext.c",
	"src/g_scalar.c",
	"src/g_slider.c",
	"src/g_template.c",
	"src/g_text.c",
	"src/g_toggle.c",
	"src/g_traversal.c",
	"src/g_undo.c",
	"src/g_vumeter.c",
	"src/m_atom.c",
	"src/m_binbuf.c",
	"src/m_class.c",
	"src/m_conf.c",
	"src/m_glob.c",
	"src/m_memory.c",
	"src/m_obj.c",
	"src/m_pd.c",
	"src/m_sched.c",
	"src/s_audio.c",
	"src/s_audio_dummy.c",
	"src/s_inter.c",
	"src/s_inter_gui.c",
	"src/s_loader.c",
	"src/s_main.c",
	"src/s_net.c",
	"src/s_path.c",
	"src/s_print.c",
	"src/s_utf8.c",
	"src/x_acoustics.c",
	"src/x_arithmetic.c",
	"src/x_array.c",
	"src/x_connective.c",
	"src/x_file.c",
	"src/x_gui.c",
	"src/x_interface.c",
	"src/x_list.c",
	"src/x_midi.c",
	"src/x_misc.c",
	"src/x_net.c",
	"src/x_scalar.c",
	"src/x_text.c",
	"src/x_time.c",
	"src/x_vexp.c",
	"src/x_vexp_if.c",
	"src/x_vexp_fun.c",
	"src/s_libpdmidi.c",
	"src/x_libpdreceive.c",
	"src/z_hooks.c",
	"src/z_libpd.c",
};

const extra_sources = [_][]const u8{
	"extra/bob~/bob~.c",
	"extra/bonk~/bonk~.c",
	"extra/choice/choice.c",
	"extra/fiddle~/fiddle~.c",
	"extra/loop~/loop~.c",
	"extra/lrshift~/lrshift~.c",
	"extra/pique/pique.c",
	"extra/pd~/pd~.c",
	"extra/pd~/pdsched.c",
	"extra/sigmund~/sigmund~.c",
	"extra/stdout/stdout.c",
};

const util_sources = [_][]const u8{
	"src/z_print_util.c",
	"src/z_queued.c",
	"src/z_ringbuffer.c"
};
