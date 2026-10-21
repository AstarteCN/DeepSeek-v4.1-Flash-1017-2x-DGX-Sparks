// Derived from TensorFold (Copyright 2026 TensorFold contributors), Apache-2.0.
// Modified: offline adapter, allocation counters and lifecycle/error tests.
fn hex(bytes: [32]u8) [64]u8 {
    var out: [64]u8=undefined;const digits="0123456789abcdef";
    for(bytes,0..) |b,i| {out[2*i]=digits[b>>4];out[2*i+1]=digits[b&15];}return out;
}
const Run = struct {
    lane: usize, candidate: bool, images: []const []const u8,
    fail_after: usize=0, tracker: Tracking=.{}, failed: bool=false,
    fn execute(r: *Run) !void {
        r.tracker.fail_after=r.fail_after;
        var request: std.heap.ArenaAllocator=.init(r.tracker.allocator());
        var alive=true;defer if(alive)request.deinit();
        var vision: Vision=.{.tracking=&r.tracker,.lane=r.lane,.pil=shared_pil};
        var outputs: [64]Prepared=undefined;var hashes: [64][32]u8=undefined;
        const start=GetTickCount64();
        for(r.images,0..) |bytes,i| {
            if(GetTickCount64()-start>30000)return error.CaseDeadline;
            vision.image=i;var problem: []const u8="";
            const prepared=if(r.candidate) try prepareCandidate(&vision,request.allocator(),bytes,&problem) else try prepareFn(&vision,request.allocator(),bytes,&problem);
            outputs[i]=prepared;std.crypto.hash.sha2.Sha256.hash(prepared.payload,&hashes[i],.{});
            std.debug.print("IMAGE {{\"lane\":{d},\"image\":{d},\"tokens\":{d},\"payload_bytes\":{d},\"sha256\":\"{s}\",\"backing_live\":{d},\"backing_peak\":{d},\"cumulative\":{d},\"arena_capacity\":{d}}}\n",.{r.lane,i,prepared.tokens,prepared.payload.len,hex(hashes[i]),r.tracker.live,r.tracker.peak,r.tracker.cumulative,request.queryCapacity()});
        }
        // Read every returned result again after all per-image scratch arenas exited.
        for(outputs[0..r.images.len],hashes[0..r.images.len]) |value,expected| {
            var got: [32]u8=undefined;std.crypto.hash.sha2.Sha256.hash(value.payload,&got,.{});
            if(!std.mem.eql(u8,&got,&expected))return error.OutputLifetimeCorruption;
        }
        std.debug.print("BOUNDARY {{\"lane\":{d},\"phase\":\"request_live\",\"live\":{d},\"capacity\":{d}}}\n",.{r.lane,r.tracker.live,request.queryCapacity()});Sleep(400);
        _=request.reset(.retain_capacity);
        std.debug.print("BOUNDARY {{\"lane\":{d},\"phase\":\"reset_retain\",\"live\":{d},\"capacity\":{d}}}\n",.{r.lane,r.tracker.live,request.queryCapacity()});Sleep(400);
        request.deinit();alive=false;
        std.debug.print("BOUNDARY {{\"lane\":{d},\"phase\":\"request_deinit\",\"live\":{d}}}\n",.{r.lane,r.tracker.live});Sleep(400);
    }
    fn thread(r: *Run) void {
        while(!start_gate.load(.acquire))std.atomic.spinLoopHint();
        r.execute() catch |err| {r.failed=true;std.debug.print("FAIL {{\"lane\":{d},\"error\":\"{s}\"}}\n",.{r.lane,@errorName(err)});};
        std.debug.print("LANE {{\"lane\":{d},\"live\":{d},\"peak\":{d},\"cumulative\":{d},\"allocs\":{d},\"frees\":{d},\"failed\":{},\"denied\":{},\"phase_backing_growth\":[{d},{d},{d},{d}]}}\n",.{r.lane,r.tracker.live,r.tracker.peak,r.tracker.cumulative,r.tracker.allocs,r.tracker.frees,r.failed,r.tracker.denied,r.tracker.phase_bytes[0],r.tracker.phase_bytes[1],r.tracker.phase_bytes[2],r.tracker.phase_bytes[3]});
    }
};
pub fn main(init: std.process.Init) !u8 {
    const a=init.arena.allocator();const args=try init.minimal.args.toSlice(a);
    if(args.len!=6)return error.ExpectedModeCountLanesListFailIndex;
    const mode=args[1];
    if (std.mem.endsWith(u8,args[4],"jpeg.lst") or std.mem.endsWith(u8,args[4],"errors.lst"))
        shared_pil=try pil.Pil.start(std.heap.page_allocator,init.io);
    defer if(shared_pil) |p| p.stop(std.heap.page_allocator);const count=try std.fmt.parseInt(usize,args[2],10);
    const lane_count=try std.fmt.parseInt(usize,args[3],10);const fail=try std.fmt.parseInt(usize,args[5],10);
    if(count==0 or count>64 or lane_count==0 or lane_count>2)return error.OutsideBudget;
    const list=try std.Io.Dir.cwd().readFileAlloc(init.io,args[4],a,.limited(65536));
    var iterator=std.mem.tokenizeScalar(u8,list,'\n');var images: [64][]const u8=undefined;var loaded: usize=0;
    while(iterator.next()) |path_| {
        if(loaded==count)break;const path=std.mem.trim(u8,path_,"\r");
        images[loaded]=try std.Io.Dir.cwd().readFileAlloc(init.io,path,a,.limited(16<<20));loaded+=1;
    }
    if(loaded!=count)return error.InsufficientFixtures;
    std.debug.print("BOUNDARY {{\"phase\":\"loaded\",\"images\":{d},\"lanes\":{d},\"mode\":\"{s}\"}}\n",.{count,lane_count,mode});Sleep(400);
    if(std.mem.eql(u8,mode,"errors")) {
        var t:Tracking=.{};var v:Vision=.{.tracking=&t,.lane=0,.pil=shared_pil};
        const backing=t.allocator();
        for(images[0..count],0..) |bytes,i| {
            var owner:std.heap.ArenaAllocator=.init(backing);
            var left_problem:[]const u8="";var right_problem:[]const u8="";
            _=prepareFn(&v,owner.allocator(),bytes,&left_problem) catch |left_err| {
                _=prepareCandidate(&v,owner.allocator(),bytes,&right_problem) catch |right_err| {
                    if(left_err!=right_err or !std.mem.eql(u8,left_problem,right_problem))return error.ErrorMismatch;
                    // Scratch is gone; churn pages and inspect the caller-owned message again.
                    const saved=try owner.allocator().dupe(u8,right_problem);
                    const churn=try backing.alloc(u8,2<<20);@memset(churn,0xa5);backing.free(churn);
                    if(!std.mem.eql(u8,saved,right_problem))return error.ErrorLifetimeCorruption;
                    std.debug.print("ERROR_PARITY {{\"image\":{d},\"same\":true,\"message_bytes\":{d}}}\n",.{i,right_problem.len});
                    owner.deinit();if(t.live!=0)return error.ErrorPathLeak;continue;
                };
                return error.CandidateAcceptedInvalid;
            };
            return error.BaselineAcceptedInvalid;
        }
        std.debug.print("SUMMARY {{\"mode\":\"errors\",\"images\":{d},\"live\":{d},\"equal\":true}}\n",.{count,t.live});return 0;
    }
    if(std.mem.eql(u8,mode,"parity")) {
        var t: Tracking=.{};var v: Vision=.{.tracking=&t,.lane=0,.pil=shared_pil};
        for(images[0..count],0..) |bytes,i| {
            var original: std.heap.ArenaAllocator=.init(t.allocator());
            var candidate: std.heap.ArenaAllocator=.init(t.allocator());
            var problem: []const u8="";v.image=i;
            const left=try prepareFn(&v,original.allocator(),bytes,&problem);
            const right=try prepareCandidate(&v,candidate.allocator(),bytes,&problem);
            const equal=left.tokens==right.tokens and std.mem.eql(u8,left.payload,right.payload);
            std.debug.print("PARITY {{\"image\":{d},\"equal_bytes\":{},\"tokens\":{d},\"bytes\":{d}}}\n",.{i,equal,left.tokens,left.payload.len});
            candidate.deinit();original.deinit();if(!equal)return error.PayloadMismatch;
            if(t.live!=0)return error.LeakedAfterParity;
        }
        std.debug.print("SUMMARY {{\"mode\":\"parity\",\"images\":{d},\"live\":{d},\"peak\":{d},\"equal\":true}}\n",.{count,t.live,t.peak});return 0;
    }
    const candidate=std.mem.eql(u8,mode,"scratch");if(!candidate and !std.mem.eql(u8,mode,"baseline"))return error.InvalidMode;
    var runs: [2]Run=undefined;var threads: [2]std.Thread=undefined;
    for(0..lane_count) |i| {runs[i]=.{.lane=i,.candidate=candidate,.images=images[0..count],.fail_after=fail};threads[i]=try std.Thread.spawn(.{},Run.thread,.{&runs[i]});}
    start_gate.store(true,.release);for(threads[0..lane_count]) |thread|thread.join();
    var failed=false;for(runs[0..lane_count]) |r| {failed=failed or r.failed or r.tracker.denied;if(r.tracker.live!=0)return error.BackingLeak;}
    std.debug.print("SUMMARY {{\"mode\":\"{s}\",\"images_per_lane\":{d},\"lanes\":{d},\"global_live\":{d},\"global_peak\":{d},\"failed\":{}}}\n",.{mode,count,lane_count,global_live.load(.monotonic),global_peak.load(.monotonic),failed});
    return if(failed)2 else 0;
}
