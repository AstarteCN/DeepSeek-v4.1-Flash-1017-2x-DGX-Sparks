// Derived from TensorFold (Copyright 2026 TensorFold contributors), Apache-2.0.
// Modified: offline adapter, allocation counters and lifecycle/error tests.
const std = @import("std");
const picture = @import("picture.zig");
const A = std.mem.Allocator;
const Alignment = std.mem.Alignment;
extern "c" fn usleep(u32) c_int;
extern "c" fn clock_gettime(c_int,*Timespec) c_int;
const Timespec=extern struct {sec:i64,nsec:i64};
fn Sleep(ms:u32) void {_=usleep(ms*1000);}
fn GetTickCount64() u64 {var t:Timespec=undefined;_=clock_gettime(1,&t);return @as(u64,@intCast(t.sec))*1000+@as(u64,@intCast(t.nsec))/1000000;}
const pil=@import("pil.zig");
var shared_pil:?*pil.Pil=null;
const header_bytes = 32;
const Prepared = struct { tokens: u32, payload: []const u8 };
const lanes = struct { const stream = struct { const Vision = struct {
    const PrepareError = error{ OutOfMemory, BadImage };
    const Prepared = @import("root").Prepared;
}; }; };
const Phase = enum(u8) { decode, picture, payload, copy };
var global_live: std.atomic.Value(usize) = .init(0);
var global_peak: std.atomic.Value(usize) = .init(0);
var start_gate: std.atomic.Value(bool) = .init(false);

fn addGlobal(n: usize) void {
    const value = global_live.fetchAdd(n, .monotonic) + n;
    var old = global_peak.load(.monotonic);
    while (value > old) {
        if (global_peak.cmpxchgWeak(old, value, .monotonic, .monotonic)) |seen| old = seen else break;
    }
}
const Tracking = struct {
    live: usize = 0, peak: usize = 0, cumulative: usize = 0,
    allocs: usize = 0, frees: usize = 0, attempts: usize = 0,
    fail_after: usize = 0, denied: bool = false,
    phase: Phase = .decode, phase_bytes: [4]usize = @splat(0),
    fn allocator(t: *Tracking) A { return .{ .ptr=t, .vtable=&.{ .alloc=alloc, .resize=resize, .remap=remap, .free=free } }; }
    fn self(p: *anyopaque) *Tracking { return @ptrCast(@alignCast(p)); }
    fn allow(t: *Tracking, n: usize) bool {
        if (t.denied or global_live.load(.monotonic) + n > 2 * 1024 * 1024 * 1024) { t.denied=true; return false; }
        return true;
    }
    fn grown(t: *Tracking, n: usize) void {
        t.live+=n; t.peak=@max(t.peak,t.live);t.cumulative+=n;t.phase_bytes[@intFromEnum(t.phase)]+=n;addGlobal(n);
    }
    fn shrunk(t: *Tracking, n: usize) void { std.debug.assert(t.live>=n);t.live-=n;_ = global_live.fetchSub(n,.monotonic); }
    fn alloc(p: *anyopaque,n: usize,al: Alignment,ra: usize) ?[*]u8 {
        const t=self(p);t.attempts+=1;
        if (t.fail_after!=0 and t.attempts>=t.fail_after) {t.denied=true;return null;}
        if (!t.allow(n)) return null;
        const ptr=std.heap.page_allocator.rawAlloc(n,al,ra) orelse return null;
        t.grown(n);t.allocs+=1;return ptr;
    }
    fn resize(p: *anyopaque,old: []u8,al: Alignment,n: usize,ra: usize) bool {
        const t=self(p);if(n>old.len and !t.allow(n-old.len))return false;
        if(!std.heap.page_allocator.rawResize(old,al,n,ra))return false;
        if(n>old.len)t.grown(n-old.len) else t.shrunk(old.len-n);return true;
    }
    fn remap(p: *anyopaque,old: []u8,al: Alignment,n: usize,ra: usize) ?[*]u8 {
        const t=self(p);if(n>old.len and !t.allow(n-old.len))return null;
        const ptr=std.heap.page_allocator.rawRemap(old,al,n,ra) orelse return null;
        if(n>old.len)t.grown(n-old.len) else t.shrunk(old.len-n);return ptr;
    }
    fn free(p: *anyopaque,old: []u8,al: Alignment,ra: usize) void {
        const t=self(p);t.shrunk(old.len);t.frees+=1;std.heap.page_allocator.rawFree(old,al,ra);
    }
};
