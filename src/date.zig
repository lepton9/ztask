const std = @import("std");

pub const DateTime = struct {
    date: Date,
    time: Time,

    pub fn fmt(self: DateTime, buf: []u8) ![]u8 {
        const d = self.date;
        const t = self.time;
        return try std.fmt.bufPrint(
            buf,
            "{d}-{d:0>2}-{d} {d}:{d}:{d}",
            .{ d.year, d.month, d.day, t.h, t.min, t.sec },
        );
    }
};

pub const Date = struct {
    year: u16,
    month: u4,
    day: u5,
};

pub const Time = struct {
    h: u5,
    min: u6,
    sec: u6,
    ms: u30 = 0,
};

/// Check if the year is a leap year
fn isLeapYear(year: u32) bool {
    return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
}

/// Calculate the amount of days in the month
/// Counts for leap years
fn daysInMonth(month: u8, year: u32) u5 {
    const days_in_month = [_]u5{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const max_days = days_in_month[month - 1];
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else max_days,
        else => max_days,
    };
}

/// Convert timestamp in seconds to datetime
pub fn timestampToDateTime(timestamp_s: u64) DateTime {
    const timestamp_ms = timestamp_s * std.time.ms_per_s;
    return milliTsToDateTime(timestamp_ms);
}

/// Convert timestamp in milliseconds to datetime
pub fn milliTsToDateTime(timestamp_ms: u64) DateTime {
    const seconds = @divTrunc(timestamp_ms, std.time.ms_per_s);

    // Calculate time
    const time: Time = .{
        .h = @intCast(@divTrunc(@rem(seconds, std.time.s_per_day), std.time.s_per_hour)),
        .min = @intCast(@divTrunc(@rem(seconds, std.time.s_per_hour), std.time.s_per_min)),
        .sec = @intCast(@rem(seconds, std.time.s_per_min)),
        .ms = @intCast(@rem(timestamp_ms, std.time.ms_per_s)),
    };

    var days = @divTrunc(seconds, std.time.s_per_day);

    // Calculate year
    var year: u16 = 1970;
    while (true) {
        const days_in_year: u16 = if (isLeapYear(year)) 366 else 365;
        if (days >= days_in_year) {
            days -= days_in_year;
            year += 1;
        } else break;
    }

    // Calculate month
    var month: u4 = 1;
    while (true) {
        const day_of_month = daysInMonth(month, year);
        if (days >= day_of_month) {
            days -= day_of_month;
            month += 1;
        } else break;
    }

    const day: u5 = @intCast(days + 1);
    const date: Date = .{
        .year = year,
        .month = month,
        .day = day,
    };
    return DateTime{ .date = date, .time = time };
}
