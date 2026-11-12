//! Regular expressions natively (M3.3, D-105): Java's common syntax, parsed and compiled
//! once into a program that a backtracking matcher runs over a string's code points.
//! skein.core's re-pattern, re-find, re-seq, re-matches and re-groups use these.
//!
//! The matcher keeps its backtracking stack on the C heap, not the machine stack, so a
//! long string or a deep pattern can't overflow a fiber's stack. A loop whose body can
//! match nothing stops once an iteration matched nothing. As Java's defaults, \d \w \s
//! are ASCII and (?i) folds ASCII letters.
//!
//! A pattern is a heap object, [source (string), program handle (fixnum)]; programs are
//! kept outside the heap, compiled once for each source and never freed.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const print = @import("print.zig");
const string = @import("string.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

// ---------------------------------------------------------------------------------------
// Programs

const Op = enum(u8) {
    char, // a: code point; fold
    any, // a: 1 if . matches line terminators too
    class, // a: class index; fold
    split, // try a, then b
    jmp, // a
    save, // a: register
    bol, // ^: a 1 in multiline mode
    eol, // $: a 1 in multiline mode
    begin_text, // \A
    end_text, // \z
    end_text_nl, // \Z
    word_boundary, // \b; a 1 for \B
    backref, // a: group; fold
    look, // a: the pc after its look_end; b 1 if negative
    look_end,
    mark, // a: register: the position a loop iteration starts at
    progress, // a: register; b: the loop's exit: an iteration that didn't move ends it
    match,
};

const Inst = struct { op: Op, a: u32 = 0, b: u32 = 0, fold: bool = false };

const Range = struct { lo: u21, hi: u21 };

/// A class: its items match if any does, unless the class is negated. An item is ranges,
/// or ranges negated (\D inside [...]).
const Class = struct {
    items: std.ArrayList(Item) = .empty,
    negate: bool = false,

    const Item = struct { ranges: std.ArrayList(Range) = .empty, negate: bool = false };

    fn matches(c: *const Class, cp: u21, fold: bool) bool {
        var found = c.hit(cp);
        if (!found and fold) {
            if (cp < 128 and std.ascii.isAlphabetic(@intCast(cp))) {
                const b: u8 = @intCast(cp);
                found = c.hit(std.ascii.toLower(b)) or c.hit(std.ascii.toUpper(b));
            }
        }
        return found != c.negate;
    }

    fn hit(c: *const Class, cp: u21) bool {
        for (c.items.items) |item| {
            var in = false;
            for (item.ranges.items) |r| {
                if (cp >= r.lo and cp <= r.hi) {
                    in = true;
                    break;
                }
            }
            if (in != item.negate) return true;
        }
        return false;
    }
};

const Program = struct {
    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(Class) = .empty,
    groups: u32 = 0,
    /// Registers: two per group (group 0 is the whole match), then one per loop mark.
    registers: u32 = 0,
    /// Named groups: name -> group.
    names: std.StringArrayHashMapUnmanaged(u32) = .empty,
};

// ---------------------------------------------------------------------------------------
// Parsing: Java's common syntax into a tree

const Node = union(enum) {
    empty,
    char: struct { cp: u21, fold: bool },
    any: bool, // dotall
    class: struct { index: u32, fold: bool },
    assert: struct { op: Op, a: u32 = 0 },
    group: struct { index: ?u32, node: *Node },
    concat: []*Node,
    alt: []*Node,
    repeat: struct { node: *Node, min: u32, max: ?u32, greedy: bool },
    backref: struct { group: u32, fold: bool },
    look: struct { node: *Node, negative: bool },
};

const Flags = struct { i: bool = false, m: bool = false, s: bool = false, x: bool = false };

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    prog: *Program,
    arena: std.mem.Allocator,
    flags: Flags = .{},
    message: []const u8 = "",
    /// Back references by name, resolved once every group is known.
    pending_names: std.ArrayList(struct { node: *Node, name: []const u8 }) = .empty,

    fn fail(p: *Parser, message: []const u8) error{Bad} {
        p.message = message;
        return error.Bad;
    }

    fn atEnd(p: *Parser) bool {
        return p.i >= p.text.len;
    }

    fn peek(p: *Parser) u21 {
        const n = std.unicode.utf8ByteSequenceLength(p.text[p.i]) catch return p.text[p.i];
        return std.unicode.utf8Decode(p.text[p.i..@min(p.i + n, p.text.len)]) catch p.text[p.i];
    }

    fn next(p: *Parser) u21 {
        const cp = p.peek();
        p.i += std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        return cp;
    }

    fn node(p: *Parser, n: Node) *Node {
        const x = p.arena.create(Node) catch rt.fatal("out of memory", .{});
        x.* = n;
        return x;
    }

    /// In (?x) mode, whitespace and # comments between tokens.
    fn skipExtended(p: *Parser) void {
        if (!p.flags.x) return;
        while (!p.atEnd()) {
            const c = p.text[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 12) {
                p.i += 1;
            } else if (c == '#') {
                while (!p.atEnd() and p.text[p.i] != '\n') p.i += 1;
            } else return;
        }
    }

    fn parseAlt(p: *Parser) error{Bad}!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        branches.append(p.arena, try p.parseConcat()) catch rt.fatal("out of memory", .{});
        while (!p.atEnd() and p.text[p.i] == '|') {
            p.i += 1;
            branches.append(p.arena, try p.parseConcat()) catch rt.fatal("out of memory", .{});
        }
        if (branches.items.len == 1) return branches.items[0];
        return p.node(.{ .alt = branches.items });
    }

    fn parseConcat(p: *Parser) error{Bad}!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (true) {
            p.skipExtended();
            if (p.atEnd() or p.text[p.i] == '|' or p.text[p.i] == ')') break;
            if (std.mem.startsWith(u8, p.text[p.i..], "\\Q")) {
                // Quoted to \E (or the end): characters as they are, as if escaped, so a
                // quantifier after it takes the last one, as Java's.
                p.i += 2;
                const end = std.mem.indexOfPos(u8, p.text, p.i, "\\E") orelse p.text.len;
                while (p.i < end) {
                    const ch = p.charNode(p.next());
                    if (p.i == end) {
                        p.i = @min(end + 2, p.text.len);
                        items.append(p.arena, try p.parseRepeat(ch)) catch rt.fatal("out of memory", .{});
                        break;
                    }
                    items.append(p.arena, ch) catch rt.fatal("out of memory", .{});
                } else p.i = @min(end + 2, p.text.len);
                continue;
            }
            const atom = (try p.parseAtom()) orelse continue;
            items.append(p.arena, try p.parseRepeat(atom)) catch rt.fatal("out of memory", .{});
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .concat = items.items });
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        while (!p.atEnd() and std.ascii.isDigit(p.text[p.i])) p.i += 1;
        if (p.i == start) return null;
        return std.fmt.parseInt(u32, p.text[start..p.i], 10) catch std.math.maxInt(u32);
    }

    fn parseRepeat(p: *Parser, atom: *Node) error{Bad}!*Node {
        var n = atom;
        var repeated = false;
        while (true) {
            p.skipExtended();
            if (p.atEnd()) return n;
            if (repeated) switch (p.text[p.i]) {
                // A quantifier on a quantifier: Java's dangling meta character.
                '*', '+', '?', '{' => return p.fail("a quantifier can't follow a quantifier"),
                else => return n,
            };
            const c = p.text[p.i];
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => p.i += 1,
                '+' => {
                    p.i += 1;
                    min = 1;
                },
                '?' => {
                    p.i += 1;
                    max = 1;
                },
                '{' => {
                    const save = p.i;
                    p.i += 1;
                    const lo = p.number() orelse {
                        // Not a quantifier: a literal {, as Java takes it nowhere, but a
                        // clearer error than a dangling one.
                        p.i = save;
                        return p.fail("a { must start a quantifier, as {2} or {1,3}");
                    };
                    min = lo;
                    max = lo;
                    if (!p.atEnd() and p.text[p.i] == ',') {
                        p.i += 1;
                        max = p.number();
                    }
                    if (p.atEnd() or p.text[p.i] != '}') return p.fail("a quantifier needs its }");
                    p.i += 1;
                    if (max != null and max.? < min) return p.fail("a quantifier's maximum is below its minimum");
                    if (min > 1000 or (max != null and max.? > 1000)) return p.fail("a quantifier over 1000 isn't supported");
                },
                else => return n,
            }
            var greedy = true;
            if (!p.atEnd() and p.text[p.i] == '?') {
                p.i += 1;
                greedy = false;
            } else if (!p.atEnd() and p.text[p.i] == '+') {
                return p.fail("possessive quantifiers aren't supported");
            }
            switch (n.*) {
                .empty, .assert => return p.fail("nothing to repeat"),
                else => {},
            }
            n = p.node(.{ .repeat = .{ .node = n, .min = min, .max = max, .greedy = greedy } });
            repeated = true;
        }
    }

    fn charNode(p: *Parser, cp: u21) *Node {
        return p.node(.{ .char = .{ .cp = cp, .fold = p.flags.i } });
    }

    /// An atom, or null for something that matches nothing to repeat ((?i) alone).
    fn parseAtom(p: *Parser) error{Bad}!?*Node {
        const c = p.next();
        switch (c) {
            '.' => return p.node(.{ .any = p.flags.s }),
            '^' => return p.node(.{ .assert = .{ .op = .bol, .a = @intFromBool(p.flags.m) } }),
            '$' => return p.node(.{ .assert = .{ .op = .eol, .a = @intFromBool(p.flags.m) } }),
            '[' => return try p.parseClass(),
            '(' => return try p.parseGroup(),
            '\\' => return try p.parseEscape(),
            '*', '+', '?' => return p.fail("nothing to repeat"),
            '{' => return p.fail("a { must start a quantifier, as {2} or {1,3}"),
            ')' => return p.fail("an unmatched )"),
            else => return p.charNode(c),
        }
    }

    fn parseGroup(p: *Parser) error{Bad}!?*Node {
        const saved = p.flags;
        if (!p.atEnd() and p.text[p.i] == '?') {
            p.i += 1;
            if (p.atEnd()) return p.fail("an unfinished group");
            const k = p.text[p.i];
            if (k == ':' or k == '=' or k == '!') {
                p.i += 1;
                const inner = try p.parseAlt();
                try p.closeGroup();
                p.flags = saved;
                if (k == ':') return p.node(.{ .group = .{ .index = null, .node = inner } });
                return p.node(.{ .look = .{ .node = inner, .negative = k == '!' } });
            }
            if (k == '<') {
                p.i += 1;
                if (!p.atEnd() and (p.text[p.i] == '=' or p.text[p.i] == '!')) return p.fail("lookbehind isn't supported");
                const start = p.i;
                while (!p.atEnd() and std.ascii.isAlphanumeric(p.text[p.i])) p.i += 1;
                if (p.i == start or p.atEnd() or p.text[p.i] != '>' or !std.ascii.isAlphabetic(p.text[start]))
                    return p.fail("a group's name is letters and digits, starting with a letter: (?<name>...)");
                const name = p.text[start..p.i];
                p.i += 1;
                p.prog.groups += 1;
                const index = p.prog.groups;
                if (p.prog.names.contains(name)) return p.fail("two groups have the same name");
                p.prog.names.put(alloc, alloc.dupe(u8, name) catch rt.fatal("out of memory", .{}), index) catch rt.fatal("out of memory", .{});
                const inner = try p.parseAlt();
                try p.closeGroup();
                p.flags = saved;
                return p.node(.{ .group = .{ .index = index, .node = inner } });
            }
            // Flags: (?imsx-imsx) for the rest of the enclosing group, or (?i:...).
            var on = true;
            var flags = p.flags;
            while (!p.atEnd()) {
                const f = p.text[p.i];
                p.i += 1;
                switch (f) {
                    'i' => flags.i = on,
                    'm' => flags.m = on,
                    's' => flags.s = on,
                    'x' => flags.x = on,
                    'd', 'u', 'U' => {},
                    '-' => on = false,
                    ')' => {
                        p.flags = flags;
                        return null;
                    },
                    ':' => {
                        p.flags = flags;
                        const inner = try p.parseAlt();
                        try p.closeGroup();
                        p.flags = saved;
                        return p.node(.{ .group = .{ .index = null, .node = inner } });
                    },
                    else => return p.fail("an unknown group or flag"),
                }
            }
            return p.fail("an unfinished group");
        }
        p.prog.groups += 1;
        const index = p.prog.groups;
        const inner = try p.parseAlt();
        try p.closeGroup();
        p.flags = saved;
        return p.node(.{ .group = .{ .index = index, .node = inner } });
    }

    fn closeGroup(p: *Parser) error{Bad}!void {
        if (p.atEnd() or p.text[p.i] != ')') return p.fail("a group without its )");
        p.i += 1;
    }

    fn newClass(p: *Parser) u32 {
        p.prog.classes.append(alloc, .{}) catch rt.fatal("out of memory", .{});
        return @intCast(p.prog.classes.items.len - 1);
    }

    fn addRanges(cls: *Class, ranges: []const Range, negate: bool) void {
        var item: Class.Item = .{ .negate = negate };
        item.ranges.appendSlice(alloc, ranges) catch rt.fatal("out of memory", .{});
        cls.items.append(alloc, item) catch rt.fatal("out of memory", .{});
    }

    const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
    const word_ranges = [_]Range{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '0', .hi = '9' }, .{ .lo = '_', .hi = '_' } };
    const space_ranges = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = '\t', .hi = '\r' } };

    /// \d \w \s and their negations, as ranges and whether negated; null for others.
    fn shorthand(c: u21) ?struct { []const Range, bool } {
        return switch (c) {
            'd' => .{ &digit_ranges, false },
            'D' => .{ &digit_ranges, true },
            'w' => .{ &word_ranges, false },
            'W' => .{ &word_ranges, true },
            's' => .{ &space_ranges, false },
            'S' => .{ &space_ranges, true },
            else => null,
        };
    }

    /// The character an escape stands for (after its \), or null if it isn't one.
    fn escapedChar(p: *Parser, c: u21) error{Bad}!?u21 {
        return switch (c) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            'f' => 12,
            'a' => 7,
            'e' => 27,
            '0' => blk: {
                const start = p.i;
                while (!p.atEnd() and p.i - start < 3 and p.text[p.i] >= '0' and p.text[p.i] <= '7') p.i += 1;
                if (p.i == start) return p.fail("\\0 needs octal digits");
                break :blk std.fmt.parseInt(u21, p.text[start..p.i], 8) catch return p.fail("a bad octal escape");
            },
            'x' => blk: {
                if (!p.atEnd() and p.text[p.i] == '{') {
                    const close = std.mem.indexOfScalarPos(u8, p.text, p.i, '}') orelse return p.fail("\\x{ needs its }");
                    const v = std.fmt.parseInt(u21, p.text[p.i + 1 .. close], 16) catch return p.fail("a bad \\x{...} escape");
                    p.i = close + 1;
                    break :blk v;
                }
                if (p.i + 2 > p.text.len) return p.fail("\\x needs two hex digits");
                const v = std.fmt.parseInt(u21, p.text[p.i .. p.i + 2], 16) catch return p.fail("\\x needs two hex digits");
                p.i += 2;
                break :blk v;
            },
            'u' => blk: {
                if (p.i + 4 > p.text.len) return p.fail("\\u needs four hex digits");
                const v = std.fmt.parseInt(u21, p.text[p.i .. p.i + 4], 16) catch return p.fail("\\u needs four hex digits");
                p.i += 4;
                break :blk v;
            },
            else => if (c < 128 and std.ascii.isAlphanumeric(@intCast(c))) null else c,
        };
    }

    fn parseEscape(p: *Parser) error{Bad}!?*Node {
        if (p.atEnd()) return p.fail("a \\ at the end of the pattern");
        const c = p.next();
        if (shorthand(c)) |s| {
            const index = p.newClass();
            addRanges(&p.prog.classes.items[index], s[0], s[1]);
            return p.node(.{ .class = .{ .index = index, .fold = false } });
        }
        switch (c) {
            'b' => return p.node(.{ .assert = .{ .op = .word_boundary } }),
            'B' => return p.node(.{ .assert = .{ .op = .word_boundary, .a = 1 } }),
            'A' => return p.node(.{ .assert = .{ .op = .begin_text } }),
            'z' => return p.node(.{ .assert = .{ .op = .end_text } }),
            'Z' => return p.node(.{ .assert = .{ .op = .end_text_nl } }),
            'k' => {
                if (p.atEnd() or p.text[p.i] != '<') return p.fail("\\k needs a name: \\k<name>");
                const close = std.mem.indexOfScalarPos(u8, p.text, p.i, '>') orelse return p.fail("\\k<name> needs its >");
                const name = p.text[p.i + 1 .. close];
                p.i = close + 1;
                const n = p.node(.{ .backref = .{ .group = 0, .fold = p.flags.i } });
                p.pending_names.append(p.arena, .{ .node = n, .name = name }) catch rt.fatal("out of memory", .{});
                return n;
            },
            '1'...'9' => {
                p.i -= 1;
                const n = p.number().?;
                return p.node(.{ .backref = .{ .group = n, .fold = p.flags.i } });
            },
            else => {},
        }
        const cp = (try p.escapedChar(c)) orelse return p.fail("an unknown escape");
        return p.charNode(cp);
    }

    /// One character of a class (an escape resolved), or a shorthand class.
    const ClassAtom = union(enum) { char: u21, short: struct { []const Range, bool } };

    fn classAtom(p: *Parser) error{Bad}!ClassAtom {
        const c = p.next();
        if (c != '\\') return .{ .char = c };
        if (p.atEnd()) return p.fail("a \\ at the end of the pattern");
        const e = p.next();
        if (shorthand(e)) |s| return .{ .short = s };
        if (e == 'b') return .{ .char = 8 };
        return .{ .char = (try p.escapedChar(e)) orelse return p.fail("an unknown escape in a class") };
    }

    fn parseClass(p: *Parser) error{Bad}!*Node {
        const index = p.newClass();
        var ranges: std.ArrayList(Range) = .empty;
        if (!p.atEnd() and p.text[p.i] == '^') {
            p.i += 1;
            p.prog.classes.items[index].negate = true;
        }
        var first = true;
        while (true) {
            if (p.atEnd()) return p.fail("a class without its ]");
            if (p.text[p.i] == ']' and !first) {
                p.i += 1;
                break;
            }
            if (p.text[p.i] == '[') return p.fail("classes inside classes aren't supported");
            if (p.i + 1 < p.text.len and p.text[p.i] == '&' and p.text[p.i + 1] == '&') return p.fail("class intersections (&&) aren't supported");
            first = false;
            const a = try p.classAtom();
            switch (a) {
                .short => |s| addRanges(&p.prog.classes.items[index], s[0], s[1]),
                .char => |lo| {
                    // A range, unless the - is last.
                    if (p.i + 1 < p.text.len and p.text[p.i] == '-' and p.text[p.i + 1] != ']') {
                        p.i += 1;
                        const b = try p.classAtom();
                        const hi = switch (b) {
                            .char => |h| h,
                            .short => return p.fail("a range can't end in a class like \\d"),
                        };
                        if (hi < lo) return p.fail("a range's end is below its start");
                        ranges.append(alloc, .{ .lo = lo, .hi = hi }) catch rt.fatal("out of memory", .{});
                    } else {
                        ranges.append(alloc, .{ .lo = lo, .hi = lo }) catch rt.fatal("out of memory", .{});
                    }
                },
            }
        }
        addRanges(&p.prog.classes.items[index], ranges.items, false);
        ranges.deinit(alloc);
        return p.node(.{ .class = .{ .index = index, .fold = p.flags.i } });
    }
};

// ---------------------------------------------------------------------------------------
// Compiling the tree into a program

const max_insts = 200_000;

const Compiler = struct {
    prog: *Program,
    message: []const u8 = "",

    fn emit(c: *Compiler, inst: Inst) error{Bad}!u32 {
        if (c.prog.insts.items.len >= max_insts) {
            c.message = "the pattern is too large";
            return error.Bad;
        }
        c.prog.insts.append(alloc, inst) catch rt.fatal("out of memory", .{});
        return @intCast(c.prog.insts.items.len - 1);
    }

    fn here(c: *Compiler) u32 {
        return @intCast(c.prog.insts.items.len);
    }

    fn register(c: *Compiler) u32 {
        c.prog.registers += 1;
        return c.prog.registers - 1;
    }

    fn compile(c: *Compiler, n: *const Node) error{Bad}!void {
        switch (n.*) {
            .empty => {},
            .char => |x| _ = try c.emit(.{ .op = .char, .a = x.cp, .fold = x.fold }),
            .any => |dotall| _ = try c.emit(.{ .op = .any, .a = @intFromBool(dotall) }),
            .class => |x| _ = try c.emit(.{ .op = .class, .a = x.index, .fold = x.fold }),
            .assert => |x| _ = try c.emit(.{ .op = x.op, .a = x.a }),
            .backref => |x| _ = try c.emit(.{ .op = .backref, .a = x.group, .fold = x.fold }),
            .group => |g| {
                if (g.index) |i| _ = try c.emit(.{ .op = .save, .a = 2 * i });
                try c.compile(g.node);
                if (g.index) |i| _ = try c.emit(.{ .op = .save, .a = 2 * i + 1 });
            },
            .concat => |items| for (items) |x| try c.compile(x),
            .alt => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                defer jumps.deinit(alloc);
                for (branches, 0..) |b, k| {
                    if (k + 1 < branches.len) {
                        const split = try c.emit(.{ .op = .split });
                        c.prog.insts.items[split].a = c.here();
                        try c.compile(b);
                        jumps.append(alloc, try c.emit(.{ .op = .jmp })) catch rt.fatal("out of memory", .{});
                        c.prog.insts.items[split].b = c.here();
                    } else {
                        try c.compile(b);
                    }
                }
                for (jumps.items) |j| c.prog.insts.items[j].a = c.here();
            },
            .look => |l| {
                const look = try c.emit(.{ .op = .look, .b = @intFromBool(l.negative) });
                try c.compile(l.node);
                _ = try c.emit(.{ .op = .look_end });
                c.prog.insts.items[look].a = c.here();
            },
            .repeat => |r| {
                for (0..r.min) |_| try c.compile(r.node);
                if (r.max) |max| {
                    // Optional copies, each inside the one before: x{1,3} is x(x(x)?)?.
                    var exits: std.ArrayList(u32) = .empty;
                    defer exits.deinit(alloc);
                    for (r.min..max) |_| {
                        const split = try c.emit(.{ .op = .split });
                        exits.append(alloc, split) catch rt.fatal("out of memory", .{});
                        const body = c.here();
                        try c.compile(r.node);
                        if (r.greedy) c.prog.insts.items[split].a = body else c.prog.insts.items[split].b = body;
                    }
                    for (exits.items) |s| {
                        if (r.greedy) c.prog.insts.items[s].b = c.here() else c.prog.insts.items[s].a = c.here();
                    }
                } else {
                    // A loop; one whose body can match nothing checks that it moved.
                    const nullable = canBeEmpty(r.node);
                    const reg: u32 = if (nullable) c.register() else 0;
                    const top = try c.emit(.{ .op = .split });
                    const body = c.here();
                    if (nullable) _ = try c.emit(.{ .op = .mark, .a = reg });
                    try c.compile(r.node);
                    const check: ?u32 = if (nullable) try c.emit(.{ .op = .progress, .a = reg }) else null;
                    _ = try c.emit(.{ .op = .jmp, .a = top });
                    const exit = c.here();
                    if (check) |k| c.prog.insts.items[k].b = exit;
                    c.prog.insts.items[top].a = if (r.greedy) body else exit;
                    c.prog.insts.items[top].b = if (r.greedy) exit else body;
                }
            },
        }
    }
};

fn canBeEmpty(n: *const Node) bool {
    return switch (n.*) {
        .empty, .assert, .look, .backref => true,
        .char, .any, .class => false,
        .group => |g| canBeEmpty(g.node),
        .concat => |items| for (items) |x| {
            if (!canBeEmpty(x)) break false;
        } else true,
        .alt => |branches| for (branches) |x| {
            if (canBeEmpty(x)) break true;
        } else false,
        .repeat => |r| r.min == 0 or canBeEmpty(r.node),
    };
}

const CompileError = struct { message: []const u8 = "", at: usize = 0 };

/// Compile `text`: the program, or an error message and where.
fn compileText(text: []const u8, err: *CompileError) ?*Program {
    const prog = alloc.create(Program) catch rt.fatal("out of memory", .{});
    prog.* = .{};
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p: Parser = .{ .text = text, .prog = prog, .arena = arena.allocator() };
    const tree = p.parseAlt() catch {
        err.* = .{ .message = p.message, .at = p.i };
        return null;
    };
    if (!p.atEnd()) {
        err.* = .{ .message = "an unmatched )", .at = p.i };
        return null;
    }
    for (p.pending_names.items) |pending| {
        const g = prog.names.get(pending.name) orelse {
            err.* = .{ .message = "\\k<name> names no group", .at = text.len };
            return null;
        };
        pending.node.backref.group = g;
    }
    // Back references to groups that don't exist are errors, as Java's.
    prog.registers = 2 * (prog.groups + 1);
    var c: Compiler = .{ .prog = prog };
    c.compile(tree) catch {
        err.* = .{ .message = c.message, .at = text.len };
        return null;
    };
    _ = c.emit(.{ .op = .match }) catch {
        err.* = .{ .message = c.message, .at = text.len };
        return null;
    };
    for (prog.insts.items) |inst| {
        if (inst.op == .backref and inst.a > prog.groups) {
            err.* = .{ .message = "a back reference to a group that doesn't exist", .at = text.len };
            return null;
        }
    }
    return prog;
}

// ---------------------------------------------------------------------------------------
// Matching

const Entry = struct {
    kind: enum { branch, restore },
    /// branch: the pc; restore: the register.
    a: u32,
    /// branch: the position; restore: the register's old value.
    b: usize,
};

const none = std.math.maxInt(usize);

const Matcher = struct {
    prog: *const Program,
    input: []const u8,
    regs: []usize,
    stack: std.ArrayList(Entry) = .empty,
    /// re-matches: the match must end at the end of the input.
    full: bool,

    fn decode(m: *const Matcher, pos: usize) ?struct { u21, usize } {
        if (pos >= m.input.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(m.input[pos]) catch return .{ m.input[pos], 1 };
        const end = @min(pos + n, m.input.len);
        const cp = std.unicode.utf8Decode(m.input[pos..end]) catch return .{ m.input[pos], 1 };
        return .{ cp, end - pos };
    }

    fn before(m: *const Matcher, pos: usize) ?u21 {
        if (pos == 0) return null;
        var i = pos - 1;
        while (i > 0 and m.input[i] & 0xC0 == 0x80) i -= 1;
        return (m.decode(i) orelse return null)[0];
    }

    fn isWord(cp: ?u21) bool {
        const c = cp orelse return false;
        return c < 128 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '_');
    }

    fn isLineEnd(c: u21) bool {
        return c == '\n' or c == '\r' or c == 0x85 or c == 0x2028 or c == 0x2029;
    }

    fn sameChar(a: u21, b: u21, fold: bool) bool {
        if (a == b) return true;
        if (!fold or a >= 128 or b >= 128) return false;
        return std.ascii.toLower(@intCast(a)) == std.ascii.toLower(@intCast(b));
    }

    fn setReg(m: *Matcher, r: u32, v: usize) void {
        m.stack.append(alloc, .{ .kind = .restore, .a = r, .b = m.regs[r] }) catch rt.fatal("out of memory", .{});
        m.regs[r] = v;
    }

    /// Run from pc at pos until match (or a lookahead's end): its end position, or null.
    fn run(m: *Matcher, pc0: u32, pos0: usize) ?usize {
        const base = m.stack.items.len;
        var pc = pc0;
        var pos = pos0;
        while (true) {
            const inst = m.prog.insts.items[pc];
            const ok: bool = switch (inst.op) {
                .char => if (m.decode(pos)) |d| ok: {
                    if (!sameChar(d[0], @intCast(inst.a), inst.fold)) break :ok false;
                    pos += d[1];
                    break :ok true;
                } else false,
                .any => if (m.decode(pos)) |d| ok: {
                    if (inst.a == 0 and isLineEnd(d[0])) break :ok false;
                    pos += d[1];
                    break :ok true;
                } else false,
                .class => if (m.decode(pos)) |d| ok: {
                    if (!m.prog.classes.items[inst.a].matches(d[0], inst.fold)) break :ok false;
                    pos += d[1];
                    break :ok true;
                } else false,
                .split => {
                    m.stack.append(alloc, .{ .kind = .branch, .a = inst.b, .b = pos }) catch rt.fatal("out of memory", .{});
                    pc = inst.a;
                    continue;
                },
                .jmp => {
                    pc = inst.a;
                    continue;
                },
                .save, .mark => blk: {
                    m.setReg(inst.a, pos);
                    break :blk true;
                },
                .progress => {
                    // An iteration that matched nothing is the last: the loop ends here,
                    // keeping what it captured, as Java's and Python's do.
                    pc = if (pos == m.regs[inst.a]) inst.b else pc + 1;
                    continue;
                },
                .bol => pos == 0 or (inst.a == 1 and m.input[pos - 1] == '\n'),
                .eol => pos == m.input.len or
                    (if (inst.a == 1) m.input[pos] == '\n' else pos + 1 == m.input.len and m.input[pos] == '\n'),
                .begin_text => pos == 0,
                .end_text => pos == m.input.len,
                .end_text_nl => pos == m.input.len or (pos + 1 == m.input.len and m.input[pos] == '\n'),
                .word_boundary => (isWord(m.before(pos)) != isWord(if (m.decode(pos)) |d| d[0] else null)) == (inst.a == 0),
                .backref => blk: {
                    const s = m.regs[2 * inst.a];
                    const e = m.regs[2 * inst.a + 1];
                    if (s == none or e == none) break :blk false;
                    // Compared a character at a time, folded as (?i) says.
                    var i = s;
                    var j = pos;
                    while (i < e) {
                        const a = m.decode(i) orelse break :blk false;
                        const b = m.decode(j) orelse break :blk false;
                        if (!sameChar(a[0], b[0], inst.fold)) break :blk false;
                        i += a[1];
                        j += b[1];
                    }
                    pos = j;
                    break :blk true;
                },
                .look => blk: {
                    const snapshot = alloc.dupe(usize, m.regs) catch rt.fatal("out of memory", .{});
                    defer alloc.free(snapshot);
                    const negative = inst.b == 1;
                    const matched = m.run(pc + 1, pos) != null;
                    if (negative or !matched) {
                        @memcpy(m.regs, snapshot);
                        if (negative == matched) break :blk false;
                    } else {
                        // Kept, and undone if the match backtracks past here.
                        for (m.regs, 0..) |v, r| if (v != snapshot[r]) {
                            m.regs[r] = snapshot[r];
                            m.setReg(@intCast(r), v);
                        };
                    }
                    pc = inst.a;
                    continue;
                },
                .look_end => {
                    m.stack.shrinkRetainingCapacity(base);
                    return pos;
                },
                .match => if (m.full and pos != m.input.len) false else {
                    m.stack.shrinkRetainingCapacity(base);
                    return pos;
                },
            };
            if (ok) {
                pc += 1;
                continue;
            }
            // Backtrack: undo registers to the last branch, and take it.
            while (true) {
                if (m.stack.items.len == base) return null;
                const e = m.stack.pop().?;
                switch (e.kind) {
                    .restore => m.regs[e.a] = e.b,
                    .branch => {
                        pc = e.a;
                        pos = e.b;
                        break;
                    },
                }
            }
        }
    }
};

/// Match `prog` against `input` from byte `start`: anchored there (re-matches, full) or
/// searching onward. The registers (byte positions, `none` unset) if it matched.
fn execute(prog: *const Program, input: []const u8, start: usize, full: bool) ?[]usize {
    const regs = alloc.alloc(usize, prog.registers) catch rt.fatal("out of memory", .{});
    var m: Matcher = .{ .prog = prog, .input = input, .regs = regs, .full = full };
    defer m.stack.deinit(alloc);
    var at = start;
    while (at <= input.len) {
        @memset(regs, none);
        if (m.run(0, at)) |end| {
            regs[0] = at;
            regs[1] = end;
            return regs;
        }
        if (full or at == input.len) break;
        at += (m.decode(at) orelse break)[1];
    }
    alloc.free(regs);
    return null;
}

// ---------------------------------------------------------------------------------------
// Patterns: the compiled programs by source, and the heap objects

var lock: platform.Mutex = .{};
var programs: std.StringHashMapUnmanaged(*Program) = .empty;
var table: std.ArrayList(*Program) = .empty;
var serial = std.atomic.Value(u32).init(0);

fn programOf(p: Value) *Program {
    if (!p.isObjectOf(.pattern)) rt.raise(.type_error, "a pattern is needed, not {s}", .{readable(p)});
    const h: usize = @intCast(coll.get(p, 1).toFixnum());
    lock.lock();
    defer lock.unlock();
    return table.items[h];
}

/// (re-pattern s): the pattern compiled from the string s (a pattern is itself).
pub fn pattern(s: Value) Value {
    if (s.isObjectOf(.pattern)) return s;
    if (!string.isString(s)) rt.raise(.type_error, "re-pattern needs a string, not {s}", .{readable(s)});
    const text = alloc.dupe(u8, string.bytes(s)) catch rt.fatal("out of memory", .{});
    lock.lock();
    const cached = programs.get(text);
    lock.unlock();
    var handle: usize = 0;
    if (cached) |prog| {
        alloc.free(text);
        lock.lock();
        handle = std.mem.indexOfScalar(*Program, table.items, prog).?;
        lock.unlock();
    } else {
        var err: CompileError = .{};
        const prog = compileText(text, &err) orelse {
            const message = err.message;
            const at = err.at;
            alloc.free(text);
            rt.raise(.@"error", "bad regex {s}: {s} at {d}", .{ readable(s), message, at });
        };
        lock.lock();
        if (programs.get(text)) |other| {
            // Another thread compiled it meanwhile.
            handle = std.mem.indexOfScalar(*Program, table.items, other).?;
            alloc.free(text);
        } else {
            table.append(alloc, prog) catch rt.fatal("out of memory", .{});
            programs.put(alloc, text, prog) catch rt.fatal("out of memory", .{});
            handle = table.items.len - 1;
        }
        lock.unlock();
    }
    return coll.make(.pattern, &.{ s, Value.fromFixnum(@intCast(handle)), Value.fromFixnum(@import("hash.zig").mix32(serial.fetchAdd(1, .monotonic) +% 1)) });
}

pub fn isPattern(v: Value) bool {
    return v.isObjectOf(.pattern);
}

/// The pattern's source text.
pub fn source(p: Value) Value {
    return coll.get(p, 0);
}

/// (%re-exec p s start full): nil, or [end g0 g1 ...]: the match's end (a byte cursor
/// into s, from which a search goes on) and its groups' text, nil for those unset.
fn exec(p: Value, s: Value, start: Value, full: Value) Value {
    const prog = programOf(p);
    if (!string.isString(s)) rt.raise(.type_error, "matching a pattern needs a string, not {s}", .{readable(s)});
    // The matcher allocates only on the C heap, so it reads s in place; making the result
    // can move s, so the groups' text is copied out first. Copying all of s instead made
    // each search of a long string take as long as the string (quadratic over re-seq).
    const input = string.bytes(s);
    const from: usize = if (start.isFixnum()) @intCast(@max(start.toFixnum(), 0)) else 0;
    if (from > input.len) return Value.nil;
    const regs = execute(prog, input, from, full.isTruthy()) orelse return Value.nil;
    defer alloc.free(regs);
    // The span the groups lie in (a lookahead's can lie past the match).
    var lo: usize = regs[0];
    var hi: usize = regs[1];
    for (0..prog.groups + 1) |g| {
        const a = regs[2 * g];
        const b = regs[2 * g + 1];
        if (a == none or b == none) continue;
        lo = @min(lo, a);
        hi = @max(hi, b);
    }
    const span = alloc.dupe(u8, input[lo..hi]) catch rt.fatal("out of memory", .{});
    defer alloc.free(span);
    var v = coll.vectorOf(&.{Value.fromFixnum(@intCast(regs[1]))});
    for (0..prog.groups + 1) |g| {
        const a = regs[2 * g];
        const b = regs[2 * g + 1];
        v = coll.vectorConj(v, if (a == none or b == none) Value.nil else string.make(span[a - lo .. b - lo]));
    }
    return v;
}

/// (%re-names p): a map of the pattern's group names to their numbers.
fn groupNames(p: Value) Value {
    const prog = programOf(p);
    var m = coll.mapOf(&.{});
    var it = prog.names.iterator();
    while (it.next()) |e| m = coll.mapAssoc(m, string.make(e.key_ptr.*), Value.fromFixnum(e.value_ptr.*));
    return m;
}

/// Print a pattern: readably as #"..." (its source, with a " escaped, which matches the
/// same), else its source alone, as str gives it.
pub fn write(v: Value, out: *std.ArrayList(u8), readably: bool) void {
    const text = string.bytes(source(v));
    if (!readably) return out.appendSlice(alloc, text) catch rt.fatal("out of memory", .{});
    out.appendSlice(alloc, "#\"") catch rt.fatal("out of memory", .{});
    var escaped = false;
    for (text) |c| {
        if (c == '"' and !escaped) out.append(alloc, '\\') catch rt.fatal("out of memory", .{});
        out.append(alloc, c) catch rt.fatal("out of memory", .{});
        escaped = c == '\\' and !escaped;
    }
    out.appendSlice(alloc, "\"") catch rt.fatal("out of memory", .{});
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const entries = [_]io.Entry{
    .{ .name = "re-pattern", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return pattern(a[0]);
        }
    }.f },
    .{ .name = "%regex-literal", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            // What #"..." reads as: the pattern of its source (a constant natively).
            return pattern(a[0]);
        }
    }.f },
    .{ .name = "%re-exec", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return exec(a[0], a[1], a[2], a[3]);
        }
    }.f },
    .{ .name = "%re-names", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return groupNames(a[0]);
        }
    }.f },
    .{ .name = "%re-source", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return source(a[0]);
        }
    }.f },
    .{ .name = "%pattern?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(isPattern(a[0]));
        }
    }.f },
};
