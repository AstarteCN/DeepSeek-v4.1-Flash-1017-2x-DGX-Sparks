const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const tok = b.createModule(.{ .root_source_file = b.path("zig/src/core/tokenizer/tokenizer.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true });
    const tmpl = b.createModule(.{ .root_source_file = b.path("zig/src/core/template/harness_template_module.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true });
    const root = b.createModule(.{
        .root_source_file = b.path("zig/src/server/hf_scratch_harness.zig"),
        .target = target, .optimize = .ReleaseSafe, .link_libc = true,
        .imports = &.{ .{ .name = "tokenizer", .module = tok }, .{ .name = "template", .module = tmpl } },
    });
    b.installArtifact(b.addExecutable(.{ .name = "hf-scratch-harness", .root_module = root }));
}
