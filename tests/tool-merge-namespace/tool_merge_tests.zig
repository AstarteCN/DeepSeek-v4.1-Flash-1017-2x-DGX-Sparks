const std = @import("std");
const template = @import("template.zig");
const original = @embedFile("baseline-chat-template.jinja");
const candidate = @embedFile("candidate-chat-template.jinja");
const fixture = @embedFile("merge-fixture.json");
const invalid_fixture = @embedFile("invalid-merge-fixture.json");
fn render(a: std.mem.Allocator, src: []const u8, raw: []const u8, expected: ?[]const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer parsed.deinit();
    var diag = template.Diag{};
    defer if (diag.msg.len > 0) a.free(diag.msg);
    const root = parsed.value;
    const out = template.renderChat(a, src, root.object.get("messages").?, root.object.get("tools") orelse .null, root, true, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.TemplateFailed and expected == null) return;
        return err;
    };
    defer a.free(out);
    try std.testing.expect(expected != null);
    try std.testing.expectEqualStrings(expected.?, out);
}
fn successOriginal(a: std.mem.Allocator, expected: []const u8) !void { try render(a, original, fixture, expected); }
fn successCandidate(a: std.mem.Allocator, expected: []const u8) !void { try render(a, candidate, fixture, expected); }
fn failedOriginal(a: std.mem.Allocator) !void { try render(a, original, invalid_fixture, null); }
fn failedCandidate(a: std.mem.Allocator) !void { try render(a, candidate, invalid_fixture, null); }
test "full template namespace equivalent with every GPA failure index" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, fixture, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const expected = try template.renderChat(a, original, root.object.get("messages").?, root.object.get("tools") orelse .null, root, true, null);
    defer a.free(expected);
    try std.testing.checkAllAllocationFailures(a, successOriginal, .{expected});
    try std.testing.checkAllAllocationFailures(a, successCandidate, .{expected});
}
test "full template diagnostic cleanup every GPA failure index" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failedOriginal, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failedCandidate, .{});
}
