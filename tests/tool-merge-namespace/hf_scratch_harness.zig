//! Real HfText CPU parity/lifetime harness. Copy beside hf_text.zig in an isolated source tree.
//! Inputs are public model metadata plus synthetic fixture JSON. No engine/GPU imports.
const std = @import("std");
const hf = @import("hf_text.zig");
const json = @import("json.zig");
const model_text = @import("model_text.zig");
const A = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Tracking = struct {
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(t: *Tracking) A {
        return .{ .ptr = t, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn self(p: *anyopaque) *Tracking { return @ptrCast(@alignCast(p)); }
    fn alloc(p: *anyopaque, n: usize, al: Alignment, ra: usize) ?[*]u8 {
        const t = self(p);
        if (t.denied) return null;
        const out = std.heap.page_allocator.rawAlloc(n, al, ra) orelse return null;
        t.live += n;
        t.peak = @max(t.peak, t.live);
        return out;
    }
    fn resize(p: *anyopaque, old: []u8, al: Alignment, n: usize, ra: usize) bool {
        const t = self(p);
        if (t.denied and n > old.len) return false;
        if (!std.heap.page_allocator.rawResize(old, al, n, ra)) return false;
        t.live = t.live - old.len + n;
        t.peak = @max(t.peak, t.live);
        return true;
    }
    fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 { return null; }
    fn free(p: *anyopaque, old: []u8, al: Alignment, ra: usize) void {
        const t = self(p);
        std.debug.assert(t.live >= old.len);
        t.live -= old.len;
        std.heap.page_allocator.rawFree(old, al, ra);
    }
};

fn equals(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }

fn gate(expected: u8) !void {
    var byte: [1]u8 = undefined;
    if (try std.posix.read(0, &byte) != 1 or byte[0] != expected) return error.InvalidRunnerHandshake;
}

fn bytes(label: []const u8, generation: bool, special: bool, value: []const u8) void {
    // ASCII hex preserves all bytes, including malformed UTF-8. No formatter dependency.
    std.debug.print("DATA {s} {d} {d} {d} ", .{ label, @intFromBool(generation), @intFromBool(special), value.len });
    const digits = "0123456789abcdef";
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    while (pos < value.len) {
        const n: usize = @min(buf.len / 2, value.len - pos);
        for (value[pos..][0..n], 0..) |b, i| {
            buf[2 * i] = digits[b >> 4];
            buf[2 * i + 1] = digits[b & 15];
        }
        std.debug.print("{s}", .{buf[0 .. 2 * n]});
        pos += n;
    }
    std.debug.print("\n", .{});
}

fn metric(phase: []const u8, generation: bool, t: *const Tracking, arena: *const std.heap.ArenaAllocator) void {
    std.debug.print("METRIC phase={s} generation={d} owner_live={d} owner_peak={d} request_capacity={d}\n", .{ phase, @intFromBool(generation), t.live, t.peak, arena.queryCapacity() });
}

const MockJob = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    rendered: []const u8,
    ids: []const u32,
    expected_text: u64,
    expected_ids: u64,
    valid: bool = false,
    fn run(job: *MockJob) void {
        while (!job.cancelled.load(.acquire)) std.atomic.spinLoopHint();
        job.valid = std.hash.Wyhash.hash(0, job.rendered) == job.expected_text and
            std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(job.ids)) == job.expected_ids;
        job.finished.store(true, .release);
    }
};

fn mockCancelDrain(rendered: []const u8, ids: []const u32) !void {
    // The consumer deliberately reads after cancellation. Request memory must
    // stay owned until finished/join, exactly the lifetime boundary under test.
    var job: MockJob = .{ .rendered = rendered, .ids = ids,
        .expected_text = std.hash.Wyhash.hash(0, rendered),
        .expected_ids = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(ids)) };
    const thread = try std.Thread.spawn(.{}, MockJob.run, .{&job});
    job.cancelled.store(true, .release);
    thread.join();
    if (!job.finished.load(.acquire) or !job.valid) return error.CancelDrainOwnershipFailure;
    std.debug.print("DATA mock_cancel_drained\n", .{});
}

fn caseRun(text: model_text.Text, fixture: json.Value) !void {
    const mode = fixture.strField("mode") orelse "normal";
    const msgs = fixture.get("messages") orelse return error.MissingMessages;
    const tools = fixture.get("tools");
    const thinking = if (fixture.get("thinking")) |v| v.bool else false;
    const effort = fixture.strField("effort");
    const expected = fixture.strField("expected_error");
    const memory_probe = if (fixture.get("memory_probe")) |v| v.bool else false;
    var tracking: Tracking = .{};
    var request: std.heap.ArenaAllocator = .init(tracking.allocator());
    defer {
        request.deinit();
        std.debug.print("METRIC phase=request_cleanup owner_live={d} owner_peak={d}\n", .{ tracking.live, tracking.peak });
        std.debug.assert(tracking.live == 0);
    }
    const a = request.allocator();
    std.debug.print("METRIC phase=request_begin\n", .{});
    for ([_]bool{ true, false }) |generation| {
        const options: model_text.RenderOptions = .{ .tools = tools, .enable_thinking = thinking, .reasoning_effort = effort, .add_generation_prompt = generation };
        var problem: []const u8 = "";
        if (equals(mode, "oom_render")) {
            tracking.denied = true;
            _ = text.render(tracking.allocator(), msgs, options, &problem) catch |err| {
                bytes(@errorName(err), generation, false, problem);
                if (err != error.OutOfMemory) return error.UnexpectedError;
                return;
            };
            return error.ExpectedOutOfMemory;
        }
        const rendered = text.render(a, msgs, options, &problem) catch |err| {
            // Read dynamic diagnostics after the function's scratch has been destroyed.
            // Also churn an unrelated mapping before reading again to expose stale pointers.
            bytes(@errorName(err), generation, false, problem);
            const churn = try std.heap.page_allocator.alloc(u8, 1 << 20);
            defer std.heap.page_allocator.free(churn);
            @memset(churn, 0xa5);
            bytes("error_after_churn", generation, false, problem);
            if (expected == null or !equals(expected.?, @errorName(err))) return error.UnexpectedError;
            metric("render_error", generation, &tracking, &request);
            continue;
        };
        if (expected != null) return error.ExpectedErrorMissing;
        metric("after_render", generation, &tracking, &request);
        bytes("render", generation, false, rendered);
        if (equals(mode, "cancel_after_render")) {
            try mockCancelDrain(rendered, &.{});
            std.debug.print("DATA cleanup_after_render\n", .{});
            return; // Simulates owner cleanup after preparation, not mid-render cancellation.
        }
        if (equals(mode, "oom_encode")) {
            tracking.denied = true;
            _ = text.encode(tracking.allocator(), rendered, false) catch |err| {
                bytes(@errorName(err), generation, false, "");
                if (err != error.OutOfMemory) return error.UnexpectedError;
                return;
            };
            return error.ExpectedOutOfMemory;
        }
        var last_ids: []const u32 = &.{};
        for ([_]bool{ false, true }) |special| {
            if (memory_probe and special) continue;
            const ids = try text.encode(a, rendered, special);
            last_ids = ids;
            metric("after_encode", generation, &tracking, &request);
            bytes("ids", generation, special, std.mem.sliceAsBytes(ids));
        }
        if (equals(mode, "cancel_after_encode")) {
            try mockCancelDrain(rendered, last_ids);
            std.debug.print("DATA cleanup_after_encode\n", .{});
            return;
        }
        // This bypasses JSON decoding deliberately: invalid UTF-8 reaches the actual
        // HfText.encode/tokenizer normalization path as raw bytes.
        const malformed = "Chinese: \xe4\xb8\xad\xe6\x96\x87; bad: \xff\xfe\xed\xa0\x80; tail";
        for ([_]bool{ false, true }) |special| {
            if (memory_probe) continue;
            const ids = text.encode(a, malformed, special) catch |err| {
                bytes(@errorName(err), generation, special, "invalid_utf8_encode");
                continue;
            };
            bytes("invalid_utf8_ids", generation, special, std.mem.sliceAsBytes(ids));
        }
    }
    metric("request_end", false, &tracking, &request);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const owner = init.arena.allocator();
    const args = try init.minimal.args.toSlice(owner);
    if (args.len == 2 and equals(args[1], "--hex-self-test")) {
        var data: [4097]u8 = undefined;
        for (&data, 0..) |*byte, i| byte.* = @intCast(i % 251);
        for ([_]usize{ 2048, 2049, 4096, 4097 }) |n| bytes("hex_self_test", false, false, data[0..n]);
        return 0;
    }
    if (args.len != 3) return error.ExpectedModelDirectoryAndFixture;
    const fixture_bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[2], owner, .limited(4 << 20));
    const fixture = switch (try json.parse(owner, fixture_bytes)) {
        .ok => |v| v,
        .err => return error.InvalidFixtureJson,
    };
    const id = fixture.strField("id") orelse return error.MissingFixtureId;
    bytes("fixture_id", false, false, id);
    var problem: []const u8 = "";
    const loaded = hf.HfText.load(init.gpa, io, args[1], owner, &problem) catch |err| {
        bytes("load_error", false, false, problem);
        return err;
    };
    defer loaded.deinit();
    // The real checkpoint may have no postprocessor prefix/suffix. A separate
    // explicit fixture exercises the same HfText concat branch with valid small
    // vocabulary IDs; model metadata and the main parity fixtures stay intact.
    const test_prefix = [_]u32{0};
    const test_suffix = [_]u32{1};
    if (fixture.get("force_boundary_tokens")) |v| {
        if (v.bool) {
            if (loaded.text().vocabSize() < 2) return error.VocabularyTooSmall;
            loaded.prefix = &test_prefix;
            loaded.suffix = &test_suffix;
        }
    }
    std.debug.print("METRIC phase=postprocessor prefix_ids={d} suffix_ids={d}\n", .{ loaded.prefix.len, loaded.suffix.len });
    std.debug.print("METRIC phase=model_loaded template_value_size={d}\n", .{@sizeOf(@import("template").Value)});
    try gate('G'); // Runner samples loaded-model baseline before allowing work.
    if (fixture.get("sequence")) |sequence| {
        if (sequence != .array) return error.InvalidSequence;
        for (sequence.array) |item| try caseRun(loaded.text(), item);
    } else try caseRun(loaded.text(), fixture);
    std.debug.print("METRIC phase=ready_to_exit\n", .{});
    try gate('Q'); // Runner samples request cleanup while the model is resident.
    return 0;
}
