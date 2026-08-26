const std = @import("std");
const contract = @import("./contract.zig");
const vm_bridge = @import("./vm_bridge.zig");

pub const handler_name = "__crullerHandle";

/// Engine-local adapter for one synchronous bundled handler. Input and output
/// are opaque bytes to the dispatcher; the initial SSR convention uses UTF-8
/// JSON envelopes so both engines execute exactly the same JavaScript API.
pub const Handler = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, []const u8, std.mem.Allocator) anyerror![]u8,
};

pub const PumpResult = struct {
    processed: u32 = 0,
    stopped: bool = false,
};

pub fn pump(
    allocator: std.mem.Allocator,
    io: contract.Duplex,
    bridge: *vm_bridge.Bridge,
    handler: Handler,
    limit: u32,
) PumpResult {
    var result: PumpResult = .{};
    while (result.processed < limit) {
        const command = io.to_engine.receive() orelse break;
        result.processed += 1;

        if (command.messageKind() == .shutdown) {
            if (!command.payload.isEmpty()) io.data.release(command.payload);
            result.stopped = true;
            break;
        }

        if (command.messageKind() == .event and command.operationKind() == .server_request) {
            dispatchRequest(allocator, io, handler, command);
        } else {
            bridge.dispatch(command);
        }
    }
    return result;
}

fn dispatchRequest(
    allocator: std.mem.Allocator,
    io: contract.Duplex,
    handler: Handler,
    request: contract.Command,
) void {
    defer if (!request.payload.isEmpty()) io.data.release(request.payload);
    const mapped = io.data.map(request.payload) catch {
        sendError(io, request.request_id, -1);
        return;
    };

    const output = handler.call(handler.context, mapped.slice(), allocator) catch {
        sendError(io, request.request_id, -2);
        return;
    };
    defer allocator.free(output);

    const output_ref = io.data.allocate(output.len) catch {
        sendError(io, request.request_id, -3);
        return;
    };
    const output_buffer = io.data.map(output_ref) catch {
        io.data.release(output_ref);
        sendError(io, request.request_id, -3);
        return;
    };
    @memcpy(output_buffer.slice(), output);

    var response = contract.Command.init(.event, .server_response_end);
    response.request_id = request.request_id;
    response.payload = output_ref;
    io.to_host.send(response) catch io.data.release(output_ref);
}

fn sendError(io: contract.Duplex, request_id: u64, status: i32) void {
    var response = contract.Command.init(.event, .server_response_end);
    response.request_id = request_id;
    response.status = status;
    io.to_host.send(response) catch {};
}
