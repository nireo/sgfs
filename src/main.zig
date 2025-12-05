const std = @import("std");
const sgfs = @import("sgfs");
const md = @import("markdown.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: program <filename>\n", .{});
        return;
    }

    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(contents);

    std.debug.print("File contents:\n{s}\n", .{contents});

    var p = try md.Parser.init(alloc, contents);
    const root = try p.parse();

    var out: std.io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(root.document.children, .{ .whitespace = .indent_2 }, &out.writer);
    var arr = out.toArrayList();
    defer arr.deinit(alloc);

    std.debug.print("File contents:\n{s}\n", .{arr.items});

    md.deinitNode(alloc, root);
    alloc.destroy(root);
}
