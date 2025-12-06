const std = @import("std");
const md = @import("markdown.zig");

fn changeExtension(allocator: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const old_ext = std.fs.path.extension(path);
    const cut_index = path.len - old_ext.len;
    const path_no_ext = path[0..cut_index];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ path_no_ext, new_ext });
}

pub const Generator = struct {
    in_dir_path: []const u8,
    out_dir_path: []const u8,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, in_dir: []const u8, out_dir: []const u8) Generator {
        return .{
            .in_dir_path = in_dir,
            .out_dir_path = out_dir,
            .alloc = allocator,
        };
    }

    fn applyLayout(self: *Generator, title: []const u8, body_content: []const u8) ![]u8 {
        const template =
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\    <meta charset="UTF-8">
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <title>{s}</title>
            \\</head>
            \\<body>
            \\    <div class="nav">
            \\        <a href="/index.html">Home</a> | <a href="/projects.html">Projects</a> | <a href="/links.html">Links</a>
            \\    </div>
            \\    <main>
            \\        {s}
            \\    </main>
            \\</body>
            \\</html>
        ;

        return std.fmt.allocPrint(self.alloc, template, .{ title, body_content });
    }

    fn processFile(self: *Generator, dir: std.fs.Dir, sub_path: []const u8, filename: []const u8) !void {
        const file = try dir.openFile(filename, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(file_content);

        var parser = try md.Parser.init(self.alloc, file_content);
        var res = try parser.parse();
        defer res.deinit(self.alloc);

        var htmlOut: std.io.Writer.Allocating = .init(self.alloc);
        try res.root.toHtml(&htmlOut.writer);

        var htmlContent = htmlOut.toArrayList();
        defer htmlContent.deinit(self.alloc);

        const title = filename[0 .. filename.len - std.fs.path.extension(filename).len];
        const full_html = try self.applyLayout(title, htmlContent.items);
        defer self.alloc.free(full_html);

        const new_filename = try changeExtension(self.alloc, filename, ".html");
        defer self.alloc.free(new_filename);

        const out_sub_path = try std.fs.path.join(self.alloc, &.{ self.out_dir_path, sub_path });
        defer self.alloc.free(out_sub_path);

        try std.fs.cwd().makePath(out_sub_path);

        var out_dir_handle = try std.fs.cwd().openDir(out_sub_path, .{});
        defer out_dir_handle.close();

        const out_file = try out_dir_handle.createFile(new_filename, .{});
        defer out_file.close();
        try out_file.writeAll(full_html);

        std.debug.print("[GEN] {s}/{s} -> {s}/{s}\n", .{ sub_path, filename, out_sub_path, new_filename });
    }

    fn walk(self: *Generator, dir_path: []const u8, relative_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try self.processFile(dir, relative_path, entry.name);
                }
            } else if (entry.kind == .directory) {
                if (std.mem.startsWith(u8, entry.name, ".")) continue;

                const new_dir_path = try std.fs.path.join(self.alloc, &.{ dir_path, entry.name });
                defer self.alloc.free(new_dir_path);

                const new_rel_path = try std.fs.path.join(self.alloc, &.{ relative_path, entry.name });
                defer self.alloc.free(new_rel_path);

                try self.walk(new_dir_path, new_rel_path);
            }
        }
    }

    pub fn generate(self: *Generator) !void {
        try std.fs.cwd().makePath(self.out_dir_path);

        std.debug.print("Starting generation from '{s}' into '{s}'...\n", .{ self.in_dir_path, self.out_dir_path });
        try self.walk(self.in_dir_path, ".");
        std.debug.print("Generation complete.\n", .{});
    }
};
