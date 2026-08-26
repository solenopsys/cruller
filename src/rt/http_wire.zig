const std = @import("std");

pub const magic: u32 = 0x43525448; // HTRC
pub const version: u16 = 1;

pub const RequestFlags = packed struct(u32) {
    disable_timeout: bool = false,
    disable_keepalive: bool = false,
    disable_decompression: bool = false,
    reject_unauthorized: bool = true,
    force_http1: bool = false,
    force_http2: bool = false,
    force_http3: bool = false,
    streaming_body: bool = false,
    _padding: u24 = 0,
};

pub const ResponseFlags = packed struct(u32) {
    redirected: bool = false,
    can_stream: bool = false,
    is_http2: bool = false,
    _padding: u29 = 0,
};

pub const Range = extern struct {
    offset: u32 = 0,
    length: u32 = 0,
};

pub const HeaderRange = extern struct {
    name: Range,
    value: Range,
};

pub const RequestPrefix = extern struct {
    magic_value: u32 = magic,
    wire_version: u16 = version,
    method: u8 = 0,
    redirect: u8 = 0,
    flags: u32 = 0,
    header_count: u32 = 0,
    url: Range = .{},
    proxy: Range = .{},
    hostname: Range = .{},
    unix_socket: Range = .{},
    headers: Range = .{},
    body: Range = .{},
};

pub const ResponsePrefix = extern struct {
    magic_value: u32 = magic,
    wire_version: u16 = version,
    _reserved: u16 = 0,
    status_code: u32 = 0,
    flags: u32 = 0,
    header_count: u32 = 0,
    url: Range = .{},
    status_text: Range = .{},
    headers: Range = .{},
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: u8,
    redirect: u8 = 0,
    flags: u32 = 0,
    url: []const u8,
    proxy: []const u8 = "",
    hostname: []const u8 = "",
    unix_socket: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const Response = struct {
    status_code: u32,
    flags: u32 = 0,
    url: []const u8,
    status_text: []const u8,
    headers: []const Header = &.{},
};

pub fn encodeRequest(allocator: std.mem.Allocator, request: Request) ![]u8 {
    var size: usize = @sizeOf(RequestPrefix);
    size = try add(size, try std.math.mul(usize, request.headers.len, @sizeOf(HeaderRange)));
    size = try addSlices(size, &.{ request.url, request.proxy, request.hostname, request.unix_socket, request.body });
    for (request.headers) |header| size = try addSlices(size, &.{ header.name, header.value });
    if (size > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var cursor: usize = @sizeOf(RequestPrefix) + request.headers.len * @sizeOf(HeaderRange);
    var prefix: RequestPrefix = .{
        .method = request.method,
        .redirect = request.redirect,
        .flags = request.flags,
        .header_count = @intCast(request.headers.len),
        .headers = .{ .offset = @sizeOf(RequestPrefix), .length = @intCast(request.headers.len * @sizeOf(HeaderRange)) },
    };
    prefix.url = put(bytes, &cursor, request.url);
    prefix.proxy = put(bytes, &cursor, request.proxy);
    prefix.hostname = put(bytes, &cursor, request.hostname);
    prefix.unix_socket = put(bytes, &cursor, request.unix_socket);
    prefix.body = put(bytes, &cursor, request.body);
    for (request.headers, 0..) |header, index| {
        const entry: HeaderRange = .{
            .name = put(bytes, &cursor, header.name),
            .value = put(bytes, &cursor, header.value),
        };
        writeValue(HeaderRange, bytes, @sizeOf(RequestPrefix) + index * @sizeOf(HeaderRange), entry);
    }
    writeValue(RequestPrefix, bytes, 0, prefix);
    return bytes;
}

pub fn encodeResponse(allocator: std.mem.Allocator, response: Response) ![]u8 {
    var size: usize = @sizeOf(ResponsePrefix);
    size = try add(size, try std.math.mul(usize, response.headers.len, @sizeOf(HeaderRange)));
    size = try addSlices(size, &.{ response.url, response.status_text });
    for (response.headers) |header| size = try addSlices(size, &.{ header.name, header.value });
    if (size > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var cursor: usize = @sizeOf(ResponsePrefix) + response.headers.len * @sizeOf(HeaderRange);
    var prefix: ResponsePrefix = .{
        .status_code = response.status_code,
        .flags = response.flags,
        .header_count = @intCast(response.headers.len),
        .headers = .{ .offset = @sizeOf(ResponsePrefix), .length = @intCast(response.headers.len * @sizeOf(HeaderRange)) },
    };
    prefix.url = put(bytes, &cursor, response.url);
    prefix.status_text = put(bytes, &cursor, response.status_text);
    for (response.headers, 0..) |header, index| {
        const entry: HeaderRange = .{
            .name = put(bytes, &cursor, header.name),
            .value = put(bytes, &cursor, header.value),
        };
        writeValue(HeaderRange, bytes, @sizeOf(ResponsePrefix) + index * @sizeOf(HeaderRange), entry);
    }
    writeValue(ResponsePrefix, bytes, 0, prefix);
    return bytes;
}

pub const DecodedRequest = struct {
    bytes: []const u8,
    prefix: RequestPrefix,

    pub fn url(self: DecodedRequest) []const u8 {
        return slice(self.bytes, self.prefix.url).?;
    }
    pub fn body(self: DecodedRequest) []const u8 {
        return slice(self.bytes, self.prefix.body).?;
    }
    pub fn header(self: DecodedRequest, index: usize) ?Header {
        if (index >= self.prefix.header_count) return null;
        const entry = readValue(HeaderRange, self.bytes, self.prefix.headers.offset + index * @sizeOf(HeaderRange)) orelse return null;
        return .{ .name = slice(self.bytes, entry.name) orelse return null, .value = slice(self.bytes, entry.value) orelse return null };
    }
};

pub const DecodedResponse = struct {
    bytes: []const u8,
    prefix: ResponsePrefix,

    pub fn url(self: DecodedResponse) []const u8 {
        return slice(self.bytes, self.prefix.url).?;
    }
    pub fn statusText(self: DecodedResponse) []const u8 {
        return slice(self.bytes, self.prefix.status_text).?;
    }
    pub fn header(self: DecodedResponse, index: usize) ?Header {
        if (index >= self.prefix.header_count) return null;
        const entry = readValue(HeaderRange, self.bytes, self.prefix.headers.offset + index * @sizeOf(HeaderRange)) orelse return null;
        return .{ .name = slice(self.bytes, entry.name) orelse return null, .value = slice(self.bytes, entry.value) orelse return null };
    }
};

pub fn decodeRequest(bytes: []const u8) !DecodedRequest {
    const prefix = readValue(RequestPrefix, bytes, 0) orelse return error.InvalidPayload;
    if (prefix.magic_value != magic or prefix.wire_version != version) return error.UnsupportedVersion;
    try validateTable(bytes, prefix.headers, prefix.header_count);
    _ = slice(bytes, prefix.url) orelse return error.InvalidPayload;
    _ = slice(bytes, prefix.proxy) orelse return error.InvalidPayload;
    _ = slice(bytes, prefix.hostname) orelse return error.InvalidPayload;
    _ = slice(bytes, prefix.unix_socket) orelse return error.InvalidPayload;
    _ = slice(bytes, prefix.body) orelse return error.InvalidPayload;
    const result: DecodedRequest = .{ .bytes = bytes, .prefix = prefix };
    for (0..prefix.header_count) |index| _ = result.header(index) orelse return error.InvalidPayload;
    return result;
}

pub fn decodeResponse(bytes: []const u8) !DecodedResponse {
    const prefix = readValue(ResponsePrefix, bytes, 0) orelse return error.InvalidPayload;
    if (prefix.magic_value != magic or prefix.wire_version != version) return error.UnsupportedVersion;
    try validateTable(bytes, prefix.headers, prefix.header_count);
    _ = slice(bytes, prefix.url) orelse return error.InvalidPayload;
    _ = slice(bytes, prefix.status_text) orelse return error.InvalidPayload;
    const result: DecodedResponse = .{ .bytes = bytes, .prefix = prefix };
    for (0..prefix.header_count) |index| _ = result.header(index) orelse return error.InvalidPayload;
    return result;
}

fn validateTable(bytes: []const u8, table: Range, count: u32) !void {
    const expected = std.math.mul(u32, count, @sizeOf(HeaderRange)) catch return error.InvalidPayload;
    if (table.length != expected or slice(bytes, table) == null) return error.InvalidPayload;
}

fn add(value: usize, amount: usize) !usize {
    return std.math.add(usize, value, amount) catch error.PayloadTooLarge;
}

fn addSlices(initial: usize, slices: []const []const u8) !usize {
    var size = initial;
    for (slices) |item| size = try add(size, item.len);
    return size;
}

fn put(bytes: []u8, cursor: *usize, value: []const u8) Range {
    const result: Range = .{ .offset = @intCast(cursor.*), .length = @intCast(value.len) };
    @memcpy(bytes[cursor.*..][0..value.len], value);
    cursor.* += value.len;
    return result;
}

fn slice(bytes: []const u8, range: Range) ?[]const u8 {
    const offset: usize = range.offset;
    const length: usize = range.length;
    if (offset > bytes.len or length > bytes.len - offset) return null;
    return bytes[offset..][0..length];
}

fn writeValue(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    @memcpy(bytes[offset..][0..@sizeOf(T)], std.mem.asBytes(&value));
}

fn readValue(comptime T: type, bytes: []const u8, offset: usize) ?T {
    if (offset > bytes.len or @sizeOf(T) > bytes.len - offset) return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[offset..][0..@sizeOf(T)]);
    return value;
}
