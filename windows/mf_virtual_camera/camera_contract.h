#pragma once

#include <guiddef.h>

// This CLSID is the stable activation identity passed to MFCreateVirtualCamera.
// The native COM media-source DLL will register this same CLSID under HKLM.
DEFINE_GUID(CLSID_IPhoneCameraStreamSource,
    0x6A3939D4, 0xC839, 0x4CC3, 0xA9, 0xC7, 0xB0, 0x37, 0x2E, 0x36, 0x80, 0xB3);

inline constexpr wchar_t kIPhoneCameraFriendlyName[] = L"iPhone Camera Stream";
inline constexpr unsigned int kIPhoneCameraWidth = 3840;
inline constexpr unsigned int kIPhoneCameraHeight = 2160;
inline constexpr unsigned int kIPhoneCameraFrameRate = 60;
