const std = @import("std");

pub const NodeKind = enum {
    document,
    heading,
    paragraph,
    list,
    codeBlock,
    link,
    monotext,
    text,
};

pub const Node = union(NodeKind) {
    document: struct {
        children: std.ArrayList(*Node),
    },
    heading: struct {
        level: u8,
        content: []const u8,
    },
    paragraph: []const *Node,
    list: struct {
        ordered: bool,
        items: []const *Node,
    },
    codeBlock: struct {
        code: []const u8,
    },
    link: struct {
        content: []const u8,
        address: []const u8,
    },
    monotext: []const u8,
    text: []const u8,
};

pub fn deinitNode(allocator: std.mem.Allocator, node: *Node) void {
    switch (node.*) {
        .document => |*doc| {
            for (doc.children.items) |child| {
                deinitNode(allocator, child);
                allocator.destroy(child);
            }
            doc.children.deinit(allocator);
        },
        .paragraph => |children| {
            for (children) |child| {
                deinitNode(allocator, child);
                allocator.destroy(child);
            }
            allocator.free(children);
        },
        .list => |list| {
            for (list.items) |item| {
                deinitNode(allocator, item);
                allocator.destroy(item);
            }
            allocator.free(list.items);
        },
        else => {},
    }
}

pub const ParserError = error{WrongCodeBlock};

pub const ParserResult = struct {
    root: *Node,
    metadata: std.StringHashMap([]const u8),

    pub fn deinit(self: *ParserResult, alloc: std.mem.Allocator) void {
        deinitNode(alloc, self.root);
        alloc.destroy(self.root);
        self.metadata.deinit();
    }
};

/// Parser is a very simplistic markdown parser. It currently does *NOT* handle incorrect markdown properly.
/// It excepts the markdown to be formatted correctly. This is just for a toy project and my own files that's
/// why it doesn't matter.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    loc: usize,
    content: []const u8,

    pub fn init(alloc: std.mem.Allocator, content: []const u8) !Parser {
        return Parser{
            .allocator = alloc,
            .loc = 0,
            .content = content,
        };
    }

    inline fn curr(p: *Parser) u8 {
        return p.content[p.loc];
    }

    inline fn sliceFromLoc(p: *Parser) []const u8 {
        return p.content[p.loc..];
    }

    const SliceResult = struct {
        content: []const u8,
        end: usize,
    };

    inline fn sliceUntilChar(p: *Parser, delim: u8) SliceResult {
        const slice = p.sliceFromLoc();
        const end = std.mem.indexOfScalar(u8, slice, delim) orelse slice.len;

        return .{
            .content = slice[0..end],
            .end = end,
        };
    }

    inline fn sliceUntilString(p: *Parser, needle: []const u8) SliceResult {
        const slice = p.sliceFromLoc();
        const end = std.mem.indexOf(u8, slice, needle) orelse slice.len;

        return .{
            .content = slice[0..end],
            .end = end,
        };
    }

    fn parseList(p: *Parser) !*Node {
        const node = try p.allocator.create(Node);
        errdefer p.allocator.destroy(node);

        var items = try std.ArrayList(*Node).initCapacity(p.allocator, 4);
        defer items.deinit(p.allocator);

        while (p.loc < p.content.len) {
            if (p.curr() == '-' or p.curr() == '*') {
                p.loc += 1; // skip the - or *
                if (p.curr() == ' ') {
                    p.loc += 1; // skip the space
                }

                const textBlock = try p.parseTextBlock();
                try items.append(p.allocator, textBlock);
            } else {
                break;
            }
        }

        node.* = Node{ .list = .{
            .ordered = false,
            .items = try items.toOwnedSlice(p.allocator),
        } };

        return node;
    }

    fn parseTextBlock(p: *Parser) !*Node {
        const nodes = try p.parseNodesInsideText();
        const pNode = try p.allocator.create(Node);
        errdefer p.allocator.destroy(pNode);

        pNode.* = .{ .paragraph = nodes };

        return pNode;
    }

    pub fn parse(p: *Parser) !ParserResult {
        var metadata = std.StringHashMap([]const u8).init(p.allocator);
        if (std.mem.startsWith(u8, p.sliceFromLoc(), "---")) {
            p.loc += 3; // skip opening ---
            if (p.loc < p.content.len and p.curr() == '\n') p.loc += 1;

            while (p.loc < p.content.len) {
                if (std.mem.startsWith(u8, p.sliceFromLoc(), "---")) {
                    p.loc += 3;
                    if (p.loc < p.content.len and p.curr() == '\n') p.loc += 1;
                    break;
                }

                const key = p.sliceUntilChar(':');
                p.loc += key.end;

                if (p.loc < p.content.len and p.curr() == ':') p.loc += 1;
                if (p.loc < p.content.len and p.curr() == ' ') p.loc += 1;

                const value = p.sliceUntilChar('\n');
                p.loc += value.end;

                if (p.loc < p.content.len and p.curr() == '\n') p.loc += 1;

                try metadata.put(key.content, value.content);
            }
        }

        var doclist = try std.ArrayList(*Node).initCapacity(p.allocator, 8);

        while (p.loc < p.content.len) {
            switch (p.curr()) {
                '#' => {
                    const headerNode = try p.parseHeading();
                    try doclist.append(p.allocator, headerNode);
                },
                '-', '*' => {
                    const listNode = try p.parseList();
                    try doclist.append(p.allocator, listNode);
                },
                '`' => {
                    const codeNode = try p.parseCodeNode();
                    try doclist.append(p.allocator, codeNode);
                },
                '\n' => {
                    p.loc += 1;
                },
                else => {
                    const tNode = try parseTextBlock(p);
                    try doclist.append(p.allocator, tNode);
                },
            }
        }

        const node = try p.allocator.create(Node);
        node.* = Node{ .document = .{
            .children = doclist,
        } };

        return .{
            .metadata = metadata,
            .root = node,
        };
    }

    fn parseNodesInsideText(p: *Parser) ![]*Node {
        var nodes = try std.ArrayList(*Node).initCapacity(p.allocator, 1);
        defer nodes.deinit(p.allocator);

        while (p.loc < p.content.len) {
            switch (p.curr()) {
                '[' => {
                    // this doesnt handle invalid links
                    // link parsing later
                    p.loc += 1; // skip the [
                    const linkName = p.sliceUntilChar(']');
                    p.loc += linkName.end + 2; // skip the ] and (
                    //
                    const link = p.sliceUntilChar(')');
                    p.loc += link.end + 1;

                    const node = try p.allocator.create(Node);
                    errdefer p.allocator.destroy(node);

                    node.* = .{ .link = .{
                        .content = linkName.content,
                        .address = link.content,
                    } };

                    try nodes.append(p.allocator, node);
                },
                '`' => {
                    // this is a monospace block
                    p.loc += 1; // skip opening `
                    const res = p.sliceUntilChar('`');

                    const node = try p.allocator.create(Node);
                    errdefer p.allocator.destroy(node);
                    node.* = .{ .monotext = res.content };
                    try nodes.append(p.allocator, node);

                    p.loc += res.end;
                    if (p.loc < p.content.len and p.curr() == '`') {
                        p.loc += 1; // skip closing `
                    }
                },
                '\n' => {
                    p.loc += 1;
                    return nodes.toOwnedSlice(p.allocator);
                },
                else => {
                    const start = p.loc;

                    while (p.loc < p.content.len and (p.curr() != '\n' and p.curr() != '`' and p.curr() != '[')) {
                        p.loc += 1;
                    }

                    const node = try p.allocator.create(Node);
                    errdefer p.allocator.destroy(node);
                    node.* = .{ .text = p.content[start..p.loc] };
                    try nodes.append(p.allocator, node);

                    if (p.loc < p.content.len and p.curr() == '\n') {
                        p.loc += 1;
                        return nodes.toOwnedSlice(p.allocator);
                    }
                },
            }
        }

        return nodes.toOwnedSlice(p.allocator);
    }

    fn parseCodeNode(p: *Parser) !*Node {
        const node = try p.allocator.create(Node);
        errdefer p.allocator.destroy(node);

        if (p.loc < p.content.len - 3) {
            const end = p.loc + 2;
            while (p.loc < end) {
                if (p.content[p.loc] != '`') {
                    return ParserError.WrongCodeBlock;
                }
                p.loc += 1;
            }

            p.loc += 1;
            if (p.content[p.loc] != '\n') {
                return ParserError.WrongCodeBlock;
            }
            p.loc += 1;
        }

        const res = p.sliceUntilString("```");
        if (res.content.len == 0 or res.content[res.content.len - 1] != '\n') {
            return ParserError.WrongCodeBlock;
        }

        const content = res.content[0 .. res.content.len - 1];
        p.loc += res.end + "```".len; // skip content and closing ```

        node.* = Node{ .codeBlock = .{
            .code = content,
        } };
        return node;
    }

    fn parseBlockContent(p: *Parser) !*Node {
        const node = try p.allocator.create(Node);
        errdefer p.allocator.destroy(node);

        // determine the type of the content;
        switch (p.curr()) {
            else => {
                const slice = p.content[p.loc..];
                const end = std.mem.indexOfScalar(u8, slice, '\n') orelse slice.len;
                const content = slice[0..end];
                p.loc += end;

                if (p.loc < p.content.len and p.curr() == '\n') {
                    p.loc += 1;
                }

                node.* = Node{ .paragraph = content };
            },
        }

        return node;
    }

    fn parseHeading(p: *Parser) !*Node {
        // measure the level
        var level: u8 = 0;
        while (p.curr() == '#') {
            level += 1;
            p.loc += 1;
        }

        if (p.curr() == ' ') {
            p.loc += 1;
        }

        const res = p.sliceUntilChar('\n');
        const content = res.content;

        p.loc += res.end;
        if (p.loc < p.content.len and p.curr() == '\n') {
            p.loc += 1;
        }

        const node = try p.allocator.create(Node);
        node.* = Node{ .heading = .{
            .level = level,
            .content = content,
        } };

        return node;
    }
};

const testing = std.testing;
test "parse heading" {
    const content = "### Hello world\n";
    const a = testing.allocator;

    var p = try Parser.init(a, content);

    var res = try p.parse();
    defer res.deinit(a);

    const root = res.root;

    try testing.expect(root.* == .document);

    const doc = root.document;
    try testing.expect(doc.children.items.len == 1);

    const h = doc.children.items[0];
    try testing.expect(h.* == .heading);
    try testing.expectEqual(@as(u8, 3), h.heading.level);
    try testing.expect(std.mem.eql(u8, h.heading.content, "Hello world"));
}

test "parse paragraph with heading" {
    const content = "### Hello world\nThis is a paragraph\n";
    const a = testing.allocator;

    var p = try Parser.init(a, content);

    var res = try p.parse();
    defer res.deinit(a);

    const root = res.root;

    try testing.expect(root.* == .document);

    const doc = root.document;
    try testing.expect(doc.children.items.len == 2);

    const h = doc.children.items[0];
    try testing.expect(h.* == .heading);
    try testing.expectEqual(@as(u8, 3), h.heading.level);
    try testing.expect(std.mem.eql(u8, h.heading.content, "Hello world"));

    const pa = doc.children.items[1];
    try testing.expect(pa.* == .paragraph);
    try testing.expect(std.mem.eql(u8, pa.paragraph[0].text, "This is a paragraph"));
}

test "code block" {
    const content = "```\nprint hello world heh\n```";
    const a = testing.allocator;

    var p = try Parser.init(a, content);

    var res = try p.parse();
    defer res.deinit(a);

    const root = res.root;

    try testing.expect(root.* == .document);

    const doc = root.document;
    try testing.expect(doc.children.items.len == 1);

    const cb = doc.children.items[0];
    try testing.expect(cb.* == .codeBlock);
    try testing.expect(std.mem.eql(u8, cb.codeBlock.code, "print hello world heh"));
}

test "parse link" {
    const content = "This is a [link](https://example.com) in a paragraph\n";
    const a = testing.allocator;
    var p = try Parser.init(a, content);

    var res = try p.parse();
    defer res.deinit(a);
    const root = res.root;

    try testing.expect(root.* == .document);

    const doc = root.document;
    try testing.expect(doc.children.items.len == 1);

    const pa = doc.children.items[0];
    try testing.expect(pa.* == .paragraph);
    try testing.expect(pa.paragraph.len == 3); // the text, link, text

    const text1 = pa.paragraph[0];
    try testing.expect(text1.* == .text);
    try testing.expect(std.mem.eql(u8, text1.text, "This is a "));

    const link = pa.paragraph[1];
    try testing.expect(link.* == .link);
    try testing.expect(std.mem.eql(u8, link.link.content, "link"));
    try testing.expect(std.mem.eql(u8, link.link.address, "https://example.com"));

    const text2 = pa.paragraph[2];
    try testing.expect(text2.* == .text);
    try testing.expect(std.mem.eql(u8, text2.text, " in a paragraph"));
}

test "parse list" {
    const content = "- Item one\n- Item two\n- Item three\n";
    const a = testing.allocator;

    var p = try Parser.init(a, content);

    var res = try p.parse();
    defer res.deinit(a);

    const root = res.root;

    try testing.expect(root.* == .document);

    const doc = root.document;
    try testing.expect(doc.children.items.len == 1);

    const list = doc.children.items[0];
    try testing.expect(list.* == .list);
    try testing.expect(!list.list.ordered);
    try testing.expect(list.list.items.len == 3);

    const item1 = list.list.items[0];
    try testing.expect(item1.* == .paragraph);
    try testing.expect(std.mem.eql(u8, item1.paragraph[0].text, "Item one"));
    const item2 = list.list.items[1];
    try testing.expect(item2.* == .paragraph);
    try testing.expect(std.mem.eql(u8, item2.paragraph[0].text, "Item two"));
    const item3 = list.list.items[2];
    try testing.expect(item3.* == .paragraph);
    try testing.expect(std.mem.eql(u8, item3.paragraph[0].text, "Item three"));
}
