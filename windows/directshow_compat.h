#pragma once

// The legacy DirectShow BaseClasses still use pre-SAL annotation spellings.
// MSVC provides them, while MinGW's Windows headers intentionally omit them.
// They are annotations only, so defining the missing spellings as empty keeps
// the ABI unchanged and lets the same filter source build in cloud CI.
#ifndef __in
#define __in
#define IPHONE_CAMERA_UNDEF___IN
#endif
#ifndef __in_opt
#define __in_opt
#define IPHONE_CAMERA_UNDEF___IN_OPT
#endif
#ifndef __out
#define __out
#define IPHONE_CAMERA_UNDEF___OUT
#endif
#ifndef __out_opt
#define __out_opt
#define IPHONE_CAMERA_UNDEF___OUT_OPT
#endif
#ifndef __inout
#define __inout
#define IPHONE_CAMERA_UNDEF___INOUT
#endif
#ifndef __inout_opt
#define __inout_opt
#define IPHONE_CAMERA_UNDEF___INOUT_OPT
#endif
#ifndef __deref_in
#define __deref_in
#define IPHONE_CAMERA_UNDEF___DEREF_IN
#endif
#ifndef __deref_inout_opt
#define __deref_inout_opt
#define IPHONE_CAMERA_UNDEF___DEREF_INOUT_OPT
#endif
#ifndef __deref_out
#define __deref_out
#define IPHONE_CAMERA_UNDEF___DEREF_OUT
#endif
#ifndef __deref_out_opt
#define __deref_out_opt
#define IPHONE_CAMERA_UNDEF___DEREF_OUT_OPT
#endif
#ifndef AM_NOVTABLE
#define AM_NOVTABLE
#define IPHONE_CAMERA_UNDEF_AM_NOVTABLE
#endif
