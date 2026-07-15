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
for block in (
    '''                if (should_add_chrome_devtools_json_route) {
                    if (strings.eqlComptime(user_route.route.path, chrome_devtools_route) or strings.hasPrefix(user_route.route.path, "/.well-known/")) {
                        should_add_chrome_devtools_json_route = false;
                    }
                }

''',
    '''            if (should_add_chrome_devtools_json_route) {
                app.get(chrome_devtools_route, *ThisServer, this, onChromeDevToolsJSONRequest);
            }

''',
):
    text = replace_exact(text, block, "")
path.write_text(text)


path = ROOT / "src/runtime/server/RequestContext.zig"
text = path.read_text()
text = remove_between(text, "        pub fn devServer(this: *const RequestContext)", "        pub fn memoryCost(")
text = remove_between(
    text,
    "            if (comptime debug_mode) {\n                if (req.server) |server| {\n                    if (!err.isEmptyOrUndefinedOrNull()) {",
    "            req.endStream(req.shouldCloseConnection());",
)
path.write_text(text)


path = ROOT / "src/runtime/server/AnyRequestContext.zig"
text = path.read_text()
text = remove_between(text, "pub fn devServer(self: AnyRequestContext)", "pub fn deref(")
path.write_text(text)


path = ROOT / "src/bundler/options.zig"
text = path.read_text()
text = replace_exact(text, "    /// Set when Bake is bundling. Affects module resolution.\n    framework: ?*bun.bake.Framework = null,\n\n", "")
path.write_text(text)

print("finished removing DevServer and Chrome debug residue")
