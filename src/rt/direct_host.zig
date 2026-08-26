const std = @import("std");
const bun = @import("bun");
const contract = @import("./contract.zig");
const HttpManager = @import("./host_http.zig").Manager;

/// Host-side executor for the monolithic phase. It consumes the same wire
/// messages that a future io_uring controller will consume and never receives
/// VM pointers or invokes VM callbacks.
pub const Host = struct {
    const Slot = struct {
        fd: ?bun.FD = null,
        generation: u32 = 1,
    };

    allocator: std.mem.Allocator,
    io: contract.Duplex,
    resources: std.array_list.Managed(Slot),
    http: HttpManager,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: contract.Duplex) Host {
        return .{
            .allocator = allocator,
            .io = io,
            .resources = std.array_list.Managed(Slot).init(allocator),
            .http = HttpManager.init(allocator, io),
        };
    }

    pub fn start(self: *Host) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Host) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        for (self.resources.items) |slot| {
            if (slot.fd) |fd| fd.close();
        }
        self.resources.deinit();
    }

    fn run(self: *Host) void {
        while (!self.stopping.load(.acquire)) {
            if (self.pump(256) == 0) bun.compat.nanosleep(0, 100_000);
        }
        _ = self.pump(std.math.maxInt(u32));
    }

    pub fn pump(self: *Host, limit: u32) u32 {
        var count: u32 = 0;
        while (count < limit) {
            const command = self.io.to_host.receive() orelse break;
            count += 1;
            self.dispatch(command);
        }
        return count;
    }

    fn dispatch(self: *Host, command: contract.Command) void {
        switch (command.messageKind()) {
            .submit => switch (command.operationKind()) {
                .resource_open => self.openFile(command),
                .resource_close => self.closeResource(command),
                .resource_read => self.readResource(command),
                .resource_write => self.writeResource(command),
                .http_request_start => self.http.start(command),
                .http_request_body => self.http.writeBody(command),
                .http_request_end => self.http.endBody(command),
                else => self.unsupported(command),
            },
            .cancel => switch (command.operationKind()) {
                .http_request_start => self.http.cancel(command),
                else => self.unsupported(command),
            },
            .shutdown => self.stopping.store(true, .release),
            .event => {
                if (!command.payload.isEmpty()) self.io.data.release(command.payload);
            },
            .completion => self.dropInvalidDirection(command),
            else => self.dropInvalidDirection(command),
        }
    }

    fn openFile(self: *Host, command: contract.Command) void {
        if (@as(contract.ResourceKind, @enumFromInt(@as(u8, @truncate(command.arg0)))) != .file) {
            self.unsupported(command);
            return;
        }

        const mapped = self.io.data.map(command.payload) catch {
            self.completeError(command, errorCode(.INVAL), .{});
            return;
        };
        defer self.io.data.release(command.payload);
        const path_bytes = mapped.slice();
        if (path_bytes.len == 0 or std.mem.indexOfScalar(u8, path_bytes, 0) != null) {
            self.completeError(command, errorCode(.INVAL), .{});
            return;
        }
        const path = self.allocator.dupeZ(u8, path_bytes) catch {
            self.completeError(command, errorCode(.NOMEM), .{});
            return;
        };
        defer self.allocator.free(path);

        const encoded_flags: u32 = @truncate(command.arg1);
        const flags = contract.FileOpenFlags.decode(encoded_flags);
        const mode: bun.Mode = @intCast(command.arg1 >> 32);
        const fd = switch (bun.sys.open(path, toSystemOpenFlags(flags), mode)) {
            .result => |result| result,
            .err => |err| {
                self.completeError(command, -@as(i32, err.errno), .{});
                return;
            },
        };

        const resource_id = self.addResource(fd) catch {
            fd.close();
            self.completeError(command, errorCode(.NOMEM), .{});
            return;
        };
        var completion = completionFor(command);
        completion.resource_id = resource_id;
        if (!self.sendCompletion(completion)) _ = self.removeResource(resource_id);
    }

    fn closeResource(self: *Host, command: contract.Command) void {
        if (!command.payload.isEmpty()) self.io.data.release(command.payload);
        if (!self.removeResource(command.resource_id)) {
            self.completeError(command, errorCode(.BADF), .{});
            return;
        }
        _ = self.sendCompletion(completionFor(command));
    }

    fn readResource(self: *Host, command: contract.Command) void {
        const slot = self.getResource(command.resource_id) orelse {
            self.completeError(command, errorCode(.BADF), command.payload);
            return;
        };
        const mapped = self.io.data.map(command.payload) catch {
            self.completeError(command, errorCode(.INVAL), command.payload);
            return;
        };
        const result = if (command.arg0 == std.math.maxInt(u64))
            bun.sys.read(slot.fd.?, mapped.slice())
        else
            bun.sys.pread(slot.fd.?, mapped.slice(), @bitCast(command.arg0));
        switch (result) {
            .result => |length| {
                var completion = completionFor(command);
                completion.payload = command.payload;
                completion.payload.length = @intCast(length);
                completion.arg0 = length;
                _ = self.sendCompletion(completion);
            },
            .err => |err| self.completeError(command, -@as(i32, err.errno), command.payload),
        }
    }

    fn writeResource(self: *Host, command: contract.Command) void {
        defer if (!command.payload.isEmpty()) self.io.data.release(command.payload);
        const slot = self.getResource(command.resource_id) orelse {
            self.completeError(command, errorCode(.BADF), .{});
            return;
        };
        const mapped = self.io.data.map(command.payload) catch {
            self.completeError(command, errorCode(.INVAL), .{});
            return;
        };
        const result = if (command.arg0 == std.math.maxInt(u64))
            bun.sys.write(slot.fd.?, mapped.slice())
        else
            bun.sys.pwrite(slot.fd.?, mapped.slice(), @bitCast(command.arg0));
        switch (result) {
            .result => |length| {
                var completion = completionFor(command);
                completion.arg0 = length;
                _ = self.sendCompletion(completion);
            },
            .err => |err| self.completeError(command, -@as(i32, err.errno), .{}),
        }
    }

    fn unsupported(self: *Host, command: contract.Command) void {
        if (!command.payload.isEmpty()) self.io.data.release(command.payload);
        self.completeError(command, errorCode(.OPNOTSUPP), .{});
    }

    fn dropInvalidDirection(self: *Host, command: contract.Command) void {
        if (!command.payload.isEmpty()) self.io.data.release(command.payload);
    }

    fn completeError(self: *Host, command: contract.Command, status: i32, payload: contract.BufferRef) void {
        var completion = completionFor(command);
        completion.status = status;
        completion.payload = payload;
        _ = self.sendCompletion(completion);
    }

    fn sendCompletion(self: *Host, command: contract.Command) bool {
        self.io.to_engine.send(command) catch {
            if (!command.payload.isEmpty()) self.io.data.release(command.payload);
            return false;
        };
        return true;
    }

    fn addResource(self: *Host, fd: bun.FD) !u64 {
        for (self.resources.items, 0..) |*slot, index| {
            if (slot.fd == null) {
                slot.fd = fd;
                return makeResourceId(index, slot.generation);
            }
        }
        try self.resources.append(.{ .fd = fd });
        const index = self.resources.items.len - 1;
        return makeResourceId(index, self.resources.items[index].generation);
    }

    fn getResource(self: *Host, resource_id: u64) ?*Slot {
        const index: usize = @intCast(@as(u32, @truncate(resource_id)));
        const generation: u32 = @truncate(resource_id >> 32);
        if (index >= self.resources.items.len) return null;
        const slot = &self.resources.items[index];
        if (slot.fd == null or slot.generation != generation) return null;
        return slot;
    }

    fn removeResource(self: *Host, resource_id: u64) bool {
        const slot = self.getResource(resource_id) orelse return false;
        slot.fd.?.close();
        slot.fd = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        return true;
    }

    fn makeResourceId(index: usize, generation: u32) u64 {
        return (@as(u64, generation) << 32) | @as(u32, @intCast(index));
    }

    fn completionFor(command: contract.Command) contract.Command {
        return .{
            .kind = @intFromEnum(contract.MessageKind.completion),
            .operation = command.operation,
            .request_id = command.request_id,
            .resource_id = command.resource_id,
        };
    }

    fn errorCode(code: bun.sys.E) i32 {
        return -@as(i32, @intCast(@intFromEnum(code)));
    }

    fn toSystemOpenFlags(flags: contract.FileOpenFlags) i32 {
        var result: i32 = if (flags.read and flags.write)
            bun.O.RDWR
        else if (flags.write)
            bun.O.WRONLY
        else
            bun.O.RDONLY;
        if (flags.create) result |= bun.O.CREAT;
        if (flags.truncate) result |= bun.O.TRUNC;
        if (flags.append) result |= bun.O.APPEND;
        if (flags.exclusive) result |= bun.O.EXCL;
        result |= bun.O.CLOEXEC;
        return result;
    }
};
