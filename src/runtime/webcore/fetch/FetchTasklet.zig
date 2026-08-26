pub const FetchTasklet = struct {
    pub const ResumableSink = jsc.WebCore.ResumableFetchSink;

    const log = Output.scoped(.FetchTasklet, .visible);
    sink: ?*ResumableSink = null,
    host_request_payload: ?[]u8 = null,
    host_request_id: u64 = 0,
    result: http.HTTPClientResult = .{},
    metadata: ?http.HTTPResponseMetadata = null,
    javascript_vm: *VirtualMachine = undefined,
    global_this: *JSGlobalObject = undefined,
    request_body: HTTPRequestBody = undefined,

    /// buffer being used by AsyncHTTP
    response_buffer: MutableString = undefined,
    /// buffer used to stream response to JS
    scheduled_response_buffer: MutableString = undefined,
    /// response weak ref we need this to track the response JS lifetime
    response: jsc.Weak(FetchTasklet) = .{},
    /// native response ref if we still need it when JS is discarted
    native_response: ?*Response = null,
    ignore_data: bool = false,
    /// stream strong ref if any is available
    readable_stream_ref: jsc.WebCore.ReadableStream.Strong = .{},
    request_headers: Headers = Headers{ .allocator = undefined },
    promise: jsc.JSPromise.Strong,
    concurrent_task: jsc.ConcurrentTask = .{},
    poll_ref: Async.KeepAlive = .{},
    /// For Http Client requests
    /// when Content-Length is provided this represents the whole size of the request
    /// If chunked encoded this will represent the total received size (ignoring the chunk headers)
    /// If is not chunked encoded and Content-Length is not provided this will be unknown
    body_size: http.HTTPClientResult.BodySize = .unknown,

    /// This is url + proxy memory buffer and is owned by FetchTasklet
    /// We always clone url and proxy (if informed)
    url_proxy_buffer: []const u8 = "",

    signal: ?*jsc.WebCore.AbortSignal = null,
    signals: http.Signals = .{},
    signal_store: http.Signals.Store = .{},
    has_schedule_callback: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // must be stored because AbortSignal stores reason weakly
    abort_reason: jsc.Strong.Optional = .empty,

    // custom checkServerIdentity
    check_server_identity: jsc.Strong.Optional = .empty,
    reject_unauthorized: bool = true,
    upgraded_connection: bool = false,
    // Custom Hostname
    hostname: ?[]u8 = null,
    is_waiting_body: bool = false,
    is_waiting_abort: bool = false,
    is_waiting_request_stream_start: bool = false,
    mutex: Mutex,

    tracker: jsc.Debugger.AsyncTaskTracker,

    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    pub fn ref(this: *FetchTasklet) void {
        const count = this.ref_count.fetchAdd(1, .monotonic);
        bun.debugAssert(count > 0);
    }

    pub fn deref(this: *FetchTasklet) void {
        const count = this.ref_count.fetchSub(1, .monotonic);
        bun.debugAssert(count > 0);

        if (count == 1) {
            this.deinit() catch |err| switch (err) {};
        }
    }

    pub fn derefFromThread(this: *FetchTasklet) void {
        const count = this.ref_count.fetchSub(1, .monotonic);
        bun.debugAssert(count > 0);

        if (count == 1) {
            if (this.javascript_vm.isShuttingDown()) {
                this.deinit() catch |err| switch (err) {};
                return;
            }
            // this is really unlikely to happen, but can happen
            // lets make sure that we always call deinit from main thread

            this.javascript_vm.eventLoop().enqueueTaskConcurrent(jsc.ConcurrentTask.fromCallback(this, FetchTasklet.deinit));
        }
    }

    pub const HTTPRequestBody = union(enum) {
        AnyBlob: AnyBlob,
        Sendfile: http.SendFile,
        ReadableStream: jsc.WebCore.ReadableStream.Strong,

        pub const Empty: HTTPRequestBody = .{ .AnyBlob = .{ .Blob = .{} } };

        pub fn store(this: *HTTPRequestBody) ?*Blob.Store {
            return switch (this.*) {
                .AnyBlob => this.AnyBlob.store(),
                else => null,
            };
        }

        pub fn slice(this: *const HTTPRequestBody) []const u8 {
            return switch (this.*) {
                .AnyBlob => this.AnyBlob.slice(),
                else => "",
            };
        }

        pub fn detach(this: *HTTPRequestBody) void {
            switch (this.*) {
                .AnyBlob => this.AnyBlob.detach(),
                .ReadableStream => |*stream| {
                    stream.deinit();
                },
                .Sendfile => {
                    if (@max(this.Sendfile.offset, this.Sendfile.remain) > 0)
                        this.Sendfile.fd.close();
                    this.Sendfile.offset = 0;
                    this.Sendfile.remain = 0;
                },
            }
        }

        pub fn fromJS(globalThis: *JSGlobalObject, value: JSValue) bun.JSError!HTTPRequestBody {
            var body_value = try Body.Value.fromJS(globalThis, value);
            if (body_value == .Used or (body_value == .Locked and (body_value.Locked.action != .none or body_value.Locked.isDisturbed2(globalThis)))) {
                return globalThis.ERR(.BODY_ALREADY_USED, "body already used", .{}).throw();
            }
            if (body_value == .Locked) {
                if (body_value.Locked.readable.has()) {
                    // just grab the ref
                    return FetchTasklet.HTTPRequestBody{ .ReadableStream = body_value.Locked.readable };
                }
                const readable = try body_value.toReadableStream(globalThis);
                if (!readable.isEmptyOrUndefinedOrNull() and body_value == .Locked and body_value.Locked.readable.has()) {
                    return FetchTasklet.HTTPRequestBody{ .ReadableStream = body_value.Locked.readable };
                }
            }
            return FetchTasklet.HTTPRequestBody{ .AnyBlob = body_value.useAsAnyBlob() };
        }

        pub fn needsToReadFile(this: *HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |blob| blob.needsToReadFile(),
                else => false,
            };
        }

        pub fn isS3(this: *const HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |*blob| blob.isS3(),
                else => false,
            };
        }

        pub fn hasContentTypeFromUser(this: *HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |blob| blob.hasContentTypeFromUser(),
                else => false,
            };
        }

        pub fn getAnyBlob(this: *HTTPRequestBody) ?*AnyBlob {
            return switch (this.*) {
                .AnyBlob => &this.AnyBlob,
                else => null,
            };
        }

        pub fn hasBody(this: *HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |blob| blob.size() > 0,
                .ReadableStream => |*stream| stream.has(),
                .Sendfile => true,
            };
        }
    };

    pub fn init(_: std.mem.Allocator) anyerror!FetchTasklet {
        return FetchTasklet{};
    }

    fn clearSink(this: *FetchTasklet) void {
        if (this.sink) |sink| {
            this.sink = null;
            sink.deref();
        }
    }

    fn clearData(this: *FetchTasklet) void {
        log("clearData ", .{});
        const allocator = bun.default_allocator;
        if (this.url_proxy_buffer.len > 0) {
            allocator.free(this.url_proxy_buffer);
            this.url_proxy_buffer.len = 0;
        }

        if (this.hostname) |hostname| {
            allocator.free(hostname);
            this.hostname = null;
        }

        if (this.result.certificate_info) |*certificate| {
            certificate.deinit(bun.default_allocator);
            this.result.certificate_info = null;
        }

        this.request_headers.entries.deinit(allocator);
        this.request_headers.buf.deinit(allocator);
        this.request_headers = Headers{ .allocator = undefined };

        if (this.host_request_payload) |payload| {
            allocator.free(payload);
            this.host_request_payload = null;
        }

        if (this.metadata != null) {
            this.metadata.?.deinit(allocator);
            this.metadata = null;
        }

        this.response_buffer.deinit();
        this.response.deinit();
        if (this.native_response) |response| {
            this.native_response = null;

            response.unref();
        }

        this.clearStreamCancelHandler();
        this.readable_stream_ref.deinit();

        this.scheduled_response_buffer.deinit();
        // Always detach request_body regardless of type.
        // When request_body is a ReadableStream, startRequestStream() creates
        // an independent Strong reference in ResumableSink, so FetchTasklet's
        // reference becomes redundant and must be released to avoid leaks.
        this.request_body.detach();

        this.abort_reason.deinit();
        this.check_server_identity.deinit();
        this.clearAbortSignal();
        // Clear the sink only after the requested ended otherwise we would potentialy lose the last chunk
        this.clearSink();
    }

    // XXX: 'fn (*FetchTasklet) error{}!void' coerces to 'fn (*FetchTasklet) bun.JSError!void' but 'fn (*FetchTasklet) void' does not
    pub fn deinit(this: *FetchTasklet) error{}!void {
        log("deinit", .{});

        bun.assert(this.ref_count.load(.monotonic) == 0);

        this.clearData();

        bun.default_allocator.destroy(this);
    }

    fn getCurrentResponse(this: *FetchTasklet) ?*Response {
        // we need a body to resolve the promise when buffering
        if (this.native_response) |response| {
            return response;
        }

        // if we did not have a direct reference we check if the Weak ref is still alive
        if (this.response.get()) |response_js| {
            if (response_js.as(Response)) |response| {
                return response;
            }
        }

        return null;
    }

    pub fn startRequestStream(this: *FetchTasklet) void {
        this.is_waiting_request_stream_start = false;
        bun.assert(this.request_body == .ReadableStream);
        if (this.request_body.ReadableStream.get(this.global_this)) |stream| {
            if (this.signal) |signal| {
                if (signal.aborted()) {
                    stream.abort(this.global_this);
                    return;
                }
            }

            const globalThis = this.global_this;
            this.ref(); // lets only unref when sink is done
            // +1 because the task refs the sink
            const sink = ResumableSink.initExactRefs(globalThis, stream, this, 2);
            this.sink = sink;
        }
    }

    pub fn onBodyReceived(this: *FetchTasklet) bun.JSTerminated!void {
        const success = this.result.isSuccess();
        const globalThis = this.global_this;
        // reset the buffer if we are streaming or if we are not waiting for bufferig anymore
        var buffer_reset = true;
        log("onBodyReceived success={} has_more={}", .{ success, this.result.has_more });
        defer {
            if (buffer_reset) {
                this.scheduled_response_buffer.reset();
            }
        }

        if (!success) {
            var err = this.onReject();
            var need_deinit = true;
            defer if (need_deinit) err.deinit();
            var js_err = JSValue.zero;
            // if we are streaming update with error
            if (this.readable_stream_ref.get(globalThis)) |readable| {
                if (readable.ptr == .Bytes) {
                    js_err = err.toJS(globalThis);
                    js_err.ensureStillAlive();
                    try readable.ptr.Bytes.onData(
                        .{
                            .err = .{ .JSValue = js_err },
                        },
                        bun.default_allocator,
                    );
                }
            }
            if (this.sink) |sink| {
                if (js_err == .zero) {
                    js_err = err.toJS(globalThis);
                    js_err.ensureStillAlive();
                }
                sink.cancel(js_err);
                return;
            }
            // if we are buffering resolve the promise
            if (this.getCurrentResponse()) |response| {
                need_deinit = false; // body value now owns the error
                const body = response.getBodyValue();
                try body.toErrorInstance(err, globalThis);
            }
            return;
        }

        if (this.readable_stream_ref.get(globalThis)) |readable| {
            log("onBodyReceived readable_stream_ref", .{});
            if (readable.ptr == .Bytes) {
                readable.ptr.Bytes.size_hint = this.getSizeHint();
                // body can be marked as used but we still need to pipe the data
                const scheduled_response_buffer = &this.scheduled_response_buffer.list;

                const chunk = scheduled_response_buffer.items;

                if (this.result.has_more) {
                    try readable.ptr.Bytes.onData(
                        .{
                            .temporary = bun.ByteList.fromBorrowedSliceDangerous(chunk),
                        },
                        bun.default_allocator,
                    );
                } else {
                    this.clearStreamCancelHandler();
                    var prev = this.readable_stream_ref;
                    this.readable_stream_ref = .{};
                    defer prev.deinit();
                    buffer_reset = false;

                    try readable.ptr.Bytes.onData(
                        .{
                            .temporary_and_done = bun.ByteList.fromBorrowedSliceDangerous(chunk),
                        },
                        bun.default_allocator,
                    );
                }
                return;
            }
        }

        if (this.getCurrentResponse()) |response| {
            log("onBodyReceived Current Response", .{});
            const sizeHint = this.getSizeHint();
            response.setSizeHint(sizeHint);
            if (response.getBodyReadableStream(globalThis)) |readable| {
                log("onBodyReceived CurrentResponse BodyReadableStream", .{});
                if (readable.ptr == .Bytes) {
                    const scheduled_response_buffer = this.scheduled_response_buffer.list;

                    const chunk = scheduled_response_buffer.items;

                    if (this.result.has_more) {
                        try readable.ptr.Bytes.onData(
                            .{
                                .temporary = bun.ByteList.fromBorrowedSliceDangerous(chunk),
                            },
                            bun.default_allocator,
                        );
                    } else {
                        readable.value.ensureStillAlive();
                        response.detachReadableStream(globalThis);
                        try readable.ptr.Bytes.onData(
                            .{
                                .temporary_and_done = bun.ByteList.fromBorrowedSliceDangerous(chunk),
                            },
                            bun.default_allocator,
                        );
                    }

                    return;
                }
            }

            // we will reach here when not streaming, this is also the only case we dont wanna to reset the buffer
            buffer_reset = false;
            if (!this.result.has_more) {
                var scheduled_response_buffer = this.scheduled_response_buffer.list;
                const body = response.getBodyValue();
                // done resolve body
                var old = body.*;
                const body_value = Body.Value{
                    .InternalBlob = .{
                        .bytes = scheduled_response_buffer.toManaged(bun.default_allocator),
                    },
                };
                body.* = body_value;
                log("onBodyReceived body_value length={}", .{body_value.InternalBlob.bytes.items.len});

                this.scheduled_response_buffer = .{
                    .allocator = bun.default_allocator,
                    .list = .{
                        .items = &.{},
                        .capacity = 0,
                    },
                };

                if (old == .Locked) {
                    log("onBodyReceived old.resolve", .{});
                    try old.resolve(body, this.global_this, response.getFetchHeaders());
                }
            }
        }
    }

    pub fn onProgressUpdate(this: *FetchTasklet) bun.JSTerminated!void {
        jsc.markBinding(@src());
        log("onProgressUpdate", .{});
        this.mutex.lock();
        this.has_schedule_callback.store(false, .monotonic);
        const is_done = !this.result.has_more;

        const vm = this.javascript_vm;
        // vm is shutting down we cannot touch JS
        if (vm.isShuttingDown()) {
            this.mutex.unlock();
            if (is_done) {
                this.deref();
            }
            return;
        }

        const globalThis = this.global_this;
        defer {
            this.mutex.unlock();
            // if we are not done we wait until the next call
            if (is_done) {
                var poll_ref = this.poll_ref;
                this.poll_ref = .{};
                poll_ref.unref(vm);
                this.deref();
            }
        }
        if (this.is_waiting_request_stream_start and this.result.can_stream) {
            // start streaming
            this.startRequestStream();
        }
        // if we already respond the metadata and still need to process the body
        if (this.is_waiting_body) {
            // `scheduled_response_buffer` has two readers that both drain-and-reset:
            // this path (onBodyReceived) and `onStartStreamingHTTPResponseBodyCallback`,
            // which runs once when JS first touches `res.body` and hands any already-
            // buffered bytes to the new ByteStream synchronously.
            //
            // That creates a stale-task race:
            //   1. HTTP thread `callback()` writes N bytes to the buffer and enqueues
            //      this onProgressUpdate task (under mutex).
            //   2. Main thread: JS touches `res.body` -> `onStartStreaming` drains those
            //      N bytes and resets the buffer (under mutex).
            //   3. This task runs and finds the buffer empty.
            //
            // The task cannot be un-enqueued in step 2, and at schedule time (step 1)
            // the buffer was non-empty, so the only place the staleness is observable
            // is here when the task runs.
            //
            // Without this guard, `onBodyReceived` would call `ByteStream.onData` with
            // a zero-length non-terminal chunk. That resolves the reader's pending
            // pull with `len=0`; `native-readable.ts` `handleNumberResult(0)` does not
            // `push()`, so node:stream `state.reading` (set before the previous `_read()`
            // early-returned on `kPendingRead`) is never cleared, `_read()` is never
            // called again, and `pipeline(Readable.fromWeb(res.body), ...)` stalls
            // forever — eventually spinning at 100% CPU once `poll_ref` unrefs.
            if (this.scheduled_response_buffer.list.items.len == 0 and
                this.result.has_more and
                this.result.isSuccess())
            {
                return;
            }
            try this.onBodyReceived();
            return;
        }
        if (this.metadata == null and this.result.isSuccess()) return;

        // if we abort because of cert error
        // we wait the Http Client because we already have the response
        // we just need to deinit
        if (this.is_waiting_abort) {
            return;
        }
        const promise_value = this.promise.valueOrEmpty();

        if (promise_value.isEmptyOrUndefinedOrNull()) {
            log("onProgressUpdate: promise_value is null", .{});
            this.promise.deinit();
            return;
        }

        if (this.result.certificate_info) |certificate_info| {
            this.result.certificate_info = null;
            defer certificate_info.deinit(bun.default_allocator);

            // we receive some error
            if (this.reject_unauthorized and !this.checkServerIdentity(certificate_info)) {
                log("onProgressUpdate: aborted due certError", .{});
                // we need to abort the request
                const promise = promise_value.asAnyPromise().?;
                const tracker = this.tracker;
                var result = this.onReject();
                defer result.deinit();

                promise_value.ensureStillAlive();
                try promise.rejectWithAsyncStack(globalThis, result.toJS(globalThis));

                tracker.didDispatch(globalThis);
                this.promise.deinit();
                return;
            }
            // checkServerIdentity passed. Fall through to resolve/reject below.
            //
            // We can reach this point with `metadata == null` when the
            // connection failed after the TLS handshake but before response
            // headers arrived (e.g. an mTLS server closing the socket because
            // the client didn't present a certificate) — the certificate_info
            // from the first progress update is coalesced into the later
            // failure result. The `metadata == null && isSuccess()` case is
            // already handled by the early return above, so the fall-through
            // here always has either metadata to resolve with or a failure to
            // reject with.
        }

        const tracker = this.tracker;
        tracker.willDispatch(globalThis);
        defer {
            log("onProgressUpdate: promise_value is not null", .{});
            tracker.didDispatch(globalThis);
            this.promise.deinit();
        }
        const success = this.result.isSuccess();
        const result = switch (success) {
            true => jsc.Strong.Optional.create(this.onResolve(), globalThis),
            false => brk: {
                // in this case we wanna a jsc.Strong.Optional so we just convert it
                var value = this.onReject();
                const err = value.toJS(globalThis);
                if (this.sink) |sink| {
                    sink.cancel(err);
                }
                break :brk value.JSValue;
            },
        };

        promise_value.ensureStillAlive();
        const Holder = struct {
            held: jsc.Strong.Optional,
            promise: jsc.Strong.Optional,
            globalObject: *jsc.JSGlobalObject,
            task: jsc.AnyTask,

            pub fn resolve(self: *@This()) bun.JSTerminated!void {
                // cleanup
                defer bun.default_allocator.destroy(self);
                defer self.held.deinit();
                defer self.promise.deinit();
                // resolve the promise
                var prom = self.promise.swap().asAnyPromise().?;
                const res = self.held.swap();
                res.ensureStillAlive();
                try prom.resolve(self.globalObject, res);
            }

            pub fn reject(self: *@This()) bun.JSTerminated!void {
                // cleanup
                defer bun.default_allocator.destroy(self);
                defer self.held.deinit();
                defer self.promise.deinit();

                // reject the promise
                var prom = self.promise.swap().asAnyPromise().?;
                const res = self.held.swap();
                res.ensureStillAlive();
                try prom.rejectWithAsyncStack(self.globalObject, res);
            }
        };
        var holder = bun.handleOom(bun.default_allocator.create(Holder));
        holder.* = .{
            .held = result,
            // we need the promise to be alive until the task is done
            .promise = this.promise.strong,
            .globalObject = globalThis,
            .task = undefined,
        };
        this.promise.strong = .empty;
        holder.task = switch (success) {
            true => jsc.AnyTask.New(Holder, Holder.resolve).init(holder),
            false => jsc.AnyTask.New(Holder, Holder.reject).init(holder),
        };

        vm.enqueueTask(jsc.Task.init(&holder.task));
    }

    pub fn checkServerIdentity(this: *FetchTasklet, certificate_info: http.CertificateInfo) bool {
        if (this.check_server_identity.get()) |check_server_identity| {
            check_server_identity.ensureStillAlive();
            if (certificate_info.cert.len > 0) {
                const cert = certificate_info.cert;
                var cert_ptr = cert.ptr;
                if (BoringSSL.d2i_X509(null, &cert_ptr, @intCast(cert.len))) |x509| {
                    const globalObject = this.global_this;
                    defer x509.free();
                    const js_cert = X509.toJS(x509, globalObject) catch |err| {
                        switch (err) {
                            error.JSError => {},
                            error.OutOfMemory => globalObject.throwOutOfMemory() catch {},
                            error.JSTerminated => {},
                        }
                        const check_result = globalObject.tryTakeException().?;
                        // mark to wait until deinit
                        this.is_waiting_abort = this.result.has_more;
                        this.abort_reason.set(globalObject, check_result);
                        this.signal_store.aborted.store(true, .monotonic);
                        this.tracker.didCancel(this.global_this);
                        // we need to abort the request
                        this.cancelHostRequest();
                        this.result.fail = error.ERR_TLS_CERT_ALTNAME_INVALID;
                        return false;
                    };
                    var hostname: bun.String = bun.String.cloneUTF8(certificate_info.hostname);
                    defer hostname.deref();
                    const js_hostname = hostname.toJS(globalObject) catch |err| {
                        switch (err) {
                            error.JSError => {},
                            error.OutOfMemory => globalObject.throwOutOfMemory() catch {},
                            error.JSTerminated => {},
                        }
                        const hostname_err_result = globalObject.tryTakeException().?;
                        this.is_waiting_abort = this.result.has_more;
                        this.abort_reason.set(globalObject, hostname_err_result);
                        this.signal_store.aborted.store(true, .monotonic);
                        this.tracker.didCancel(this.global_this);
                        this.cancelHostRequest();
                        this.result.fail = error.ERR_TLS_CERT_ALTNAME_INVALID;
                        return false;
                    };
                    js_hostname.ensureStillAlive();
                    js_cert.ensureStillAlive();
                    const check_result = check_server_identity.call(globalObject, .js_undefined, &.{ js_hostname, js_cert }) catch |err| globalObject.takeException(err);

                    // > Returns <Error> object [...] on failure
                    if (check_result.isAnyError()) {
                        // mark to wait until deinit
                        this.is_waiting_abort = this.result.has_more;
                        this.abort_reason.set(globalObject, check_result);
                        this.signal_store.aborted.store(true, .monotonic);
                        this.tracker.didCancel(this.global_this);

                        // we need to abort the request
                        this.cancelHostRequest();
                        this.result.fail = error.ERR_TLS_CERT_ALTNAME_INVALID;
                        return false;
                    }

                    // > On success, returns <undefined>
                    // We treat any non-error value as a success.
                    return true;
                }
            }
        }
        this.result.fail = error.ERR_TLS_CERT_ALTNAME_INVALID;
        return false;
    }

    fn getAbortError(this: *FetchTasklet) ?Body.Value.ValueError {
        if (this.abort_reason.has()) {
            defer this.clearAbortSignal();
            const out = this.abort_reason;

            this.abort_reason = .empty;
            return Body.Value.ValueError{ .JSValue = out };
        }

        if (this.signal) |signal| {
            if (signal.reasonIfAborted(this.global_this)) |reason| {
                defer this.clearAbortSignal();
                return reason.toBodyValueError(this.global_this);
            }
        }

        return null;
    }

    fn clearAbortSignal(this: *FetchTasklet) void {
        const signal = this.signal orelse return;
        this.signal = null;
        defer {
            signal.pendingActivityUnref();
            signal.unref();
        }

        signal.cleanNativeBindings(this);
    }

    pub fn onReject(this: *FetchTasklet) Body.Value.ValueError {
        bun.assert(this.result.fail != null);
        log("onReject", .{});

        if (this.getAbortError()) |err| {
            return err;
        }

        if (this.result.abortReason()) |reason| {
            return .{ .AbortReason = reason };
        }

        // Fetch-spec "network error" cases that callers feature-detect via
        // `instanceof TypeError`. Keep this list narrow; the catch-all
        // SystemError below is still a plain Error for backwards compat.
        switch (this.result.fail.?) {
            error.RequestBodyNotReusable => return .{
                .TypeError = bun.String.static("Request body is a ReadableStream and cannot be replayed for this redirect"),
            },
            else => {},
        }

        const path = if (this.metadata) |metadata|
            bun.String.cloneUTF8(metadata.url)
        else
            bun.String.empty;

        const fetch_error = jsc.SystemError{
            .code = bun.String.static(switch (this.result.fail.?) {
                error.ConnectionClosed => "ECONNRESET",
                else => |e| @errorName(e),
            }),
            .message = switch (this.result.fail.?) {
                error.ConnectionClosed => bun.String.static("The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()"),
                error.FailedToOpenSocket => bun.String.static("Was there a typo in the url or port?"),
                error.TooManyRedirects => bun.String.static("The response redirected too many times. For more information, pass `verbose: true` in the second argument to fetch()"),
                error.ConnectionRefused => bun.String.static("Unable to connect. Is the computer able to access the url?"),
                error.RedirectURLInvalid => bun.String.static("Redirect URL in Location header is invalid."),

                error.UNABLE_TO_GET_ISSUER_CERT => bun.String.static("unable to get issuer certificate"),
                error.UNABLE_TO_GET_CRL => bun.String.static("unable to get certificate CRL"),
                error.UNABLE_TO_DECRYPT_CERT_SIGNATURE => bun.String.static("unable to decrypt certificate's signature"),
                error.UNABLE_TO_DECRYPT_CRL_SIGNATURE => bun.String.static("unable to decrypt CRL's signature"),
                error.UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY => bun.String.static("unable to decode issuer public key"),
                error.CERT_SIGNATURE_FAILURE => bun.String.static("certificate signature failure"),
                error.CRL_SIGNATURE_FAILURE => bun.String.static("CRL signature failure"),
                error.CERT_NOT_YET_VALID => bun.String.static("certificate is not yet valid"),
                error.CRL_NOT_YET_VALID => bun.String.static("CRL is not yet valid"),
                error.CERT_HAS_EXPIRED => bun.String.static("certificate has expired"),
                error.CRL_HAS_EXPIRED => bun.String.static("CRL has expired"),
                error.ERROR_IN_CERT_NOT_BEFORE_FIELD => bun.String.static("format error in certificate's notBefore field"),
                error.ERROR_IN_CERT_NOT_AFTER_FIELD => bun.String.static("format error in certificate's notAfter field"),
                error.ERROR_IN_CRL_LAST_UPDATE_FIELD => bun.String.static("format error in CRL's lastUpdate field"),
                error.ERROR_IN_CRL_NEXT_UPDATE_FIELD => bun.String.static("format error in CRL's nextUpdate field"),
                error.OUT_OF_MEM => bun.String.static("out of memory"),
                error.DEPTH_ZERO_SELF_SIGNED_CERT => bun.String.static("self signed certificate"),
                error.SELF_SIGNED_CERT_IN_CHAIN => bun.String.static("self signed certificate in certificate chain"),
                error.UNABLE_TO_GET_ISSUER_CERT_LOCALLY => bun.String.static("unable to get local issuer certificate"),
                error.UNABLE_TO_VERIFY_LEAF_SIGNATURE => bun.String.static("unable to verify the first certificate"),
                error.CERT_CHAIN_TOO_LONG => bun.String.static("certificate chain too long"),
                error.CERT_REVOKED => bun.String.static("certificate revoked"),
                error.INVALID_CA => bun.String.static("invalid CA certificate"),
                error.INVALID_NON_CA => bun.String.static("invalid non-CA certificate (has CA markings)"),
                error.PATH_LENGTH_EXCEEDED => bun.String.static("path length constraint exceeded"),
                error.PROXY_PATH_LENGTH_EXCEEDED => bun.String.static("proxy path length constraint exceeded"),
                error.PROXY_CERTIFICATES_NOT_ALLOWED => bun.String.static("proxy certificates not allowed, please set the appropriate flag"),
                error.INVALID_PURPOSE => bun.String.static("unsupported certificate purpose"),
                error.CERT_UNTRUSTED => bun.String.static("certificate not trusted"),
                error.CERT_REJECTED => bun.String.static("certificate rejected"),
                error.APPLICATION_VERIFICATION => bun.String.static("application verification failure"),
                error.SUBJECT_ISSUER_MISMATCH => bun.String.static("subject issuer mismatch"),
                error.AKID_SKID_MISMATCH => bun.String.static("authority and subject key identifier mismatch"),
                error.AKID_ISSUER_SERIAL_MISMATCH => bun.String.static("authority and issuer serial number mismatch"),
                error.KEYUSAGE_NO_CERTSIGN => bun.String.static("key usage does not include certificate signing"),
                error.UNABLE_TO_GET_CRL_ISSUER => bun.String.static("unable to get CRL issuer certificate"),
                error.UNHANDLED_CRITICAL_EXTENSION => bun.String.static("unhandled critical extension"),
                error.KEYUSAGE_NO_CRL_SIGN => bun.String.static("key usage does not include CRL signing"),
                error.KEYUSAGE_NO_DIGITAL_SIGNATURE => bun.String.static("key usage does not include digital signature"),
                error.UNHANDLED_CRITICAL_CRL_EXTENSION => bun.String.static("unhandled critical CRL extension"),
                error.INVALID_EXTENSION => bun.String.static("invalid or inconsistent certificate extension"),
                error.INVALID_POLICY_EXTENSION => bun.String.static("invalid or inconsistent certificate policy extension"),
                error.NO_EXPLICIT_POLICY => bun.String.static("no explicit policy"),
                error.DIFFERENT_CRL_SCOPE => bun.String.static("Different CRL scope"),
                error.UNSUPPORTED_EXTENSION_FEATURE => bun.String.static("Unsupported extension feature"),
                error.UNNESTED_RESOURCE => bun.String.static("RFC 3779 resource not subset of parent's resources"),
                error.PERMITTED_VIOLATION => bun.String.static("permitted subtree violation"),
                error.EXCLUDED_VIOLATION => bun.String.static("excluded subtree violation"),
                error.SUBTREE_MINMAX => bun.String.static("name constraints minimum and maximum not supported"),
                error.UNSUPPORTED_CONSTRAINT_TYPE => bun.String.static("unsupported name constraint type"),
                error.UNSUPPORTED_CONSTRAINT_SYNTAX => bun.String.static("unsupported or invalid name constraint syntax"),
                error.UNSUPPORTED_NAME_SYNTAX => bun.String.static("unsupported or invalid name syntax"),
                error.CRL_PATH_VALIDATION_ERROR => bun.String.static("CRL path validation error"),
                error.SUITE_B_INVALID_VERSION => bun.String.static("Suite B: certificate version invalid"),
                error.SUITE_B_INVALID_ALGORITHM => bun.String.static("Suite B: invalid public key algorithm"),
                error.SUITE_B_INVALID_CURVE => bun.String.static("Suite B: invalid ECC curve"),
                error.SUITE_B_INVALID_SIGNATURE_ALGORITHM => bun.String.static("Suite B: invalid signature algorithm"),
                error.SUITE_B_LOS_NOT_ALLOWED => bun.String.static("Suite B: curve not allowed for this LOS"),
                error.SUITE_B_CANNOT_SIGN_P_384_WITH_P_256 => bun.String.static("Suite B: cannot sign P-384 with P-256"),
                error.HOSTNAME_MISMATCH => bun.String.static("Hostname mismatch"),
                error.EMAIL_MISMATCH => bun.String.static("Email address mismatch"),
                error.IP_ADDRESS_MISMATCH => bun.String.static("IP address mismatch"),
                error.INVALID_CALL => bun.String.static("Invalid certificate verification context"),
                error.STORE_LOOKUP => bun.String.static("Issuer certificate lookup error"),
                error.NAME_CONSTRAINTS_WITHOUT_SANS => bun.String.static("Issuer has name constraints but leaf has no SANs"),
                error.UNKNOWN_CERTIFICATE_VERIFICATION_ERROR => bun.String.static("unknown certificate verification error"),

                else => |e| bun.String.createFormat("{s} fetching \"{f}\". For more information, pass `verbose: true` in the second argument to fetch()", .{
                    @errorName(e),
                    path,
                }) catch |err| bun.handleOom(err),
            },
            .path = path,
        };

        return .{ .SystemError = fetch_error };
    }

    pub fn onReadableStreamAvailable(ctx: *anyopaque, globalThis: *jsc.JSGlobalObject, readable: jsc.WebCore.ReadableStream) void {
        const this = bun.cast(*FetchTasklet, ctx);
        this.readable_stream_ref = jsc.WebCore.ReadableStream.Strong.init(readable, globalThis);
    }

    pub fn onStartStreamingHTTPResponseBodyCallback(ctx: *anyopaque) jsc.WebCore.DrainResult {
        const this = bun.cast(*FetchTasklet, ctx);
        if (this.signal_store.aborted.load(.monotonic)) {
            return jsc.WebCore.DrainResult{
                .aborted = {},
            };
        }

        this.mutex.lock();
        defer this.mutex.unlock();
        const size_hint = this.getSizeHint();

        var scheduled_response_buffer = this.scheduled_response_buffer.list;
        // This means we have received part of the body but not the whole thing
        if (scheduled_response_buffer.items.len > 0) {
            this.scheduled_response_buffer = .{
                .allocator = bun.default_allocator,
                .list = .{
                    .items = &.{},
                    .capacity = 0,
                },
            };

            return .{
                .owned = .{
                    .list = scheduled_response_buffer.toManaged(bun.default_allocator),
                    .size_hint = size_hint,
                },
            };
        }

        return .{
            .estimated_size = size_hint,
        };
    }

    fn getSizeHint(this: *FetchTasklet) Blob.SizeType {
        return switch (this.body_size) {
            .content_length => @truncate(this.body_size.content_length),
            .total_received => @truncate(this.body_size.total_received),
            .unknown => 0,
        };
    }

    /// Clear the cancel_handler on the ByteStream.Source to prevent use-after-free.
    /// Must be called before releasing readable_stream_ref, while the Strong ref
    /// still keeps the ReadableStream (and thus the ByteStream.Source) alive.
    fn clearStreamCancelHandler(this: *FetchTasklet) void {
        if (this.readable_stream_ref.get(this.global_this)) |readable| {
            if (readable.ptr == .Bytes) {
                const source = readable.ptr.Bytes.parent();
                source.cancel_handler = null;
                source.cancel_ctx = null;
            }
        }
    }

    fn onStreamCancelledCallback(ctx: ?*anyopaque) void {
        const this = bun.cast(*FetchTasklet, ctx.?);
        if (this.ignore_data) return;
        this.ignoreRemainingResponseBody();
    }

    fn toBodyValue(this: *FetchTasklet) Body.Value {
        if (this.getAbortError()) |err| {
            return .{ .Error = err };
        }
        if (this.is_waiting_body) {
            const response = Body.Value{
                .Locked = .{
                    .size_hint = this.getSizeHint(),
                    .task = this,
                    .global = this.global_this,
                    .onStartStreaming = FetchTasklet.onStartStreamingHTTPResponseBodyCallback,
                    .onReadableStreamAvailable = FetchTasklet.onReadableStreamAvailable,
                    .onStreamCancelled = FetchTasklet.onStreamCancelledCallback,
                },
            };
            return response;
        }

        var scheduled_response_buffer = this.scheduled_response_buffer.list;
        const response = Body.Value{
            .InternalBlob = .{
                .bytes = scheduled_response_buffer.toManaged(bun.default_allocator),
            },
        };
        this.scheduled_response_buffer = .{
            .allocator = bun.default_allocator,
            .list = .{
                .items = &.{},
                .capacity = 0,
            },
        };

        return response;
    }

    fn toResponse(this: *FetchTasklet) Response {
        log("toResponse", .{});
        bun.assert(this.metadata != null);
        // at this point we always should have metadata
        const metadata = this.metadata.?;
        const http_response = metadata.response;
        this.is_waiting_body = this.result.has_more;
        return Response.init(
            .{
                .headers = FetchHeaders.createFromPicoHeaders(http_response.headers),
                .status_code = @as(u16, @truncate(http_response.status_code)),
                .status_text = bun.String.createAtomIfPossible(http_response.status),
            },
            Body{
                .value = this.toBodyValue(),
            },
            bun.String.createAtomIfPossible(metadata.url),
            this.result.redirected,
        );
    }

    fn ignoreRemainingResponseBody(this: *FetchTasklet) void {
        log("ignoreRemainingResponseBody", .{});
        // we should not keep the process alive if we are ignoring the body
        const vm = this.javascript_vm;
        this.poll_ref.unref(vm);
        // clean any remaining references
        this.clearStreamCancelHandler();
        this.readable_stream_ref.deinit();
        this.response.deinit();

        if (this.native_response) |response| {
            response.unref();
            this.native_response = null;
        }

        this.ignore_data = true;
    }

    export fn Bun__FetchResponse_finalize(this: *FetchTasklet) callconv(.c) void {
        log("onResponseFinalize", .{});
        if (this.native_response) |response| {
            const body = response.getBodyValue();
            // Three scenarios:
            //
            // 1. We are streaming, in which case we should not ignore the body.
            // 2. We were buffering, in which case
            //    2a. if we have no promise, we should ignore the body.
            //    2b. if we have a promise, we should keep loading the body.
            // 3. We never started buffering, in which case we should ignore the body.
            //
            // Note: We cannot call .get() on the ReadableStreamRef. This is called inside a finalizer.
            if (body.* != .Locked or this.readable_stream_ref.held.has()) {
                // Scenario 1 or 3.
                return;
            }

            if (body.Locked.promise) |promise| {
                if (promise.isEmptyOrUndefinedOrNull()) {
                    // Scenario 2b.
                    this.ignoreRemainingResponseBody();
                }
            } else {
                // Scenario 3.
                this.ignoreRemainingResponseBody();
            }
        }
    }
    comptime {
        _ = Bun__FetchResponse_finalize;
    }

    pub fn onResolve(this: *FetchTasklet) JSValue {
        log("onResolve", .{});
        const response = bun.new(Response, this.toResponse());
        const response_js = Response.makeMaybePooled(@as(*jsc.JSGlobalObject, this.global_this), response);
        response_js.ensureStillAlive();
        this.response = jsc.Weak(FetchTasklet).create(response_js, this.global_this, .FetchResponse, this);
        this.native_response = response.ref();
        return response_js;
    }

    pub fn get(
        allocator: std.mem.Allocator,
        globalThis: *jsc.JSGlobalObject,
        fetch_options: *const FetchOptions,
        promise: jsc.JSPromise.Strong,
    ) !*FetchTasklet {
        var jsc_vm = globalThis.bunVM();
        var fetch_tasklet = try allocator.create(FetchTasklet);

        fetch_tasklet.* = .{
            .mutex = .{},
            .scheduled_response_buffer = .{
                .allocator = bun.default_allocator,
                .list = .{
                    .items = &.{},
                    .capacity = 0,
                },
            },
            .response_buffer = MutableString{
                .allocator = bun.default_allocator,
                .list = .{
                    .items = &.{},
                    .capacity = 0,
                },
            },
            .javascript_vm = jsc_vm,
            .request_body = fetch_options.body,
            .global_this = globalThis,
            .promise = promise,
            .request_headers = fetch_options.headers,
            .url_proxy_buffer = fetch_options.url_proxy_buffer,
            .signal = fetch_options.signal,
            .hostname = fetch_options.hostname,
            .tracker = jsc.Debugger.AsyncTaskTracker.init(jsc_vm),
            .check_server_identity = fetch_options.check_server_identity,
            .reject_unauthorized = fetch_options.reject_unauthorized,
            .upgraded_connection = fetch_options.upgraded_connection,
        };
        errdefer fetch_tasklet.deref();

        fetch_tasklet.signals = fetch_tasklet.signal_store.to();

        fetch_tasklet.tracker.didSchedule(globalThis);

        if (fetch_tasklet.request_body.store()) |store| {
            store.ref();
        }

        var url = fetch_options.url;
        var proxy: ?ZigURL = null;
        if (fetch_options.proxy) |proxy_opt| {
            if (!proxy_opt.isEmpty()) { //if is empty just ignore proxy
                // Check NO_PROXY even for explicitly-provided proxies
                if (!jsc_vm.transpiler.env.isNoProxy(url.hostname, url.host)) {
                    proxy = proxy_opt;
                }
            }
            // else: proxy: "" means explicitly no proxy (direct connection)
        } else {
            // no proxy provided, use default proxy resolution
            if (jsc_vm.transpiler.env.getHttpProxyFor(url)) |env_proxy| {
                // env_proxy.href may be a slice into a RefCountedEnvValue's bytes which can
                // be freed by a subsequent `process.env.HTTP_PROXY = "..."` assignment while
                // this fetch is in flight on the HTTP thread. Clone it into url_proxy_buffer
                // alongside the request URL — the same pattern fetch.zig uses for the explicit
                // `fetch(url, { proxy: "..." })` option.
                if (env_proxy.href.len > 0) {
                    const old_url_len = url.href.len;
                    const new_buffer = try std.fmt.allocPrint(bun.default_allocator, "{s}{s}", .{ fetch_tasklet.url_proxy_buffer, env_proxy.href });
                    if (fetch_tasklet.url_proxy_buffer.len > 0) {
                        bun.default_allocator.free(fetch_tasklet.url_proxy_buffer);
                    }
                    fetch_tasklet.url_proxy_buffer = new_buffer;
                    url = ZigURL.parse(new_buffer[0..old_url_len]);
                    proxy = ZigURL.parse(new_buffer[old_url_len..]);
                } else {
                    proxy = env_proxy;
                }
            }
        }

        if (fetch_tasklet.check_server_identity.has() and fetch_tasklet.reject_unauthorized) {
            fetch_tasklet.signal_store.cert_errors.store(true, .monotonic);
        } else {
            fetch_tasklet.signals.cert_errors = null;
        }

        const entries = fetch_options.headers.entries.slice();
        const names = entries.items(.name);
        const values = entries.items(.value);
        const wire_headers = try allocator.alloc(bun.rt.http_wire.Header, entries.len);
        defer allocator.free(wire_headers);
        for (wire_headers, 0..) |*header, index| {
            header.* = .{
                .name = fetch_options.headers.asStr(names[index]),
                .value = fetch_options.headers.asStr(values[index]),
            };
        }
        const wire_flags: bun.rt.http_wire.RequestFlags = .{
            .disable_timeout = fetch_options.disable_timeout,
            .disable_keepalive = fetch_options.disable_keepalive,
            .disable_decompression = fetch_options.disable_decompression,
            .reject_unauthorized = fetch_options.reject_unauthorized,
            .force_http1 = fetch_options.force_http1,
            .force_http2 = fetch_options.force_http2,
            .force_http3 = fetch_options.force_http3,
            .streaming_body = fetch_tasklet.request_body == .ReadableStream,
        };
        fetch_tasklet.is_waiting_request_stream_start = fetch_tasklet.request_body == .ReadableStream;
        fetch_tasklet.host_request_payload = bun.rt.http_wire.encodeRequest(allocator, .{
            .method = @intFromEnum(fetch_options.method),
            .redirect = @intFromEnum(fetch_options.redirect_type),
            .flags = @bitCast(wire_flags),
            .url = url.href,
            .proxy = if (proxy) |value| value.href else "",
            .hostname = fetch_options.hostname orelse "",
            .unix_socket = fetch_options.unix_socket_path.slice(),
            .headers = wire_headers,
            .body = fetch_tasklet.request_body.slice(),
        }) catch return error.OutOfMemory;

        if (fetch_tasklet.signal) |signal| {
            signal.pendingActivityRef();
            fetch_tasklet.signal = signal.listen(FetchTasklet, fetch_tasklet, FetchTasklet.abortListener);
        }
        return fetch_tasklet;
    }

    pub fn abortListener(this: *FetchTasklet, reason: JSValue) void {
        log("abortListener", .{});
        reason.ensureStillAlive();
        this.abort_reason.set(this.global_this, reason);
        this.abortTask();
        if (this.sink) |sink| {
            sink.cancel(reason);
            return;
        }
        // Abort fired before the HTTP thread asked for the body, so the
        // ReadableStream was never wired into a sink. Cancel it directly so
        // the underlying source's cancel(reason) callback still observes the
        // signal's reason (https://fetch.spec.whatwg.org/#abort-fetch step 5).
        if (this.is_waiting_request_stream_start and this.request_body == .ReadableStream) {
            this.is_waiting_request_stream_start = false;
            if (this.request_body.ReadableStream.get(this.global_this)) |stream| {
                stream.cancelWithReason(this.global_this, reason);
            }
        }
    }

    /// Whether the request body should skip chunked transfer encoding framing.
    /// True for upgraded connections (e.g. WebSocket) or when the user explicitly
    /// set Content-Length without setting Transfer-Encoding.
    fn skipChunkedFraming(this: *const FetchTasklet) bool {
        return this.upgraded_connection or
            this.result.is_http2 or
            (this.request_headers.get("content-length") != null and this.request_headers.get("transfer-encoding") == null);
    }

    pub fn writeRequestData(this: *FetchTasklet, data: []const u8) ResumableSinkBackpressure {
        log("writeRequestData {}", .{data.len});
        if (this.signal) |signal| {
            if (signal.aborted()) {
                return .done;
            }
        }
        if (this.skipChunkedFraming()) {
            return if (this.sendHostBytes(.http_request_body, data)) .want_more else .backpressure;
        }

        var size_buffer: [18]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buffer, "{x}\r\n", .{data.len}) catch unreachable;
        const framed = bun.default_allocator.alloc(u8, size.len + data.len + 2) catch return .backpressure;
        defer bun.default_allocator.free(framed);
        @memcpy(framed[0..size.len], size);
        @memcpy(framed[size.len..][0..data.len], data);
        @memcpy(framed[size.len + data.len ..], "\r\n");
        return if (this.sendHostBytes(.http_request_body, framed)) .want_more else .backpressure;
    }

    pub fn writeEndRequest(this: *FetchTasklet, err: ?jsc.JSValue) void {
        log("writeEndRequest hasError? {}", .{err != null});
        defer this.deref();
        if (err) |jsError| {
            if (this.signal_store.aborted.load(.monotonic) or this.abort_reason.has()) {
                return;
            }
            if (!jsError.isUndefinedOrNull()) {
                this.abort_reason.set(this.global_this, jsError);
            }
            this.abortTask();
        } else {
            if (!this.skipChunkedFraming()) {
                if (!this.sendHostBytes(.http_request_body, http.end_of_chunked_http1_1_encoding_response_body)) {
                    this.abortTask();
                    return;
                }
            }
            if (bun.rt.vm_bridge.get()) |bridge| {
                var command = bun.rt.contract.Command.init(.submit, .http_request_end);
                command.request_id = this.host_request_id;
                bridge.send(command) catch this.abortTask();
            }
        }
    }

    fn sendHostBytes(this: *FetchTasklet, operation: bun.rt.contract.Operation, bytes: []const u8) bool {
        const bridge = bun.rt.vm_bridge.get() orelse return false;
        const payload = bridge.io.data.allocate(bytes.len) catch return false;
        const mapped = bridge.io.data.map(payload) catch {
            bridge.io.data.release(payload);
            return false;
        };
        @memcpy(mapped.slice(), bytes);
        var command = bun.rt.contract.Command.init(.submit, operation);
        command.request_id = this.host_request_id;
        command.payload = payload;
        bridge.send(command) catch {
            bridge.io.data.release(payload);
            return false;
        };
        return true;
    }

    fn cancelHostRequest(this: *FetchTasklet) void {
        if (this.host_request_id == 0) return;
        if (bun.rt.vm_bridge.get()) |bridge| {
            bridge.cancel(this.host_request_id, .http_request_start) catch {};
        }
    }

    pub fn abortTask(this: *FetchTasklet) void {
        this.signal_store.aborted.store(true, .monotonic);
        this.tracker.didCancel(this.global_this);

        this.cancelHostRequest();
    }

    const FetchOptions = struct {
        method: Method,
        headers: Headers,
        body: HTTPRequestBody,
        disable_timeout: bool,
        disable_keepalive: bool,
        disable_decompression: bool,
        reject_unauthorized: bool,
        url: ZigURL,
        verbose: http.HTTPVerboseLevel = .none,
        redirect_type: FetchRedirect = FetchRedirect.follow,
        proxy: ?ZigURL = null,
        proxy_headers: ?Headers = null,
        url_proxy_buffer: []const u8 = "",
        signal: ?*jsc.WebCore.AbortSignal = null,
        globalThis: ?*JSGlobalObject,
        // Custom Hostname
        hostname: ?[]u8 = null,
        check_server_identity: jsc.Strong.Optional = .empty,
        unix_socket_path: ZigString.Slice,
        ssl_config: ?SSLConfig.SharedPtr = null,
        upgraded_connection: bool = false,
        force_http2: bool = false,
        force_http3: bool = false,
        force_http1: bool = false,
    };

    pub fn queue(
        allocator: std.mem.Allocator,
        global: *JSGlobalObject,
        fetch_options: *const FetchOptions,
        promise: jsc.JSPromise.Strong,
    ) std.mem.Allocator.Error!*FetchTasklet {
        var node = try get(
            allocator,
            global,
            fetch_options,
            promise,
        );
        errdefer node.deref();
        const bridge = bun.rt.vm_bridge.get() orelse Output.panic("runtime host bridge is not installed", .{});
        const payload_bytes = node.host_request_payload orelse unreachable;
        const payload = bridge.io.data.allocate(payload_bytes.len) catch return error.OutOfMemory;
        errdefer bridge.io.data.release(payload);
        @memcpy((bridge.io.data.map(payload) catch return error.OutOfMemory).slice(), payload_bytes);
        allocator.free(payload_bytes);
        node.host_request_payload = null;

        const request_id = bridge.allocateRequestId();
        node.host_request_id = request_id;
        node.poll_ref.ref(global.bunVM());
        node.ref();
        errdefer node.deref();
        var command = bun.rt.contract.Command.init(.submit, .http_request_start);
        command.request_id = request_id;
        command.payload = payload;
        bridge.submit(command, .{ .context = node, .on_message = FetchTasklet.onHostMessage }) catch return error.OutOfMemory;

        return node;
    }

    fn onHostMessage(context: *anyopaque, command: bun.rt.contract.Command) bool {
        const task: *FetchTasklet = @ptrCast(@alignCast(context));
        const bridge = bun.rt.vm_bridge.get() orelse return true;
        defer if (!command.payload.isEmpty()) bridge.io.data.release(command.payload);

        switch (command.operationKind()) {
            .http_request_ready => {
                var empty_body: MutableString = .{ .allocator = bun.default_allocator, .list = .empty };
                task.acceptResult(.{
                    .body = &empty_body,
                    .has_more = true,
                    .can_stream = true,
                    .is_http2 = command.arg0 != 0,
                });
                return false;
            },
            .http_response_headers => {
                const mapped = bridge.io.data.map(command.payload) catch {
                    task.acceptHostFailure(error.InvalidHostResponse);
                    return true;
                };
                const owned = bun.default_allocator.dupe(u8, mapped.slice()) catch {
                    task.acceptHostFailure(error.OutOfMemory);
                    return true;
                };
                const decoded = bun.rt.http_wire.decodeResponse(owned) catch {
                    bun.default_allocator.free(owned);
                    task.acceptHostFailure(error.InvalidHostResponse);
                    return true;
                };
                const response_headers = bun.default_allocator.alloc(bun.picohttp.Header, decoded.prefix.header_count) catch {
                    bun.default_allocator.free(owned);
                    task.acceptHostFailure(error.OutOfMemory);
                    return true;
                };
                for (response_headers, 0..) |*header, index| {
                    const source = decoded.header(index).?;
                    header.* = .{ .name = source.name, .value = source.value };
                }
                var empty_body: MutableString = .{ .allocator = bun.default_allocator, .list = .empty };
                task.acceptResult(.{
                    .body = &empty_body,
                    .has_more = true,
                    .metadata = .{
                        .url = decoded.url(),
                        .owned_buf = owned,
                        .response = .{
                            .status_code = decoded.prefix.status_code,
                            .status = decoded.statusText(),
                            .headers = .{ .list = response_headers },
                        },
                    },
                });
                return false;
            },
            .http_response_body => {
                const mapped = bridge.io.data.map(command.payload) catch {
                    task.acceptHostFailure(error.InvalidHostResponse);
                    return true;
                };
                var body: MutableString = .{ .allocator = bun.default_allocator, .list = .empty };
                _ = body.write(mapped.slice()) catch {
                    task.acceptHostFailure(error.OutOfMemory);
                    return true;
                };
                task.acceptResult(.{ .body = &body, .has_more = true });
                return false;
            },
            .http_response_end => {
                var empty_body: MutableString = .{ .allocator = bun.default_allocator, .list = .empty };
                const failure: ?anyerror = if (command.status == 0)
                    null
                else switch (command.arg0) {
                    1 => error.Timeout,
                    2 => error.Aborted,
                    else => error.FetchHostFailure,
                };
                task.acceptResult(.{ .body = &empty_body, .has_more = false, .fail = failure });
                return true;
            },
            else => {
                task.acceptHostFailure(error.InvalidHostResponse);
                return true;
            },
        }
    }

    fn acceptHostFailure(task: *FetchTasklet, failure: anyerror) void {
        var empty_body: MutableString = .{ .allocator = bun.default_allocator, .list = .empty };
        task.acceptResult(.{ .body = &empty_body, .has_more = false, .fail = failure });
    }

    fn acceptResult(task: *FetchTasklet, result: http.HTTPClientResult) void {
        const is_done = !result.has_more;
        defer if (is_done) task.derefFromThread();

        task.mutex.lock();
        defer task.mutex.unlock();

        log("callback success={} ignore_data={} has_more={} bytes={}", .{ result.isSuccess(), task.ignore_data, result.has_more, result.body.?.list.items.len });

        const prev_metadata = task.result.metadata;
        const prev_cert_info = task.result.certificate_info;
        const prev_can_stream = task.result.can_stream;
        task.result = result;
        // can_stream is a one-shot signal to start the request body stream; don't let a
        // later coalesced result clobber it before the JS thread sees it.
        task.result.can_stream = task.result.can_stream or prev_can_stream;

        // Preserve pending certificate info if it was preovided in the previous update.
        if (task.result.certificate_info == null) {
            if (prev_cert_info) |cert_info| {
                task.result.certificate_info = cert_info;
            }
        }

        // metadata should be provided only once
        if (result.metadata orelse prev_metadata) |metadata| {
            log("added callback metadata", .{});
            if (task.metadata == null) {
                task.metadata = metadata;
            }

            task.result.metadata = null;
        }

        task.body_size = result.body_size;

        const success = result.isSuccess();
        task.response_buffer = result.body.?.*;

        if (task.ignore_data) {
            task.response_buffer.reset();

            if (task.scheduled_response_buffer.list.capacity > 0) {
                task.scheduled_response_buffer.deinit();
                task.scheduled_response_buffer = .{
                    .allocator = bun.default_allocator,
                    .list = .{
                        .items = &.{},
                        .capacity = 0,
                    },
                };
            }
            if (success and result.has_more) {
                // we are ignoring the body so we should not receive more data, so will only signal when result.has_more = true
                return;
            }
        } else {
            if (success) {
                _ = bun.handleOom(task.scheduled_response_buffer.write(task.response_buffer.list.items));
            }
            // reset for reuse
            task.response_buffer.reset();
        }

        if (task.has_schedule_callback.cmpxchgStrong(false, true, .acquire, .monotonic)) |has_schedule_callback| {
            if (has_schedule_callback) {
                return;
            }
        }
        // will deinit when done with the http client (when is_done = true)
        if (task.javascript_vm.isShuttingDown()) return;
        task.javascript_vm.eventLoop().enqueueTaskConcurrent(task.concurrent_task.from(task, .manual_deinit));
    }
};

const X509 = @import("../../api/bun/x509.zig");
const std = @import("std");
const Method = @import("../../../http_types/Method.zig").Method;
const ZigURL = @import("../../../url/url.zig").URL;

const bun = @import("bun");
const Async = bun.Async;
const MutableString = bun.MutableString;
const Mutex = bun.Mutex;
const Output = bun.Output;
const BoringSSL = bun.BoringSSL.c;
const FetchHeaders = bun.webcore.FetchHeaders;
const SSLConfig = bun.api.server.ServerConfig.SSLConfig;

const http = bun.http;
const FetchRedirect = http.FetchRedirect;
const Headers = bun.http.Headers;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSPromise = jsc.JSPromise;
const JSValue = jsc.JSValue;
const VirtualMachine = jsc.VirtualMachine;
const ZigString = jsc.ZigString;

const Body = jsc.WebCore.Body;
const Response = jsc.WebCore.Response;
const ResumableSinkBackpressure = jsc.WebCore.ResumableSinkBackpressure;

const Blob = jsc.WebCore.Blob;
const AnyBlob = jsc.WebCore.Blob.Any;
