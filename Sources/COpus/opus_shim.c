#include "COpus.h"

void homeplay_opus_encoder_settings(OpusEncoder *st, opus_int32 bitrate) {
    opus_encoder_ctl(st, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(st, OPUS_SET_VBR(1));
    opus_encoder_ctl(st, OPUS_SET_COMPLEXITY(10));
    opus_encoder_ctl(st, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}
