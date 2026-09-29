# Pro BTB (Back To Breakeven) — Research Roadmap

Owner repository: `https://github.com/artaveo/ProBTB-STR_Expert` · owner folder `E:\Trade\ProBTB-STR_Expert` · commits go straight to `main` (no branches, no PRs).

Status: **BTB-1, BTB-2 and BTB-3 are to be implemented, compiled, run and reported together in one session** (owner decision 2026-09-29). Nothing beyond BTB-3 is authorized. After BTB-3 the owner decides whether to continue.

---

## 0. How a new chat must start (read first)

1. Work in a **local** Claude Code session on the owner's machine with folder `E:\Trade\ProBTB-STR_Expert`. MetaTrader, the tick cache and Python are there (Section 10). A cloud session cannot run MT5.
2. Get the engine source from the previous project at an **exact commit**:
   ```
   git clone https://github.com/artaveo/Liquidity-Sweep-Reversal-STR_Expert <tmp>
   git -C <tmp> checkout a6ad185
   ```
   `a6ad185` = "Phase 3 COMPLETE" of the LSR project (verified on GitHub `main`, 2026-09-29). **Do not use any later commit.** Later commits contain unfinished ORB changes to `LSR_Costs`, `LSR_Sessions` and `LSR_Types` that must not enter this project.
3. Never modify the LSR repository or the folder `E:\Trade\Liquidity Sweep Reversal_STR`. That strategy is frozen at its current stage.
4. Read the LSR roadmap at `a6ad185` (`Liquidity_Sweep_Reversal_Roadmap.md`) only as the specification of the reused engine (Phase 1 contract, data audit, sessions, costs, tick execution). Its strategy content (sweeps, pools) does not apply.
5. Where this roadmap is silent, prefer the LSR engine's existing behaviour. Where both are silent, choose the conservative option, write it into Section 11 (closures) and continue. Do not stop to ask unless a rule here is contradicted by data.

### 0.1 Lessons carried forward from LSR (why some rules exist)

- LSR Phase 3 on XAUUSD 2026 H1 found no edge. M5 was `STOP_EARLY_REDESIGN`.
- **The mean entry spread on FundedNext XAUUSD was about 5.7 pips.** Short stops are eaten by cost. Every result here must therefore be net of the real tick spread and commission, and spread is stratified in every report.
- Late-evening and rollover spreads are abnormal. Hence the trading block in Section 3.

---

## 1. Engine port — rename only (BTB-1)

The LSR infrastructure becomes a strategy-neutral engine called **TRE (Tick Research Engine)**. The port is a **mechanical rename with no logic change**.

### 1.1 Rename rules

| LSR (at `a6ad185`) | New |
|---|---|
| folder `MQL5/Include/LiquiditySweepReversal/` | `MQL5/Include/TickResearchEngine/` |
| file prefix `LSR_` | `TRE_` |
| classes `CLSR_*` | `CTRE_*` |
| enums `ENUM_LSR_*`, constants/functions/macros `LSR_*` | `ENUM_TRE_*`, `TRE_*` |
| `LSR_Phase1.mqh` (umbrella) | `TRE_Engine.mqh` |
| `python/lsr_reference/` (reused helpers only) | `python/tre_reference/` |

### 1.2 Files ported (rename only)

`TRE_Types, TRE_Json, TRE_Timeframes, TRE_BrokerTime, TRE_Sessions, TRE_SymbolSpec, TRE_Quote, TRE_Costs, TRE_Sizing, TRE_AccountRules, TRE_RiskAdmission, TRE_DataAudit, TRE_Manifest, TRE_Bars` (+ `TRE_Engine.mqh` umbrella), script `MQL5/Scripts/TickResearchEngine/TRE_RawTickAudit.mq5`, `docs/DataManifest.schema.json`, and from `python/lsr_reference/event_study.py` the functions `day_block_bootstrap_upper` and the bootstrap helpers (into `python/tre_reference/stats.py`).

### 1.3 Not ported as files (used only as source to adapt)

`LSR_Liquidity.mqh` (PDH/PDL day tracking, 2/2 fractal swings, level apply-time rule), `LSR_EventStudy.mqh` (tick-level entry/SL/TP geometry, TP solve, LIVE_NATIVE_STOP, gap/ambiguity, MAE/MFE), `python/lsr_reference/engine.py` (M1/TF bars, Wilder ATR, fractals). Their logic is copied into the new BTB files (Section 1.5) and adapted there.

### 1.4 Rename verification (blocking)

Apply the inverse rename (`TRE`→`LSR`, `TickResearchEngine`→`LiquiditySweepReversal`, `TRE_Engine`→`LSR_Phase1`) to a temporary copy of the ported files and diff against `a6ad185`. **The diff must be empty.** Record the result in the BTB-1 completion record.

### 1.5 New files

| File | Content |
|---|---|
| `MQL5/Include/ProBTB/BTB_Types.mqh` | Level types, sides, window flags, proxy states, exit reasons |
| `MQL5/Include/ProBTB/BTB_Window.mqh` | Late-spread block and spread-normal resume rule (Section 3) |
| `MQL5/Include/ProBTB/BTB_Levels.mqh` | The four level engines L1–L4 and break detection (Section 4) |
| `MQL5/Include/ProBTB/BTB_Proxy.mqh` | Tick-level Buy/Sell Limit proxy simulator for R = 1, 2, 3 (Section 5) |
| `MQL5/Include/ProBTB/BTB_Engine.mqh` | Umbrella: `../TickResearchEngine/TRE_Engine.mqh` + BTB files |
| `MQL5/Experts/ProBTB/BTB_Expert.mq5` | Non-trading research EA: Phase 1 contract, data audit, events and proxies for **M5 and M15, all four levels, both windows, all three R, in one tick pass** |
| `MQL5/Scripts/ProBTB/BTB_Tests.mq5` | The **single** blocking-test script: all ported TRE suites (same assertions as LSR Phase 1) + new BTB suites |
| `MQL5/Scripts/ProBTB/BTB_EventReplay.mq5` | Rebuilds the event ledgers from an exported M1 file (like `LSR_EventReplay`) |
| `python/btb_reference/{__init__,levels,run_reference,study}.py` | Independent Python reference for the event ledgers (byte-identical) and the BTB-3 report |
| `python/tests/test_btb_levels.py`, `test_btb_study.py` | Python blocking fixtures |
| `docs/BTB_RunCard.md` | Exact tester settings, inputs and commands |
| `research/btb_run/` | The run packet (Section 7) |

Run packages are written to `Common\Files\BTB\<ExperimentId>\`. Test output: `Common\Files\BTB\tests\btb_tests.txt`.

---

## 2. Frozen research decisions (owner-approved 2026-09-29, pre-registered)

| Item | Value |
|---|---|
| Symbol / server | XAUUSD, FundedNext-Server 2 (same as LSR) |
| Tester | Every tick based on real ticks, 2026.01.01 → 2026.07.01 (end exclusive), deposit 100000 USD, leverage 100 |
| Holdout | Data from 2026-07-01 onward is **not touched** in BTB-1..3 |
| Signal timeframes | M5 and M15, reported separately |
| Pattern | Break of an important level → return to the breakout candle's close ("breakeven") → continuation |
| Entry mode | **Mode 1 only: Buy Limit / Sell Limit exactly at the close of the breakout candle** |
| Directions | Long (break of a high) and short (break of a low), reported pooled and per side |
| Stop | Beyond the breakout candle's extreme by the **live spread** (Section 5.2) |
| Targets | R = 1, 2, 3 — each a separate result; every R is a **full net** R (Section 5.3) |
| Levels | L1 PDH/PDL, L2 Asian range, L3 H1 swing, L4 consolidation box (Section 4) — each a separate result |
| Windows | FULL (whole day except the late-spread block) and NY (16:30–21:30) — separate results |
| Size | 1-lot proxy per event; results in net R. No portfolio, no admission gate (diagnostic study, as LSR Phase 3) |
| Open positions and pending orders at 21:30 | Cancelled / closed at market (Section 3) |

Result grid: 4 levels × 2 timeframes × 2 windows = **16 groups**, each with R = 1, 2, 3 = **48 cells**. All come from **one tester pass**; Python only regroups the ledgers (Section 7).

---

## 3. Trading windows (Broker Server Time)

### 3.1 Late-spread block (both windows)

No order may be placed or be pending, and no position may be open, in `[21:30, ResumeTime(next trading day))`.

- At 21:30 every pending limit is cancelled (`CANCELLED_WINDOW_END`) and every open proxy is closed at the executable quote (long at Bid, short at Ask): exit reason `SESSION_CLOSE`.
- This reuses the LSR Mode 1 block (`[21:30, NextTradableSessionStart)`, `TRE_Sessions`) and adds the spread-normal rule below.

### 3.2 Spread-normal resume rule (owner requirement: "until spread is normal")

- **Per-M1 spread sample** = Ask − Bid (in points) of the **last tick** of each M1 bar.
- **Reference spread of day d** = median of the M1 spread samples of the previous trading day in `[10:00, 21:30)`.
- **ResumeTime(d)** = the close of the first M1 bar at or after `NextTradableSessionStart(d)` for which the spread samples of that bar and the 4 bars before it (5 consecutive M1 bars, all at or after the session start) are each ≤ 1.5 × reference.
- If this is not met by 16:30, the day is flagged `ABNORMAL_SPREAD_DAY` and ResumeTime = 16:30.
- The first trading day of the data has no reference; it is a warm-up day (no events).
- ResumeTime per day is written to `btb_days.csv`.

### 3.3 Windows

- **FULL** = `[ResumeTime(d), 21:30)` intersected with the actual trade session.
- **NY** = `[max(16:30, ResumeTime(d)), 21:30)` intersected with the actual trade session.

An event belongs to a window if its **breakout candle closes inside it**. NY events are a subset of FULL events, so both are computed in the same pass. Every spread value used anywhere is the live tick spread; no averaged or fixed spread enters any price.

---

## 4. Levels and breakout events (BTB-2)

### 4.1 Common rules

- Bars are Bid bars built from ticks (engine `TRE_Bars`). ATR = Wilder ATR(14) of the signal timeframe.
- A level becomes usable at the open of the first bar after the bar that completes it (LSR apply-time rule). No look-ahead.
- **Breakout candle (long)**: a completed signal-TF bar with `open ≤ level` and `close > level`. **Short**: `open ≥ level` and `close < level`. A bar that opens beyond the level is not a breakout (`OPEN_BEYOND_LEVEL`, ledgered, not traded).
- Each level produces at most **one** breakout event per side; after its first breakout it is consumed.
- If one candle breaks several levels of the same type and side, there is **one** event (the level record keeps the farthest broken level). Different level types produce separate events in separate groups.
- The event is ledgered even outside the windows (flags `in_full`, `in_ny`), so the ledger is complete for reconciliation.

### 4.2 The four levels (owner's selection, most to least conventional)

**L1 — Previous day high/low (PDH/PDL).** High and low of the previous broker trading day (whole session, Bid). Active for the whole current trading day.

**L2 — Asian range high/low.** High and low of Bid M1 bars in `[ResumeTime(d), 08:00)` of the current day. Usable from 08:00 until 21:30 of the same day. If ResumeTime ≥ 08:00 there is no Asian range that day.

**L3 — H1 swing high/low.** A 2/2 fractal on H1 (the LSR swing definition: the high is strictly above the 2 bars on each side; lows mirrored), confirmed at the close of the second right bar. It stays active until its first breakout on the signal timeframe or for 120 H1 bars, whichever comes first.

**L4 — Consolidation box (owner-added; parameters chosen here).**
- At the close of signal bar k, look back over the bars `[k−N, k−1]`. The **box** is the largest N in `[20, 96]` for which `max(high) − min(low) ≤ 2.5 × ATR(14)` measured at bar k−1. No such N ≥ 20 means no box.
- Why 20 and 2.5: a trading range in price-action practice is usually taken as roughly 20+ bars, and "longer is better" is honoured by taking the **longest** qualifying window, up to 96 bars (8 h on M5, 24 h on M15). A random walk over 20 bars typically spans about √20 ≈ 4.5 ATR, so ≤ 2.5 ATR is a genuinely compressed range. These values are pre-registered and must not be tuned.
- Box top/bottom are the level. The box length N is recorded and stratified (`20–39`, `40–59`, `60–96`).
- After an L4 event on one side, no new L4 event on that side for 20 bars.

### 4.3 Event ledger — `btb_events_<TF>.csv` (bar-derived columns only)

`event_id` (stable SHA-256 of tf, level type, side, level source time, break bar time), `tf`, `level_type` (L1..L4), `side`, `level_price`, `level_source_time`, `box_n` (L4), `break_bar_time`, `break_open/high/low/close`, `atr14`, `in_full`, `in_ny`, `status` (`EVENT`, `OPEN_BEYOND_LEVEL`, `WARMUP`, `IN_QUARANTINE`).

Python reconstructs this file from the exported M1 bars (including the per-M1 spread sample needed for ResumeTime) and must match it **byte for byte**.

---

## 5. Limit-order proxies (BTB-3)

Each `EVENT` inside a window gives three proxies, one per R. They share the entry and the stop; they differ only in the TP.

### 5.1 Placement and fill (owner requirement: the entry price is exact)

- **Placement** = first tick at or after the breakout candle's close (same bar-completion path as LSR, `FixedExecutionDelayMs` = 0).
- **Limit price P** = breakout candle close (Bid chart price), normalized to the tick grid.
- **Buy Limit fills** on the first tick with `Ask ≤ P`, **at exactly P**. Sell Limit fills on the first tick with `Bid ≥ P`, at exactly P. There is no price improvement and no slippage on the entry.
- If the Ask never reaches P, there is no trade. This is intended: the entry is exact or it does not happen.
- If P is not a valid limit at placement (Ask already ≤ P for a buy), the order is placed as a limit but fills on the placement tick at P. Record `FILLED_AT_PLACEMENT`.

### 5.2 Stop (owner requirement: never stopped by spread)

- `s0` = Ask − Bid at the placement tick (the live spread).
- **Long SL = breakout low − s0**. **Short SL = breakout high + s0**.
- The SL is aligned outward to the tick grid and must respect `SYMBOL_TRADE_STOPS_LEVEL`. Otherwise the event is `INVALID_STOP_GEOMETRY`.
- The long SL triggers on Bid ≤ SL and the short SL on Ask ≥ SL (LIVE_NATIVE_STOP), filled at the executable quote. On a gap this can be worse than SL; that is realistic and is kept.
- Every row reports `s0` and the spread at the SL trigger.

### 5.3 Target (owner requirement: full reward, never reduced by spread)

- `PlannedRisk1R` = the loss from P to SL at 1 lot (`OrderCalcProfit`) + the round-trip commission (engine `TRE_Costs`).
- For each k ∈ {1, 2, 3}, the TP is solved so that profit(P → TP) − round-trip commission = k × PlannedRisk1R. It is aligned outward, never inward.
- The long TP fills when Bid ≥ TP, at TP; the short TP when Ask ≤ TP, at TP. The realized net result at TP is therefore **at least k R**.

### 5.4 Order life and exits

- A pending limit is cancelled by the first of:
  - **(a)** 12 signal bars after placement without a fill: `EXPIRED_12_BARS`;
  - **(b)** price reaching that proxy's TP before the fill (long: Bid ≥ TP): `MISSED_TP_FIRST`. This is per R, so the three proxies can differ;
  - **(c)** 21:30: `CANCELLED_WINDOW_END`;
  - **(d)** the data quarantine.
- Exits: `TP`, `SL`, `SESSION_CLOSE` (21:30), `GAP_*` (tick gap > 300 s, the LSR rule), `END_OF_DATA`. If SL and TP are both hit on one tick, the stop wins.
- No swap arises, because nothing is held past 21:30.
- Proxies are independent (they may overlap in time). One-at-a-time trading is a later-phase question.

### 5.5 Proxy ledger — `btb_proxies_<TF>.csv`

One row per event × R:
- event link: `event_id`, `r_target`;
- order: `placement_time`, `s0`, `limit_price`, `sl`, `tp`, `planned_risk_1r`, `state` (`FILLED`, `FILLED_AT_PLACEMENT`, `EXPIRED_12_BARS`, `MISSED_TP_FIRST`, `CANCELLED_WINDOW_END`, `INVALID_STOP_GEOMETRY`, `IN_QUARANTINE`);
- fill and exit: `fill_time`, `fill_delay_s`, `exit_time`, `exit_price`, `exit_reason`, `spread_at_exit`;
- result: gross, commission, net, `net_r`, MAE/MFE in R;
- stratification: hour bucket, spread bucket (in pips `<3`, `3–5`, `5–8`, `≥8`), `box_n` bucket.

---

## 6. Statistics and verdict (BTB-3)

For each of the 48 cells (level × TF × window × R), the analysis set is the filled proxies with a real exit (not `END_OF_DATA`, not quarantine).

Report per cell:
- the number of events, fills (and fill rate) and independent days;
- win rate, mean net R and total net R;
- a one-sided 95% interval from the **day-block bootstrap** (10,000 reps, seed 20260929, the LSR function) and the bootstrap p-value (share of resamples with mean ≤ 0);
- mean s0 and cost as a share of R;
- the long/short split.

Classification per cell (pre-registered):

| Class | Rule |
|---|---|
| `INCONCLUSIVE_LOW_N` | fewer than 100 filled proxies or fewer than 20 independent days |
| `NEGATIVE` | upper 95% bound of mean net R < 0 |
| `POSITIVE_EVIDENCE` | **Holm–Bonferroni** over all 48 p-values at α = 0.05 is still significant |
| `OPEN` | otherwise (not negative, not proven) |

- The Holm correction exists because 48 cells are tested. Without it, one or two cells would look good by chance alone.
- The three R cells of one group share entries, so they are not independent; Holm is conservative here, which is accepted.
- No cell is "selected as best". The report shows all 48.
- The owner decides after reading it.

---

## 7. One pass, many reports

- The tester runs **once**. The EA builds M5 and M15 together from the same M1 stream. It evaluates all four level types and both sides, flags both windows, and simulates R = 1, 2, 3 per event.
- Outputs: `btb_days.csv`, `btb_events_M5.csv`, `btb_events_M15.csv`, `btb_proxies_M5.csv`, `btb_proxies_M15.csv`, the M1 export, the data audit files and `manifest.json` (SHA-256 of every file).
- `python -m btb_reference.run_reference <package>` reconciles the event ledgers byte for byte. `python -m btb_reference.study <package>` writes `report.md` + `report.json` with the 16 groups × 3 R. Changing a report never requires re-running the tester.

---

## 8. Phases (one session, in order; stop only on a blocking failure)

### BTB-1 — Engine port and contract
- Clone at `a6ad185`, port with the rename rules and pass the rename verification (1.4).
- Create the repo structure. Compile everything with 0 errors and 0 warnings.
- `BTB_Tests` must pass with all ported TRE suites.
- Run the raw tick audit and the EA's data audit on XAUUSD 2026 H1. The gate is `DATA-PASSED`; the ticks are already cached from LSR.

### BTB-2 — Levels and events
- Implement Sections 3–4, with MQL5 test suites for:
  - the window and resume rules;
  - each level type;
  - the breakout, open-beyond, consumption and cooldown rules;
  - the event ID.
- Add the Python reference and Python tests. Run the tester and reconcile the event ledgers byte-identically.

### BTB-3 — Proxies and report
- Implement Sections 5–6, with MQL5 test suites for:
  - the exact limit fill (Ask = P fills, Ask = P + 1 point does not);
  - the spread-offset SL;
  - the TP solve (net = k R exactly);
  - the cancellation reasons, the stop-wins-on-same-tick rule and the 21:30 close.
- Add the Python statistics tests: bootstrap determinism, Holm and classification.
- Run the single tester pass for the final numbers. Write `research/btb_run/`: the report, the manifest, the ledgers (compressed if over 50 MB), the tester log and the inputs.

### Delivery (same session)
1. Install `MQL5\...` into the MT5 data folder and compile there.
2. Commit to `main` in `E:\Trade\ProBTB-STR_Expert` with a completion record per phase (Section 9). The owner pushes.
3. Also produce a zip of all repository files with repo-relative paths, and tell the owner where it is.
4. Give the owner a short Persian summary of the 16 groups × 3 R table and the classifications.

---

## 9. Completion record (append per phase)

```
BTB-N — COMPLETE
Date: YYYY-MM-DD
Files changed: ...
Summary: ...
Compile/Tests: ...
Result: ...
```

## 10. Operator notes (owner's machine, verified 2026-09-29)

| Item | Value |
|---|---|
| MetaEditor (CLI compile) | `C:\Program Files\MetaTrader 5\MetaEditor64.exe /compile:"<file.mq5>" /log:"<log>" /inc:"<repo>\MQL5"`. The log is UTF-16. Compile files one at a time; a shell loop produced no logs |
| MT5 data folder | `%APPDATA%\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075` (copy `MQL5\...` here to install) |
| Common files | `%APPDATA%\MetaQuotes\Terminal\Common\Files\BTB\<ExperimentId>\` |
| Run a script without the GUI | Write `config\<name>.ini` with `[StartUp]`, `Script=...`, `Symbol=XAUUSD` and `Period=M1`. Close `terminal64.exe` gracefully, then start `terminal64.exe /config:"<full path>"`. The config must be inside the data folder, because long paths are ignored |
| Run the tester without the GUI | Use a `[Tester]` config with:<br>• `Expert=ProBTB\BTB_Expert`<br>• `ExpertParameters=<.set in MQL5\Profiles\Tester>`<br>• `Symbol=XAUUSD`, `Period=M1`, `Model=4`<br>• `FromDate=2026.01.01`, `ToDate=2026.07.01` (the end date is exclusive)<br>• `Deposit=100000`, `Currency=USD`, `Leverage=100`, `ShutdownTerminal=0`<br>Datetime inputs in `.set` files are epoch seconds |
| Tick cache | `bases\FundedNext-Server 2\ticks\XAUUSD\YYYYMM.tkc`. 2026-01..06 was already downloaded for LSR. After a connection drop, MT5 resumes the download on its own. A PowerShell watchdog that relaunches the tester config **only if `terminal64.exe` exits** is an optional safety net; do not use Git-Bash for it (fork errors) |
| Python | `%LOCALAPPDATA%\Programs\Python\Python312-arm64\python.exe` (standard library only). In tests use `os.path.normpath(...)` for inserted paths |
| Algo Trading | Switched on by the owner after any terminal restart |

## 11. Closures (decisions taken during implementation)

(empty — append numbered items here)

---

# Roadmap Update Log

## 2026-09-29 — Roadmap created (owner decisions)
- New strategy, new repository and folder; LSR frozen at its Phase 3 stage.
- Engine taken from LSR `a6ad185` and renamed to TRE (strategy-neutral).
- Entry mode 1 (limit at the breakout close) only; M5 and M15; four level types; FULL and NY windows; R = 1, 2, 3; live-spread stop offset; full-net TP; late-spread block with the spread-normal resume rule; one tester pass for all 48 cells.
- The owner wrote the NY window once as 18:30; it is taken as **16:30–21:30** (the LSR NY window, stated twice by the owner). Change only on the owner's instruction.
