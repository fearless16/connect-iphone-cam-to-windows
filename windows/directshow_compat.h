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
#ifndef __field_ecount_opt
#define __field_ecount_opt(x)
#define IPHONE_CAMERA_UNDEF___FIELD_ECOUNT_OPT
#endif
#ifndef __in_bcount_opt
#define __in_bcount_opt(x)
#define IPHONE_CAMERA_UNDEF___IN_BCOUNT_OPT
#endif
#ifndef __in_bcount
#define __in_bcount(x)
#define IPHONE_CAMERA_UNDEF___IN_BCOUNT
#endif
#ifndef __in_ecount_opt
#define __in_ecount_opt(x)
#define IPHONE_CAMERA_UNDEF___IN_ECOUNT_OPT
#endif
#ifndef __in_ecount
#define __in_ecount(x)
#define IPHONE_CAMERA_UNDEF___IN_ECOUNT
#endif
#ifndef __inout_ecount_full
#define __inout_ecount_full(x)
#define IPHONE_CAMERA_UNDEF___INOUT_ECOUNT_FULL
#endif
#ifndef __out_bcount_part
#define __out_bcount_part(x, y)
#define IPHONE_CAMERA_UNDEF___OUT_BCOUNT_PART
#endif
#ifndef __out_bcount
#define __out_bcount(x)
#define IPHONE_CAMERA_UNDEF___OUT_BCOUNT
#endif
#ifndef __out_ecount_part
#define __out_ecount_part(x, y)
#define IPHONE_CAMERA_UNDEF___OUT_ECOUNT_PART
#endif
#ifndef __out_ecount
#define __out_ecount(x)
#define IPHONE_CAMERA_UNDEF___OUT_ECOUNT
#endif
#ifndef __deref_out_range
#define __deref_out_range(x, y)
#define IPHONE_CAMERA_UNDEF___DEREF_OUT_RANGE
#endif
#ifndef __out_range
#define __out_range(x, y)
#define IPHONE_CAMERA_UNDEF___OUT_RANGE
#endif
#ifndef __range
#define __range(x, y)
#define IPHONE_CAMERA_UNDEF___RANGE
#endif
#ifndef __success
#define __success(x)
#define IPHONE_CAMERA_UNDEF___SUCCESS
#endif
#ifndef __format_string
#define __format_string
#define IPHONE_CAMERA_UNDEF___FORMAT_STRING
#endif
#ifndef __control_entrypoint
#define __control_entrypoint(x)
#define IPHONE_CAMERA_UNDEF___CONTROL_ENTRYPOINT
#endif
#ifndef __analysis_assume
#define __analysis_assume(...)
#define IPHONE_CAMERA_UNDEF___ANALYSIS_ASSUME
#endif
