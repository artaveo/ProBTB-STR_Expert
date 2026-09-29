"""Generates the MQL5 copy of the BTB-v2 E2 test fixtures (python/tests/btb_v2_fixtures.py).

Usage (from the repository root):
    python tools/gen_e2_fixtures.py            # prints the block
    python tools/gen_e2_fixtures.py --write    # replaces the block in MQL5/Scripts/ProBTB/BTB_Tests.mq5

python/tests/test_btb_setups.py checks that the block in BTB_Tests.mq5 equals this output,
so the MQL5 and Python E2 tests always run on the same bars.
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(ROOT, "python", "tests"))

import btb_v2_fixtures as fx  # noqa: E402

BEGIN = "//--- BEGIN GENERATED E2 FIXTURES (tools/gen_e2_fixtures.py; do not edit) ---"
END = "//--- END GENERATED E2 FIXTURES ---"
TESTS = os.path.join(ROOT, "MQL5", "Scripts", "ProBTB", "BTB_Tests.mq5")


def arr(name, ohlc):
    rows = ",\n".join("   {" + ", ".join(f"{v:.2f}" for v in bar) + "}" for bar in ohlc)
    return f"double {name}[{len(ohlc)}][4] =\n  {{\n{rows}\n  }};"


def block() -> str:
    parts = [BEGIN, f"#define BTB_FX_T0        {fx.T0}   // 2026.01.07 02:00", f"#define BTB_FX_EVENT_BAR {fx.EVENT_BAR}"]
    for name, data in (("OWNER", fx.OWNER), ("ZONE_TOUCH", fx.ZONE_TOUCH), ("NO_SPIKE", fx.NO_SPIKE),
                       ("LINE_PASSED", fx.LINE_PASSED), ("EXPIRED", fx.EXPIRED), ("INVALIDATED", fx.INVALIDATED)):
        parts.append(arr(f"BTB_FX_{name}", data))
        parts.append(arr(f"BTB_FX_{name}_S", fx.mirror(data)))
    t = fx.times(len(fx.EXPIRED), fx.EXPIRED_DAYS)
    parts.append(f"long BTB_FX_EXPIRED_T[{len(t)}] = {{" + ", ".join(str(x) for x in t) + "};")
    parts.append(END)
    return "\n".join(parts)


def main(argv) -> int:
    b = block()
    if "--write" not in argv:
        print(b)
        return 0
    with open(TESTS, "r", encoding="utf-8") as f:
        src = f.read()
    i, j = src.index(BEGIN), src.index(END) + len(END)
    with open(TESTS, "w", encoding="utf-8", newline="") as f:
        f.write(src[:i] + b + src[j:])
    print(f"fixtures written to {TESTS}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
