/*
 * sal_shim.h — minimal SAL annotation shim.
 *
 * Microsoft's DirectShow BaseClasses (wxutil.h, combase.h) are written for
 * MSVC and rely on SAL annotations (__in, __out, __deref_in, __drv_*...).
 * MinGW-w64 does not define these, so we neutralise them. This file is only
 * injected on MinGW builds via -include; MSVC provides the real sal.h.
 */
#ifndef SAL_SHIM_H
#define SAL_SHIM_H

/* Object-like annotations -> nothing */
#define __in
#define __out
#define __inout
#define __in_opt
#define __out_opt
#define __inout_opt
#define __deref_in
#define __deref_out
#define __deref_inout
#define __deref_in_opt
#define __deref_out_opt
#define __deref_inout_opt
#define __deref_opt_in
#define __deref_opt_out
#define __deref_opt_inout
#define __deref_opt_in_opt
#define __deref_opt_out_opt
#define __deref_opt_inout_opt
#define __field_nullterminated
#define __field_ecount(x)
#define __field_xcount(x)
#define __field_range(a, b)
#define __field_bcount(x)
#define __field_ecount_opt(x)
#define __field_bcount_opt(x)
#define __range(a, b)
#define __success(x)
#define __null
#define __notnull
#define __maybenull
#define __reserved
#define __checkReturn
#define __callback
#define __nullterminated
#define __ecount(x)
#define __bcount(x)
#define __xcount(x)
#define __deref
#define __in_z
#define __struct_bcount(x)

/* Counted / partial buffer annotations -> nothing */
#define __in_bcount(x)
#define __in_ecount(x)
#define __in_ecount_z(x)
#define __out_bcount(x)
#define __out_ecount(x)
#define __out_opt_bcount(x)
#define __out_opt_ecount(x)
#define __inout_bcount(x)
#define __inout_ecount(x)
#define __inout_opt_bcount(x)
#define __inout_opt_ecount(x)
#define __in_opt_bcount(x)
#define __in_opt_ecount(x)
#define __deref_out_opt_bcount(x)
#define __deref_out_opt_ecount(x)
#define __deref_inout_opt_bcount(x)
#define __deref_inout_opt_ecount(x)
#define __out_ecount_part(x, y)
#define __out_bcount_part(x, y)
#define __in_ecount_part(x, y)
#define __in_bcount_part(x, y)
#define __inout_ecount_part(x, y)
#define __inout_bcount_part(x, y)
#define __deref_out_ecount_part(x, y)
#define __deref_out_bcount_part(x, y)
#define __deref_inout_ecount_part(x, y)
#define __deref_inout_bcount_part(x, y)
#define __deref_opt_out_ecount_part(x, y)
#define __deref_opt_out_bcount_part(x, y)
#define __out_opt_ecount_part(x, y)
#define __out_opt_bcount_part(x, y)
#define __in_opt_ecount_part(x, y)
#define __in_opt_bcount_part(x, y)
#define __in_awcount(a, b)
#define __out_awcount(a, b)
#define __inout_awcount(a, b)
#define __deref_out_awcount(a, b)
#define __deref_opt_out_awcount(a, b)
#define __deref_inout_awcount(a, b)
#define __deref_opt_inout_awcount(a, b)

/* Function-like PreFast / driver annotations -> nothing */
#define __drv_maxIRQL(...)
#define __drv_minIRQL(...)
#define __drv_satisfied(...)
#define __drv_when(...)
#define __drv_valueIs(...)
#define __drv_allocatesMem(...)
#define __drv_freesMem(...)
#define __drv_aliasesMem(...)
#define __drv_never(...)
#define __drv_mustHold(...)
#define __drv_mayHold(...)
#define __drv_release(...)
#define __drv_bcount(...)
#define __drv_out_saves(...)
#define __drv_formatString(...)
#define __drv_ts(...)
#define __drv_mustBe(...)
#define __drv_reportError(...)
#define __drv_saveFile(...)
#define __drv_validatesIRQL(...)
#define __drv_preferredUse(...)
#define __drv_requiresIRQL(...)
#define __drv_satisfiesIRQL(...)
#define __drv_neverHold(...)
#define __drv_sameIRQL(...)
#define __drv_minFunctionIRQL(...)
#define __drv_passesIRQL(...)
#define __drv_validatesHandle(...)
#define __drv_validHandle(...)
#define __drv_validatesObject(...)
#define __drv_validObject(...)
#define __drv_isObject(...)
#define __drv_setISO(...)
#define __drv_in(...)
#define __drv_out(...)
#define __drv_inout(...)

/* Static-analysis only */
#define __analysis_assume(...)
#define __analysis_assert(...)
#define __analysis_noreturn
#define __annotation(...)
#define __increment
#define __decrement
#define __post

/* SAL 2.0 style (in case BaseClasses is a newer drop) */
#ifndef _In_
#define _In_
#define _Out_
#define _Inout_
#define _In_opt_
#define _Out_opt_
#define _Inout_opt_
#define _In_reads_(x)
#define _In_reads_bytes_(x)
#define _In_reads_opt_(x)
#define _Out_writes_(x)
#define _Out_writes_bytes_(x)
#define _Out_writes_opt_(x)
#define _Inout_updates_(x)
#define _Inout_updates_bytes_(x)
#define _Inout_updates_opt_(x)
#define _Outptr_
#define _Outptr_opt_
#define _Outptr_result_maybenull_
#define _Outptr_opt_result_maybenull_
#define _Success_(x)
#define _Check_return_
#define _Must_inspect_result_
#define _Null_terminated_
#define _Reserved_
#define _Inout_updates_bytes_to_(x, y)
#define _Out_writes_bytes_to_(x, y)
#define _In_reads_bytes_to_(x, y)
#endif

#endif /* SAL_SHIM_H */
