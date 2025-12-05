const std = @import("std");
const sgfs = @import("sgfs");
const md = @import("markdown.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        std.debug.print("Usage: program <filename>\n", .{});
        return;
    }

    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(contents);

    var p = try md.Parser.init(alloc, contents);
    var res = try p.parse();
    defer res.deinit(alloc);

    if (std.mem.eql(u8, args[2], "-dump")) {
        var out: std.io.Writer.Allocating = .init(alloc);
        try std.json.Stringify.value(res.root.document.children, .{ .whitespace = .indent_2 }, &out.writer);
        var arr = out.toArrayList();
        defer arr.deinit(alloc);

        std.debug.print("\n{s}\n", .{arr.items});
    } else if (std.mem.eql(u8, args[2], "-html")) {
        var htmlOut: std.io.Writer.Allocating = .init(alloc);
        try res.root.toHtml(&htmlOut.writer);

        var htmlContent = htmlOut.toArrayList();
        defer htmlContent.deinit(alloc);

        std.debug.print("{s}", .{htmlContent.items});
    }
}
