// macFEMM modification notice:
// Modified by Linus Meierhoefer <linusmeierhoefer@protonmail.com>
// on 2026-05-16 to support native headless macOS/Linux builds.

// stdafx.h : include file for standard system include files,
//  or project specific include files that are used frequently, but
//      are changed infrequently
//

#ifdef FEMM_HEADLESS
#include "mfc_compat.h"
#else
#define VC_EXTRALEAN // Exclude rarely-used stuff from Windows headers
#define _CRT_SECURE_NO_WARNINGS
#include <afxwin.h> // MFC core and standard components
#include <afxext.h> // MFC extensions
#ifndef _AFX_NO_AFXCMN_SUPPORT
#include <afxcmn.h> // MFC support for Windows 95 Common Controls
#endif // _AFX_NO_AFXCMN_SUPPORT

int MsgBox(PSTR sz, ...);
int MsgBox(CString s);
#endif
