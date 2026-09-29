"""BTB-1 engine port: mechanical LSR -> TRE rename and its blocking verification.

Usage (from the repository root):
    python tools/tre_port.py port   <lsr_checkout_at_a6ad185>
    python tools/tre_port.py verify <lsr_checkout_at_a6ad185>

`port` copies the files listed in roadmap 1.2 from the LSR checkout and applies
the rename rules of roadmap 1.1. It changes no logic.

`verify` is the roadmap 1.4 check: it applies the inverse rename to a temporary
copy of the ported files and compares them byte for byte with the LSR files.
The result must be an empty diff. It also checks that the Python bootstrap
function in python/tre_reference/stats.py is textually identical to the LSR
original. Exit code 0 = empty diff, 1 = differences.

Standard library only.
"""

from __future__ import annotations

import ast
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile

LSR_COMMIT = "a6ad185"

LSR_INC = "MQL5/Include/LiquiditySweepReversal"
TRE_INC = "MQL5/Include/TickResearchEngine"

MODULES = ["Types", "Json", "Timeframes", "BrokerTime", "Sessions", "SymbolSpec", "Quote", "Costs", "Sizing",
           "AccountRules", "RiskAdmission", "DataAudit", "Manifest", "Bars"]

# (LSR path, TRE path) — roadmap 1.2
FILES = [(f"{LSR_INC}/LSR_{m}.mqh", f"{TRE_INC}/TRE_{m}.mqh") for m in MODULES]
FILES += [
    (f"{LSR_INC}/LSR_Phase1.mqh", f"{TRE_INC}/TRE_Engine.mqh"),
    ("MQL5/Scripts/LiquiditySweepReversal/LSR_RawTickAudit.mq5", "MQL5/Scripts/TickResearchEngine/TRE_RawTickAudit.mq5"),
    ("docs/DataManifest.schema.json", "docs/DataManifest.schema.json"),
]

# Python function ported verbatim (roadmap 1.2): LSR file, TRE file, function names
PY_FUNCTIONS = ("python/lsr_reference/event_study.py", "python/tre_reference/stats.py", ["day_block_bootstrap_upper"])

# Roadmap 1.1. Order matters: the umbrella and the folder name first, then class
# prefixes, then the remaining whole-token prefix (ENUM_LSR_, LSR_, "LSR\\", "LSR-").
FORWARD = [
    (re.compile(r"LSR_Phase1"), "TRE_Engine"),
    (re.compile(r"LiquiditySweepReversal"), "TickResearchEngine"),
    (re.compile(r"CLSR_"), "CTRE_"),
    (re.compile(r"(?<![A-Za-z0-9])LSR(?![a-z])"), "TRE"),
    (re.compile(r"(?<![A-Za-z0-9])lsr(?![a-z])"), "tre"),
]

# Roadmap 1.4 inverse rename.
INVERSE = [
    (re.compile(r"TRE_Engine"), "LSR_Phase1"),
    (re.compile(r"TickResearchEngine"), "LiquiditySweepReversal"),
    (re.compile(r"CTRE_"), "CLSR_"),
    (re.compile(r"(?<![A-Za-z0-9])TRE(?![a-z])"), "LSR"),
    (re.compile(r"(?<![A-Za-z0-9])tre(?![a-z])"), "lsr"),
]


def apply(rules, text: str) -> str:
    for pat, rep in rules:
        text = pat.sub(rep, text)
    return text


def read_bytes(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def write_bytes(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def check_commit(lsr: str) -> str:
    try:
        head = subprocess.run(["git", "-C", lsr, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown (not a git checkout)"
    return head


def function_sources(path: str, names) -> dict:
    src = read_bytes(path).decode("utf-8")
    tree = ast.parse(src)
    lines = src.splitlines(keepends=True)
    out = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in names:
            out[node.name] = "".join(lines[node.lineno - 1:node.end_lineno])
    return out


def port(lsr: str, repo: str) -> int:
    head = check_commit(lsr)
    if not head.startswith(LSR_COMMIT):
        print(f"warning: LSR checkout HEAD is {head}, expected {LSR_COMMIT}", file=sys.stderr)
    for src, dst in FILES:
        text = read_bytes(os.path.join(lsr, src)).decode("utf-8")
        write_bytes(os.path.join(repo, dst), apply(FORWARD, text).encode("utf-8"))
        print(f"ported {src} -> {dst}")
    return 0


def verify(lsr: str, repo: str) -> int:
    head = check_commit(lsr)
    print(f"LSR checkout HEAD: {head}")
    ok = head.startswith(LSR_COMMIT)
    if not ok:
        print(f"FAIL: the LSR checkout must be at {LSR_COMMIT}")
    tmp = tempfile.mkdtemp(prefix="tre_inverse_")
    diffs = 0
    try:
        for src, dst in FILES:
            ported = read_bytes(os.path.join(repo, dst)).decode("utf-8")
            restored = apply(INVERSE, ported).encode("utf-8")
            write_bytes(os.path.join(tmp, src), restored)
            original = read_bytes(os.path.join(lsr, src))
            if restored != original:
                diffs += 1
                print(f"DIFF {dst} -> {src}")
                for line in difflib.unified_diff(original.decode("utf-8").splitlines(), restored.decode("utf-8").splitlines(),
                                                 fromfile=f"a6ad185/{src}", tofile=f"inverse/{dst}", lineterm="", n=1):
                    print("  " + line)
            else:
                print(f"identical  {dst} -> {src}")
        lsr_py, tre_py, names = PY_FUNCTIONS
        a = function_sources(os.path.join(lsr, lsr_py), names)
        b = function_sources(os.path.join(repo, tre_py), names)
        for name in names:
            if name not in a or name not in b or a[name] != b[name]:
                diffs += 1
                print(f"DIFF python function {name}: {tre_py} vs {lsr_py}")
            else:
                print(f"identical  {tre_py}:{name} -> {lsr_py}:{name}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    n = len(FILES) + len(PY_FUNCTIONS[2])
    print(f"RENAME VERIFICATION: {'PASS' if ok and diffs == 0 else 'FAIL'}  files={n} differences={diffs}")
    return 0 if ok and diffs == 0 else 1


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] not in ("port", "verify"):
        print(__doc__)
        return 2
    repo = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    lsr = os.path.normpath(argv[1])
    return port(lsr, repo) if argv[0] == "port" else verify(lsr, repo)


if __name__ == "__main__":
    sys.exit(main())
