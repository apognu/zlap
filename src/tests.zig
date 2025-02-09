const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const zlap = @import("zlap.zig");

fn TestResult(comptime employed_default: bool) type {
    return struct {
        firstname: []const u8,
        lastname: []const u8,
        age: i32 = 42,
        address: ?[]const u8,
        employed: bool = employed_default,
    };
}

fn setupTestParser(comptime R: type) !zlap.Zlap(R) {
    var parser = try zlap.Zlap(R).init(std.testing.allocator);

    _ = try parser.opt("firstname", .{ .long = "firstname" });
    _ = try parser.opt("lastname", .{ .long = "lastname" });
    _ = try parser.opt("age", .{ .long = "age", .short = 'a' });
    _ = try parser.opt("address", .{ .long = "address" });
    _ = try parser.opt("employed", .{ .long = "employed", .short = 'e' });

    return parser;
}

test "cannot use a struct with unsupported types" {
    try expectError(zlap.ZlapError.InvalidType, zlap.Zlap(struct { b: ?*bool = null }).init(std.testing.allocator));
}

test "cannot build an argument without long or short option" {
    var parser = try zlap.Zlap(struct { b: bool = true }).init(std.testing.allocator);
    defer parser.deinit();

    try expectError(zlap.ZlapError.InvalidArgument, parser.opt("a", .{}));
}

test "cannot build a parser on unknown struct field" {
    var parser = try zlap.Zlap(struct { b: bool = true }).init(std.testing.allocator);
    defer parser.deinit();

    try expectError(zlap.ZlapError.UnknownStructField, parser.opt("a", .{ .short = 'a' }));
}

test "a boolean defaulting to true must have a long-form option" {
    var parser = try zlap.Zlap(struct { b: bool = true }).init(std.testing.allocator);
    defer parser.deinit();

    try expectError(zlap.ZlapError.ImmutableBoolean, parser.opt("b", .{ .short = 'b' }));
}

test "default values are used" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(std.mem.eql(u8, parsed.arguments.firstname, "First Name"));
    try expect(std.mem.eql(u8, parsed.arguments.lastname, "Last Name"));
    try expect(parsed.arguments.age == 42);
    try expect(parsed.arguments.address == null);
    try expect(!parsed.arguments.employed);
}

test "boolean is set to true" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "--employed" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(std.mem.eql(u8, parsed.arguments.firstname, "First Name"));
    try expect(std.mem.eql(u8, parsed.arguments.lastname, "Last Name"));
    try expect(parsed.arguments.employed);
    try expect(parsed.positionals == null);
}

test "short-form boolean is set to true" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "-e" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(std.mem.eql(u8, parsed.arguments.firstname, "First Name"));
    try expect(std.mem.eql(u8, parsed.arguments.lastname, "Last Name"));
    try expect(parsed.arguments.employed);
    try expect(parsed.positionals == null);
}

test "boolean negation allows to set a boolean to false" {
    var parser = try setupTestParser(TestResult(true));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "--no-employed" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(std.mem.eql(u8, parsed.arguments.firstname, "First Name"));
    try expect(std.mem.eql(u8, parsed.arguments.lastname, "Last Name"));
    try expect(!parsed.arguments.employed);
    try expect(parsed.positionals == null);
}

test "integers are parsed" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "--employed", "-a", "100" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(parsed.arguments.age == 100);
}

test "optional are properly populated" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "--employed", "--address", "Over there" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(parsed.arguments.address != null);
    try expect(std.mem.eql(u8, parsed.arguments.address.?, "Over there"));
}

test "positionals are collected" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "--employed", "one", "two", "three" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(parsed.positionals != null);
    try expect(parsed.positionals.?.len == 3);
    try expect(std.mem.eql(u8, parsed.positionals.?[0], "one"));
    try expect(std.mem.eql(u8, parsed.positionals.?[1], "two"));
    try expect(std.mem.eql(u8, parsed.positionals.?[2], "three"));
}

test "positionals can be mixed within other options" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "one", "--firstname", "First Name", "--lastname", "Last Name", "two", "--employed", "three" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(parsed.positionals != null);
    try expect(parsed.positionals.?.len == 3);
    try expect(std.mem.eql(u8, parsed.positionals.?[0], "one"));
    try expect(std.mem.eql(u8, parsed.positionals.?[1], "two"));
    try expect(std.mem.eql(u8, parsed.positionals.?[2], "three"));
}

test "double-dashed positionals are properly parsed" {
    var parser = try setupTestParser(TestResult(false));
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--firstname", "First Name", "--lastname", "Last Name", "--", "--one", "--", "-two" };
    const parsed = try parser.build(args[0..]);
    defer parsed.deinit();

    try expect(parsed.positionals != null);
    try expect(parsed.positionals.?.len == 3);
    try expect(std.mem.eql(u8, parsed.positionals.?[0], "--one"));
    try expect(std.mem.eql(u8, parsed.positionals.?[1], "--"));
    try expect(std.mem.eql(u8, parsed.positionals.?[2], "-two"));
}

test "error on missing required argument" {
    var parser = try zlap.Zlap(struct { age: i32 }).init(std.testing.allocator);
    defer parser.deinit();

    var args = [_][:0]const u8{""};
    const parsed = parser.build(args[0..]);

    try std.testing.expectError(zlap.ZlapError.MissingRequiredArgument, parsed);
}

test "no error on missing argument but optional" {
    var parser = try zlap.Zlap(struct { age: ?i32 }).init(std.testing.allocator);
    defer parser.deinit();

    var args = [_][:0]const u8{""};
    _ = try parser.build(args[0..]);
}

test "no error on missing argument with default value" {
    var parser = try zlap.Zlap(struct { age: i32 = -40 }).init(std.testing.allocator);
    defer parser.deinit();

    var args = [_][:0]const u8{""};
    const parsed = try parser.build(args[0..]);

    try expect(parsed.arguments.age == -40);
}

test "missing argument value returns an error" {
    var parser = try zlap.Zlap(struct { age: i32 = -40 }).init(std.testing.allocator);
    defer parser.deinit();

    _ = try parser.opt("age", .{ .long = "age" });

    var args = [_][:0]const u8{ "", "--age" };

    try expectError(zlap.ZlapError.MissingArgumentValue, parser.build(args[0..]));
}

test "cannot use unknown arguments" {
    var parser = try zlap.Zlap(struct { age: i32 }).init(std.testing.allocator);
    defer parser.deinit();

    var args = [_][:0]const u8{ "", "--unknown" };
    try std.testing.expectError(zlap.ZlapError.UnsupportedArgument, parser.build(args[0..]));
}

test "cannot map an argument twice" {
    var parser = try zlap.Zlap(struct { age: i32 }).init(std.testing.allocator);
    defer parser.deinit();

    _ = try parser.opt("age", .{ .short = 'a' });

    try expectError(zlap.ZlapError.ArgumentDeclaredTwice, parser.opt("age", .{ .short = 'a' }));
}

test "cannot set a non-boolean as negatable" {
    var parser = try zlap.Zlap(struct { age: i32 }).init(std.testing.allocator);
    defer parser.deinit();

    try expectError(zlap.ZlapError.NonBooleanNegatable, parser.opt("age", .{ .short = 'a', ._negatable = true }));
}
