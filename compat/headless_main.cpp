// headless_main.cpp — Shared entry point for headless solver binaries.
//
// Each solver (belasolv, csolv, hsolv, fkn) defines `void old_main(void*)`
// which does the real work. On Windows the MFC app starts `old_main` on a
// background thread and pumps messages; in headless mode we just call
// `old_main` directly.
//
// Building a solver binary on macOS/Linux:
//   clang++ -std=c++17 -DFEMM_HEADLESS -Icompat \
//       compat/headless_main.cpp <solver>/main.cpp <math.cpp files...> \
//       -o <solver>e
//
// We expose __argc / __argv as globals so that the existing `old_main`
// implementations (which read them for the input path) work unchanged.

#include "mfc_compat.h"
#include "progress.h"
#include <cstdio>
#include <cstdlib>

// MSVC auto-populates __argc/__argv. We do it ourselves.
int __argc = 0;
char** __argv = nullptr;

// Declared by each solver in its own main.cpp. The binary that pulls this
// translation unit in also pulls in that solver's old_main.
extern "C++" void old_main(void* inptr);

// Thin CLI wrapper. Quiet mode suppresses all progress chatter — useful for
// the regression harness where stderr diffs would be noisy.
int main(int argc, char** argv) {
    __argc = argc;
    __argv = argv;

    bool quiet = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--quiet") == 0 || std::strcmp(argv[i], "-q") == 0) {
            quiet = true;
        }
    }

    // Pick reporter. `old_main` calls exit() on every path (success and
    // failure), so we never actually return from it — the reporter is
    // heap-allocated so its dtor order with exit() doesn't matter.
    ProgressReporter* reporter = quiet
        ? static_cast<ProgressReporter*>(new SilentProgress())
        : static_cast<ProgressReporter*>(new StderrProgress());

    old_main(reporter);

    // Should be unreachable — old_main always exit()s. Defensive fallback:
    delete reporter;
    return 0;
}
