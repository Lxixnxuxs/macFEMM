// progress.h — Abstraction for the solver progress UI.
//
// The Windows build of each solver drives a modal MFC dialog with a status
// line, a frame/heading label, a stats pane, and one or two progress bars.
// The math layer touches the dialog at ~30 call sites spread across four
// solvers, using patterns like:
//
//   TheView->SetDlgItemText(IDC_FRAME1, "Matrix Construction");
//   TheView->m_prog1.SetPos(n);
//   TheView->InvalidateRect(NULL, FALSE);
//   TheView->UpdateWindow();
//
// To avoid editing every call site, ProgressReporter is *shaped like* the MFC
// dialog: it exposes the same method names and the same m_prog1/m_prog2
// fields. The math code therefore compiles unchanged on headless builds, and
// the real MFC dialog is still used on Windows non-headless builds.
//
// Two concrete implementations:
//   StderrProgress — prints status updates to stderr (useful for humans).
//   SilentProgress — no-op (useful for regression tests and scripts).

#ifndef FEMM_COMPAT_PROGRESS_H
#define FEMM_COMPAT_PROGRESS_H

#include <cstdio>

// --- Fake dialog control IDs --------------------------------------------------
// The real values don't matter here — the math never reads them back, it just
// passes one of these into SetDlgItemText to pick which label to update. We
// give each a unique sentinel so ProgressReporter can dispatch correctly.
#ifndef IDC_FRAME1
#define IDC_FRAME1        1001
#endif
#ifndef IDC_FRAME2
#define IDC_FRAME2        1002
#endif
#ifndef IDC_STATUSWINDOW
#define IDC_STATUSWINDOW  1003
#endif
#ifndef IDC_PROBSTATS
#define IDC_PROBSTATS     1004
#endif

struct ProgressReporter;

// Mimics CProgressCtrl. Holds a pointer back to its owner so SetPos can route
// to setPrimaryProgress / setSecondaryProgress without the math knowing.
struct FakeProgressCtrl {
    ProgressReporter* owner = nullptr;
    int slot = 0; // 0 = primary, 1 = secondary
    inline void SetPos(int n);
};

struct ProgressReporter {
    FakeProgressCtrl m_prog1;
    FakeProgressCtrl m_prog2;
    void* m_hWnd = nullptr; // sentinel for IsWindow() spin-wait in main.cpp

    ProgressReporter() {
        m_prog1.owner = this; m_prog1.slot = 0;
        m_prog2.owner = this; m_prog2.slot = 1;
    }
    virtual ~ProgressReporter() = default;

    // --- Hooks for subclasses ------------------------------------------------
    virtual void setStatus(const char* /*s*/) {}
    virtual void setFrame(const char* /*s*/) {}
    virtual void setStats(const char* /*s*/) {}
    virtual void setTitle(const char* /*s*/) {}
    virtual void setPrimaryProgress(int /*percent*/) {}
    virtual void setSecondaryProgress(int /*percent*/) {}

    // Generic helper used by headless main.cpp files (maps to primary bar).
    void setProgress(int percent) { setPrimaryProgress(percent); }

    // --- MFC-shaped surface used directly by the math ------------------------
    void SetDlgItemText(int id, const char* s) {
        switch (id) {
            case IDC_FRAME1:       setFrame(s); break;
            case IDC_FRAME2:       setStats(s); break;
            case IDC_STATUSWINDOW: setStatus(s); break;
            case IDC_PROBSTATS:    setStats(s); break;
            default:               setStatus(s); break;
        }
    }
    void SetWindowText(const char* s) { setTitle(s); }

    // Called by the math after updating a progress value. On Windows these
    // kick the dialog to repaint; in headless builds they do nothing.
    void InvalidateRect(void* /*rect*/, int /*erase*/) {}
    void UpdateWindow() {}
};

inline void FakeProgressCtrl::SetPos(int n) {
    if (!owner) return;
    if (slot == 0) owner->setPrimaryProgress(n);
    else           owner->setSecondaryProgress(n);
}

// IsWindow(TheView->m_hWnd) appears in the main.cpp files as a spin-wait for
// the dialog to become visible. In headless mode the "dialog" is always ready.
// We supply a dummy m_hWnd member and a matching IsWindow() free function.
//
// These live alongside ProgressReporter because we want them only in headless
// builds — the real MFC provides its own ::IsWindow and HWND.
#ifdef FEMM_HEADLESS
typedef void* HWND;
inline bool IsWindow(HWND /*h*/) { return true; }
#endif

struct StderrProgress : ProgressReporter {
    void setStatus(const char* s) override {
        std::fprintf(stderr, "[status] %s\n", s ? s : "");
    }
    void setFrame(const char* s) override {
        std::fprintf(stderr, "[phase]  %s\n", s ? s : "");
    }
    void setStats(const char* s) override {
        std::fprintf(stderr, "[stats]  %s\n", s ? s : "");
    }
    void setTitle(const char* s) override {
        std::fprintf(stderr, "[title]  %s\n", s ? s : "");
    }
    void setPrimaryProgress(int percent) override {
        std::fprintf(stderr, "\r[%3d%%]", percent);
        if (percent >= 100) std::fputc('\n', stderr);
        std::fflush(stderr);
    }
    void setSecondaryProgress(int /*percent*/) override {
        // Secondary bar chatter is suppressed by default.
    }
};

struct SilentProgress : ProgressReporter {};

#endif // FEMM_COMPAT_PROGRESS_H
