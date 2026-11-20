#pragma once
#ifndef ALPHA_DEF_H
#define ALPHA_DEF_H

// 単一行コメントアウトされたダミー定義（抽出されてはならない）
// #define ALPHA_VERSION "0.8.0-commented"

/*
 * 複数行ブロックコメント内のダミー定義（抽出されてはならない）
 * #define ALPHA_VERSION "0.9.0-block-comment"
 */

#if 0
#define ALPHA_VERSION "0.9.5-disabled-block"
#endif

/*
 * 改訂履歴（#define の方が優先されることを確認するための古い履歴）
 * 2025/01/10 Ver 1.3.0 内部リファクタリング
 * 2024/06/01 Ver 1.2.0 初期リリース
 */

// 有効なバージョン定義（期待抽出値: 1.4.2）
#define ALPHA_VERSION "1.4.2"

namespace Alpha {
    int InitializeAlpha();
}

#endif // ALPHA_DEF_H