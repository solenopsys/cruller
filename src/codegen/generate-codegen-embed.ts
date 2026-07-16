import { writeIfChanged } from "../../scripts/build/fs.ts";

const output = process.argv[2];
if (!output) throw new Error("usage: generate-codegen-embed.ts <output>");

writeIfChanged(
  output,
  `pub inline fn file(comptime path: []const u8) []const u8 {\n    return @embedFile(path);\n}\n`,
);
