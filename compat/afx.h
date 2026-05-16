// Stub for <afx.h> on headless builds.
// Some FEMM headers (e.g. complex.h) include <afx.h> just to get BOOL/TRUE/
// FALSE. Redirect to our compat shim.
#ifndef FEMM_COMPAT_AFX_H
#define FEMM_COMPAT_AFX_H
#include "mfc_compat.h"
#endif
