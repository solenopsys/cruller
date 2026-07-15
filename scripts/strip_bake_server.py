#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def replace_exact(text: str, old: str, new: str, expected: int = 1) -> str:
    found = text.count(old)
    if found != expected:
        raise SystemExit(f"expected {expected} occurrences, found {found}: {old[:100]!r}")
    return text.replace(old, new)


def remove_between(text: str, start: str, end: str, keep_end: bool = True) -> str:
    if text.count(start) != 1:
        raise SystemExit(f"non-unique range: {start!r} .. {end!r}")
    a = text.index(start)
    b = text.find(end, a)
    if b < 0:
        raise SystemExit(f"missing range end after start: {end!r}")
    return text[:a] + (text[b:] if keep_end else text[b + len(end):])


server_path = ROOT / "src/runtime/server/server.zig"
text = server_path.read_text()
text = replace_exact(text, 'pub const HTMLBundle = @import("./HTMLBundle.zig");\n', "")
text = replace_exact(
    text,
    '''    /// Bundle an HTML import
    /// import html from "./index.html";
    /// "/": html,
    html: bun.ptr.RefPtr(HTMLBundle.Route),
    /// Use file system routing.
    /// "/*": {
    ///   "dir": import.meta.resolve("./pages"),
    ///   "style": "nextjs-pages",
    /// }
    framework_router: bun.bake.FrameworkRouter.Type.Index,
''',
    "",
)
for block in (
    '''            .html => |html_bundle_route| html_bundle_route.data.memoryCost(),
            .framework_router => @sizeOf(bun.bake.Framework.FileSystemRouterType),
''',
    '''            .html => |html_bundle_route| html_bundle_route.server = server,
            .framework_router => {}, // DevServer contains .server field
''',
    '''            .html => |html_bundle_route| html_bundle_route.deref(),
            .framework_router => {}, // not reference counted
''',
    '''            .html => |html_bundle_route| html_bundle_route.ref(),
            .framework_router => {}, // not reference counted
''',
):
    text = replace_exact(text, block, "")

text = remove_between(text, "    fn bundledHTMLManifestItemFromJS(", "    pub fn fromOptions(")
text = remove_between(text, "    pub fn htmlRouteFromJS(", "    pub fn fromJS(")
text = replace_exact(
    text,
    '''        argument: jsc.JSValue,
        init_ctx: *ServerInitContext,
    ) bun.JSError!?AnyRoute {
        if (try AnyRoute.htmlRouteFromJS(argument, init_ctx)) |html_route| {
            return html_route;
        }

        if (argument.isObject()) {
            const FrameworkRouter = bun.bake.FrameworkRouter;
            if (try argument.getOptional(global, "dir", bun.String.Slice)) |dir| {
                var alloc = init_ctx.js_string_allocations;
                const relative_root = alloc.track(dir);

                var style: FrameworkRouter.Style = if (try argument.get(global, "style")) |style|
                    try FrameworkRouter.Style.fromJS(style, global)
                else
                    .nextjs_pages;
                errdefer style.deinit();

                if (!bun.strings.endsWith(path, "/*")) {
                    return global.throwInvalidArguments("To mount a directory, make sure the path ends in `/*`", .{});
                }

                try init_ctx.framework_router_list.append(.{
                    .root = relative_root,
                    .style = style,

                    // trim the /*
                    .prefix = if (path.len == 2) "/" else path[0 .. path.len - 2],

                    // TODO: customizable framework option.
                    .entry_client = "bun-framework-react/client.tsx",
                    .entry_server = "bun-framework-react/server.tsx",
                    .ignore_underscores = true,
                    .ignore_dirs = &.{ "node_modules", ".git" },
                    .extensions = &.{ ".tsx", ".jsx" },
                    .allow_layouts = true,
                });

                const limit = std.math.maxInt(@typeInfo(FrameworkRouter.Type.Index).@"enum".tag_type);
                if (init_ctx.framework_router_list.items.len > limit) {
                    return global.throwInvalidArguments("Too many framework routers. Maximum is {d}.", .{limit});
                }
                return .{ .framework_router = .init(@intCast(init_ctx.framework_router_list.items.len - 1)) };
            }
        }

''',
    '''        argument: jsc.JSValue,
    ) bun.JSError!?AnyRoute {
        _ = path;
''',
)

text = remove_between(text, "/// State machine to handle loading plugins asynchronously.", "pub fn NewServer(")
text = replace_exact(text, "        plugins: ?*ServePlugins = null,\n\n", "")
text = remove_between(text, "        /// Returns:\n        /// - .ready if no plugin has to be loaded", "        pub fn doSubscriberCount(")
text = replace_exact(
    text,
    '''            if (this.plugins) |plugins| {
                plugins.deref();
            }

''',
    "",
)
text = replace_exact(
    text,
    '''                        .html => |html_bundle_route| {
                            ServerConfig.applyStaticRoute(any_server, ssl_enabled, app, *HTMLBundle.Route, html_bundle_route.data, entry.path, entry.method);
                            if (comptime has_h3) if (this.h3_app) |h3_app|
                                ServerConfig.applyStaticRouteH3(any_server, h3_app, *HTMLBundle.Route, html_bundle_route.data, entry.path, entry.method);
                            if (dev_server) |dev| {
                                bun.handleOom(dev.html_router.put(dev.allocator(), entry.path, html_bundle_route.data));
                            }
                            needs_plugins = true;
                        },
                        .framework_router => {},
''',
    "",
)
text = remove_between(text, "            // --- 6. Initialize plugins if needed ---", "            // --- 7. Debug mode specific routes ---")
text = remove_between(text, "    pub fn plugins(this: AnyServer)", "    pub fn reloadStaticRoutes(")
server_path.write_text(text)


config_path = ROOT / "src/runtime/server/ServerConfig.zig"
text = config_path.read_text()
text = replace_exact(text, "bake: ?bun.bake.UserOptions = null,\n\n", "")
text = replace_exact(text, "    this.bake = null;\n", "")
text = replace_exact(
    text,
    '''    if (this.bake) |*bake| {
        bake.deinit();
    }

''',
    "",
)
text = replace_exact(
    text,
    '''    defer {
        if (!args.development.isHMREnabled()) {
            bun.assert(args.bake == null);
        }
    }

''',
    "",
)
text = remove_between(text, "            var init_ctx_: AnyRoute.ServerInitContext", "            errdefer {\n                for (args.static_routes.items)")
text = replace_exact(text, "AnyRoute.fromJS(global, path, function, init_ctx)", "AnyRoute.fromJS(global, path, function)")
text = replace_exact(text, "AnyRoute.fromJS(global, path, value, init_ctx)", "AnyRoute.fromJS(global, path, value)")
text = remove_between(text, "            // When HTML bundles are provided", "        }\n\n        if (global.hasException()", keep_end=True)
text = remove_between(text, "        if (opts.allow_bake_config) {", "        if (try arg.get(global, \"reusePort\"))")
text = replace_exact(text, "        } else if (args.bake == null and args.onNodeHTTPRequest", "        } else if (args.onNodeHTTPRequest")
text = replace_exact(text, "Response | HTMLBundle | ", "Response | ")
config_path.write_text(text)

print("removed Bake/HTML-bundling/plugin paths from the production server graph")
