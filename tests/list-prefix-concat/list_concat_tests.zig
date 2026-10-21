const std = @import("std");
const template = @import("template.zig");
fn probe(a: std.mem.Allocator, source: []const u8, expected: ?[]const u8) !void {
    var diag = template.Diag{};
    defer if (diag.msg.len > 0) a.free(diag.msg);
    const out = template.renderChat(a, source, .null, .null, .null, true, &diag) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (expected == null and err == error.TemplateFailed) return;
        return error.TestUnexpectedError;
    };
    defer a.free(out);
    try std.testing.expect(expected != null);
    try std.testing.expectEqualStrings(expected.?, out);
}
test "immutable list old_alias_branch" {
    try probe(std.testing.allocator, "{% set ns=namespace(xs=[], old=[]) %}{% for i in range(300) %}{% set ns.xs=ns.xs+[i] %}{% if i==199 %}{% set ns.old=ns.xs %}{% endif %}{% endfor %}{% set branch=ns.old+[999] %}{{ ns.old|length }}:{{ ns.old[-1] }}|{{ ns.xs|length }}:{{ ns.xs[-1] }}|{{ branch|length }}:{{ branch[-1] }}", "200:199|300:299|201:999");
}
test "immutable list self_concat_no_growth" {
    try probe(std.testing.allocator, "{% set a=(range(160)|list)+[160] %}{% set a=a+[161] %}{% set out=a+a %}{{ a|length }}:{{ a[-1] }}|{{ out|length }}:{{ out[161] }}:{{ out[162] }}:{{ out[-1] }}", "162:161|324:161:0:161");
}
test "immutable list rhs_changes_acc" {
    try probe(std.testing.allocator, "{% set a=(range(160)|list)+[160] %}{% set b=(range(170)|list)+[170] %}{% set c=a+(b+[171]) %}{{ a|length }}:{{ a[-1] }}|{{ b|length }}:{{ b[-1] }}|{{ c|length }}:{{ c[160] }}:{{ c[161] }}:{{ c[-1] }}", "161:160|171:170|333:160:0:171");
}
test "immutable list iterate_old_while_append" {
    try probe(std.testing.allocator, "{% set ns=namespace(xs=(range(160)|list)+[160], count=0) %}{% for i in ns.xs %}{% set ns.xs=ns.xs+[i] %}{% set ns.count=ns.count+1 %}{% if loop.first or loop.last %}{{ loop.index }}:{{ loop.length }}:{{ loop.last }}|{% endif %}{% endfor %}{{ ns.count }}:{{ ns.xs|length }}", "1:161:False|161:161:True|161:322");
}
test "immutable list empty_identity" {
    try probe(std.testing.allocator, "{% set a=(range(160)|list)+[160] %}{% set alias=a %}{% set b=a+[] %}{{ a is sameas alias }}:{{ a is sameas b }}:{{ a==b }}", "True:False:True");
}
test "immutable list shallow_namespace" {
    try probe(std.testing.allocator, "{% set n=namespace(v=1) %}{% set a=(range(160)|list)+[n] %}{% set b=a+[0] %}{% set n.v=7 %}{{ a[-1].v }}:{{ b[-2].v }}", "7:7");
}
test "immutable list tuple_concat" {
    try probe(std.testing.allocator, "{% set ns=namespace(xs=()) %}{% for i in range(260) %}{% set ns.xs=ns.xs+(i,) %}{% endfor %}{{ ns.xs|length }}:{{ ns.xs[-1] }}:{{ ns.xs[128:130] }}", "260:259:(128, 129)");
}
test "immutable list mixed_type_error" {
    try probe(std.testing.allocator, "{{ ((range(160)|list)+[160])+(1,) }}", null);
}
test "immutable list range_type_error" {
    try probe(std.testing.allocator, "{{ range(160)+range(160) }}", null);
}
test "immutable list missing_error" {
    try probe(std.testing.allocator, "{{ ((range(160)|list)+[160])+absent }}", null);
}
test "immutable list macro_nested_unicode" {
    try probe(std.testing.allocator, "{% macro m(x) %}{% set n=namespace(v=[]) %}{% for i in range(260) %}{% if i%2==0 %}{% set n.v=n.v+[x~i] %}{% else %}{% set n.v=n.v+['中文🧪'] %}{% endif %}{% endfor %}{{ n.v|length }}:{{ n.v[0] }}:{{ n.v[-1] }}{% endmacro %}{{ m('é') }}|{{ m('傅里叶') }}", "260:é0:中文🧪|260:傅里叶0:中文🧪");
}
test "immutable list sliced_branch" {
    try probe(std.testing.allocator, "{% set a=(range(160)|list)+[160] %}{% set b=a+[161] %}{% set c=a[:-1]+[999] %}{{ a[-1] }}:{{ b[-1] }}:{{ c[-1] }}:{{ c|length }}", "160:161:999:161");
}
test "immutable list alternating_chains" {
    try probe(std.testing.allocator, "{% set n=namespace(a=[],b=[]) %}{% for i in range(300) %}{% set n.a=n.a+[i] %}{% set n.b=n.b+[i+1000] %}{% endfor %}{{ n.a|length }}:{{ n.a[-1] }}:{{ n.b|length }}:{{ n.b[-1] }}", "300:299:300:1299");
}
test "immutable list same_backing_old_prefix" {
    try probe(std.testing.allocator, "{% set ns=namespace(xs=[], old=[]) %}{% for i in range(240) %}{% set ns.xs=ns.xs+[i] %}{% if i==199 %}{% set ns.old=ns.xs %}{% endif %}{% endfor %}{% set branch=ns.old+[999] %}{{ ns.old|length }}:{{ ns.old[-1] }}|{{ ns.xs|length }}:{{ ns.xs[-1] }}|{{ branch|length }}:{{ branch[-1] }}", "200:199|240:239|201:999");
}
fn sweep(a: std.mem.Allocator) !void {
    try probe(a, "{% set ns=namespace(xs=[]) %}{% for i in range(300) %}{% set ns.xs=ns.xs+[i] %}{% endfor %}{{ ns.xs|length }}:{{ ns.xs[-1] }}", "300:299");
}
test "all template allocation failure indices release" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sweep, .{});
}
fn sweepError(a: std.mem.Allocator) !void {
    try probe(a, "{% set ns=namespace(xs=[]) %}{% for i in range(300) %}{% set ns.xs=ns.xs+[i] %}{% endfor %}{{ ns.xs+(1,) }}", null);
}
test "error diagnostic allocation failure indices release" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sweepError, .{});
}
