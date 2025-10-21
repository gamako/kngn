const std = @import("std");

// SwiftのオブジェクトファイルからC関数をインポート
extern "c" fn external_add_swift(a: c_int, b: c_int) c_int;
extern "c" fn external_multiply_swift(a: c_int, b: c_int) c_int;
extern "c" fn external_divide_swift(a: c_int, b: c_int) c_int;

test "external_add_swift basic" {
    const result = external_add_swift(5, 3);
    try std.testing.expectEqual(@as(c_int, 8), result);
}

test "external_add_swift with negative numbers" {
    const result = external_add_swift(-5, 3);
    try std.testing.expectEqual(@as(c_int, -2), result);
}

test "external_add_swift zero" {
    const result = external_add_swift(0, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "external_multiply_swift basic" {
    const result = external_multiply_swift(5, 3);
    try std.testing.expectEqual(@as(c_int, 15), result);
}

test "external_multiply_swift by zero" {
    const result = external_multiply_swift(5, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "external_divide_swift basic" {
    const result = external_divide_swift(15, 3);
    try std.testing.expectEqual(@as(c_int, 5), result);
}

test "external_divide_swift by zero protection" {
    const result = external_divide_swift(15, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}
