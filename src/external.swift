// Swift実装ファイル
// @_cdecl属性を使ってC ABI互換の関数をエクスポート
// 条件分岐を避けてSwiftランタイム依存を最小化

@_cdecl("external_add_swift")
public func externalAddSwift(_ a: Int32, _ b: Int32) -> Int32 {
    return a + b
}

@_cdecl("external_multiply_swift")
public func externalMultiplySwift(_ a: Int32, _ b: Int32) -> Int32 {
    return a * b
}

@_cdecl("external_divide_swift")
public func externalDivideSwift(_ a: Int32, _ b: Int32) -> Int32 {
    // 0で除算する場合、結果は0とする（三項演算子を避けてランタイム依存を最小化）
    let result = Int32(truncatingIfNeeded: Int64(a) / Int64(b == 0 ? 1 : b))
    return b == 0 ? 0 : result
}
