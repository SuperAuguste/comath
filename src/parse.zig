const comath = @import("main.zig");

const std = @import("std");
const assert = std.debug.assert;

const util = @import("util");

const Tokenizer = @import("Tokenizer.zig");

const MatchOpFn = fn (comptime str: []const u8) callconv(.Inline) bool;
const OrderBinOpFn = fn (comptime lhs: []const u8, comptime rhs: []const u8) callconv(.Inline) ?comath.Order;

pub fn parseExpr(
    comptime expr: []const u8,
    comptime maybeMatchUnOp: ?MatchOpFn,
    comptime maybeMatchBinOp: ?MatchOpFn,
    comptime maybeOrderBinOp: ?OrderBinOpFn,
) ExprNode {
    comptime {
        const deduped_expr = util.dedupe.scalarSlice(u8, expr[0..].*);
        const res = parseExprImpl(
            deduped_expr,
            .none,
            .{},
            maybeMatchUnOp,
            maybeMatchBinOp,
            maybeOrderBinOp,
        );
        return res.result;
    }
}

fn ParseExprTester(
    comptime UnOp: type,
    comptime BinOp: type,
    comptime relations: anytype,
) type {
    return struct {
        fn expectEqual(
            comptime expr: []const u8,
            comptime expected: ExprNode,
        ) !void {
            const actual = comptime parseExpr(expr, matchUnOp, matchBinOp, orderBinOp);
            if (!actual.eql(expected)) {
                @compileError(std.fmt.comptimePrint("Expected `{}`, got `{}`", .{ expected.fmt(.{ .verbose_paren = true }), actual.fmt(.{ .verbose_paren = true }) }));
            }
        }

        inline fn matchUnOp(comptime str: []const u8) bool {
            return @hasField(UnOp, str);
        }
        inline fn matchBinOp(comptime str: []const u8) bool {
            return @hasField(BinOp, str);
        }
        inline fn orderBinOp(comptime lhs: []const u8, comptime rhs: []const u8) ?comath.Order {
            comptime if (!matchBinOp(lhs) or !matchBinOp(rhs)) return null;
            const lhs_rel: comath.Relation = if (@hasField(@TypeOf(relations), lhs)) @field(relations, lhs) else return null;
            const rhs_rel: comath.Relation = if (@hasField(@TypeOf(relations), rhs)) @field(relations, rhs) else return null;
            return lhs_rel.order(rhs_rel);
        }
    };
}

test parseExpr {
    const helper = struct {
        inline fn number(comptime src: []const u8) ExprNode {
            return .{ .number = src };
        }
        inline fn ident(comptime name: []const u8) ExprNode {
            return .{ .ident = name };
        }
        inline fn group(comptime expr: ExprNode) ExprNode {
            return .{ .group = &expr };
        }
        inline fn err(comptime str: []const u8) ExprNode {
            return .{ .err = str };
        }
        inline fn binOp(comptime lhs: ExprNode, comptime op: []const u8, comptime rhs: ExprNode) ExprNode {
            return .{ .bin_op = &.{
                .lhs = lhs,
                .op = op,
                .rhs = rhs,
            } };
        }
        inline fn unOp(comptime op: []const u8, comptime expr: ExprNode) ExprNode {
            return .{ .un_op = &.{
                .op = op,
                .val = expr,
            } };
        }
        inline fn fieldAccess(comptime expr: ExprNode, comptime field: []const u8) ExprNode {
            return .{ .field_access = &.{
                .accessed = expr,
                .accessor = field,
            } };
        }
        inline fn indexAccess(comptime lhs: ExprNode, comptime idx: []const ExprNode) ExprNode {
            return .{ .index_access = &.{
                .accessed = lhs,
                .accessor = idx,
            } };
        }
        inline fn funcCall(comptime callee: ExprNode, comptime args: []const ExprNode) ExprNode {
            return .{ .func_call = &.{
                .callee = callee,
                .args = args,
            } };
        }
    };
    const number = helper.number;
    const ident = helper.ident;
    const group = helper.group;
    const err = helper.err;
    const binOp = helper.binOp;
    const unOp = helper.unOp;
    const fieldAccess = helper.fieldAccess;
    const indexAccess = helper.indexAccess;
    const funcCall = helper.funcCall;
    const Tester = ParseExprTester(
        enum { @"-", @"~", @"!" },
        enum { @"-", @"+", @"*", @"/", @"^", @"<", @">", @"&" },
        .{
            .@"<" = comath.relation(.none, 0),
            .@">" = comath.relation(.none, 0),
            .@"-" = comath.relation(.left, 1),
            .@"+" = comath.relation(.left, 1),
            .@"*" = comath.relation(.left, 2),
            .@"/" = comath.relation(.left, 2),
            .@"^" = comath.relation(.right, 3),
        },
    );

    try Tester.expectEqual("423_324", number("423_324"));
    try Tester.expectEqual("-423_324", unOp("-", number("423_324")));
    try Tester.expectEqual("~-423_324", unOp("~", unOp("-", number("423_324"))));
    try Tester.expectEqual("~(-423_324)", unOp("~", group(unOp("-", number("423_324")))));
    try Tester.expectEqual("!(0.3 + a ^ (3 / y.z))", unOp("!", group(binOp(
        number("0.3"),
        "+",
        binOp(
            ident("a"),
            "^",
            group(binOp(number("3"), "/", fieldAccess(ident("y"), "z"))),
        ),
    ))));
    try Tester.expectEqual("3 + -2", binOp(
        number("3"),
        "+",
        unOp("-", number("2")),
    ));
    try Tester.expectEqual("(y + 2) * x", binOp(
        group(binOp(ident("y"), "+", number("2"))),
        "*",
        ident("x"),
    ));
    try Tester.expectEqual("y + 2 * x", binOp(
        ident("y"),
        "+",
        binOp(number("2"), "*", ident("x")),
    ));
    try Tester.expectEqual("2.0 * y ^ 3", binOp(
        number("2.0"),
        "*",
        binOp(ident("y"), "^", number("3")),
    ));
    try Tester.expectEqual("2 ^ 3 ^ 4", binOp(number("2"), "^", binOp(number("3"), "^", number("4"))));

    try Tester.expectEqual("a.b", fieldAccess(ident("a"), "b"));
    try Tester.expectEqual("a + b.c", binOp(ident("a"), "+", fieldAccess(ident("b"), "c")));
    try Tester.expectEqual("(a + b).c", fieldAccess(group(binOp(ident("a"), "+", ident("b"))), "c"));
    try Tester.expectEqual("foo.b@r", fieldAccess(ident("foo"), "b@r"));
    try Tester.expectEqual("foo.?", fieldAccess(ident("foo"), "?"));
    try Tester.expectEqual("foo.0", fieldAccess(ident("foo"), "0"));

    try Tester.expectEqual("a[b]", indexAccess(ident("a"), &.{ident("b")}));
    try Tester.expectEqual("(a)[(b)]", indexAccess(group(ident("a")), &.{group(ident("b"))}));
    try Tester.expectEqual("(~(a + b))[(c)]", indexAccess(
        group(unOp("~", group(binOp(ident("a"), "+", ident("b"))))),
        &.{group(ident("c"))},
    ));

    try Tester.expectEqual("foo()", funcCall(ident("foo"), &.{}));
    try Tester.expectEqual("foo(bar)", funcCall(ident("foo"), &.{ident("bar")}));
    try Tester.expectEqual("foo(bar,)", funcCall(ident("foo"), &.{ident("bar")}));
    try Tester.expectEqual("foo(bar,baz)", funcCall(ident("foo"), &.{ ident("bar"), ident("baz") }));
    try Tester.expectEqual("foo(bar, baz, )", funcCall(ident("foo"), &.{ ident("bar"), ident("baz") }));

    try Tester.expectEqual("foo[]", indexAccess(ident("foo"), &.{}));
    try Tester.expectEqual("foo[bar]", indexAccess(ident("foo"), &.{ident("bar")}));
    try Tester.expectEqual("foo[bar,]", indexAccess(ident("foo"), &.{ident("bar")}));
    try Tester.expectEqual("foo[bar,baz]", indexAccess(ident("foo"), &.{ ident("bar"), ident("baz") }));
    try Tester.expectEqual("foo[bar, baz, ]", indexAccess(ident("foo"), &.{ ident("bar"), ident("baz") }));

    try Tester.expectEqual(
        "6*1-3*1+4*1+2",
        binOp(
            binOp(
                binOp(
                    binOp(number("6"), "*", number("1")),
                    "-",
                    binOp(number("3"), "*", number("1")),
                ),
                "+",
                binOp(
                    number("4"),
                    "*",
                    number("1"),
                ),
            ),
            "+",
            number("2"),
        ),
    );

    try Tester.expectEqual("foo bar", err("Unexpected token 'bar'"));
    try Tester.expectEqual("foo )", err("Unexpected closing parentheses"));
    try Tester.expectEqual("foo (", err("Missing closing parentheses"));
    try Tester.expectEqual("foo (a,", err("Missing closing parentheses"));
    try Tester.expectEqual("a < b < c", err("'<' cannot be chained with '<'"));
    try Tester.expectEqual("$a", err("Unexpected operator symbols '$'"));
    try Tester.expectEqual("$a # b", err("Unexpected operator symbols '#'"));
    try Tester.expectEqual("$a / b", err("Unexpected operator symbols '$'"));
    try Tester.expectEqual("a $ b # c", err("Unexpected operator symbols '$'"));

    try Tester.expectEqual("a & b + 1", err("No precedence/associativity defined between operators '&' and '+'"));
    try Tester.expectEqual(
        "(a & b) + 1",
        binOp(
            group(binOp(ident("a"), "&", ident("b"))),
            "+",
            number("1"),
        ),
    );
    try Tester.expectEqual(
        "a & (b + 1)",
        binOp(
            ident("a"),
            "&",
            group(binOp(ident("b"), "+", number("1"))),
        ),
    );
}

const NestType = enum(comptime_int) { none, paren, bracket };
const ParseExprImplInnerUpdate = struct {
    terminator: Terminator,
    tokenizer: Tokenizer,
    result: ExprNode,

    const Terminator = enum {
        eof,
        comma,
        paren,
        bracket,
    };
};
fn parseExprImpl(
    comptime expr: []const u8,
    comptime nest_type: NestType,
    comptime tokenizer_init: Tokenizer,
    comptime maybeMatchUnOpEnum: ?MatchOpFn,
    comptime maybeMatchBinOp: ?MatchOpFn,
    comptime maybeOrderBinOp: ?OrderBinOpFn,
) ParseExprImplInnerUpdate {
    comptime {
        var result: ExprNode = .null;
        var tokenizer = tokenizer_init;
        var terminator: ParseExprImplInnerUpdate.Terminator = .eof;

        @setEvalBranchQuota(expr.len + expr.len / 2);
        var can_be_unary = true;
        mainloop: while (true) switch (tokenizer.next(expr)) {
            .eof => break,
            .err => |err| switch (err) {
                .empty_field_access => |start| {
                    result = .{ .err = std.fmt.comptimePrint("Expected field access characters after period ('.'), instead found '{}'", .{Tokenizer.peek(.{ .index = start }, expr)}) };
                    break :mainloop;
                },
            },
            .ident => |ident| {
                can_be_unary = false;
                result = result.concatIdent(ident);
            },
            .number => |number_src| {
                can_be_unary = false;
                result = result.concatNumber(number_src);
            },
            .field => |field| {
                can_be_unary = false;
                result = result.concatFieldAccess(field);
            },
            .op_symbols => |op_symbols| {
                assert(op_symbols.len != 0);

                var start = 0;
                var len = op_symbols.len;

                if (!can_be_unary) {
                    const matchBinOp = maybeMatchBinOp orelse {
                        result = .{ .err = "No `matchBinOp` function was given to parse the expected binary operator(s) in '" ++ op_symbols[start..] };
                        break :mainloop;
                    };
                    while (start < op_symbols.len) {
                        if (len == 0) {
                            result = .{ .err = "Unexpected operator symbols '" ++ op_symbols[start..] ++ "'" };
                            break :mainloop;
                        }

                        const op = util.dedupe.scalarSlice(u8, op_symbols[start..][0..len].*);
                        if (!matchBinOp(op)) {
                            len -= 1;
                            continue;
                        }
                        start += len;
                        len = op_symbols.len - start;
                        result = result.concatBinOp(op, maybeOrderBinOp);
                        break;
                    }
                    can_be_unary = true;
                }
                if (start == op_symbols.len) continue;

                const matchUnOp = maybeMatchUnOpEnum orelse {
                    result = .{ .err = "No `UnOp` enum was given to parse the expected unary operator(s) in '" ++ op_symbols[start..] };
                    break;
                };
                while (start < op_symbols.len) {
                    if (len == 0) {
                        result = .{ .err = "Unexpected operator symbols '" ++ op_symbols[start..] ++ "'" };
                        break;
                    }

                    const op = util.dedupe.scalarSlice(u8, op_symbols[start..][0..len].*);
                    if (!matchUnOp(op)) {
                        len -= 1;
                        continue;
                    }
                    start += len;
                    len = op_symbols.len - start;
                    result = result.concatUnOp(op);
                }
            },
            inline .paren_open, .bracket_open => |_, tag| {
                const inner_nest_type = switch (tag) {
                    .paren_open => .paren,
                    .bracket_open => .bracket,
                    else => unreachable,
                };

                can_be_unary = false;
                var args: []const ExprNode = &.{};
                while (true) {
                    const update = parseExprImpl(expr, inner_nest_type, tokenizer, maybeMatchUnOpEnum, maybeMatchBinOp, maybeOrderBinOp);
                    tokenizer = update.tokenizer;
                    if (update.result != .null) {
                        args = args ++ &[_]ExprNode{update.result};
                    }
                    switch (update.terminator) {
                        .comma => {},
                        .eof => {
                            result = .{ .err = "Missing closing " ++ switch (inner_nest_type) {
                                .paren => "parentheses",
                                .bracket => "bracket",
                                else => unreachable,
                            } };
                            break;
                        },
                        .paren, .bracket => {
                            if (inner_nest_type != update.terminator) {
                                result = .{ .err = "Unexpected closing " ++ switch (inner_nest_type) {
                                    .paren => "parentheses where a closing bracket was expected",
                                    .bracket => "bracket where a closing parentheses was expected",
                                    else => unreachable,
                                } };
                            }
                            break;
                        },
                    }
                }
                result = result.concatFunctionArgsOrJustGroup(inner_nest_type, args);
            },
            .comma => {
                can_be_unary = undefined;
                terminator = .comma;
                break;
            },
            .paren_close => {
                can_be_unary = undefined;
                terminator = .paren;
                if (nest_type != .paren) result = .{ .err = "Unexpected closing parentheses" };
                break;
            },
            .bracket_close => {
                can_be_unary = undefined;
                terminator = .bracket;
                if (nest_type != .bracket) result = .{ .err = "Unexpected closing bracket" };
                break;
            },
        };
        return .{
            .terminator = terminator,
            .tokenizer = tokenizer,
            .result = result,
        };
    }
}

pub const ExprNode = union(enum(comptime_int)) {
    null,
    err: []const u8,

    ident: []const u8,
    number: []const u8,
    group: *const ExprNode,
    field_access: *const FieldAccess,
    index_access: *const IndexAccess,
    func_call: *const FuncCall,
    un_op: *const UnOp,
    bin_op: *const BinOp,

    pub inline fn eql(comptime a: ExprNode, comptime b: ExprNode) bool {
        const tag_a: @typeInfo(ExprNode).Union.tag_type.? = a;
        const tag_b: @typeInfo(ExprNode).Union.tag_type.? = b;
        comptime if (tag_a != tag_b) return false;
        const val_a = @field(a, @tagName(tag_a));
        const val_b = @field(b, @tagName(tag_b));
        comptime return switch (tag_a) {
            .null => true,
            .err => util.eqlComptime(u8, val_a, val_b),

            .ident => util.eqlComptime(u8, val_a, val_b),
            .number => util.eqlComptime(u8, val_a, val_b),
            .group => val_a.eql(val_b.*),
            .field_access => val_a.accessed.eql(val_b.accessed) and util.eqlComptime(u8, val_a.accessor, val_b.accessor),
            .index_access => val_a.accessed.eql(val_b.accessed) and
                val_a.accessor.len == val_b.accessor.len and blk: {
                break :blk for (
                    val_a.accessor,
                    val_b.accessor,
                ) |accessor_a, accessor_b| {
                    if (!accessor_a.eql(accessor_b)) break false;
                } else true;
            },
            .func_call => val_a.callee.eql(val_b.callee) and
                val_a.args.len == val_b.args.len and blk: {
                break :blk for (
                    val_a.args,
                    val_b.args,
                ) |arg_a, arg_b| {
                    if (!arg_a.eql(arg_b)) break false;
                } else true;
            },
            .un_op => util.eqlComptime(u8, val_a.op, val_b.op) and val_a.val.eql(val_b.val),
            .bin_op => util.eqlComptime(u8, val_a.op, val_b.op) and val_a.lhs.eql(val_b.lhs),
        };
    }

    inline fn concatUnOp(
        comptime base: ExprNode,
        comptime op: []const u8,
    ) ExprNode {
        return switch (base) {
            .null => ExprNode{ .un_op = &.{
                .op = op,
                .val = .null,
            } },
            .err => base,
            .un_op => |un| un.concatOp(op),
            .bin_op => |bin| ExprNode{ .bin_op = &.{
                .lhs = bin.lhs,
                .op = bin.op,
                .rhs = bin.rhs.concatUnOp(op),
            } },

            .ident,
            .field_access,
            .index_access,
            .number,
            .group,
            .func_call,
            => .{ .err = "Unexpected token '" ++ op ++ "'" },
        };
    }

    inline fn concatBinOp(
        comptime base: ExprNode,
        comptime op: []const u8,
        comptime maybeOrderBinOp: ?OrderBinOpFn,
    ) ExprNode {
        return switch (base) {
            .null => .{ .err = "Unexpected token '" ++ op ++ "'" },
            .err => base,

            .ident,
            .field_access,
            .index_access,
            .number,
            .group,
            .func_call,
            .un_op,
            => .{ .bin_op = &.{
                .lhs = base,
                .op = op,
                .rhs = .null,
            } },

            .bin_op => |lhs_bin| switch (lhs_bin.rhs) {
                .null => .{ .err = "Unexpected token '" ++ op ++ "'" },
                .err => base,

                .bin_op => |mid_bin| blk: {
                    const orderBinOp = maybeOrderBinOp orelse break :blk .{
                        .err = "No `orderBinOp` function was given to determine the order between '" ++ lhs_bin.op ++ "', '" ++ mid_bin.op ++ "', and '" ++ op ++ "'",
                    };
                    if (orderBinOp(lhs_bin.op, mid_bin.op).? != .lt) unreachable;

                    const order = orderBinOp(mid_bin.op, op) orelse break :blk .{
                        .err = "No precedence/associativity defined between operators '" ++ mid_bin.op ++ "' and '" ++ op ++ "'",
                    };
                    break :blk switch (order) {
                        .incompatible => .{ .err = lhs_bin.op ++ " cannot be chained with " ++ op },
                        .lt => .{ .bin_op = &.{
                            .lhs = lhs_bin.lhs,
                            .op = lhs_bin.op,
                            .rhs = lhs_bin.rhs.concatBinOp(op, maybeOrderBinOp),
                        } },
                        .gt => .{ .bin_op = &.{
                            .lhs = base,
                            .op = op,
                            .rhs = .null,
                        } },
                    };
                },

                .ident,
                .field_access,
                .index_access,
                .number,
                .group,
                .func_call,
                .un_op,
                => blk: {
                    const orderBinOp = maybeOrderBinOp orelse break :blk .{
                        .err = "No `orderBinOp` function was given to determine the order between '" ++ lhs_bin.op ++ "', and '" ++ op ++ "'",
                    };
                    const order = orderBinOp(lhs_bin.op, op) orelse break :blk .{
                        .err = "No precedence/associativity defined between operators '" ++ lhs_bin.op ++ "' and '" ++ op ++ "'",
                    };
                    break :blk switch (order) {
                        .incompatible => .{ .err = "'" ++ lhs_bin.op ++ "'" ++ " cannot be chained with '" ++ op ++ "'" },
                        .lt => .{ .bin_op = &.{
                            .lhs = lhs_bin.lhs,
                            .op = lhs_bin.op,
                            .rhs = .{ .bin_op = &.{
                                .lhs = lhs_bin.rhs,
                                .op = op,
                                .rhs = .null,
                            } },
                        } },
                        .gt => .{ .bin_op = &.{
                            .lhs = base,
                            .op = op,
                            .rhs = .null,
                        } },
                    };
                },
            },
        };
    }
    inline fn concatIdent(comptime base: ExprNode, comptime ident: []const u8) ExprNode {
        return switch (base) {
            .null => .{ .ident = ident },
            .err => base,

            .ident,
            .field_access,
            .index_access,
            .number,
            .group,
            .func_call,
            => .{ .err = std.fmt.comptimePrint("Unexpected token '{s}'", .{ident}) },

            .bin_op => |bin| switch (bin.rhs) {
                .null => .{ .bin_op = &.{
                    .lhs = bin.lhs,
                    .op = bin.op,
                    .rhs = .{ .ident = ident },
                } },
                .err => base,

                .ident,
                .field_access,
                .index_access,
                .number,
                .group,
                .func_call,
                => .{ .err = std.fmt.comptimePrint("Unexpected token '{s}'", .{ident}) },

                .bin_op,
                .un_op,
                => .{ .bin_op = &.{
                    .lhs = bin.lhs,
                    .op = bin.op,
                    .rhs = bin.rhs.concatIdent(ident),
                } },
            },
            .un_op => |un| un.insertExprAsInnerTarget(.{ .ident = ident }),
        };
    }
    inline fn concatNumber(comptime base: ExprNode, comptime src: []const u8) ExprNode {
        return switch (base) {
            .null => .{ .number = src },
            .err => base,

            .ident,
            .field_access,
            .index_access,
            .number,
            .group,
            .func_call,
            => .{ .err = std.fmt.comptimePrint("Unexpected token '{s}'", .{src}) },

            .un_op => |un| un.insertExprAsInnerTarget(.{ .number = src }),
            .bin_op => |bin| switch (bin.rhs) {
                .null => .{ .bin_op = &.{
                    .lhs = bin.lhs,
                    .op = bin.op,
                    .rhs = .{ .number = src },
                } },
                .err => base,

                .ident,
                .field_access,
                .index_access,
                .number,
                .group,
                .func_call,
                => .{ .err = std.fmt.comptimePrint("Unexpected token '{s}'", .{src}) },

                .bin_op,
                .un_op,
                => .{ .bin_op = &.{
                    .lhs = bin.lhs,
                    .op = bin.op,
                    .rhs = bin.rhs.concatNumber(src),
                } },
            },
        };
    }
    inline fn concatFunctionArgsOrJustGroup(
        comptime base: ExprNode,
        comptime delimiter: enum { paren, bracket },
        comptime args: []const ExprNode,
    ) ExprNode {
        return switch (base) {
            .null => if (args.len != 1 or delimiter != .paren)
                .{ .err = "Group must be comprised of exactly 1 expression and be delimited by parentheses" }
            else
                .{ .group = &args[0] },
            .err => base,

            .ident,
            .field_access,
            .number,
            .group,
            .index_access,
            .func_call,
            => switch (delimiter) {
                .paren => .{ .func_call = &.{
                    .callee = base,
                    .args = args,
                } },
                .bracket => .{ .index_access = &.{
                    .accessed = base,
                    .accessor = args,
                } },
            },
            .bin_op => |bin| .{ .bin_op = &.{
                .lhs = bin.lhs,
                .op = bin.op,
                .rhs = bin.rhs.concatFunctionArgsOrJustGroup(delimiter, args),
            } },
            .un_op => |un| .{ .un_op = &.{
                .op = un.op,
                .val = un.val.concatFunctionArgsOrJustGroup(delimiter, args),
            } },
        };
    }
    inline fn concatFieldAccess(comptime base: ExprNode, comptime field: []const u8) ExprNode {
        return switch (base) {
            .null => .{ .err = "Unexpected token '." ++ field ++ "'" },
            .err => base,
            .number,
            .ident,
            .field_access,
            .index_access,
            .group,
            .func_call,
            => .{ .field_access = &.{
                .accessed = base,
                .accessor = field,
            } },
            .bin_op => |bin| .{ .bin_op = &.{
                .lhs = bin.lhs,
                .op = bin.op,
                .rhs = bin.rhs.concatFieldAccess(field),
            } },
            .un_op => |un| .{ .un_op = .{
                .op = un.op,
                .val = un.val.concatFieldAccess(field),
            } },
        };
    }

    const FieldAccess = struct {
        accessed: ExprNode,
        accessor: []const u8,
    };
    const IndexAccess = struct {
        accessed: ExprNode,
        accessor: []const ExprNode,
    };
    pub const FuncCall = struct {
        callee: ExprNode,
        args: []const ExprNode,
    };
    const BinOp = struct {
        lhs: ExprNode,
        op: []const u8,
        rhs: ExprNode,
    };
    const UnOp = struct {
        op: []const u8,
        val: ExprNode,

        inline fn insertExprAsInnerTarget(comptime un: UnOp, comptime expr: ExprNode) ExprNode {
            return switch (un.val) {
                .null => .{ .un_op = &.{
                    .op = un.op,
                    .val = expr,
                } },
                .un_op => |inner| .{ .un_op = &.{
                    .op = un.op,
                    .val = inner.insertExprAsInnerTarget(expr),
                } },
                else => .{ .err = std.fmt.comptimePrint("Unexpected token '{}'", .{un.val.fmt()}) },
            };
        }

        inline fn concatOp(comptime un: UnOp, comptime op: []const u8) ExprNode {
            const updated = un.concatOpInnerImpl(op) orelse .{ .err = "Unexpected token '" ++ op ++ "'" };
            return .{ .un_op = &updated };
        }

        /// returns null if the inner-most target of the unary operations is already present,
        /// meaning the unary operator can simply be used as the LHS of a binary operation
        inline fn concatOpInnerImpl(comptime un: UnOp, comptime op: []const u8) ?UnOp {
            switch (un.val) {
                .null => return .{
                    .op = un.op,
                    .val = .{ .un_op = &.{
                        .op = op,
                        .val = .null,
                    } },
                },
                .un_op => |inner| return if (inner.concatOpInnerImpl(op)) |updated| .{
                    .op = un.op,
                    .val = .{ .un_op = &updated },
                },
                else => return null,
            }
        }
    };

    inline fn fmt(
        comptime expr: ExprNode,
        comptime config: Fmt.Config,
    ) Fmt {
        return .{ .expr = expr, .config = config };
    }
    const Fmt = struct {
        expr: ExprNode,
        config: Config,

        const Config = struct {
            verbose_paren: bool = false,
        };

        pub fn format(
            comptime formatter: Fmt,
            comptime fmt_str: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            _ = options;
            if (fmt_str.len != 0) std.fmt.invalidFmtError(fmt_str, formatter);
            const str = switch (formatter.expr) {
                .null => "null",
                .err => |err| std.fmt.comptimePrint("@compileError(\"{}\")", .{std.zig.fmtEscapes(err)}),
                .ident => |ident| ident,
                .field_access => |field| std.fmt.comptimePrint("{}.{s}", .{ field.accessed.fmt(formatter.config), field.accessor }),
                .index_access => |ia| std.fmt.comptimePrint("{}", .{ia.accessed.fmt(formatter.config)}) ++ args: {
                    var args: []const u8 = "";
                    args = args ++ "[";
                    if (ia.accessor.len != 0) {
                        args = args ++ std.fmt.comptimePrint("{}", .{ia.accessor[0].fmt(formatter.config)});
                        for (ia.accessor[1..]) |idx| {
                            args = args ++ std.fmt.comptimePrint(", {}", .{idx.fmt(formatter.config)});
                        }
                    }
                    args = args ++ "]";
                    break :args args;
                },
                .func_call => |fc| std.fmt.comptimePrint("{}", .{fc.callee.fmt(formatter.config)}) ++ args: {
                    var args: []const u8 = "";
                    args = args ++ "(";
                    if (fc.args.len != 0) {
                        args = args ++ std.fmt.comptimePrint("{}", .{fc.args[0].fmt(formatter.config)});
                        for (fc.args[1..]) |arg| {
                            args = args ++ std.fmt.comptimePrint(", {}", .{arg.fmt(formatter.config)});
                        }
                    }
                    args = args ++ ")";
                    break :args args;
                },
                .number => |src| src,
                .group => |group| std.fmt.comptimePrint("({})", .{group.fmt(formatter.config)}),
                .bin_op => |bin_op| std.fmt.comptimePrint("{} {s} {}", .{ bin_op.lhs.fmt(formatter.config), bin_op.op, bin_op.rhs.fmt(formatter.config) }),
                .un_op => |un_op| std.fmt.comptimePrint("{s}{}", .{ un_op.op, un_op.val.fmt(formatter.config) }),
            };
            if (formatter.config.verbose_paren) switch (formatter.expr) {
                .bin_op, .un_op => {
                    try writer.writeAll("(" ++ str ++ ")");
                    return;
                },
                else => {},
            };
            try writer.writeAll(str);
        }
    };
};
