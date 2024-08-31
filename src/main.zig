const std = @import("std");
const vaxis = @import("vaxis");
const gwidth = vaxis.gwidth;

pub const panic = vaxis.panic_handler;

pub const MAX_LOG_MESSAGES: usize = 15;
pub const BORDER_OFFSET: u16 = 2;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    paste: []const u8,
    color_report: vaxis.Color.Report,
    color_scheme: vaxis.Color.Scheme,
    winsize: vaxis.Winsize,
};

const Screen = enum {
    MainMenu,
    NewTask,
    Calender,
};

const MyApp = struct {
    current_screen: Screen = .MainMenu,
    log_buffer: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    mouse: ?vaxis.Mouse,

    pub fn log(self: *MyApp, comptime format: []const u8, args: anytype) !void {
        const log_msg = try std.fmt.allocPrint(self.allocator, format, args);
        try self.log_buffer.append(log_msg);
    }

    pub fn init(allocator: std.mem.Allocator) !MyApp {
        return .{
            .allocator = allocator,
            .log_buffer = std.ArrayList([]const u8).init(allocator),
            .should_quit = false,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .mouse = null,
        };
    }

    pub fn deinit(self: *MyApp) void {
        // Deallocate our logs
        for (self.log_buffer.items) |item| {
            self.allocator.free(item);
        }
        self.log_buffer.deinit();

        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
    }

    pub fn run(self: *MyApp) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        try loop.init();
        try loop.start();
        defer loop.stop();

        try self.vx.enterAltScreen(self.tty.anyWriter());
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(self.tty.anyWriter(), true);

        while (!self.should_quit) {
            loop.pollEvent();

            while (loop.tryEvent()) |event| {
                try self.update(event);
            }

            self.draw();

            var buffered = self.tty.bufferedWriter();

            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }
    }

    pub fn update(self: *MyApp, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.should_quit = true;
                } else if (key.matches('c', .{ .ctrl = false })) {
                    try self.log("Switched from {any} to {any}", .{ self.current_screen, .Calendar });
                    self.current_screen = .Calender;
                } else if (key.matches('n', .{ .ctrl = false })) {
                    try self.log("Switched from {any} to {any}", .{ self.current_screen, .NewTask });
                    self.current_screen = .NewTask;
                } else if (key.matches('m', .{ .ctrl = false })) {
                    try self.log("Switched from {any} to {any}", .{ self.current_screen, .MainMenu });
                    self.current_screen = .MainMenu;
                }
            },
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
            else => {},
        }
    }

    pub fn draw(self: *MyApp) void {
        const msg = "Time CLI";
        const win = self.vx.window();
        win.clear();
        self.vx.setMouseShape(.default);

        if (self.current_screen == .MainMenu) {
            self.drawMainMenu();
        }

        const child = win.child(.{
            .x_off = (win.width / 2) - 7,
            .y_off = win.height / 2 + 1,
            .width = .{ .limit = msg.len },
            .height = .{ .limit = 1 },
        });

        const style: vaxis.Style = if (child.hasMouse(self.mouse)) |_| blk: {
            self.mouse = null;
            self.vx.setMouseShape(.pointer);
            break :blk .{ .reverse = true };
        } else .{};

        self.drawLogs();

        _ = try child.printSegment(.{ .text = msg, .style = style }, .{});
    }

    fn drawMainMenu(self: *MyApp) void {
        const win = self.vx.window();
        const options = [_][]const u8{
            "(N)ew entry",
            "(C)alendar",
        };

        const options_start_y = win.height - BORDER_OFFSET;
        for (options, 0..) |option, i| {
            const option_win = win.child(.{
                .x_off = BORDER_OFFSET,
                .y_off = options_start_y - @as(u16, @intCast(i)) * 1,
                .width = .{ .limit = option.len },
                .height = .{ .limit = 1 },
            });
            _ = option_win.printSegment(.{ .text = option }, .{}) catch {};
        }
    }

    pub fn drawLogs(self: *MyApp) void {
        const win = self.vx.window();
        const win_width: f64 = @floatFromInt(win.width);
        const x_off: usize = @intFromFloat(win_width * 0.2);
        const log_win = win.child(.{
            .x_off = x_off,
            .y_off = win.height - 50,
            .width = .{ .limit = win.width },
            .height = .{ .limit = MAX_LOG_MESSAGES },
        });

        _ = log_win.printSegment(.{ .text = "Logs:", .style = .{ .bold = true } }, .{}) catch {};

        var y: u16 = 1;
        var i: usize = 0;

        while (y < MAX_LOG_MESSAGES and i < self.log_buffer.items.len) : (i += 1) {
            const log_item = self.log_buffer.items[self.log_buffer.items.len - 1 - i];
            const log_child = log_win.child(.{
                .y_off = y,
                .width = .{ .limit = win.width },
                .height = .{ .limit = 1 },
            });

            _ = log_child.printSegment(.{ .text = log_item }, .{}) catch {};
            y += 1;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();

        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    var app = try MyApp.init(allocator);
    defer app.deinit();

    try app.run();
}
