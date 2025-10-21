// 外部コンパイル用のC関数
// これはclangで.oファイルとしてコンパイルされる

int external_add(int a, int b) {
    return a + b;
}

int external_multiply(int a, int b) {
    return a * b;
}

int external_divide(int a, int b) {
    if (b == 0) {
        return 0;
    }
    return a / b;
}
