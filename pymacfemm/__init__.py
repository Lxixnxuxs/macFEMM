"""pymacfemm — native macOS/Linux driver for FEMM 4.2 solvers.

Four physics modules mirror FEMM's Lua/pyfemm surface:
  * magnetics        (mi_*)  — .fem → fknsolve → .ans
  * electrostatics   (ei_*)  — .fee → belasolve → .res
  * heat             (hi_*)  — .feh → hsolve   → .anh
  * current          (ci_*)  — .fec → csolve   → .res

Top level re-exports the four Problem classes and the solver-locator helper.
"""

from .magnetics import MagneticsProblem
from .electrostatics import ElectrostaticsProblem
from .heat import HeatProblem
from .current import CurrentProblem
from .solver import find_binary, run_triangle, run_solver
from .ans_reader import (
    read_electrostatics,
    read_heat,
    read_current,
    read_magnetics,
)

__all__ = [
    "MagneticsProblem",
    "ElectrostaticsProblem",
    "HeatProblem",
    "CurrentProblem",
    "find_binary",
    "run_triangle",
    "run_solver",
    "read_electrostatics",
    "read_heat",
    "read_current",
    "read_magnetics",
]
