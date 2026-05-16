// femm_error.cpp — thread-local last-error string.
#include "femm_doc.hpp"
#include "femm_c.h"

#include <string>

namespace femmcore {
namespace {
thread_local std::string g_last_error;
}

void set_last_error(const std::string& msg) {
    g_last_error = msg;
}

} // namespace femmcore

extern "C" const char* femm_last_error_message(void) {
    return femmcore::g_last_error.empty() ? "" : femmcore::g_last_error.c_str();
}

extern "C" const char* femm_version_string(void) {
    return "libfemm_core 0.1 (phase A)";
}
