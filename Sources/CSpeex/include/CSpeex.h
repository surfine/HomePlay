// SpeexDSP 的 Swift 橋接頭（只用到 echo canceller）。
#include "speex_echo.h"

// Swift 不能呼叫 C 的 variadic speex_echo_ctl；把取樣率設定包成一般函式。
int homeplay_speex_set_rate(SpeexEchoState *st, int rate);
