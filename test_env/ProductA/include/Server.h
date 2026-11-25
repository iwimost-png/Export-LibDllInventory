#pragma once
// パス例: docs/*.h や /* コメント内スラッシュが後続の有効定義を消さないこと
#if 0
#ifdef LEGACY_SERVER_API
#define SERVER_VERSION "0.1.0-nested-disabled"
#endif
#endif

#define SERVER_VERSION "2.7.0"

namespace Server {
    bool Start();
}