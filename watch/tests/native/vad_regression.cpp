#include "webrtc/common_audio/vad/include/webrtc_vad.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#include <cstring>

int main(int argc, char** argv)
{
    if (argc != 2) return 2;
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<char> raw((std::istreambuf_iterator<char>(input)), {});
    const char* expected[] = {
        "011110111111111111111111111100",
        "011110111111111111111111111100",
        "000000111111111111111111110000",
        "000000111111111111111100000000"
    };
    if (raw.size() < 28 * 480) return 3;
    for (int mode = 0; mode < 4; ++mode) {
        VadInst* vad = WebRtcVad_Create();
        if (!vad || WebRtcVad_Init(vad) || WebRtcVad_set_mode(vad, mode)) return 4;
        std::string actual;
        for (size_t offset = 0; offset + 480 <= raw.size(); offset += 480) {
            int16_t samples[240];
            std::memcpy(samples, raw.data() + offset, 480);
            const int result = WebRtcVad_Process(vad, 8000, samples, 240);
            if (result < 0) return 5;
            actual += result ? '1' : '0';
        }
        WebRtcVad_Free(vad);
        if (actual != expected[mode]) {
            std::cerr << "mode " << mode << ": " << actual << " != " << expected[mode] << '\n';
            return 6;
        }
    }
    std::cout << "WebRTC upstream audio: all four mode decisions match\n";
}
