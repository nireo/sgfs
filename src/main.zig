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
    var res = try p.parse();
    defer res.deinit(alloc);

    var out: std.io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(res.root.document.children, .{ .whitespace = .indent_2 }, &out.writer);
    var arr = out.toArrayList();
    defer arr.deinit(alloc);

    std.debug.print("File contents:\n{s}\n", .{arr.items});

    std.debug.print("got metadata:\n", .{});
    var it = res.metadata.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}
