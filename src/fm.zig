const std = @import("std");
const pd = @import("libpd");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const channels = 2;
const block = 64 * channels;

inline fn allocPrintZ(
	gpa: Allocator,
	comptime fmt: []const u8,
	args: anytype,
) Allocator.Error![:0]u8 {
	return std.fmt.allocPrintSentinel(gpa, fmt, args, 0);
}

fn floatHook(recv: [*:0]const u8, f: f32) callconv(.c) void {
	rl.traceLog(.info, "%s: %g", .{ recv, f });
}

fn sendFloat(dest: [*:0]const u8, f: f32) void {
	pd.sendFloat(dest, f) catch rl.traceLog(.warning, "couldn't find `%s`", .{ dest });
}

/// Holds the unused suffix of a processed block and supplies it to the next callback.
const TailBuffer = struct {
	buffer: [block]i16 = undefined,
	/// Starting index of leftover samples.
	onset: usize = block,

	/// Copy leftover samples into `buf`, returning the unused tail of `buf`.
	fn drain(self: *const TailBuffer, buf: []i16) []i16 {
		const count = block - self.onset;
		@memcpy(buf[0..count], self.buffer[self.onset..]);
		return buf[count..];
	}

	/// Copy the prefix into `buf` and hold the remaining suffix for the next callback.
	fn store(self: *TailBuffer, buf: []i16) void {
		if (buf.len > 0) {
			pd.processShort(1, null, &self.buffer) catch return;
			@memcpy(buf, self.buffer[0..buf.len]);
			self.onset = buf.len;
		} else {
			self.onset = block;
		}
	}
};

const AudioController = struct {
	/// handles freeing of the ring buffer, if in queued mode
	base: pd.Base,
	/// raylib audio stream
	stream: rl.AudioStream,
	/// receiver for "toZig"
	rec_tozig: *anyopaque,

	var tail: TailBuffer = .{};

	fn callback(buffer: ?*anyopaque, frames: c_uint) callconv(.c) void {
		var buf: []i16 = blk: {
			const ptr: [*]i16 = @ptrCast(@alignCast(buffer orelse return));
			break :blk ptr[0 .. frames * channels];
		};
		buf = tail.drain(buf);

		// pd delivers samples in blocks, so we round down to a multiple of block size
		const ticks = buf.len / block;
		pd.processShort(@intCast(ticks), null, buf.ptr) catch return;
		buf = buf[ticks * block..];

		tail.store(buf);
	}

	fn init(sample_rate: u32, bit_depth: u32) !AudioController {
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

		return .{
			.base = base,
			.stream = stream,
			.rec_tozig = rec_tozig,
		};
	}

	fn close(self: *const AudioController) void {
		self.base.close();
		pd.unbind(self.rec_tozig);

		rl.traceLog(.info, "PD: audio processing stopped successfully", .{});
		rl.unloadAudioStream(self.stream);
		rl.closeAudioDevice();
	}
};

const Slope = struct {
	m: f32,
	b: f32,

	fn init(min: f32, max: f32, run: f32) Slope {
		return .{
			.m = (max - min) / run,
			.b = min,
		};
	}

	fn at(self: Slope, x: f32) f32 {
		return self.m * x + self.b;
	}
};

const Line = struct {
	start: rl.Vector2,
	end: rl.Vector2,
	color: rl.Color,

	fn init(x1: f32, y1: f32, x2: f32, y2: f32, color: rl.Color) Line {
		return .{
			.start = .{ .x = x1, .y = y1 },
			.end   = .{ .x = x2, .y = y2 },
			.color = color,
		};
	}

	fn draw(self: Line) void {
		rl.drawLineV(self.start, self.end, self.color);
	}
};

pub fn main() !void {
	//---------------------------------------------------------------------------
	// Initialization
	const screenWidth = 700;
	const screenHeight = 700;
	rl.initWindow(screenWidth, screenHeight,
		"raylib-zig [core] example - libpd audio streaming");
	defer rl.closeWindow();

	const audio: AudioController = try .init(48000, 16);
	defer audio.close();

	const patch: pd.Patch = try .fromFile("test.pd", "./pd");
	defer patch.close();

	rl.setTargetFPS(30); // Set our game to run at 30 frames-per-second

	const pan: Slope = .init(-1, 1, screenWidth);
	const freq: Slope = .init(0, 300, screenWidth);
	const tone: Slope = .init(100, 5, screenHeight);
	const idx: Slope = .init(3200, 0, screenHeight);
	var carrier: f32 = 400;

	const s_pan = try allocPrintZ(rl.mem, "{d}pan", .{ patch.dollar_zero });
	defer rl.mem.free(s_pan);
	const s_freq = try allocPrintZ(rl.mem, "{d}freq", .{ patch.dollar_zero });
	defer rl.mem.free(s_freq);
	const s_tone = try allocPrintZ(rl.mem, "{d}tone", .{ patch.dollar_zero });
	defer rl.mem.free(s_tone);
	const s_idx = try allocPrintZ(rl.mem, "{d}idx", .{ patch.dollar_zero });
	defer rl.mem.free(s_idx);
	const s_car = try allocPrintZ(rl.mem, "{d}car", .{ patch.dollar_zero });
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
			gl[i]     = .init(wi, 0,  wi,          screenHeight, .dark_gray);
			gl[i + 1] = .init(0,  hi, screenWidth, hi,           .dark_gray);
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
			const val: f32 = if (wheel < 0) -1 else 1;
			carrier *= @exp2(val / 12);
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
