#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def replace_exact(text: str, old: str, new: str, expected: int = 1) -> str:
    found = text.count(old)
    if found != expected:
        raise SystemExit(f"expected {expected} occurrences, found {found}: {old[:100]!r}")
    return text.replace(old, new)


def remove_between(text: str, start: str, end: str) -> str:
    if text.count(start) != 1:
        raise SystemExit(f"non-unique range start: {start!r}")
    a = text.index(start)
    b = text.find(end, a)
    if b < 0:
        raise SystemExit(f"missing range end: {end!r}")
    return text[:a] + text[b:]


path = ROOT / "src/runtime/server/server.zig"
text = path.read_text()
text = replace_exact(text, "        dev_server: ?*bun.bake.DevServer,\n\n", "")
text = replace_exact(
    text,
    '''            return @sizeOf(ThisServer) +
                this.base_url_string_for_joining.len +
                this.config.memoryCost() +
                (if (this.dev_server) |dev| dev.memoryCost() else 0);
''',
    '''            return @sizeOf(ThisServer) +
                this.base_url_string_for_joining.len +
                this.config.memoryCost();
''',
)
for block in (
    '''            // These get re-applied when we set the static routes again.
            if (this.dev_server) |dev_server| {
                // Prevent a use-after-free in the hash table keys.
                dev_server.html_router.clear();
                dev_server.html_router.fallback = null;
            }

''',
    '''                // Detach DevServer. This is needed because there are aggressive
                // tests that check for DevServer memory soundness. This reveals
                // a larger problem, that it seems that some objects like Server
                // should be detachable from their JSValue, so that when the
                // native handle is done, keeping the JS binding doesn't use
                // `this.memoryCost()` bytes.
                if (this.dev_server) |dev| {
                    this.dev_server = null;
                    if (this.app) |app| app.clearRoutes();
                    dev.deinit();
                }

''',
    '''            if (this.dev_server) |dev_server| {
                dev_server.deinit();
            }

''',
):
    text = replace_exact(text, block, "")

text = remove_between(text, "            const dev_server = if (config.bake)", "            var server = ThisServer.new(")
text = replace_exact(text, "                .dev_server = dev_server,\n", "")
text = remove_between(text, "        // https://chromium.googlesource.com/devtools/devtools-frontend/+/main/docs/ecosystem/automatic_workspace_folders.md\n        fn onChromeDevToolsJSONRequest", "        fn setRoutes(")
text = replace_exact(text, "            const dev_server = this.dev_server;\n\n", "")
text = remove_between(
    text,
    "            // https://chromium.googlesource.com/devtools/devtools-frontend/+/main/docs/ecosystem/automatic_workspace_folders.md\n            // Only enable this when we're using the dev server.",
    "            // --- 1. Handle user_routes_to_build",
)
text = replace_exact(text, "            var needs_plugins = dev_server != null;\n", "")
text = replace_exact(
    text,
    '''                    if (should_add_chrome_devtools_json_route) {
                        if (strings.eqlComptime(entry.path, chrome_devtools_route) or strings.hasPrefix(entry.path, "/.well-known/")) {
                            should_add_chrome_devtools_json_route = false;
                        }
                    }

''',
    "",
)
text = remove_between(text, "            // --- 8. Handle DevServer routes", "            // Setup user websocket fallback route")
text = replace_exact(text, " or has_dev_server_for_star_path", "")

for ty in ("HTTPServer", "HTTPSServer", "DebugHTTPServer", "DebugHTTPSServer"):
    text = replace_exact(
        text,
        f'''                if (this.ptr.as({ty}).dev_server) |dev_server| {{
                    dev_server.inspector_server_id = id;
                }}
''',
        "",
    )
text = remove_between(text, "    pub fn devServer(this: AnyServer)", "};\n\n")
path.write_text(text)


path = ROOT / "src/runtime/server/RequestContext.zig"
text = path.read_text()
text = remove_between(text, "        pub fn devServer(this: *const RequestContext)", "        pub fn memoryCost(")
text = remove_between(text, "            if (comptime debug_mode) {", "            req.endStream(req.shouldCloseConnection());")
path.write_text(text)


path = ROOT / "src/runtime/server/AnyRequestContext.zig"
text = path.read_text()
text = remove_between(text, "pub fn devServer(self: AnyRequestContext)", "pub fn deref(")
path.write_text(text)


path = ROOT / "src/bundler/options.zig"
text = path.read_text()
text = replace_exact(text, "    /// Set when Bake is bundling. Affects module resolution.\n    framework: ?*bun.bake.Framework = null,\n\n", "")
path.write_text(text)

print("removed remaining DevServer state and debug routes")
