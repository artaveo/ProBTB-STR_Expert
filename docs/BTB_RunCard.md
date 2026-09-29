# Pro BTB Run Card — BTB-1..3 (Step B)

This card is the exact procedure for Step B (roadmap 8B). Step A wrote and pushed the code; nothing here was compiled or run in MT5 yet. All paths are the owner's machine (roadmap 10). The EA never trades.

Abbreviations used below (PowerShell):

```powershell
$Repo   = "E:\Trade\ProBTB-STR_Expert"
$Data   = "$env:APPDATA\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$Common = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
$ME     = "C:\Program Files\MetaTrader 5\MetaEditor64.exe"
$Term   = "C:\Program Files\MetaTrader 5\terminal64.exe"
$Py     = "$env:LOCALAPPDATA\Programs\Python\Python312-arm64\python.exe"
```

## 1. What is in the repository

| Path | Purpose |
|---|---|
| `MQL5/Include/TickResearchEngine/TRE_*.mqh` | Tick Research Engine = LSR `a6ad185` Phase 1 library + `LSR_Bars`, renamed only (`TRE_Engine.mqh` = `LSR_Phase1.mqh`) |
| `MQL5/Scripts/TickResearchEngine/TRE_RawTickAudit.mq5` | Raw real-tick audit outside the tester (renamed LSR script; writes to `Common\Files\TRE\<ExperimentId>\`) |
| `MQL5/Include/ProBTB/BTB_Types.mqh` | Level types, sides, window flags, day/proxy states, exit reasons, frozen constants, run-package writer |
| `MQL5/Include/ProBTB/BTB_Window.mqh` | Late-spread block, spread-normal resume rule, FULL/NY windows (roadmap 3) |
| `MQL5/Include/ProBTB/BTB_Levels.mqh` | L1 PDH/PDL, L2 Asian range, L3 H1 swing, L4 consolidation box, breakout events (roadmap 4) |
| `MQL5/Include/ProBTB/BTB_Proxy.mqh` | Tick-level Buy/Sell Limit proxies for R = 1, 2, 3 (roadmap 5) |
| `MQL5/Include/ProBTB/BTB_Engine.mqh` | Umbrella: `TRE_Engine.mqh` + `TRE_Bars.mqh` + BTB files |
| `MQL5/Experts/ProBTB/BTB_Expert.mq5` | Research EA: contract, data audit, M5 + M15 events, both windows, all three R, one tick pass |
| `MQL5/Scripts/ProBTB/BTB_Tests.mq5` | The single blocking test script (ported TRE suites + BTB suites) |
| `MQL5/Scripts/ProBTB/BTB_EventReplay.mq5` | Rebuilds `btb_days.csv` and `btb_events_<TF>.csv` from an exported M1 file |
| `MQL5/Profiles/Tester/BTB_RUN.set` | EA inputs: all defaults, `ExperimentId=BTB-RUN` |
| `MQL5/Presets/TRE_RawTickAudit_BTB.set` | Raw-audit script inputs for the same range |
| `config/btb_tests.ini`, `config/btb_raw_audit.ini`, `config/btb_tester.ini` | Startup configs (tests, raw audit, tester pass) |
| `python/tre_reference/stats.py` | Ported `day_block_bootstrap_upper` (verbatim) + p-value / Holm helpers |
| `python/btb_reference/levels.py`, `run_reference.py`, `study.py` | Independent event reference, byte-for-byte reconciliation, BTB-3 report |
| `python/tests/` | Python blocking tests |
| `tools/tre_port.py` | The rename (`port`) and the blocking rename verification (`verify`) |

## 2. Install

```powershell
Copy-Item -Recurse -Force "$Repo\MQL5\*" "$Data\MQL5\"
Copy-Item -Force "$Repo\config\*.ini" "$Data\config\"
```

## 3. Compile (one file at a time; target 0 errors, 0 warnings)

```powershell
$files = @("MQL5\Scripts\ProBTB\BTB_Tests.mq5", "MQL5\Scripts\ProBTB\BTB_EventReplay.mq5",
           "MQL5\Scripts\TickResearchEngine\TRE_RawTickAudit.mq5", "MQL5\Experts\ProBTB\BTB_Expert.mq5")
foreach ($f in $files) {
  $log = "$Data\" + [IO.Path]::GetFileNameWithoutExtension($f) + "_compile.log"
  Start-Process -Wait -FilePath $ME -ArgumentList "/compile:`"$Data\$f`"", "/log:`"$log`"", "/inc:`"$Data\MQL5`""
  Get-Content -Encoding Unicode $log | Select-String "result|error|warning"
}
```

The log is UTF-16. Fix every error in the repository (not only in the MT5 copy), re-install, recompile, and record each fix in roadmap Section 11. Start with the items listed there under "Step B: check first".

## 4. Tests

MQL5 (terminal closed gracefully first):

```powershell
Start-Process -FilePath $Term -ArgumentList "/config:`"$Data\config\btb_tests.ini`""
Get-Content "$Common\BTB\tests\btb_tests.txt" | Select-Object -Last 3
```

The last line must be `RESULT: PASS  passed=N failed=0`.

Python (standard library only):

```powershell
cd "$Repo\python"
& $Py -m unittest discover -s tests -v
```

Optional re-check of the rename (needs an LSR clone at `a6ad185`, roadmap 0.2):

```powershell
git clone https://github.com/artaveo/Liquidity-Sweep-Reversal-STR_Expert "$env:TEMP\lsr"
git -C "$env:TEMP\lsr" checkout a6ad185
& $Py "$Repo\tools\tre_port.py" verify "$env:TEMP\lsr"      # must print RENAME VERIFICATION: PASS
```

## 5. Raw tick audit (XAUUSD 2026 H1)

```powershell
Start-Process -FilePath $Term -ArgumentList "/config:`"$Data\config\btb_raw_audit.ini`""
```

`Common\Files\TRE\BTB-RUN\raw_tick_audit_report.json` must show `DATA-PASSED`. If the `ScriptParameters` key is not honoured by the terminal, run `TRE_RawTickAudit` from the Navigator on an XAUUSD chart with `ExperimentId=BTB-RUN`, dates 2026.01.01 / 2026.06.30.

## 6. The single tester pass

Before the run, put the identity values into `$Data\MQL5\Profiles\Tester\BTB_RUN.set`:

```powershell
git -C $Repo rev-parse HEAD                                   # -> InpCodeCommitSHA
(Get-FileHash -Algorithm SHA256 "$Repo\ProBTB_Roadmap.md").Hash.ToLower()   # -> InpRoadmapSHA256
```

Then:

```powershell
Start-Process -FilePath $Term -ArgumentList "/config:`"$Data\config\btb_tester.ini`""
```

| Setting | Value |
|---|---|
| Expert | `ProBTB\BTB_Expert` |
| Symbol / period | `XAUUSD` / `M1` (signal timeframes M5 and M15 are built inside the EA) |
| Model | `4` = every tick based on real ticks |
| Dates | `2026.01.01` → `2026.07.01` (end exclusive; data from 2026-07-01 is the untouched holdout) |
| Deposit / currency / leverage | `100000` / `USD` / `100` |
| Inputs | `BTB_RUN.set` — every input at its default; only `CodeCommitSHA` and `RoadmapSHA256` are filled |

The ticks are cached. If the connection drops, MT5 resumes by itself; do not close the terminal. Switch Algo Trading on after any terminal restart.

### EA inputs (all defaults)

| Input | Default |
|---|---|
| ExperimentId | `BTB-RUN` |
| CodeCommitSHA / RoadmapSHA256 | empty (fill before the run) |
| AuditRequestedStartDate / EndDate | `2026.01.01` / `2026.06.30` (inclusive end date; epoch `1767225600` / `1782777600` in the `.set`) |
| ClosedMarketCalendarFile / DataQuarantineFile | empty |
| StrategyPipSize | `0.10` |
| CommissionRatePercent | `0.0016` (FundedNext metals, published formula applied once) |
| CostScheduleDate | `2026-09-28` |
| ExportReferenceBars | `true` |

Frozen decisions (not inputs, recorded in `run_card_inputs.txt`): M5 + M15, Bid bars, LIVE_NATIVE_STOP, Mode 1 limit at the breakout close, R = 1, 2, 3, FULL + NY windows, 21:30 late block, NY 16:30–21:30, no slippage, zero latency.

## 7. Run package — `Common\Files\BTB\BTB-RUN\`

| File | Content |
|---|---|
| `btb_days.csv` | Per broker day: session start, reference spread, ResumeTime, NY start, status |
| `btb_events_M5.csv`, `btb_events_M15.csv` | Event ledgers (roadmap 4.3), byte-reconciled by Python |
| `btb_proxies_M5.csv`, `btb_proxies_M15.csv` | Proxy ledgers (roadmap 5.5), one row per event × R |
| `bars_M1_BID.csv` | M1 export with `spread_pts` (last-tick spread of each minute) |
| `session_schedule.csv` | Broker-declared session intervals (for the reference and the replay) |
| `reference_config.json`, `event_summary.json` | Reference configuration; counts |
| `data_quality_report.json`, `potential_fallback_minutes.csv`, `critical_data_gaps.csv`, `detected_market_closures.csv`, `data_quarantine_windows.csv` | TRE data audit |
| `symbol_session_snapshot.json`, `execution_contract.json`, `run_card_inputs.txt` | Contract snapshots and exact inputs |
| `manifest.json` | SHA-256 of every file above (written last) |

## 8. Reconcile and report

```powershell
cd "$Repo\python"
& $Py -m btb_reference.run_reference "$Common\BTB\BTB-RUN"      # must print RECONCILIATION PASS
& $Py -m btb_reference.study "$Common\BTB\BTB-RUN"              # writes python_reference\report.md + report.json
```

`run_reference` compares `btb_days.csv` and both event ledgers byte for byte. Optional cross-check of the MQL5 replay: run `BTB_EventReplay` (inputs `InpFolder=BTB\BTB-RUN`), then
`& $Py -m btb_reference.run_reference "$Common\BTB\BTB-RUN" --mql5-dir "$Common\BTB\BTB-RUN\replay"`.

Copy the package (with `python_reference\`) to `$Repo\research\btb_run\BTB-RUN\`; compress any ledger over 50 MB (`Compress-Archive`).

## 9. Gate checklist

- [ ] 4 programs compile: 0 errors, 0 warnings
- [ ] `btb_tests.txt`: `RESULT: PASS ... failed=0`
- [ ] Python tests: OK
- [ ] Raw audit and tester package: `DATA-PASSED`
- [ ] `manifest.json` → `inputs.non_default_inputs` lists only `CodeCommitSHA` and `RoadmapSHA256`
- [ ] `run_reference`: `RECONCILIATION PASS`
- [ ] `study`: 48 cells reported and classified; no cell selected as best
- [ ] No data from 2026-07-01 onward used
