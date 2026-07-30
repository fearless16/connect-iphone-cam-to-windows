#!/usr/bin/env sh
set -eu

source_file="$1"

# Keep non-buildable platform contracts checked in CI too. CSourceStream's
# Active/Inactive methods are non-virtual in the BaseClasses used by CI.
grep -q 'OnThreadCreate() override' "$source_file"
grep -q 'OnThreadDestroy() override' "$source_file"
! grep -q 'Active() override' "$source_file"
! grep -q 'Inactive() override' "$source_file"
grep -q 'AMovieDllRegisterServer2(TRUE)' "$source_file"
grep -q 'AMovieDllRegisterServer2(FALSE)' "$source_file"
grep -q 'CLSID_VideoInputDeviceCategory' "$source_file"
grep -q 'REFERENCE_TIME endTime' "$source_file"
grep -q 'makeFilterRegistration' "$source_file"
grep -q 'directshow_compat.h' "$source_file"
grep -q 'directshow_compat_cleanup.h' "$source_file"
grep -q 'IPHONE_CAMERA_UNDEF___OUT' windows/directshow_compat.h
