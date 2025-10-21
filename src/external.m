// Objective-C実装ファイル
// C ABI互換の関数をエクスポート

int external_add_objc(int a, int b) {
    return a + b;
}

int external_multiply_objc(int a, int b) {
    return a * b;
}

int external_divide_objc(int a, int b) {
    if (b == 0) {
        return 0;
    }
    return a / b;
}
