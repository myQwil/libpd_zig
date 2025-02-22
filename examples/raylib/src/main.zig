const std = @import("std");
const pd = @import("pd");
const rl = @import("raylib");

const Slope = struct {
	const Self = @This();

	m: f32,
	b: f32,

	fn new(min: f32, max: f32, run: f32) Self {
		return Self{
			.m = (max - min) / run,
			.b = min,
		};
	}

	fn at(self: *const Self, x: f32) f32 {
		return self.m * x + self.b;
	}
};

fn AudioController(
	sample_rate: u32,
	bit_depth: u32,
	channels: u32,
) type { return struct {
	const Self = @This();

	/// handles freeing of the ring buffer, if in queued mode
	base: pd.Base,
	/// raylib audio stream
	stream: rl.AudioStream,
	/// receiver for "toZig"
	rec_tozig: *anyopaque,

	const block = 64 * channels;
	/// buffer that holds excess samples to be used in the next callback
	var bridge: [block]i16 = undefined;
	var onset: usize = block;

	fn callback(buffer: ?*anyopaque, frames: c_uint) callconv(.C) void {
		var buf: []i16 = @as([*]i16, @alignCast(@ptrCast(buffer orelse return)))
			[0..frames * channels];
		const prev = block - onset;
		@memcpy(buf[0..prev], bridge[onset..]);
		buf = buf[prev..];

		// pd delivers samples in blocks, so we round down to a multiple of block size
		const ticks = buf.len / block;
		pd.processShort(@intCast(ticks), null, buf.ptr) catch return;
		buf = buf[ticks * block..];

		if (buf.len > 0) {
			// fill the buffer with part of a block and use the rest in next callback
			pd.processShort(1, null, &bridge) catch return;
			@memcpy(buf, bridge[0..buf.len]);
			onset = buf.len;
		} else {
			onset = block;
		}
	}

	fn floatHook(recv: [*:0]const u8, f: f32) callconv(.C) void {
		rl.traceLog(.info, "%s: %g", .{ recv, f });
	}

	fn init() !Self {
		rl.initAudioDevice();
		errdefer rl.closeAudioDevice();

		// may help with audio stuttering
		//rl.setAudioStreamBufferSizeDefault(4096);

		const stream = try rl.loadAudioStream(sample_rate, bit_depth, channels);
		errdefer rl.unloadAudioStream(stream);

		rl.setAudioStreamCallback(stream, &callback);
		rl.playAudioStream(stream);

		// Pd initialization
		const base = try pd.Base.init(0, channels, sample_rate, false);
		errdefer base.close();

		// subscribe to receive source
		const rec_tozig = try pd.bind("toZig");
		errdefer pd.unbind(rec_tozig);

		// set hooks
		pd.setFloatHook(&floatHook);

		// add the data/pd folder to the search path
		pd.addToSearchPath("pd/lib");

		// audio processing on
		pd.computeAudio(true);

		return Self{
			.base = base,
			.stream = stream,
			.rec_tozig = rec_tozig,
		};
	}

	fn close(self: *const Self) void {
		self.base.close();
		pd.unbind(self.rec_tozig);

		rl.traceLog(.info, "PD: audio processing stopped successfully", .{});
		rl.unloadAudioStream(self.stream);
		rl.closeAudioDevice();
	}
};}

fn sendBang(dest: [*:0]const u8) void {
	pd.sendBang(dest) catch rl.traceLog(.warning, "couldn't find `%s`", .{ dest });
}

fn sendFloat(dest: [*:0]const u8, f: f32) void {
	pd.sendFloat(dest, f) catch rl.traceLog(.warning, "couldn't find `%s`", .{ dest });
}

pub fn main() !void {
	//---------------------------------------------------------------------------
	// Initialization
	const screenWidth = 800;
	const screenHeight = 450;
	rl.initWindow(screenWidth, screenHeight,
		"raylib-zig [core] example - libpd audio streaming");
	defer rl.closeWindow();

	const audio = try AudioController(48000, 16, 2).init();
	defer audio.close();

	const patch = try pd.Patch.fromFile("test.pd", "./pd");
	defer patch.close();

	rl.setTargetFPS(30); // Set our game to run at 30 frames-per-second

	const freq = Slope.new(0, 300, screenWidth);
	const idx = Slope.new(3200, 0, screenHeight);

	const s_tone = try std.fmt.allocPrintZ(rl.mem, "{d}tone", .{ patch.dollar_zero });
	defer rl.mem.free(s_tone);
	const s_freq = try std.fmt.allocPrintZ(rl.mem, "{d}freq", .{ patch.dollar_zero });
	defer rl.mem.free(s_freq);
	const s_idx = try std.fmt.allocPrintZ(rl.mem, "{d}idx", .{ patch.dollar_zero });
	defer rl.mem.free(s_idx);

	//---------------------------------------------------------------------------
	// Main game loop
	while (!rl.windowShouldClose()) { // Detect window close button or ESC key
		//------------------------------------------------------------------------
		// Update
		if (rl.isMouseButtonDown(.left)) {
			rl.drawText("mouse1", screenWidth - 220, 10, 20, rl.Color.dark_green);
			const m_pos = rl.getMousePosition();
			sendFloat(s_freq.ptr, freq.at(m_pos.x));
			sendFloat(s_idx.ptr, idx.at(m_pos.y));
		}
		if (rl.isMouseButtonPressed(.right)) {
			sendBang(s_tone.ptr);
		}

		//------------------------------------------------------------------------
		// Draw
		rl.beginDrawing();
		defer rl.endDrawing();

		if (rl.isMouseButtonDown(.right)) {
			rl.drawText("mouse2", screenWidth - 120, 10, 20, rl.Color.red);
		}

		rl.clearBackground(rl.Color.ray_white);
	}
}
