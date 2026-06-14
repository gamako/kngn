// Color も libs/font が正準定義する。gui からは再エクスポート（実体・テストは libs/font 側）。
const fnt = @import("font");

pub const Color = fnt.Color;
