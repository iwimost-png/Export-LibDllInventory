#pragma once
#ifndef EPSILON_AMBIGUOUS_H
#define EPSILON_AMBIGUOUS_H

/*
 * ============================================================================
 * EpsilonAmbiguous Codec Header
 * 改訂履歴 (Revision History) - 昇順・降順が判別不能なケース
 * ----------------------------------------------------------------------------
 * 2025/05/10  Ver 2.1.0  顧客向けカスタムパッチ適用版
 * 2025/08/20  Ver 1.8.0  旧安定版ブランチからのバックポート統合
 * 2025/03/01  Ver 1.9.0  ベースラインリリース
 * ============================================================================
 */

namespace Epsilon {
    int EncodeFrame(const void* src, int size);
}

#endif // EPSILON_AMBIGUOUS_H