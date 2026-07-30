// Windows 11 Media Foundation virtual-camera controller. This executable owns
// virtual-camera registration/lifetime only; frame delivery lives in the COM
// media-source DLL identified by CLSID_IPhoneCameraStreamSource.

#include <windows.h>
#include <mfapi.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksmedia.h>
#include <cstdio>
#include <iterator>
#include <string>

#include "camera_contract.h"

static std::wstring hresult_text(HRESULT hr) {
    wchar_t *message = nullptr;
    const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                        FORMAT_MESSAGE_IGNORE_INSERTS;
    const DWORD count = FormatMessageW(flags, nullptr, static_cast<DWORD>(hr), 0,
                                       reinterpret_cast<wchar_t *>(&message), 0, nullptr);
    std::wstring result = count ? std::wstring(message, count) : L"unknown error";
    if (message) LocalFree(message);
    return result;
}

static int fail(const wchar_t *operation, HRESULT hr) {
    std::fwprintf(stderr, L"ERROR: %ls failed: 0x%08X (%ls)\n", operation,
                  static_cast<unsigned int>(hr), hresult_text(hr).c_str());
    return 1;
}

int wmain(int argc, wchar_t **argv) {
    const bool remove = argc == 2 && std::wstring(argv[1]) == L"--remove";
    if (argc > 2 || (argc == 2 && !remove)) {
        std::fwprintf(stderr, L"Usage: IPhoneCameraVcamController.exe [--remove]\n");
        return 2;
    }

    HRESULT hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) return fail(L"MFStartup", hr);

    wchar_t sourceId[64]{};
    if (StringFromGUID2(CLSID_IPhoneCameraStreamSource, sourceId,
                        static_cast<int>(std::size(sourceId))) == 0) {
        MFShutdown();
        std::fputs("ERROR: source CLSID formatting failed\n", stderr);
        return 1;
    }

    const GUID categories[] = { KSCATEGORY_VIDEO_CAMERA, KSCATEGORY_VIDEO, KSCATEGORY_CAPTURE };
    IMFVirtualCamera *camera = nullptr;
    hr = MFCreateVirtualCamera(MFVirtualCameraType_SoftwareCameraSource,
                               MFVirtualCameraLifetime_System,
                               MFVirtualCameraAccess_CurrentUser,
                               kIPhoneCameraFriendlyName,
                               sourceId,
                               categories,
                               static_cast<ULONG>(std::size(categories)),
                               &camera);
    if (FAILED(hr)) {
        MFShutdown();
        return fail(L"MFCreateVirtualCamera", hr);
    }

    hr = remove ? camera->Remove() : camera->Start(nullptr);
    camera->Release();
    MFShutdown();
    if (FAILED(hr)) return fail(remove ? L"IMFVirtualCamera::Remove" : L"IMFVirtualCamera::Start", hr);

    std::wprintf(remove ? L"iPhone Camera Stream removed\n" :
                           L"iPhone Camera Stream registered; select it in OBS after source DLL installation.\n");
    return 0;
}
