const std = @import("std");
const pd = @import("libpd");
const rl = @import("raylib");

const Slope = struct {
	m: f32,
	b: f32,

	fn new(min: f32, max: f32, run: f32) Slope {
		return Slope{
			.m = (max - min) / run,
			.b = min,
		};
	}

	fn at(self: *const Slope, x: f32) f32 {
		return self.m * x + self.b;
	}
};

fn AudioController(channels: u32) type { return struct {
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

	fn callback(buffer: ?*anyopaque, frames: c_uint) callconv(.c) void {
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

	fn floatHook(recv: [*:0]const u8, f: f32) callconv(.c) void {
		rl.traceLog(.info, "%s: %g", .{ recv, f });
	}

	fn init(sample_rate: u32, bit_depth: u32) !Self {
		rl.initAudioDevice();
		errdefer rl.closeAudioDevice();

		// may help with audio stuttering
		//rl.setAudioStreamBufferSizeDefault(4096);

		const stream = try rl.loadAudioStream(sample_rate, bit_depth, channels);
		errdefer rl.unloadAudioStream(stream);

		rl.setAudioStreamCallback(stream, &callback);
		rl.playAudioStream(stream);

		// Pd initialization
		const base: pd.Base = try .init(
			0, @intCast(channels), @intCast(sample_rate), false,
		);
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

const Line = struct {
	start: rl.Vector2,
	end: rl.Vector2,
	color: rl.Color,

	fn new(x1: f32, y1: f32, x2: f32, y2: f32, color: rl.Color) Line {
		return .{
			.start = .{ .x = x1, .y = y1 },
			.end   = .{ .x = x2, .y = y2 },
			.color = color,
		};
	}

	fn draw(self: *const Line) void {
		rl.drawLineV(self.start, self.end, self.color);
	}
};

fn sendBang(dest: [*:0]const u8) void {
	pd.sendBang(dest) catch rl.traceLog(.warning, "couldn't find `%s`", .{ dest });
}

fn sendFloat(dest: [*:0]const u8, f: f32) void {
	pd.sendFloat(dest, f) catch rl.traceLog(.warning, "couldn't find `%s`", .{ dest });
}

pub fn main() !void {
	//---------------------------------------------------------------------------
	// Initialization
	const screenWidth = 700;
	const screenHeight = 700;
	rl.initWindow(screenWidth, screenHeight,
		"raylib-zig [core] example - libpd audio streaming");
	defer rl.closeWindow();

	const audio: AudioController(2) = try .init(48000, 16);
	defer audio.close();

	const patch: pd.Patch = try .fromFile("test.pd", "./pd");
	defer patch.close();

	rl.setTargetFPS(30); // Set our game to run at 30 frames-per-second

	const pan: Slope = .new(-1, 1, screenWidth);
	const freq: Slope = .new(0, 300, screenWidth);
	const tone: Slope = .new(100, 5, screenHeight);
	const idx: Slope = .new(3200, 0, screenHeight);
	var carrier: f32 = 400;

	const s_pan = try std.fmt.allocPrintZ(rl.mem, "{d}pan", .{ patch.dollar_zero });
	defer rl.mem.free(s_pan);
	const s_freq = try std.fmt.allocPrintZ(rl.mem, "{d}freq", .{ patch.dollar_zero });
	defer rl.mem.free(s_freq);
	const s_tone = try std.fmt.allocPrintZ(rl.mem, "{d}tone", .{ patch.dollar_zero });
	defer rl.mem.free(s_tone);
	const s_idx = try std.fmt.allocPrintZ(rl.mem, "{d}idx", .{ patch.dollar_zero });
	defer rl.mem.free(s_idx);
	const s_car = try std.fmt.allocPrintZ(rl.mem, "{d}car", .{ patch.dollar_zero });
	defer rl.mem.free(s_car);

	const grid = blk: {
		const rows = 8.0;
		const lines = (rows - 1) * 2;
		var gl: [lines]Line = undefined;
		const inc: f32 = 1.0 / rows;
		var f = inc;
		var i: u32 = 0;
		while (i < lines) : ({f += inc; i += 2;}) {
			const wi: f32 = screenWidth * f;
			const hi: f32 = screenHeight * f;
			gl[i]     = .new(wi, 0,  wi,          screenHeight, .dark_gray);
			gl[i + 1] = .new(0,  hi, screenWidth, hi,           .dark_gray);
		}
		break :blk gl;
	};


	//---------------------------------------------------------------------------
	// Main game loop
	while (!rl.windowShouldClose()) { // Detect window close button or ESC key
		//------------------------------------------------------------------------
		// Update
		if (rl.isMouseButtonDown(.left)) {
			const m_pos = rl.getMousePosition();
			sendFloat(s_freq.ptr, freq.at(m_pos.x));
			sendFloat(s_idx.ptr, idx.at(m_pos.y));
		}
		if (rl.isMouseButtonPressed(.right)) {
			const m_pos = rl.getMousePosition();
			sendFloat(s_pan.ptr, pan.at(m_pos.x));
			sendFloat(s_tone.ptr, tone.at(m_pos.y));
		}
		const wheel = rl.getMouseWheelMove();
		if (wheel != 0) {
			carrier *= @exp2(wheel / 12);
			sendFloat(s_car.ptr, carrier);
		}

		//------------------------------------------------------------------------
		// Draw
		rl.beginDrawing();
		defer rl.endDrawing();

		rl.clearBackground(.black);

		for (&grid) |*g| {
			g.draw();
		}

		if (rl.isMouseButtonDown(.left)) {
			rl.drawText("mouse1", screenWidth - 220, 10, 20, .red);
		}
		if (rl.isMouseButtonDown(.right)) {
			rl.drawText("mouse2", screenWidth - 120, 10, 20, .green);
		}
	}
}
