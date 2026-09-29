# BTB run packet (roadmap 7, 8B.6)

Step B, 2026-09-29. Tester package of the single pass (XAUUSD, FundedNext-Server 2, every tick based on
real ticks, 2026.01.01 -> 2026.07.01 end exclusive), code commit `2d3effb`, roadmap SHA-256 `0b945239...1843`
(the roadmap as it was before the Step B completion records were added).

| Path | Content |
|---|---|
| `BTB-RUN/` | `Common\Files\BTB\BTB-RUN\` as written by `BTB_Expert` (`manifest.json` holds the SHA-256 of every file) |
| `BTB-RUN/python_reference/` | `reconciliation_report.json` (RECONCILIATION PASS), `report.md` + `report.json` (48 cells) |
| `raw_audit/` | `TRE_RawTickAudit` output from `Common\Files\TRE\BTB-RUN\` (DATA-PASSED) |
| `tests/btb_tests.txt` | `BTB_Tests` output: `RESULT: PASS  passed=363 failed=0  build=6182` |
| `tests/compile_results.txt` | MetaEditor result lines of the four programs (0 errors, 0 warnings each) |

No ledger is over 50 MB, so nothing is compressed. Rebuild the report without MT5:

```
cd python
python -m btb_reference.run_reference ../research/btb_run/BTB-RUN
python -m btb_reference.study ../research/btb_run/BTB-RUN
```
