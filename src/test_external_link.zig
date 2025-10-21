const std = @import("std");

// 外部オブジェクトファイルからC関数をインポート
extern "c" fn external_add(a: c_int, b: c_int) c_int;
extern "c" fn external_multiply(a: c_int, b: c_int) c_int;
extern "c" fn external_divide(a: c_int, b: c_int) c_int;

test "external_add basic" {
    const result = external_add(5, 3);
    try std.testing.expectEqual(@as(c_int, 8), result);
}

test "external_add with negative numbers" {
    const result = external_add(-5, 3);
    try std.testing.expectEqual(@as(c_int, -2), result);
}

test "external_add zero" {
    const result = external_add(0, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "external_multiply basic" {
    const result = external_multiply(5, 3);
    try std.testing.expectEqual(@as(c_int, 15), result);
}

test "external_multiply by zero" {
    const result = external_multiply(5, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "external_divide basic" {
    const result = external_divide(15, 3);
    try std.testing.expectEqual(@as(c_int, 5), result);
}

test "external_divide by zero protection" {
    const result = external_divide(15, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}
