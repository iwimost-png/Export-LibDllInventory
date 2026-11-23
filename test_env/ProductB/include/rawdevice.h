#pragma once
/*
 * rawdevice.h - デバイス直接制御ユーティリティ
 * ※ 本ファイルにはバージョン定義(#define)や改訂履歴コメントが存在しない
 */

int RawDevice_Control(unsigned int ioctlCode, void* inBuf, unsigned int inSize);
