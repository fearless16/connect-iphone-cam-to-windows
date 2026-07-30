#pragma once

// The legacy DirectShow BaseClasses still use pre-SAL annotation spellings.
// MSVC provides them, while MinGW's Windows headers intentionally omit them.
// They are annotations only, so defining the missing spellings as empty keeps
// the ABI unchanged and lets the same filter source build in cloud CI.
#ifndef __in
#define __in
#endif
#ifndef __in_opt
#define __in_opt
#endif
#ifndef __out
#define __out
#endif
#ifndef __out_opt
#define __out_opt
#endif
#ifndef __inout
#define __inout
#endif
#ifndef __inout_opt
#define __inout_opt
#endif
#ifndef __deref_in
#define __deref_in
#endif
#ifndef __deref_inout_opt
#define __deref_inout_opt
#endif
#ifndef __deref_out
#define __deref_out
#endif
#ifndef __deref_out_opt
#define __deref_out_opt
#endif
