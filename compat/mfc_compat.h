// mfc_compat.h — Minimal shim for the tiny MFC surface the FEMM solvers use.
//
// On Windows, this file is a no-op: it just includes the real MFC headers.
// On Unix (macOS/Linux), it provides just enough of CString, BOOL, and the
// Win32 entry points the solvers touch so that the pure-math .cpp files can
// build without afxwin.h.
//
// Scope is deliberately narrow — only what appears in belasolv/csolv/hsolv/fkn.

#ifndef FEMM_COMPAT_MFC_COMPAT_H
#define FEMM_COMPAT_MFC_COMPAT_H

#if defined(_WIN32) && !defined(FEMM_HEADLESS)

// Native Windows build — keep the original MFC includes exactly as they were.
#define VC_EXTRALEAN
#define _CRT_SECURE_NO_WARNINGS
#include <afxwin.h>
#include <afxext.h>
#ifndef _AFX_NO_AFXCMN_SUPPORT
#include <afxcmn.h>
#endif

#else // Headless / Unix build

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <unistd.h>
#include <strings.h>

#include "progress.h"

// --- Win32 primitive typedefs -------------------------------------------------
// The solvers use BOOL/TRUE/FALSE extensively as a generic tri-ish bool.
#ifndef BOOL
typedef int BOOL;
#endif
#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif
#ifndef NULL
#define NULL 0
#endif

typedef char* PSTR;
typedef const char* LPCSTR;

// MSVC-only fixed-width integer aliases. liblua/complex.h uses __int64.
#ifndef __int64
typedef long long __int64;
#endif
#ifndef __int32
typedef int __int32;
#endif

// --- Sleep(ms) ----------------------------------------------------------------
// Only used by solver as an IPC-timing kludge; map to usleep.
inline void Sleep(unsigned int ms) { ::usleep(static_cast<useconds_t>(ms) * 1000u); }

// --- __argc / __argv ---------------------------------------------------------
// MSVC auto-populates these globals with the process argv. On Unix we provide
// them ourselves; the headless main() fills them in before calling old_main.
extern int __argc;
extern char** __argv;

// --- DeleteFile(path) ---------------------------------------------------------
// Used in ~15 places across the solvers to clean up temp mesh files.
inline BOOL DeleteFile(const char* path) {
    return (std::remove(path) == 0) ? TRUE : FALSE;
}

// --- _strnicmp / _stricmp -----------------------------------------------------
inline int _strnicmp(const char* a, const char* b, size_t n) {
    return strncasecmp(a, b, n);
}
inline int _stricmp(const char* a, const char* b) { return strcasecmp(a, b); }

// --- MSVC minwindef macros ---------------------------------------------------
// `__min` and `__max` are MSVC/Windows extensions used in fkn/prob*.cpp.
#ifndef __min
#define __min(a, b) (((a) < (b)) ? (a) : (b))
#endif
#ifndef __max
#define __max(a, b) (((a) > (b)) ? (a) : (b))
#endif

// --- CString ------------------------------------------------------------------
// The solvers use: default ctor, ctor from const char*, operator=, operator+=,
// GetLength, Left, Mid, Find, Empty, Format, FormatV, implicit conversion to
// const char*. Everything else is out of scope.
class CString {
public:
    CString() = default;
    CString(const char* s) : s_(s ? s : "") {}
    CString(const CString&) = default;
    CString(CString&&) noexcept = default;
    CString& operator=(const CString&) = default;
    CString& operator=(CString&&) noexcept = default;
    CString& operator=(const char* s) { s_ = s ? s : ""; return *this; }

    CString& operator+=(const char* s) { if (s) s_ += s; return *this; }
    CString& operator+=(const CString& o) { s_ += o.s_; return *this; }

    int GetLength() const { return static_cast<int>(s_.size()); }

    CString Left(int n) const {
        if (n < 0) n = 0;
        if (static_cast<size_t>(n) > s_.size()) n = static_cast<int>(s_.size());
        return CString(s_.substr(0, n).c_str());
    }
    CString Mid(int start, int count) const {
        if (start < 0) start = 0;
        if (static_cast<size_t>(start) > s_.size()) return CString("");
        if (count < 0) count = 0;
        return CString(s_.substr(start, count).c_str());
    }
    CString Mid(int start) const {
        if (start < 0) start = 0;
        if (static_cast<size_t>(start) > s_.size()) return CString("");
        return CString(s_.substr(start).c_str());
    }
    // Returns byte offset, -1 if not found. Both overloads seen in the code.
    int Find(char c) const {
        auto pos = s_.find(c);
        return (pos == std::string::npos) ? -1 : static_cast<int>(pos);
    }
    int Find(const char* sub) const {
        if (!sub) return -1;
        auto pos = s_.find(sub);
        return (pos == std::string::npos) ? -1 : static_cast<int>(pos);
    }
    // Searches from the right end; returns byte offset or -1.
    int ReverseFind(char c) const {
        auto pos = s_.rfind(c);
        return (pos == std::string::npos) ? -1 : static_cast<int>(pos);
    }

    void Empty() { s_.clear(); }

    // MFC-style printf formatting. The solvers pass narrow strings only.
    void Format(const char* fmt, ...) {
        va_list args;
        va_start(args, fmt);
        FormatV(fmt, args);
        va_end(args);
    }
    void FormatV(const char* fmt, va_list args) {
        va_list copy;
        va_copy(copy, args);
        int needed = vsnprintf(nullptr, 0, fmt, copy);
        va_end(copy);
        if (needed < 0) { s_.clear(); return; }
        s_.assign(static_cast<size_t>(needed), '\0');
        vsnprintf(s_.data(), static_cast<size_t>(needed) + 1, fmt, args);
    }

    // Implicit decay to const char* — matches MFC behavior used by fopen etc.
    operator const char*() const { return s_.c_str(); }
    const char* c_str() const { return s_.c_str(); }

private:
    std::string s_;
};

inline CString operator+(const CString& a, const CString& b) {
    CString r = a;
    r += b;
    return r;
}
inline CString operator+(const CString& a, const char* b) {
    CString r = a;
    r += b;
    return r;
}

// --- MsgBox -------------------------------------------------------------------
// Original: popped up an AfxMessageBox on Windows. Headless version just writes
// to stderr so errors are visible in terminals and log files.
inline int MsgBox(const CString& s) {
    std::fprintf(stderr, "%s\n", static_cast<const char*>(s));
    return 1; // IDOK
}
inline int MsgBox(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    va_end(args);
    std::fputc('\n', stderr);
    return 1;
}

// --- Dialog class aliases -----------------------------------------------------
// The math code in each solver declares `CxxxDlg* TheView;` as a member, and
// the per-solver main.cpp passes a dialog pointer down. To avoid editing every
// math header, we alias each dialog class name to ProgressReporter.
//
// On Windows the originals are full MFC classes. In headless mode we treat
// them as identical to ProgressReporter — the math only ever calls
// setStatus/setFrame/setProgress through TheView (after the Phase 2 sweep).
typedef ProgressReporter CbelasolvDlg;
typedef ProgressReporter CcsolvDlg;
typedef ProgressReporter ChsolvDlg;
typedef ProgressReporter CFknDlg;

#endif // _WIN32 / headless

#endif // FEMM_COMPAT_MFC_COMPAT_H
