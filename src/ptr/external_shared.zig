/// A shared pointer whose reference count is managed externally; e.g., by extern functions.
///
/// `T.external_shared_descriptor` must be a struct of the following form:
///
///     pub const external_shared_descriptor = struct {
///         pub fn ref(T*) void;
///         pub fn deref(T*) void;
///     };
pub fn ExternalShared(comptime T: type) type {
    return struct {
        const Self = @This();

        comptime {
            _ = T.external_shared_descriptor.ref; // must define a `ref` function
            _ = T.external_shared_descriptor.deref; // must define a `deref` function
        }

        priv_impl: *T,

        /// `incremented_raw` should have already had its ref count incremented by 1.
        pub fn adopt(incremented_raw: *T) Self {
            return .{ .priv_impl = incremented_raw };
        }

        /// Deinitializes the shared pointer, decrementing the ref count.
        pub fn deinit(self: *Self) void {
            T.external_shared_descriptor.deref(self.priv_impl);
            self.* = undefined;
        }

        /// Gets the underlying pointer. This pointer may not be valid after `self` is
        /// deinitialized.
        pub fn get(self: Self) *T {
            return self.priv_impl;
        }

        /// Clones the shared pointer, incrementing the ref count.
        pub fn clone(self: Self) Self {
            T.external_shared_descriptor.ref(self.priv_impl);
            return self;
        }

        pub fn cloneFromRaw(raw: *T) Self {
            T.external_shared_descriptor.ref(raw);
            return .{ .priv_impl = raw };
        }

        /// Returns the raw pointer without decrementing the ref count. Invalidates `self`.
        pub fn leak(self: *Self) *T {
            defer self.* = undefined;
            return self.priv_impl;
        }

        const NonOptional = Self;

        pub const Optional = struct {
            priv_impl: ?*T = null,

            pub fn initNull() Optional {
                return .{};
            }

            /// `incremented_raw`, if non-null, should have already had its ref count incremented
            /// by 1.
            pub fn adopt(incremented_raw: ?*T) Optional {
                return .{ .priv_impl = incremented_raw };
            }

            pub fn deinit(self: *Optional) void {
                if (self.priv_impl) |impl| {
                    T.external_shared_descriptor.deref(impl);
                }
                self.* = undefined;
            }

            pub fn get(self: Optional) ?*T {
                return self.priv_impl;
            }

            /// Sets `self` to null.
            pub fn take(self: *Optional) ?NonOptional {
                const result: NonOptional = .{ .priv_impl = self.priv_impl orelse return null };
                self.priv_impl = null;
                return result;
            }

            pub fn clone(self: Optional) Optional {
                if (self.priv_impl) |impl| {
                    T.external_shared_descriptor.ref(impl);
                }
                return self;
            }

            pub fn cloneFromRaw(raw: ?*T) Optional {
                if (raw) |some_raw| {
                    T.external_shared_descriptor.ref(some_raw);
                }
                return .{ .priv_impl = raw };
            }

            /// Returns the raw pointer without decrementing the ref count. Invalidates `self`.
            pub fn leak(self: *Optional) ?*T {
                defer self.* = undefined;
                return self.priv_impl;
            }
        };

        /// Invalidates `self`.
        pub fn intoOptional(self: *Self) Optional {
            defer self.* = undefined;
            return .{ .priv_impl = self.priv_impl };
        }
    };
}
