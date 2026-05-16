// Stub for <malloc.h> on headless builds.
// Linux/Windows provide <malloc.h> with calloc/free prototypes. On macOS
// these live in <stdlib.h>. Redirect here so the solvers' original
// #include <malloc.h> keeps working without edits.
#ifndef FEMM_COMPAT_MALLOC_H
#define FEMM_COMPAT_MALLOC_H
#include <stdlib.h>
#endif
