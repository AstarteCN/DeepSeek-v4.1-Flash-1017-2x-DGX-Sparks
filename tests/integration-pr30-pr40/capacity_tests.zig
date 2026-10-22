const std = @import("std");
const parts = @import("parts.zig");
const shard = @import("shard.zig");

fn four(pool: usize, expected: usize, twins: bool) !void {
    const a = std.testing.allocator;
    const p = try shard.plan(pool, 1048576, 16, 2, true);
    var planner = try parts.Planner.init(.{ .cap = pool, .parts = 2, .twins = twins });
    defer planner.deinit(a);
    var placed: usize = 0;
    for (0..4) |i| {
        var plan = try planner.planAdmit(a, .{ .stream = i + 1, .slot = @intCast(i), .size = p.extent, .twins = twins });
        defer plan.deinit(a);
        if (plan.status != .placed) break;
        try planner.apply(a, &plan);
        planner.setDecoding(i + 1, true);
        // Real decode withdraws this stream's opportunistic prefill twins.
        var round = try planner.planDecode(a, i + 1);
        defer round.deinit(a);
        try planner.apply(a, &round);
        placed += 1;
    }
    try std.testing.expectEqual(expected, placed);
    if (placed == 4) {
        var live: [2]usize = .{ 0, 0 };
        for (planner.lives.items) |lane| {
            try std.testing.expect(lane.decoding);
            try std.testing.expectEqual(@as(usize, 1050624), lane.size);
            try std.testing.expect(lane.base + lane.size <= (lane.part + 1) * planner.part_rows);
            live[lane.part] += 1;
        }
        try std.testing.expectEqualSlices(usize, &.{ 2, 2 }, &live);
    }
}

test "4M nominal pool cannot admit four full-window reservations" { try four(4194304, 2, false); }
test "exact fresh-layout minimum admits two full windows per owner" { try four(4202496, 4, false); }
test "requested 5218304 pool admits four full windows with twins off" { try four(5218304, 4, false); }
test "requested 5218304 pool admits four windows with opportunistic twins" { try four(5218304, 4, true); }
test "pool layout and per-window bounds stay explicit" {
    const p = try shard.plan(5218304, 1048576, 16, 2, true);
    try std.testing.expectEqual(@as(usize, 2609152), p.part);
    try std.testing.expectEqual(@as(usize, 507904), p.part - 2 * p.extent);
    try std.testing.expectError(error.PartTooSmall, shard.plan(1048576, 1048576, 16, 2, true));
    try std.testing.expectError(error.PoolNotWholeParts, shard.plan(5218303, 1048576, 16, 2, true));
}
