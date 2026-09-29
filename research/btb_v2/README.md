# BTB-4 run packet (roadmap PART 2, V7 Step B)

Step B, 2026-09-30. Single tester pass XAUUSD, FundedNext-Server 2, every tick based on real ticks,
2026.01.01 -> 2026.09.26 (end exclusive), code commit `9b95d1e`, roadmap SHA-256 `0557833a...8c82`
(the roadmap as it was before the BTB-4 Step B records were added). DESIGN = break date < 2026-07-01,
HOLDOUT = 2026-07-01..2026-09-25.

| Path | Content |
|---|---|
| `BTB-V2/` | `Common\Files\BTB\BTB-V2\` as written by `BTB_Expert` 2.00 (`manifest.json` holds the SHA-256 of every file) |
| `BTB-V2/python_reference/reconciliation_report.json` | days, events and E2 setup ledgers byte-identical: RECONCILIATION PASS |
| `BTB-V2/python_reference/regression_report.json` | E0 regression against `research/btb_run/BTB-RUN` (see roadmap closure 61) |
| `BTB-V2/python_reference/report.md`, `report.json` | v2 study: 36 primary cells, DESIGN / HOLDOUT / ALL, verdicts, E2 funnel, diagnostics |
| `raw_audit/` | `TRE_RawTickAudit` output from `Common\Files\TRE\BTB-V2\` (DATA-PASSED) |
| `tests/btb_tests.txt` | `BTB_Tests` output: `RESULT: PASS  passed=455 failed=0  build=6182` |
| `tests/compile_results.txt` | MetaEditor result lines of the four programs (0 errors, 0 warnings each) |

No ledger is over 50 MB, so nothing is compressed. Rebuild without MT5:

```
cd python
python -m btb_reference.run_reference ../research/btb_v2/BTB-V2
python -m btb_reference.regression ../research/btb_v2/BTB-V2 ../research/btb_run/BTB-RUN
python -m btb_reference.study ../research/btb_v2/BTB-V2
```
