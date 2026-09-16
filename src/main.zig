const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx.zig");
const devmapper = @import("devicemapper.zig");
const page = @import("page.zig");
const page_tests = @import("page_tests.zig");
const PageCache = @import("PageCache.zig");
const BTree = @import("BTree.zig");
const Session = @import("Session.zig");

const mem = std.mem;
const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    comptime {
        if (builtin.cpu.arch.endian() != .little) {
            @compileError("Big endian architectures are not supported");
        }
    }

    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();

    var session = try Session.open(init.io, gpa, cwd, "db.z");
    defer session.deinit();

    try session.insert("abc", "123");

    const value = try session.find("abc") orelse unreachable;
    defer gpa.free(value);

    assert(mem.eql(u8, value, "123"));
}

test {
    std.testing.refAllDecls(devmapper);
    std.testing.refAllDecls(stdx);
    std.testing.refAllDecls(page);
    std.testing.refAllDecls(page_tests);
    std.testing.refAllDecls(PageCache);
    std.testing.refAllDecls(BTree);
    std.testing.refAllDecls(Session);
}
