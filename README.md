# macFEMM

<img src="mac/Sources/macFEMM/Resources/macFEMM.png" alt="macFEMM logo" width="128">

macFEMM is a native macOS port and rewrite of
[Finite Element Method Magnetics](https://www.femm.info/) (FEMM).

The goal is to keep FEMM's file formats and solver behavior while replacing the
Windows/MFC application layer with a portable solver pipeline and a SwiftUI
macOS app.

macFEMM is not an official FEMM release. It is a derived project based on FEMM
4.2 and still carries FEMM's licensing and provenance requirements.

## What It Does

macFEMM solves 2D planar and axisymmetric finite-element problems for:

- magnetics
- electrostatics
- heat flow
- current flow

macFEMM ships with a Swift app that can create and open FEMM problem files, edit geometry and
properties, run the solver, inspect results, draw density/contour/vector plots,
query field values, and evaluate supported line and block integrals.

## Requirements

On macOS:

- Xcode command line tools
- Swift 5.9 or newer
- `clang` / `clang++`
- `uv`, if you want to run the Python smoke tests through the locked
  environment


## Build

From the repository root, build the native solvers, Triangle, Lua, and
`libfemm_core`:

```sh
./build_macos.sh
```

Build the Swift app:

```sh
cd mac
swift build
```

To package a local `.app` bundle from the repository root:

```sh
./mac/pack_app.sh release
```

The pack script currently writes:

```text
mac/macFEMM.app
```

## Run

After packaging:

```sh
open mac/macFEMM.app
```

For development builds, `swift run` from `mac/` also works, provided the solver
binaries have already been built with `./build_macos.sh`.

## Test

Run the native core smoke test:

```sh
build/libfemm_core/femm_cli_smoke
```

Run the integral verification test:

```sh
build/libfemm_core/femm_cli_integrals
```

Run the Python end-to-end smoke test:

```sh
uv run python tests/smoke_e2e.py
```

The Python smoke test builds and solves one problem for each physics type and
writes result images under `tests/out/`.

An `examples/` directory is planned. Once examples are added, they should cover
small, complete problems that can be opened in the app and reproduced from the
Python API.

## Python API

The `pymacfemm` package provides a scriptable interface for constructing FEMM
problems, writing problem files, running the native solvers, and reading result
files.

Typical usage looks like:

```python
from pymacfemm import MagneticsProblem, read_magnetics

p = MagneticsProblem()
p.mi_probdef(units="millimeters", problem_type="planar")
p.mi_add_material("air", mu_x=1.0, mu_y=1.0)

# add geometry, labels, and boundary conditions

result_path = p.mi_analyze("example")
result = read_magnetics(result_path)
```

See `examples/` for more test-cases.


## License And Provenance

macFEMM is based on FEMM 4.2 by David C. Meeker. FEMM is distributed under the
Aladdin Free Public License. The full license text is included in
`license.txt`.

Triangle and Lua are included under their own licensing terms, also reproduced
in `license.txt`.

See `NOTICE.md` for attribution and third-party notices.

Because this project contains modified FEMM source code, the repository should
be treated as a derivative work of FEMM. Do not assume that the project can be
relicensed under MIT, Apache, GPL, or another common open-source license.
