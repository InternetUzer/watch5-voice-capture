// Synchronous, per-instance Node-API bridge. Same implementation is tested on Node;
// only module registration and header paths differ on HarmonyOS.
#ifdef WATCH_VAD_HOST_TEST
#include <node_api.h>
#else
#include "napi/native_api.h"
#include "napi/native_node_api.h"
#endif
#include "webrtc/common_audio/vad/include/webrtc_vad.h"
#include <cmath>
#include <cstring>
#include <new>

namespace {
struct Detector {
    VadInst* vad = nullptr;
    ~Detector() { if (vad) WebRtcVad_Free(vad); }
};

napi_value Fail(napi_env env, const char* message)
{
    napi_throw_error(env, nullptr, message);
    return nullptr;
}

bool ReadMode(napi_env env, napi_value value, int* mode)
{
    double number = -1;
    if (!value || napi_get_value_double(env, value, &number) != napi_ok ||
        !std::isfinite(number) || number < 0 || number > 3 || number != std::floor(number)) {
        napi_throw_range_error(env, nullptr, "WebRTC mode must be an integer in 0..3");
        return false;
    }
    *mode = static_cast<int>(number);
    return true;
}

void Finalize(napi_env, void* data, void*) { delete static_cast<Detector*>(data); }

napi_value Construct(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr}, self = nullptr, target = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok ||
        napi_get_new_target(env, info, &target) != napi_ok || !target)
        return Fail(env, "Use new WebRtcVad(mode)");
    int mode;
    if (!ReadMode(env, args[0], &mode)) return nullptr;
    auto* detector = new (std::nothrow) Detector();
    if (!detector) return Fail(env, "Cannot allocate WebRTC VAD");
    detector->vad = WebRtcVad_Create();
    if (!detector->vad || WebRtcVad_Init(detector->vad) != 0 ||
        WebRtcVad_set_mode(detector->vad, mode) != 0) {
        delete detector;
        return Fail(env, "Cannot initialize WebRTC VAD");
    }
    if (napi_wrap(env, self, detector, Finalize, nullptr, nullptr) != napi_ok) {
        delete detector;
        return Fail(env, "Cannot wrap WebRTC VAD");
    }
    return self;
}

Detector* Unwrap(napi_env env, napi_value self)
{
    void* raw = nullptr;
    if (napi_unwrap(env, self, &raw) != napi_ok || !raw) {
        Fail(env, "Invalid WebRTC VAD receiver");
        return nullptr;
    }
    return static_cast<Detector*>(raw);
}

napi_value Process(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr}, self = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok)
        return Fail(env, "Invalid WebRTC call");
    auto* detector = Unwrap(env, self);
    if (!detector) return nullptr;
    if (!detector->vad) return Fail(env, "WebRTC VAD is closed");
    bool isBuffer = false;
    void* data = nullptr;
    size_t bytes = 0;
    if (!args[0] || napi_is_arraybuffer(env, args[0], &isBuffer) != napi_ok || !isBuffer ||
        napi_get_arraybuffer_info(env, args[0], &data, &bytes) != napi_ok || !data || bytes != 640) {
        napi_throw_range_error(env, nullptr, "Expected 640 bytes of PCM16 LE mono at 16000 Hz (20 ms)");
        return nullptr;
    }
    // Copy into aligned stack storage; never retain an ArkTS ArrayBuffer pointer.
    int16_t samples[320];
    std::memcpy(samples, data, sizeof(samples));
    const int decision = WebRtcVad_Process(detector->vad, 16000, samples, 320);
    if (decision < 0) return Fail(env, "WebRTC VAD rejected audio frame");
    napi_value result = nullptr;
    if (napi_get_boolean(env, decision != 0, &result) != napi_ok) return nullptr;
    return result;
}

napi_value Reset(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr}, self = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok)
        return Fail(env, "Invalid WebRTC call");
    auto* detector = Unwrap(env, self);
    if (!detector) return nullptr;
    if (!detector->vad) return Fail(env, "WebRTC VAD is closed");
    int mode;
    if (!ReadMode(env, args[0], &mode)) return nullptr;
    if (WebRtcVad_Init(detector->vad) != 0 || WebRtcVad_set_mode(detector->vad, mode) != 0)
        return Fail(env, "Cannot reset WebRTC VAD");
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Close(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    napi_value self = nullptr;
    if (napi_get_cb_info(env, info, &argc, nullptr, &self, nullptr) != napi_ok)
        return Fail(env, "Invalid WebRTC call");
    auto* detector = Unwrap(env, self);
    if (!detector) return nullptr;
    if (detector->vad) { WebRtcVad_Free(detector->vad); detector->vad = nullptr; }
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"process", nullptr, Process, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reset", nullptr, Reset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_value constructor = nullptr;
    if (napi_define_class(env, "WebRtcVad", NAPI_AUTO_LENGTH, Construct, nullptr,
        sizeof(methods) / sizeof(methods[0]), methods, &constructor) != napi_ok ||
        napi_set_named_property(env, exports, "WebRtcVad", constructor) != napi_ok) return nullptr;
    return exports;
}
} // namespace

#ifdef WATCH_VAD_HOST_TEST
NAPI_MODULE(watchvad, Init)
#else
static napi_module watchVadModule = {
    1, 0, nullptr, Init, "watchvad", nullptr, {0}
};
extern "C" __attribute__((constructor)) void RegisterWatchVadModule()
{
    napi_module_register(&watchVadModule);
}
#endif
