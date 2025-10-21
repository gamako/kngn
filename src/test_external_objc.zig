const std = @import("std");

// Objective-CのオブジェクトファイルからC関数をインポート
extern "c" fn external_add_objc(a: c_int, b: c_int) c_int;
extern "c" fn external_multiply_objc(a: c_int, b: c_int) c_int;
extern "c" fn external_divide_objc(a: c_int, b: c_int) c_int;

test "external_add_objc basic" {
    const result = external_add_objc(5, 3);
    try std.testing.expectEqual(@as(c_int, 8), result);
}

test "external_add_objc with negative numbers" {
    const result = external_add_objc(-5, 3);
    try std.testing.expectEqual(@as(c_int, -2), result);
}

test "external_add_objc zero" {
    const result = external_add_objc(0, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "external_multiply_objc basic" {
    const result = external_multiply_objc(5, 3);
    try std.testing.expectEqual(@as(c_int, 15), result);
}

test "external_multiply_objc by zero" {
    const result = external_multiply_objc(5, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "external_divide_objc basic" {
    const result = external_divide_objc(15, 3);
    try std.testing.expectEqual(@as(c_int, 5), result);
}

test "external_divide_objc by zero protection" {
    const result = external_divide_objc(15, 0);
    try std.testing.expectEqual(@as(c_int, 0), result);
}
