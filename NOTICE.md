# Notices

This project, macFEMM, is a macOS-native port and rewrite of Finite Element
Method Magnetics (FEMM). It contains original FEMM source code, modified FEMM
source code, and new code written for the macFEMM project.

This notice summarizes provenance and third-party components. It is not a
replacement for the license text in `license.txt`.

## FEMM

Finite Element Method Magnetics (FEMM) is copyright David C. Meeker.

The FEMM portions of this repository are distributed under the Aladdin Free
Public License. The full FEMM license text is included in `license.txt`.

macFEMM modifies and extends FEMM to support a native macOS workflow, including:

- headless native builds of the solver backends
- a small compatibility layer for building solver code outside Windows/MFC
- a portable C/C++ core library and C ABI
- a SwiftUI macOS application
- Python tooling and regression tests for the native solver pipeline

These changes are part of a work derived from FEMM and should be distributed
under the same overall license terms unless a different arrangement is obtained
from the relevant rights holders.

## Triangle

Triangle is copyright Jonathan Richard Shewchuk.

Triangle is used by FEMM and macFEMM for mesh generation. Triangle is not
covered by the FEMM Aladdin Free Public License. Its separate licensing terms
are included in `license.txt` and in the Triangle source files.

Triangle's license contains restrictions on compensation and commercial
distribution. Review the Triangle license before distributing binaries,
including Triangle in another product, or using macFEMM in a commercial
distribution.

## Lua

Lua is copyright TeCGraf, PUC-Rio.

The Lua 4.0 source included in this repository is used by the inherited FEMM
solver code. Lua's license terms are included in `license.txt` and in the Lua
source files.

## macFEMM Contributions

New macFEMM-specific code includes the Swift app, the C/C++ core library, the
macOS build and packaging scripts, the Python `pymacfemm` package, and the
native regression/smoke tests.

Copyright for new macFEMM-specific contributions belongs to their respective
authors. Unless otherwise stated in a file header, these contributions are
distributed as part of the AFPL-licensed macFEMM derivative work.

## Naming

macFEMM is not an official FEMM release and is not affiliated with or endorsed
by the original FEMM project unless explicitly stated by that project.

The FEMM name is used to describe compatibility, provenance, and the origin of
the solver code.
