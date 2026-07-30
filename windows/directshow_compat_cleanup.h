#pragma once

// Do not leak DirectShow's legacy SAL spellings into libstdc++: identifiers
// such as __out are used internally by GCC's standard library.
#ifdef IPHONE_CAMERA_UNDEF___IN
#undef __in
#undef IPHONE_CAMERA_UNDEF___IN
#endif
#ifdef IPHONE_CAMERA_UNDEF___IN_OPT
#undef __in_opt
#undef IPHONE_CAMERA_UNDEF___IN_OPT
#endif
#ifdef IPHONE_CAMERA_UNDEF___OUT
#undef __out
#undef IPHONE_CAMERA_UNDEF___OUT
#endif
#ifdef IPHONE_CAMERA_UNDEF___OUT_OPT
#undef __out_opt
#undef IPHONE_CAMERA_UNDEF___OUT_OPT
#endif
#ifdef IPHONE_CAMERA_UNDEF___INOUT
#undef __inout
#undef IPHONE_CAMERA_UNDEF___INOUT
#endif
#ifdef IPHONE_CAMERA_UNDEF___INOUT_OPT
#undef __inout_opt
#undef IPHONE_CAMERA_UNDEF___INOUT_OPT
#endif
#ifdef IPHONE_CAMERA_UNDEF___DEREF_IN
#undef __deref_in
#undef IPHONE_CAMERA_UNDEF___DEREF_IN
#endif
#ifdef IPHONE_CAMERA_UNDEF___DEREF_INOUT_OPT
#undef __deref_inout_opt
#undef IPHONE_CAMERA_UNDEF___DEREF_INOUT_OPT
#endif
#ifdef IPHONE_CAMERA_UNDEF___DEREF_OUT
#undef __deref_out
#undef IPHONE_CAMERA_UNDEF___DEREF_OUT
#endif
#ifdef IPHONE_CAMERA_UNDEF___DEREF_OUT_OPT
#undef __deref_out_opt
#undef IPHONE_CAMERA_UNDEF___DEREF_OUT_OPT
#endif
#ifdef IPHONE_CAMERA_UNDEF_AM_NOVTABLE
#undef AM_NOVTABLE
#undef IPHONE_CAMERA_UNDEF_AM_NOVTABLE
#endif
