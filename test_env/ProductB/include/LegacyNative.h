#pragma once
// DLL側にVS_VERSION_INFOリソースが無い場合、ヘッダの #define から抽出されることを確認
// #define LEGACY_NATIVE_VERSION "3.9.9-old"
#define LEGACY_NATIVE_VERSION "4.0.1"

extern "C" __declspec(dllexport) int LegacyNativeInit();