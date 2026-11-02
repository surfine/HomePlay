// libopus 的 Swift 橋接頭。標頭隨專案一起帶，連結時用 Homebrew 的 libopus.a。
#include "opus.h"

// Swift 不能呼叫 C 的 variadic opus_encoder_ctl；把要調的參數包成一般函式。
void homeplay_opus_encoder_settings(OpusEncoder *st, opus_int32 bitrate);
