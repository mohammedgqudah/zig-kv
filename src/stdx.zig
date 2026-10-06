const std = @import("std");
const builtin = @import("builtin");

pub const fd_t = std.posix.system.fd_t;
const ReadError = std.posix.ReadError;
const native_os = std.posix.ReadError;
const errno = std.posix.errno;
const unexpectedErrno = std.posix.unexpectedErrno;

/// Converts an array of pointers/slices into an `iovec`
pub fn asIoVec(buffers: anytype) [buffers.len]std.posix.iovec_const {
    var iovecs: [buffers.len]std.posix.iovec_const = undefined;
    inline for (buffers, 0..) |buf, idx| {
        const info = @typeInfo(@TypeOf(buf));
        if (info == .pointer and info.pointer.size == .one) {
            iovecs[idx] = .{
                .base = @ptrCast(buf),
                .len = @sizeOf(info.pointer.child),
            };
        } else if (info == .pointer and info.pointer.size == .slice) {
            iovecs[idx] = .{
                .base = buf.ptr,
                .len = buf.len,
            };
        } else {
            @compileError("un-handled type: " ++ @typeName(@TypeOf(buf)));
        }
    }
    return iovecs;
}

pub fn pread(fd: fd_t, buf: []u8, offset: usize) ReadError!usize {
    if (buf.len == 0) return 0;

    // Prevents EINVAL.
    const max_count = 0x7ffff000;

    while (true) {
        const rc = std.os.linux.pread(fd, buf.ptr, @min(buf.len, max_count), @intCast(offset));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.Unexpected,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.Unexpected,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn pwritev(fd: fd_t, iovec: []const std.posix.iovec_const, offset: usize) ReadError!usize {
    while (true) {
        const rc = std.os.linux.pwritev(fd, iovec.ptr, iovec.len, @intCast(offset));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.Unexpected,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .TIMEDOUT => return error.Unexpected,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn xxd(io: std.Io, buffer: []const u8) !void {
    if (builtin.mode == .debug and !builtin.is_test) {
        @compileError("can't use xxd in release mode");
    }

    var child = try std.process.spawn(io, .{
        .argv = &(.{"xxd"} ++ .{
            "-c", "8",
        }),
        .stdin = .pipe,
    });
    const stdin = child.stdin.?;
    try stdin.writeStreamingAll(io, buffer);
    stdin.close(io);
    // set to null so child.wait wouldn't panic trying to close it again
    child.stdin = null;
    _ = try child.wait(io);
}

/// This is a cursor over an iovec array. It lets you "peek" `n` bytes
/// of it by returning a new iovec array. Use this when you need to:
///
/// 1. Retry after a short write
///     ```zig
///     var cursor: stdx.IoVecCursor(iovec.len) = .init(&iovec);
///     while (!cursor.isDone()) {
///         const written = try writePositional(io, cursor.peekAll(), offset);
///         cursor.advance(written); // advance the cursor by only what was actually written
///         offset += written;
///     }
///     ```
/// 2. Write an iovec across multiple files.
///     ```zig
///     var cursor: stdx.IoVecCursor(iovec.len) = .init(&iovec);
///     while (!cursor.isDone()) {
///         if (file_len == file_size) {
///             file = try nextFile(io); // file is full, move to the next one
///             file_len = 0;
///         }
///
///         // Trim the iovec to what still fits in this file.
///         const chunk = cursor.peek(file_size - file_len);
///         const written = try file.writePositional(io, chunk, file_len);
///         cursor.advance(written); // advance by what was actually written
///         file_len += written;
///     }
///     ```
///
/// Note: the iovec returned by `peek` is only valid until the next `peek`, because it's stored in
/// the internal `buf`
pub fn IoVecCursor(comptime n: usize) type {
    return struct {
        const Self = @This();

        /// The caller's iovec
        vec: *const [n][]const u8,
        /// Index of the buffer the cursor points at (buffer with unconsumed bytes)
        idx: usize = 0,
        /// Bytes already confused from `vec[idx]`
        off: usize = 0,
        // Backing storage for the iovec returned by `peek`
        buf: [n][]const u8 = undefined,

        pub fn init(vec: *const [n][]const u8) Self {
            var c: Self = .{ .vec = vec };
            c.skipEmpty();
            return c;
        }

        pub fn isDone(self: *const Self) bool {
            return self.idx >= n;
        }

        /// Total bytes unconsumed.
        pub fn remaining(self: *const Self) usize {
            if (self.isDone()) return 0;
            var total = self.vec[self.idx].len - self.off;
            for (self.vec[self.idx + 1 ..]) |s| total += s.len;
            return total;
        }

        /// The returned iovec is valid until the next `peek` and is
        /// tied to lifetime of the cursor.
        pub fn peek(self: *Self, budget: usize) []const []const u8 {
            var used: usize = 0;
            var left = budget;
            var i = self.idx;
            var o = self.off;
            while (i < n and left > 0) : ({
                i += 1;
                o = 0;
            }) {
                const s = self.vec[i][o..];
                if (s.len == 0) continue;
                const t = @min(s.len, left);
                self.buf[used] = s[0..t];
                used += 1;
                left -= t;
            }
            return self.buf[0..used];
        }

        pub fn peekAll(self: *Self) []const []const u8 {
            return self.peek(std.math.maxInt(usize));
        }

        /// Consume `count` bytes (what a write actually returned).
        pub fn advance(self: *Self, count: usize) void {
            var left = count;
            while (left > 0) {
                std.debug.assert(self.idx < n); // count <= remaining()
                const avail = self.vec[self.idx].len - self.off;
                if (left < avail) {
                    self.off += left;
                    return;
                }
                left -= avail;
                self.idx += 1;
                self.off = 0;
            }
            self.skipEmpty();
        }

        /// Skip empty buffers in the iovec
        fn skipEmpty(self: *Self) void {
            while (self.idx < n and self.off >= self.vec[self.idx].len) {
                self.idx += 1;
                self.off = 0;
            }
        }
    };
}

test "VecCursor splits across budgets and short writes" {
    const v = [_][]const u8{ "abc", "", "defg", "h" };
    var c: IoVecCursor(v.len) = .init(&v);

    // "abc","de"
    const a = c.peek(5);

    try std.testing.expectEqual(2, a.len);
    try std.testing.expectEqualStrings("abc", a[0]);
    try std.testing.expectEqualStrings("de", a[1]);

    // short write: only 4 of 5 were written
    c.advance(4);

    const b = c.peek(100); // "efg","h"

    try std.testing.expectEqualStrings("efg", b[0]);
    try std.testing.expectEqualStrings("h", b[1]);
    try std.testing.expectEqual(4, c.remaining());

    c.advance(4);

    try std.testing.expect(c.isDone());
}
