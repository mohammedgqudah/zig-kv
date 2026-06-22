const std = @import("std");
const stdx = @import("stdx.zig");

const Io = std.Io;
const assert = std.debug.assert;
const mem = std.mem;

const zig_simple_kv = @import("zig_simple_kv");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const db = try blk: {
        if (cwd.openFile(init.io, "db.z", .{ .mode = .read_write })) |f| {
            break :blk f;
        } else |err| {
            if (err == std.Io.Dir.OpenError.FileNotFound) {
                break :blk createDatabase(init.io, cwd);
            } else {
                break :blk err;
            }
        }
    };

    _ = try setKey(db, "abc", "123");
    //_ = try setKey(db, "abc", "555");
    //_ = try setKey(db, "hello", "AAA");

    const val = try getKey(gpa, db, "abc") orelse unreachable;
    defer gpa.free(val);

    assert(mem.eql(u8, val, "123"));
    //assert(mem.eql(u8, try getKey(gpa, db, "hello") orelse unreachable, "AAA"));
}

pub fn createDatabase(io: std.Io, cwd: std.Io.Dir) !std.Io.File {
    const file = try cwd.createFile(io, "db.z", .{
        .truncate = false,
        .read = true,
    });

    var super = SuperBlock{
        .free_offset = @sizeOf(SuperBlock),
    };
    super.nativeToEndian();

    try file.writePositionalAll(io, std.mem.asBytes(&super), 0);

    return file;
}

const SuperBlock = extern struct {
    const Magic = 0xdeadbeefcafebabe;

    magic: u64 = Magic,
    count: u64 = 0, // total number of keys
    free_offset: u64 = 0, // offset for next free spot

    pub fn endianToNative(self: *SuperBlock) void {
        const info = @typeInfo(SuperBlock);
        inline for (info.@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .int => {
                    @field(self, field.name) = std.mem.littleToNative(field.type, @field(self, field.name));
                },
                .float => @compileError("floats are not supported in SuperBlock"),
                else => {},
            }
        }
    }

    pub fn nativeToEndian(self: *SuperBlock) void {
        const info = @typeInfo(SuperBlock);
        inline for (info.@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .int => {
                    @field(self, field.name) = std.mem.nativeToLittle(field.type, @field(self, field.name));
                },
                .float => @compileError("floats are not supported in SuperBlock"),
                else => {},
            }
        }
    }
};

pub fn loadSuperBlock(db: std.Io.File) !SuperBlock {
    var super: SuperBlock = undefined;
    _ = try stdx.pread(db.handle, std.mem.asBytes(&super), 0);
    super.endianToNative();

    if (super.magic != SuperBlock.Magic) {
        return error.InvalidMagicNumber;
    }

    return super;
}

pub fn writeSuperBlock(db: std.Io.File, super: *const SuperBlock) !void {
    if (super.magic != SuperBlock.Magic) {
        return error.InvalidMagicNumber;
    }

    var copy: SuperBlock = super.*;
    copy.nativeToEndian();

    const iovec: []const std.posix.iovec_const = &.{
        .{ .base = @ptrCast(&copy), .len = @sizeOf(SuperBlock) },
    };
    _ = try stdx.pwritev(db.handle, &iovec, 0);
}

pub fn setKey(db: std.Io.File, key: []const u8, value: []const u8) !void {
    var super = try loadSuperBlock(db);

    const key_len: usize = key.len;
    const val_len: usize = value.len;
    // -----------------------------------
    // key_size | value_size | key | value
    // -----------------------------------
    const iovec: []const std.posix.iovec_const = &.{
        .{ .base = @ptrCast(&key_len), .len = @sizeOf(usize) },
        .{ .base = @ptrCast(&val_len), .len = @sizeOf(usize) },

        .{ .base = key.ptr, .len = key_len },
        .{ .base = value.ptr, .len = val_len },
    };
    _ = try stdx.pwritev(db.handle, &iovec, super.free_offset);

    super.free_offset += key_len + val_len + (@sizeOf(usize) * 2);
    try writeSuperBlock(db, &super);
}

pub fn getKey(allocator: std.mem.Allocator, db: std.Io.File, key: []const u8) !?[]const u8 {
    const super = try loadSuperBlock(db);
    _ = super;

    var offset: usize = @sizeOf(SuperBlock);
    var buffer: [0x1000]u8 = undefined;
    while (true) {
        if (try stdx.pread(db.handle, &buffer, offset) == 0) {
            break;
        }

        const key_start = @sizeOf(usize) * 2;
        const key_size = std.mem.readInt(usize, buffer[0..8], .little);
        const value_size = std.mem.readInt(usize, buffer[8..16], .little);
        const value_start = key_start + key_size;
        const cand_key = buffer[key_start .. key_start + key_size];
        if (std.mem.eql(u8, cand_key, key)) {
            const cand_value = buffer[value_start .. value_start + value_size];
            std.log.info("found", .{});
            const ret = try allocator.alloc(u8, cand_value.len);
            @memcpy(ret, cand_value);
            return ret;
        }
        offset += key_start + key_size + value_size;
    }
    return null;
}
