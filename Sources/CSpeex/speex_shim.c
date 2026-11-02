#include "CSpeex.h"

int homeplay_speex_set_rate(SpeexEchoState *st, int rate) {
    return speex_echo_ctl(st, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);
}
