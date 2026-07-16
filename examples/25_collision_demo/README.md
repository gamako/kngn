# 25_collision_demo

`kit.gmath` の AABB / 円衝突判定を使い、固定 60 Hz でボールを四辺の壁と左右の AABB パドルへ反射させるデモです。衝突した tick はボールが赤くなります。

ホットパス宣言: simulation はイベント毎の `pollEvents()` 1 回につき 1 tick、描画はフレーム毎の framebuffer 全画素ループ。gmath は inline・allocation-free・O(1) です。
