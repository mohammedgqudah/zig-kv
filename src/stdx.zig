const std = @import("std");
const builtin = @import("builtin");

pub const fd_t = std.posix.system.fd_t;
const ReadError = std.posix.ReadError;
const native_os = std.posix.ReadError;
const errno = std.posix.errno;
const unexpectedErrno = std.posix.unexpectedErrno;

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

pub fn pwrite(fd: fd_t, buf: []u8, offset: usize) ReadError!usize {
    if (buf.len == 0) return 0;

    while (true) {
        const rc = std.os.linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => error.InvalidValue,
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

pub fn pwritev(fd: fd_t, iovec: *const []const std.posix.iovec_const, offset: usize) ReadError!usize {
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
    std.debug.assert(builtin.mode == .Debug);

    const child = try std.process.spawn(io, .{
        .argv = &(.{"xxd"} ++ .{
            "-c", "8",
        }),
        .stdin = .pipe,
    });
    try child.stdin.?.writeStreamingAll(io, buffer);
    child.stdin.?.close(io);
}
