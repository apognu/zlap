const std = @import("std");
const print = std.debug.print;

pub const ZlapError = error{
    MissingRequiredArgument,
    ArgumentDeclaredTwice,
    NonBooleanNegatable,
    MissingArgumentValue,
    ImmutableBoolean,
    UnknownStructField,
    InvalidArgument,
    UnsupportedArgument,
    InvalidType,
};

pub fn Zlap(comptime T: anytype) type {
    return struct {
        const Self = @This();

        const ArgumentForm = enum { long, short, positional };

        const Config = struct {
            short: ?u8 = null,
            long: ?[]const u8 = null,
            _negatable: bool = false,
        };

        const Mapping = struct {
            field_name: []const u8,
            config: Config,
        };

        const Parsed = struct {
            allocator: std.mem.Allocator,
            arguments: T,
            positionals: ?[][]const u8 = null,

            pub fn deinit(self: @This()) void {
                if (self.positionals) |positionals| self.allocator.free(positionals);
            }
        };

        allocator: std.mem.Allocator,
        mappings: std.ArrayList(Mapping),

        mapped: std.BufSet,
        required: std.BufSet,

        result: T,
        positionals: ?std.ArrayList([]const u8) = null,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var zlap = Self{
                .mappings = std.ArrayList(Mapping).init(allocator),
                .allocator = allocator,
                .result = undefined,
                .mapped = std.BufSet.init(allocator),
                .required = std.BufSet.init(allocator),
            };

            try zlap.initializeResult();

            return zlap;
        }

        pub fn opt(self: *Self, comptime field_name: []const u8, comptime config: Config) !*Self {
            if (self.mapped.contains(field_name)) {
                return ZlapError.ArgumentDeclaredTwice;
            }

            const mapping = try self.checkMappingInvariants(field_name, config);

            try self.mapped.insert(field_name);
            try self.mappings.append(.{ .field_name = field_name, .config = mapping });

            return self;
        }

        pub fn build(self: *Self, args: [][:0]const u8) !Parsed {
            var i: usize = 1;
            var double_dashed = false;

            var received = std.BufSet.init(self.allocator);
            defer received.deinit();

            while (i < args.len) : (i += 1) {
                if (!double_dashed and args[i].len == 2 and std.mem.eql(u8, args[i], "--")) {
                    double_dashed = true;
                    continue;
                }

                const form: ArgumentForm = switch (double_dashed) {
                    true => .positional,
                    else => if (std.mem.startsWith(u8, args[i], "--")) .long else if (std.mem.startsWith(u8, args[i], "-")) .short else .positional,
                };

                const arg = switch (form) {
                    .long => args[i][2..],
                    .short => args[i][1..],
                    inline else => {
                        try self.parsePositional(args[i]);
                        continue;
                    },
                };

                const mapping = for (self.mappings.items) |mapping| {
                    if (form == .short and mapping.config.short == arg[0]) break mapping;

                    if (mapping.config.long) |long| {
                        if (form == .long and std.mem.eql(u8, long, arg)) break mapping;

                        if (mapping.config._negatable) {
                            if (form == .long and std.mem.eql(u8, long, arg)) break mapping;
                            const negation = try std.mem.concat(self.allocator, u8, &.{ "no-", long });
                            defer self.allocator.free(negation);

                            if (form == .long and mapping.config._negatable and std.mem.eql(u8, negation, arg)) break mapping;
                        }
                    }
                } else return ZlapError.UnsupportedArgument;

                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, field.name, mapping.field_name)) {
                        if (field.type == bool and form == .long) {
                            @field(self.result, field.name) = !std.mem.startsWith(u8, arg, "no-");
                        } else if (field.type == bool and form == .short) {
                            @field(self.result, field.name) = true;
                        } else {
                            if (i + 1 >= args.len) return ZlapError.MissingArgumentValue;

                            const value = args[i + 1];

                            @field(self.result, field.name) = try convertValue(field.type, value);

                            i += 1;
                        }

                        try received.insert(mapping.field_name);
                    }
                }
            }

            try self.checkRequiredArguments(received);

            return .{
                .allocator = self.allocator,
                .arguments = self.result,
                .positionals = if (self.positionals) |*positionals| try positionals.toOwnedSlice() else null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mappings.deinit();
            self.mapped.deinit();
            self.required.deinit();
            if (self.positionals) |*positionals| positionals.deinit();
        }

        inline fn checkFieldType(comptime F: type) !void {
            switch (@typeInfo(F)) {
                .Optional => |optional| try checkFieldType(optional.child),
                .Bool, .Int, .Float => {},
                else => switch (F) {
                    []const u8 => {},
                    else => return ZlapError.InvalidType,
                },
            }
        }

        inline fn convertValue(comptime F: type, value: []const u8) !F {
            return switch (@typeInfo(F)) {
                .Optional => |optional| try convertValue(optional.child, value),
                .Int => try std.fmt.parseInt(F, value, 10),
                .Float => try std.fmt.parseFloat(F, value, 10),
                else => switch (F) {
                    []const u8 => value,
                    else => return error.InvalidArgument,
                },
            };
        }

        fn initializeResult(self: *Self) !void {
            inline for (std.meta.fields(T)) |field| {
                try checkFieldType(field.type);

                if (@typeInfo(field.type) == .Optional) {
                    @field(self.result, field.name) = null;
                    continue;
                }

                if (field.default_value == null) {
                    try self.required.insert(field.name);
                    continue;
                }

                @field(self.result, field.name) = @as(*const field.type, @ptrCast(@alignCast(field.default_value.?))).*;
            }
        }

        fn checkRequiredArguments(self: Self, received: std.BufSet) !void {
            var iter = self.required.iterator();

            while (iter.next()) |required| {
                if (!received.contains(required.*)) return ZlapError.MissingRequiredArgument;
            }
        }

        fn checkMappingInvariants(_: *Self, field_name: []const u8, config: Config) !Config {
            if (config.short == null and config.long == null) return ZlapError.InvalidArgument;

            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    if (field.type == bool) {
                        if (config.long == null and field.default_value != null) {
                            const default: bool = @as(*const bool, @ptrCast(@alignCast(field.default_value.?))).*;

                            if (default == true) return ZlapError.ImmutableBoolean;
                        }

                        return Config{
                            .short = config.short,
                            .long = config.long,
                            ._negatable = true,
                        };
                    }

                    if (config._negatable and field.type != bool) return ZlapError.NonBooleanNegatable;

                    break;
                }
            } else return ZlapError.UnknownStructField;

            return config;
        }

        fn parsePositional(self: *Self, arg: []const u8) !void {
            if (self.positionals == null) {
                self.positionals = std.ArrayList([]const u8).init(self.allocator);
            }

            try self.positionals.?.append(arg);
        }
    };
}
