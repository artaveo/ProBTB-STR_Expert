# Pro BTB (Back To Breakeven) — Research Roadmap

Owner repository: `https://github.com/artaveo/ProBTB-STR_Expert` · owner folder `E:\Trade\ProBTB-STR_Expert` · commits go straight to `main` (no branches, no PRs).

Status: **BTB-1, BTB-2 and BTB-3 are COMPLETE** (Step A code 2026-09-29, Step B build and run 2026-09-29; completion records in Section 9, report in `research/btb_run/BTB-RUN/python_reference/report.md`). **PART 2 (BTB-v2), phase BTB-4: Step A CODE COMPLETE (not compiled), 2026-09-30** — record in Section 9, closures 35–60 in Section 11, procedure in `docs/BTB_RunCard.md` Section 10. **Next: BTB-4 Step B** (owner: `git pull`, then Cowork).

| Step | Who | What |
|---|---|---|
| **A — Code** | Claude Code **cloud** session | Writes all code, tests, the Run Card and the tester/.set files for BTB-1..3; runs what can run without MT5 (Python tests, rename verification); commits to `main` of this repo and pushes. **It does not compile MQL5 or run MT5.** Section 8A |
| (owner) | owner | `git pull` in `E:\Trade\ProBTB-STR_Expert` |
| **B — Build and run** | **Cowork** session on the owner's machine | Installs into MT5, compiles, fixes compile/test failures, runs the tests, the audit and the single tester pass, reconciles, writes the report, commits the results. Section 8B |

---

## 0. How a new chat must start (read first)

1. Find your step in the table above and do only that step (Section 8A or 8B).
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
| `config/btb_tests.ini`, `config/btb_tester.ini`, `MQL5/Profiles/Tester/BTB_RUN.set` | Ready-to-use startup/tester configs for Step B |
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

## 8. Phases

The content of the three phases is the same regardless of who does it. The work is split between Step A (cloud, code) and Step B (Cowork, build and run).

### 8A — Step A: cloud session (code only)

The cloud session has no MetaTrader. **It writes code carefully and verifies it by reading.** Anything that needs MT5 is left to Step B.

1. **BTB-1 — engine port.** Clone the LSR repo at `a6ad185` and port it with the rename rules (1.1–1.3). Run the rename verification (1.4); it must produce an empty diff. Port the LSR Phase 1 test suites into `BTB_Tests.mq5`, and port `day_block_bootstrap_upper` with its tests.
2. **BTB-2 — levels and events.** Implement Sections 3–4 in MQL5 plus the Python reference (`btb_reference/levels.py`), which reads the EA's M1 export and reproduces the event ledgers. MQL5 test suites must cover:
   - the window and resume rules;
   - each level type;
   - the breakout, open-beyond, consumption and cooldown rules;
   - the event ID.
3. **BTB-3 — proxies and report.** Implement Sections 5–6 in MQL5 plus `btb_reference/study.py`. MQL5 test suites must cover:
   - the exact limit fill (Ask = P fills, Ask = P + 1 point does not);
   - the spread-offset SL;
   - the TP solve (net = k R exactly);
   - the cancellation reasons, the stop-wins-on-same-tick rule and the 21:30 close.
   
   Python tests must cover bootstrap determinism, Holm and the classification.
4. **Run what can run without MT5.** All Python tests must pass. Also check the Python reference on a small synthetic M1 file created by the tests.
5. **Write the Run Card** `docs/BTB_RunCard.md` and the ready files for Step B:
   - `config/btb_tests.ini` (script startup);
   - `config/btb_tester.ini` (Section 10 values);
   - `MQL5/Profiles/Tester/BTB_RUN.set` (all defaults, `ExperimentId=BTB-RUN`);
   - the exact Python commands.
6. **MQL5 care**, since the code cannot be compiled here:
   - Reuse the LSR idioms exactly: no `ZeroMemory` on structs with strings; explicit init; `#property strict` style as in LSR.
   - Every new function must have a test in `BTB_Tests`.
   - List any uncertainty (API calls not used before in LSR) in the Section 11 closures, so Step B checks those first.
7. **Commit and push to `main`** of `github.com/artaveo/ProBTB-STR_Expert`. Do not use another branch or a PR. If the session cannot push to `main`, push a branch and say so clearly.
   - Add a completion record `BTB-1..3 — CODE COMPLETE (not compiled)`.
   - End with the message **"Step A done — owner: git pull, then start Step B."**

### 8B — Step B: Cowork session on the owner's machine (build and run)

Work in `E:\Trade\ProBTB-STR_Expert`, which the owner has already pulled. If the folder is missing, clone the repo there. Use Section 10 for all paths.

1. **Install.** Copy the repo's `MQL5\...` into the MT5 data folder, and the `config\*.ini` files into the data folder's `config\`.
2. **Compile** every `.mq5` with MetaEditor (CLI, one file at a time). The target is 0 errors and 0 warnings. If there are errors, fix them in the repo (not only in the MT5 copy), re-install and recompile. Record every fix in Section 11.
3. **Run the tests.** Run `BTB_Tests` from `config\btb_tests.ini`; the result must be `RESULT: PASS ... failed=0`. Run the Python tests (`python -m unittest discover -s tests` from `python/`). Fix any failures in the repo.
4. **Run the raw tick audit** on XAUUSD 2026 H1. It must end `DATA-PASSED`.
5. **Run the tester once** via `config\btb_tester.ini`: XAUUSD, real ticks, 2026.01.01 → 2026.07.01. The ticks are already cached. If the connection drops, MT5 resumes by itself; do not close the terminal.
6. **Reconcile and report.**
   - `python -m btb_reference.run_reference <package>`: the event ledgers must be byte-identical.
   - `python -m btb_reference.study <package>`: this writes the report.
   - Copy the package to `research/btb_run/`, compressing the ledgers if they are over 50 MB.
7. **Commit to `main`.** The commit includes the fixes, the research packet and the completion records `BTB-1/2/3 — COMPLETE` (Section 9) with the compile/test counts and results. The owner pushes.
8. **Tell the owner in Persian:**
   - the 16 groups × 3 R table with classifications;
   - the mean spread and the fill rate;
   - anything the owner must do, for example switch on Algo Trading after a terminal restart.

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

```
BTB-1..3 — CODE COMPLETE (not compiled)
Date: 2026-09-29
Step: A (Claude Code cloud session; no MetaTrader)
Files changed:
  MQL5/Include/TickResearchEngine/TRE_*.mqh (15), MQL5/Scripts/TickResearchEngine/TRE_RawTickAudit.mq5,
  docs/DataManifest.schema.json  — ported from LSR a6ad185, rename only
  MQL5/Include/ProBTB/BTB_Types.mqh, BTB_Window.mqh, BTB_Levels.mqh, BTB_Proxy.mqh, BTB_Engine.mqh
  MQL5/Experts/ProBTB/BTB_Expert.mq5, MQL5/Scripts/ProBTB/BTB_Tests.mq5, MQL5/Scripts/ProBTB/BTB_EventReplay.mq5
  MQL5/Profiles/Tester/BTB_RUN.set, MQL5/Presets/TRE_RawTickAudit_BTB.set
  config/btb_tests.ini, config/btb_tester.ini, config/btb_raw_audit.ini
  python/tre_reference/{__init__,stats}.py, python/btb_reference/{__init__,levels,run_reference,study}.py
  python/tests/test_tre_stats.py, test_btb_levels.py, test_btb_study.py
  tools/tre_port.py, docs/BTB_RunCard.md, research/btb_run/README.md, .gitattributes, .gitignore
Summary:
  BTB-1: engine ported by the mechanical rename (1.1-1.3); LSR Phase 1 test suites and the TRE bar/ATR
    suite ported into BTB_Tests.mq5; day_block_bootstrap_upper ported verbatim with its tests.
  BTB-2: late-spread block, spread-normal resume rule and FULL/NY windows (Section 3); L1-L4 levels,
    breakout / open-beyond / consumption / cooldown rules, event ledgers (Section 4) in MQL5 and in the
    independent Python reference (levels.py, run_reference.py; byte-for-byte reconciliation).
  BTB-3: tick-level Buy/Sell Limit proxies for R = 1, 2, 3 (Section 5) and the 48-cell study with the
    day-block bootstrap, bootstrap p-values, Holm-Bonferroni and the pre-registered classification (Section 6).
Compile/Tests:
  MQL5: NOT compiled, NOT run (Step B). BTB_Tests.mq5 holds the ported TRE suites plus the BTB suites
    (types/ids/buckets, windows and resume rule, levels and events, tick path == M1 path, proxies,
    ledgers/quarantine/run package).
  Rename verification (1.4): tools/tre_port.py verify against a6ad185 -> RENAME VERIFICATION: PASS,
    18 files (17 ported files + the Python bootstrap function), 0 differences (empty diff).
  Python: python -m unittest discover -s tests -> Ran 36 tests, OK (includes the synthetic M1 package
    run end to end through run_reference, and the tick-path equivalence of the event ledgers).
Result: CODE COMPLETE. Step B must install, compile (0 errors / 0 warnings), run BTB_Tests, the raw audit
  and the single tester pass, reconcile and report. Check the Section 11 "Step B: check first" items first.
```

```
BTB-1 — COMPLETE
Date: 2026-09-29
Step: B (Claude Code desktop session on the owner's machine, MT5 build 6182)
Files changed: none in MQL5/ or python/ (no compile or test fix was needed); research/btb_run/tests/*
Summary: TRE engine installed into the MT5 data folder with the BTB files and configs.
Compile/Tests: MetaEditor CLI, one file at a time: BTB_Tests, BTB_EventReplay, TRE_RawTickAudit, BTB_Expert
  -> each 0 errors, 0 warnings. BTB_Tests (config/btb_tests.ini): RESULT: PASS passed=363 failed=0 build=6182
  (ported TRE suites + BTB suites). Python: python -m unittest discover -s tests -> Ran 36 tests, OK.
  Raw tick audit (config/btb_raw_audit.ini, ScriptParameters honoured): XAUUSD 2026.01.01-2026.07.01,
  85,119,865 ticks, fallback share 0.19 %, quarantine share 0.20 %, 6 critical gaps all quarantined -> DATA-PASSED.
Result: PASS. The engine port is compiled and verified in MT5.
```

```
BTB-2 — COMPLETE
Date: 2026-09-29
Step: B
Files changed: research/btb_run/BTB-RUN/ (btb_days.csv, btb_events_M5.csv, btb_events_M15.csv, bars_M1_BID.csv, ...)
Summary: single tester pass (config/btb_tester.ini, BTB_RUN.set with only CodeCommitSHA=2d3effb and
  RoadmapSHA256 filled): 85,120,384 real ticks, 174,621 M1 bars, test time 59 s. Tester data gate DATA-PASSED
  (fallback 0.19 %, quarantine 0.19 %). Days: 127 (126 NORMAL, 1 WARMUP, 0 ABNORMAL_SPREAD_DAY),
  mean reference spread 53.3 points. M5: 34,939 bars, 805 event rows (771 EVENT, 33 OPEN_BEYOND_LEVEL,
  1 WARMUP). M15: 11,651 bars, 691 event rows (662 EVENT, 29 OPEN_BEYOND_LEVEL).
Compile/Tests: python -m btb_reference.run_reference -> btb_days.csv (127 rows), btb_events_M5.csv (805),
  btb_events_M15.csv (691) IDENTICAL -> RECONCILIATION PASS, ledger checksum 15ae8f3a…cbdd.
  manifest.json: non_default_inputs = [CodeCommitSHA, RoadmapSHA256].
Result: PASS. Event ledgers byte-identical between MQL5 and the independent Python reference.
```

```
BTB-3 — COMPLETE
Date: 2026-09-29
Step: B
Files changed: research/btb_run/BTB-RUN/btb_proxies_M5.csv, btb_proxies_M15.csv,
  python_reference/report.md, report.json; research/btb_run/README.md
Summary: proxies M5 2,037 (1,982 filled: 1,403 FILLED + 579 FILLED_AT_PLACEMENT; 45 MISSED_TP_FIRST,
  10 EXPIRED_12_BARS), M15 1,725 (1,698 filled; 24 MISSED_TP_FIRST, 3 IN_QUARANTINE). No
  CANCELLED_WINDOW_END and no INVALID_STOP_GEOMETRY. Mean entry spread s0: M5 5.68 pips, M15 5.66 pips.
  Fill rate (R=1, FULL): M5 0.962, M15 0.976. All FILLED_AT_PLACEMENT rows are SHORT (see closure 32).
Compile/Tests: python -m btb_reference.study -> 48 cells reported and classified, no cell selected.
Result: INCONCLUSIVE_LOW_N 30, NEGATIVE 8, OPEN 10, POSITIVE_EVIDENCE 0.
  NEGATIVE: L3 M5 FULL R1/R2/R3, L3 M5 NY R1/R2/R3, L3 M15 FULL R1, L2 M5 FULL R1.
  OPEN: L2 M5 FULL R2/R3, L2 M15 FULL R1/R2/R3, L3 M15 FULL R2/R3, L3 M15 NY R1/R2/R3.
  No cell reaches POSITIVE_EVIDENCE (no p-value survives Holm apart from L4 M15 NY R1, which has 3 fills and
  is INCONCLUSIVE_LOW_N). The owner decides whether to continue.
```

```
BTB-4 — CODE COMPLETE (not compiled)
Date: 2026-09-30
Step: A (Claude Code cloud session; no MetaTrader)
Files changed:
  new:  MQL5/Include/ProBTB/BTB_Swings.mqh, BTB_Setups.mqh
        MQL5/Profiles/Tester/BTB_RUN_V2.set, MQL5/Presets/TRE_RawTickAudit_BTB_V2.set
        python/btb_reference/{swings,setups,entries,regression}.py
        python/tests/btb_v2_fixtures.py, test_btb_setups.py, tools/gen_e2_fixtures.py
  edit: MQL5/Include/ProBTB/BTB_Types.mqh, BTB_Levels.mqh, BTB_Proxy.mqh, BTB_Engine.mqh
        MQL5/Experts/ProBTB/BTB_Expert.mq5 (2.00), MQL5/Scripts/ProBTB/BTB_EventReplay.mq5 (2.00), BTB_Tests.mq5
        config/btb_tester.ini, config/btb_raw_audit.ini
        python/btb_reference/run_reference.py, study.py, python/tests/test_btb_study.py
        docs/BTB_RunCard.md (Section 10), ProBTB_Roadmap.md
  TRE engine files: unchanged (tools/tre_port.py verify -> PASS; empty git diff).
Summary:
  V1: sample column DESIGN/HOLDOUT (break date < / >= 2026-07-01) on proxies and setups; one pass
    2026-01-01..2026-09-25 (tester ToDate 2026.09.26), ExperimentId BTB-V2.
  V2: E1 for D = 1.0 / 1.5 / 2.0 in the same proxy book: reference stop, arming at P +/- Dep, arming tick =
    placement tick, INVALIDATED_BEFORE_ARM / _BEFORE_FILL, 21:30 cancel, no 12-bar expiry, no MISSED_TP_FIRST.
  V3: ZigZag(1.0 x ATR14) and 2/2 fractals; E2 setups (leg 1 containing the breakout, legs 2..n with higher
    highs / higher lows above the zone, >= 3 legs, spike 2.0 x ATR in 3 bars, pushes p1/p2 with rolls, trend
    line, live bars at |y - P| <= 0.5 x ATR inside FULL, 3-day life, all terminal statuses); E2 proxies with
    s0 from the first live tick and the window from the fill; btb_setups_E2_<TF>.csv (MQL5 + Python).
  V4: study.py v2: 36 primary cells (E0, E1 D=1.0, E2 x TF x window x R) per sample DESIGN / HOLDOUT / ALL,
    funnel events -> armed/live -> filled, Holm 36 on DESIGN, Holm 24 (E1+E2) on HOLDOUT, CONFIRMED /
    NOT_CONFIRMED / BASELINE, HOLDOUT minimum 30 fills / 10 days; diagnostics (per level, D 1.5/2.0,
    n_legs 3 vs >= 4, long/short, spread buckets). Part 1 packages still produce the Part 1 report.
  V5: E0 regression tool (python -m btb_reference.regression); E0 columns 1-36 and E0 behaviour unchanged.
Compile/Tests:
  MQL5: NOT compiled, NOT run (Step B). New suites in BTB_Tests.mq5: TestBtbSwings, TestBtbTrendLine,
    TestBtbE2Setups (owner chart long + short mirror, exact ledger row, every terminal status, warm-up and
    window gating), TestBtbE1 (arming boundary, invalidation, no 12-bar expiry, 21:30, short mirror),
    TestBtbE2Proxy; the tick path == M1 path test also compares the setup ledgers.
  Python: python -m unittest discover -s tests -> Ran 67 tests, OK. The owner-chart test (V6) passes:
    LIVE_TO_FILL, n_legs = 3, n_pushes = 2, live from bar 40, P reached on bar 41, long and short.
  E0 fixtures of Part 1 pass unchanged. On the committed Part 1 DESIGN bars the Python E2 reference builds
    771 (M5) / 662 (M15) setups; no M5 setup reaches LIVE_TO_FILL (most end STRUCTURE_FAILED on the first
    pullback into the zone) — consistent with "E2 is rare" (V4), not a verdict.
Result: CODE COMPLETE. Step B: follow docs/BTB_RunCard.md Section 10; check the Section 11 "Step B: check
  first (BTB-4)" items first.
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

Step A, 2026-09-29. Each item is conservative or follows the LSR engine where the roadmap is silent.

**Engine port (BTB-1)**

1. The rename is token-based (`tools/tre_port.py`): `LSR_Phase1`→`TRE_Engine`, `LiquiditySweepReversal`→`TickResearchEngine`, `CLSR_`→`CTRE_`, the whole token `LSR` (in `LSR_`, `ENUM_LSR_`, `LSR-`, `LSR\\`) → `TRE`, and the lowercase token `lsr` → `tre` (manifest schema id `tre.datamanifest.v1`). Free text that no rule covers is unchanged: comments and `#property copyright` still say "Liquidity Sweep Reversal", and `TRE_ROADMAP_FILENAME` is still `Liquidity_Sweep_Reversal_Roadmap.md` (it is the engine's specification). The BTB manifest writes `roadmap_file = ProBTB_Roadmap.md` itself.
2. `TRE_Engine.mqh` is the renamed `LSR_Phase1.mqh`, so it does not include `TRE_Bars.mqh` (adding it would break the empty-diff rule). `BTB_Engine.mqh` includes `TRE_Engine.mqh` + `TRE_Bars.mqh` + the BTB files.
3. `CTRE_RunOutput` writes to `Common\Files\TRE\` (rename only). The BTB run package goes to `Common\Files\BTB\<ExperimentId>\` through `CBTB_RunOutput` (same contract, root `BTB`). `TRE_RawTickAudit` still writes to `Common\Files\TRE\<ExperimentId>\`.
4. Ported tests: the LSR Phase 1 suites (JSON … Manifest) verbatim after renaming, and the LSR 2.10A bar/ATR suite without its `LSR_StableId` check (that function lives in `LSR_Liquidity`, which is not ported; `BTB_EventId` is tested instead). The LSR Phase 2/3 suites are strategy-specific and are not ported.
5. `day_block_bootstrap_upper` is ported verbatim (the verify tool compares its source text). New helpers in `stats.py` reproduce its draw sequence exactly (tested), so a cell's upper bound and p-value come from the same 10,000 resamples. p-value = share of resample means ≤ 0. The bootstrap day is the broker date of the fill.

**Windows (Section 3)**

6. `NextTradableSessionStart(d)` = `CTRE_SessionSchedule::NextSessionStartAfter(21:30 of date d−1)`. If that start is not on date d, the day is `NO_SESSION_START` (no window).
7. "Previous trading day" of the reference = the most recent earlier broker date that has at least one M1 spread sample in `[10:00, 21:30)`. Without one the day is `WARMUP` (the first data day).
8. The 5 consecutive M1 bars are the 5 most recent existing M1 bars at/after the session start (a minute without ticks has no bar). Samples are integer points (Ask − Bid of the last usable tick of the minute, rounded to points); the comparison `sample ≤ 1.5 × median` is exact in binary.
9. The qualifying bar's close must be ≤ 16:30; otherwise the day is `ABNORMAL_SPREAD_DAY` with ResumeTime 16:30, even if the spread normalises a few minutes later. A day whose data ends undecided is also `ABNORMAL_SPREAD_DAY`.
10. A breakout candle belongs to the broker day of its open time d; with close time c it is in FULL when `c ≥ ResumeTime(d)`, `c < d + 21:30` and `IsInSession(c)`, and in NY when also `c ≥ d + 16:30`.

**Levels and events (Section 4)**

11. A level is eligible for signal bars whose open time is at or after the level's completion time (PDH/PDL: 00:00 of the day; Asian range: 08:00; H1 swing: close of the second right H1 bar). Validity ends: L1 at the end of the broker day, L2 for bars opening at/after 21:30, L3 at the close time of the 120th H1 bar after the confirming bar (existing H1 bars; hours without data do not count).
12. L1 source = all M1 bars of the previous broker date with data. The first data date is never a source (LSR rule: it may be partial). L1 levels therefore start on the third data date.
13. L2 uses M1 bars with open time in `[ResumeTime, 08:00)` on `NORMAL` days only (abnormal days resume at 16:30; warm-up days have no resume). `level_source_time` of L2 = ResumeTime.
14. Crossing and consumption: the first eligible bar that opens or closes beyond an active level consumes it. It is `EVENT` if the bar opened at/inside the level, `OPEN_BEYOND_LEVEL` if it opened beyond. A wick alone (close not beyond) does not consume. When one candle crosses several levels of one type and side there is one row: the farthest breakout level (highest for long, lowest for short), or, if all were opened beyond, the farthest of those. All crossed levels are consumed.
15. L4: the box uses ATR(14) of bar k−1 (before bar k updates it) and is re-derived every bar. The cooldown starts only after a breakout row (`EVENT` or `WARMUP`) and blocks every L4 row on that side for 20 bars; `OPEN_BEYOND_LEVEL` does not start it. The ledger's `atr14` is the same pre-bar ATR for every level type.
16. Status precedence: `OPEN_BEYOND_LEVEL` > `WARMUP` > `IN_QUARANTINE` > `EVENT`. `IN_QUARANTINE` is applied when the ledger is written, if the breakout candle `[open, close)` overlaps a quarantine window (LSR rule), so the in-memory event and the Python reference agree.
17. `event_id` = first 16 hex characters of SHA-256(`BTB|tf|level|side|level_source_time|break_bar_time`) (the LSR stable-id length). Row order: bar order, then L1, L2, L3, L4, then LONG before SHORT.
18. The EA completes signal bars on the first tick at/after their close (`OnTime`), the replay and Python on the next M1 bar. Both paths give identical ledgers (MQL5 and Python tests "tick path == M1 path").

**Proxies (Section 5)**

19. Order life: pending from placement until `breakout close + 12 × signal period`. Per tick a pending order is checked in the order: 21:30 → 12-bar expiry → fill → TP reached (`MISSED_TP_FIRST`).
20. The round-trip commission of 5.3 is the TRE commission: the published FundedNext metals formula applied once to the opening price (LSR 1.7: "applied once … never doubled").
21. The TP must also respect `SYMBOL_TRADE_STOPS_LEVEL` and lie beyond P; otherwise `INVALID_STOP_GEOMETRY` (conservative extension of 5.2).
22. Exits are evaluated on the fill tick too (only the stop can trigger there). Precedence on one tick: SL > TP > 21:30 close (`BTB_ResolveExit`). With LIVE_NATIVE triggers (Bid for long, Ask for short) and SL < P < TP, SL and TP cannot both trigger on one tick; the rule is tested directly on `BTB_ResolveExit`.
23. Gap exits: a tick more than 300 s after the proxy's previous tick → `GAP_SL`, `GAP_TP` or `GAP_SESSION_CLOSE`.
24. Extra ledger states: `NOT_PLACED_END_OF_DATA` (breakout completed at the final flush) and `NOT_FILLED_END_OF_DATA` (pending when the data ends). Both are outside the analysis set.
25. Quarantine (5.4 d) is applied when the ledger is written: a proxy whose life `[breakout open, end of life]` overlaps a quarantine window gets the state `IN_QUARANTINE` and leaves the analysis set. No real-time cancellation is simulated.
26. `s0_pips` = whole points ÷ points per pip (0.30 → 3.0 pips, not 2.999…); the spread bucket uses it. The hour bucket is the breakout close hour (LSR buckets H00_08, H08_13, H13_17, H17_24).

**Study (Section 6)**

27. Events per cell = `EVENT` rows (quarantined ones excluded) with the window flag; fill rate = fills ÷ events; analysis set = `FILLED`/`FILLED_AT_PLACEMENT` with exit ≠ `END_OF_DATA`; independent days = distinct fill dates. Holm runs over all 48 cells; a cell without data has p = 1. Classification order: `INCONCLUSIVE_LOW_N` → `NEGATIVE` → `POSITIVE_EVIDENCE` → `OPEN`. Cost share of R = commission ÷ R + s0 × (profit per 1.0 price) ÷ R.

**EA**

28. `BTB_Expert` runs only in the Strategy Tester (init fails elsewhere). The LSR sizing, risk-admission and account-rule contracts are ported and tested but not used by the EA (roadmap 2: no admission gate). The EA exports `session_schedule.csv` (raw `SymbolInfoSessionTrade` intervals) and a `spread_pts` column in `bars_M1_BID.csv` for the Python reference and the replay. The spread sample of an M1 bar is the spread of the last usable tick before the tick that completes the bar.
29. Every new library function has a test in `BTB_Tests.mq5`. The EA's own glue functions (`OnInit`, `OnTick`, package writing) are exercised only by the tester run; `CBtbFlow::Tick` in the tests reproduces `OnTick`'s order.

**Step B: check first** (constructs not used in LSR, or not verifiable without MetaEditor)

30. (a) `ScriptParameters=` in `config/btb_raw_audit.ini` (fallback in the Run Card); (b) `.set` files written as ASCII with `;` comments and epoch-second datetimes; (c) `ArraySort` on an `int` array (`BTB_MedianInt`); (d) `static` class methods taking `const TRE_Bar &` (`CBTB_LevelEngine::Crosses/Breaks`); (e) `((long)1) << 31` and long arithmetic in the test fixture; (f) calling a non-const virtual `Overlaps` through a reference parameter inside `const` methods (`WrittenStatus`, `WrittenState`); (g) date literals with seconds (`D'2026.01.07 10:04:59'`); (h) public data members named `from` / `to` in the test quarantine class; (i) any implicit `datetime`/`int` conversion warnings (target 0 warnings); (j) very long string concatenations in `CBTB_ProxyBook::CsvRow`.

Step B, 2026-09-29.

31. Items 30 (a)–(j) resolved without code change: all four programs compiled with 0 errors and 0 warnings on MT5 build 6182, `BTB_Tests` passed 363/363, and `ScriptParameters=` in `config/btb_raw_audit.ini` was honoured (the raw audit wrote to `Common\Files\TRE\BTB-RUN\` with the preset dates). No fix was needed, so no file under `MQL5/` or `python/` changed in Step B.
32. Entry-fill asymmetry (observation, no change — Section 5.1 is pre-registered): P is the Bid close, a Buy Limit fills on Ask ≤ P and a Sell Limit on Bid ≥ P. A long therefore needs the Bid to fall by at least one spread below the close, while a short fills at placement whenever the Bid has not fallen since the close. In the run all 1,017 `FILLED_AT_PLACEMENT` rows are SHORT and no LONG row is; `MISSED_TP_FIRST` is almost only LONG. Long and short results are reported separately (report.md) and must be read with this in mind.
33. The manifest's `RoadmapSHA256` (`0b945239…1843`) is the roadmap as it was at the run (commit `2d3effb`), before the Step B records were appended.
34. Owner request after the report: `report.md` also shows per cell the exit counts (TP, SL, 21:30 close, gap) and two descriptive risk columns: **Max DD R** = largest peak-to-trough fall of the cumulative net R of the cell's analysed proxies in exit order (exit time, then fill time; equity starts at 0), and **Max L streak** = most consecutive trades with net R < 0. Proxies overlap in time and are 1-lot diagnostics, so these are per-cell sequences, not a portfolio drawdown. They do not enter the Section 6 classification (unchanged). Report regenerated from the committed ledgers; no tester re-run. Python tests: 37 OK.

**BTB-4 (PART 2), Step A, 2026-09-30.** Conservative choices where V1–V6 are silent.

*Sample and ledgers*

35. `sample` is written only where V3.6 adds columns: `btb_proxies_<TF>.csv` and `btb_setups_E2_<TF>.csv`. `btb_days.csv` and `btb_events_<TF>.csv` keep their Part 1 format (the sample follows from the date), so the Part 1 fixtures and the E0 regression apply unchanged.
36. The proxy ledger keeps the 36 Part 1 columns in place and appends `mode, dep_d, sample, arm_time, n_legs, n_pushes` (42 columns; the header test changed from 36 to 42). E0 rows are the Part 1 rows plus these six columns (`E0, NA, <sample>, , NA, NA`). Row order: per event E0 R1–R3, then E1 D1.0 R1–R3, D1.5, D2.0; E2 rows follow when the setup is created (at the breakout bar).
37. E0 regression = DESIGN days, DESIGN events and E0 DESIGN proxy rows cut to 36 columns, compared line by line with the Part 1 package (`python -m btb_reference.regression`).

*E1 (V2)*

38. `Dep = D × |P − SL_ref|`, where `SL_ref` is the Part 1 stop computed from the spread of the reference tick (the first tick at/after the breakout close, i.e. the Part 1 placement tick). The arming price is aligned to the tick size **away** from P, so the departure is never shorter than Dep. Arming is on the Bid for both sides (V2.2): long `Bid ≥ P + Dep`, short `Bid ≤ P − Dep`.
39. Before arming, a stop trigger on `SL_ref` ends the row as `INVALIDATED_BEFORE_ARM`. At the arming tick SL is recomputed with that tick's spread (5.2), the TP solved (5.3) and the order placed; a placement-tick fill is allowed as in Part 1.
40. Per tick, a pending E1 order is checked in the order 21:30 → fill → stop trigger (`INVALIDATED_BEFORE_FILL`). Before arming: 21:30 → stop → arm. New end states: `NOT_ARMED_WINDOW_END` (21:30 reached unarmed) and `NOT_ARMED_END_OF_DATA`; both are outside the analysis set, like the other non-fill states.
41. The E1 window is decided by the breakout close (V2.5), as in Part 1; the E1 funnel is events → armed → filled.

*Structure (V3.1)*

42. ZigZag: a bar that makes a new swing extreme continues the swing even if its other end also reaches the reversal distance (a single wide bar does not reverse itself). Z uses ATR14 **after** the detecting bar k. No reversal is detected until ATR14 is ready; the first-pivot rule compares bar 0's low (tested first) and high. After a pivot the opposite extreme is recomputed over the bars after the pivot bar up to k.
43. Fractals are strict 2/2 (strictly beyond both neighbours on each side, as LSR), confirmed at the close of bar c + 2.

*E2 setups (V3.2–V3.5)*

44. Leg 1 = two consecutive ZigZag pivots L0 → H1 (long) with `bar(L0) ≤ breakout bar ≤ bar(H1)`. All pivots of the data are scanned in order, including those confirmed before the event, and the setup waits while the swing is unconfirmed. If the first pivot whose bar is after the breakout bar does not complete such a pair (for example a pivot low), the setup ends as `NO_LEG1`.
45. Before 3 legs, every pull pivot must be strictly above the zone top (`break_high`) and strictly above the previous pull pivot; every leg pivot strictly above the previous one. Otherwise `STRUCTURE_FAILED`.
46. Spike: bars `bar(Hn)+1 … bar(Hn)+3`, threshold `2.0 × ATR14` after the Hn bar; the first bar that reaches it is the spike bar (its low/high and depth in ATR are recorded). With n ≥ 3 and no spike, a new higher leg with a valid pull pivot restarts the legs (n + 1, new spike window); a lower leg pivot or an invalid pull pivot ends the setup as `NO_SPIKE`.
47. Pushes: pull fractals after the Hn bar. Push 1 = the first; a lower one without a confirmed opposite fractal strictly between them extends push 1, a higher one restarts it. Push 2 = a lower one with such a fractal between. In the LINE phase a lower fractal with an opposite fractal between rolls the pushes (`n_pushes + 1`); without one it deepens p2. Any pull fractal at or inside the zone before the line exists ends the setup as `STRUCTURE_FAILED`; in the LINE phase such fractals are ignored.
48. Slope is taken from the current p1/p2. With the geometry of 47 it is always < 0 for a long (V3.4.3).
49. Live bar k (from the bar after p2's confirmation): `|y(k) − P| ≤ 0.5 × ATR14(k−1)` (both boundaries included), and the whole bar inside the FULL window (`open` in FULL of its broker day and `open + period ≤ 21:30`). `y(k) < P − tol` (long) ends the setup as `LINE_PASSED`, checked before the live test.
50. Bar-level end of a setup (at the bar's close, for the ledger): a live bar whose low reaches P → `LIVE_TO_FILL`; a bar whose low reaches the far edge of the zone (`break_low`) → `INVALIDATED_BEFORE_FILL`. The tick-level proxy fills or stops on its own rules; a `LIVE_TO_FILL` bar where the Ask never reached P ends the proxy as `NOT_FILLED_AT_TOUCH`. After placement, a tick-level stop trigger ends the proxy as `INVALIDATED_BEFORE_FILL`.
51. 3-day life: the broker dates of the bars seen, counted from the breakout date (= day 1); the first bar on a 4th date ends the setup (`EXPIRED_3_DAYS`) before anything else on that bar.
52. `END_OF_DATA` is an extra setup status for setups still open at the end of the data (outside the analysis). The setup ledger has an `in_quarantine` column (breakout candle overlaps a quarantine window); the setup status itself is not changed.
53. Per signal bar, each setup advances in this order: expiry → LINE step → ZigZag pivots → spike → fractals. A new setup is created after its breakout bar and runs pivots → spike → fractals immediately.
54. E2 proxies: s0 and SL come from the first live tick (the placement tick); orders exist only on live bars; the window of a filled E2 proxy is decided by the fill time (FULL always, NY when `fill ≥ 16:30`), so unfilled E2 rows have `in_full = in_ny = 0`. `n_legs` / `n_pushes` in the proxy row are the setup values at the fill or the end.

*Study (V4)*

55. The E2 "events" of a cell are the E2 setups (events that entered E2), and the E2 funnel is setups → live → filled; E0/E1 events are Part 1 `EVENT` rows. `n_legs = 3` vs `≥ 4` is a diagnostic split.
56. Holm: DESIGN over the 36 primary cells; HOLDOUT over the 24 E1 + E2 primary cells. Verdicts: E1/E2 `CONFIRMED` / `NOT_CONFIRMED` / `INCONCLUSIVE_LOW_N` (HOLDOUT < 30 fills or < 10 days), E0 `BASELINE`. The Part 1 bootstrap settings (10,000 resamples, seed 20260929) are kept; diagnostic cells report descriptive values only (no bootstrap, no p-value).
57. `study.py` detects a v2 package by the `mode` column; a Part 1 package (no `mode` column) goes through the unchanged Part 1 code path.

*Tests*

58. The E2 fixture bars live in `python/tests/btb_v2_fixtures.py` and are copied into `BTB_Tests.mq5` by `tools/gen_e2_fixtures.py --write` (generated block, checked by a Python test for staleness).

**Step B: check first (BTB-4)** (constructs new to this repository)

59. (a) Two-dimensional array parameters `const double &x[][4]` / `[][2]` and global 2-D initialisers in the generated fixture block of `BTB_Tests.mq5`; (b) the class pointer `CBTB_E2Setups *` held in `CBTB_ProxyBook` and `CBtbFlow`, compared with `NULL` and dereferenced with `.`; (c) `ConfigureV2(const double &deps[], CBTB_E2Setups *e2)` called with `GetPointer(g_e2[i])` of a global object array and with `NULL`; (d) `BTB_ParseDepList` (`StringSplit` into a string array, `StringToDouble`); (e) the date macro `BTB_HOLDOUT_START D'2026.07.01'` compared with `datetime` values; (f) structs with a `string` member (`BTB_E2Setup.event_id`) in dynamic arrays with `ArrayResize` reserve; (g) `const` accessor methods of `CBTB_E2Setups` called from `const` methods of the proxy book; (h) long string concatenations in `CBTB_E2Setups::CsvRow` and the extended `CBTB_ProxyBook::CsvRow`; (i) implicit `long`/`datetime`/`int` conversions in the E1 tick tests (target 0 warnings); (j) `input string InpE1DepD = BTB_E1_DEP_D_LIST` (macro as an input default).
60. The Python E2 reference and the MQL5 code implement 42–54 independently; the byte-identical setup ledgers (`run_reference`) are the gate. If they differ, the Python reference and the V3 text decide, and the fix is recorded here.

---

# PART 2 — BTB-v2: departure-then-return entries (owner-approved 2026-09-30)

Part 1 (Sections 1–11) is complete and stays valid. Part 2 **adds** two entry modes on top of the same engine, levels, windows, stops, targets and statistics. Everything in Part 1 applies unless a v2 section changes it explicitly. The Part 1 mode is kept as the baseline `E0`.

## V0. Why v2 (evidence from the Part 1 run)

Analysis of the committed ledgers (`research/btb_run/BTB-RUN`):

- **E0 was not a pullback entry.** 73% of the fills happened within 10 s of the breakout close, 90% within 60 s, and 27% at the placement tick itself. The limit at the breakout close was filled by the noise of the breakout bar, not by a return after a move away. That contradicts the Pro BTB picture: break → move away → return to the breakeven → continuation.
- **The `MISSED_TP_FIRST` rule removed exactly the textbook case**, where price moves far away first and returns later.
- **Costs were not the problem.** Commission plus entry spread was about 5% of R (median). The mean **gross** R was already negative (−0.11 / −0.10 / −0.05 for R = 1 / 2 / 3).
- **An M1 approximation of a "move away ≥ 1 × risk first, then return" rule** was run on the same data. The approximation reproduces E0 within 0.01 R. With the rule:
  - n = 415 and mean net R = +0.17 / +0.18 / +0.24 for R = 1 / 2 / 3;
  - positive in both quarters and on both sides;
  - increasing with the departure distance: +0.18 at 1.0 R, +0.22 at 1.5 R and +0.27 at 2.0 R (all at R = 2);
  - positive in all 8 level × TF groups.

  This was found **after** looking at the data. It is a hypothesis to be tested exactly and confirmed on the untouched holdout, not a result.

## V1. Sample: design + holdout in one pass

| Part | Range (Broker dates) | Use |
|---|---|---|
| DESIGN | 2026-01-01 → 2026-06-30 | Same sample as Part 1. E1 was *suggested* by this sample, so its DESIGN numbers are optimistic by construction |
| **HOLDOUT** | 2026-07-01 → 2026-09-25 | **Never looked at before.** It is the decisive test for E1 and E2 |

- The tester runs **once** from `2026.01.01` to `2026.09.26` (end exclusive). The XAUUSD ticks for 2026-07..09 are already in the cache (`202607–202609.tkc`).
- Every ledger row carries `sample = DESIGN|HOLDOUT` by the event's break-candle date.
- The data audit must be `DATA-PASSED` for the whole range.
- Section 2 "Holdout — not touched" is superseded for this pass only.

## V2. E1 — departure, then return to the breakeven (owner: "first move away, then come back")

This mode uses the same events (L1–L4, M5/M15), the same P (breakout close), SL (breakout extreme ∓ s0) and TP solve (R = 1, 2, 3), and the same exact-fill rules (5.1), stop rules (5.2), target rules (5.3) and 21:30 rules (3.1) as Part 1. Only the order life changes.

1. **Departure distance** `Dep = D × |P − SL|`, with **D = 1.0 as primary** and D = 1.5 and 2.0 as secondary variants. All three come from the same pass.
2. **Arming.** After the breakout close, the order is **not** placed until the Bid reaches `P + Dep` (long) or `P − Dep` (short). The arming tick is the placement tick, and `s0` is the spread at that tick. The SL is recomputed from `s0` as in 5.2; the P and TP rules are unchanged.
3. **Invalidation before arming.** If the long SL trigger (Bid ≤ SL) or the short SL trigger (Ask ≥ SL) happens before arming, the setup ends as `INVALIDATED_BEFORE_ARM`.
4. **Order life.** Once armed, the limit stays until filled, until the SL trigger (`INVALIDATED_BEFORE_FILL`) or until 21:30 of the break day (`CANCELLED_WINDOW_END`).
   - The Part 1 rules `MISSED_TP_FIRST` and `EXPIRED_12_BARS` **do not apply** to E1.
   - Arming after 21:30 is impossible, because the setup ends at 21:30.
5. **Windows.** As in Part 1, the window is decided by the breakout candle's close (FULL / NY).

## V3. E2 — three legs, spike, three pushes into the breakeven (owner-specified)

This is the owner's second entry, shown on the owner's annotated chart:
- Leg1 contains the breakout, and the BTB lines sit at that breakout candle.
- Leg2 and Leg3 make higher highs.
- A spike comes down from Leg3.
- The pullback falls in three pushes (1, 2, 3) along a descending trend line.
- The third push lands on the BTB and is the buy. After it a new Leg1–Leg3 up follows.

The description below is for a **long**; shorts are mirrored exactly (highs ↔ lows, Bid/Ask as in Part 1). All on the signal TF (M5 or M15), with Bid bars, using completed bars only (no look-ahead). ATR = Wilder ATR(14) of the signal TF.

### V3.1 Structure tools (new, `BTB_Swings.mqh`)

**ZigZag pivots (leg structure).** The reversal threshold is `Z = 1.0 × ATR14`, taken at the bar where the reversal is detected.
- In an up-swing, track the highest high `HH` and its bar.
- When a completed bar has `low ≤ HH − Z`, the pivot high is confirmed at `HH`:
  - its **time** is the bar of HH (the first such bar on ties);
  - its **confirmation time** is the close of the detecting bar.
- Lows are mirrored.
- The first pivot of the data is the first bar's low or high, whichever is reversed first.
- Pivots alternate strictly.

**Fractal pushes (pullback structure).** Use 2/2 fractal lows and highs on the signal TF (the LSR swing definition), confirmed at the close of the second right bar.

### V3.2 Legs (the move away)

1. **Breakout.** The E2 setup starts from a Part 1 `EVENT` (any of L1–L4, long).
2. **Leg 1** is the ZigZag up-swing that contains the breakout candle: from pivot low `L0` (at or before the breakout bar) to the next pivot high `H1` (at or after it).
3. **Legs 2..n.** The following pivots `L1, H2, L2, H3, …` must satisfy:
   - higher highs: `H1 < H2 < H3 < …`;
   - higher lows: `L1 < L2 < …`;
   - every `Lk > break_high`: the impulse must not return to the BTB zone while it is being built.
4. **Leg count.** The setup needs **at least 3 legs**. Its count `n` is recorded; `n = 3` is the owner's case, and `n ≥ 4` is reported separately.
5. **Failures.** A pivot low that breaks the higher-low rule or touches the zone before 3 legs exist ends the setup as `STRUCTURE_FAILED`.

### V3.3 Spike (after the last leg)

- **Spike definition.** Let `Hn` be the pivot high of the last leg, with ATR taken at the Hn bar. A **spike** exists if, within the **first 3 completed bars after the Hn bar**, the lowest low is ≤ `Hn − 2.0 × ATR14`.
- **Legs continue.** If price instead makes a new pivot high above Hn that satisfies the leg rules, the leg count increases and the spike is checked after the new last leg.
- **No spike.** If the ZigZag confirms a pivot low after Hn without a spike (a normal pullback), and no further higher high follows, the setup ends as `NO_SPIKE`.

### V3.4 Three pushes and the trend line

1. **Push 1 and push 2.**
   - `p1` is the first confirmed fractal low after the Hn bar; it may be the spike low.
   - `p2` is the next confirmed fractal low with `p2 < p1`, with at least one confirmed fractal high between them.
   - Both must be **above the zone top** (`p1, p2 > break_high`).
2. **Rolling pushes.** If a newer fractal low forms below p2 but still above the zone, the pushes roll: `p1 ← p2`, `p2 ← new low`. The number of pushes is recorded.
3. **Trend line.** The line runs through `(bar(p1), p1)` and `(bar(p2), p2)`. Its slope must be < 0. For bar index `i` after p2: `y(i) = p2 + slope × (i − bar(p2))`.
4. **Third push = entry.** From the confirmation of p2 onwards:
   - the Buy Limit at **P** is **live only on bars where `|y(i) − P| ≤ 0.5 × ATR14`** (the line is at the breakeven);
   - on other bars it is not live;
   - when `y(i) < P − 0.5 × ATR14`, the line has passed the zone and the setup ends as `LINE_PASSED`.

   The fill follows 5.1 exactly (Ask ≤ P, fill at P). The live-bar test is decided at each bar's open from known values, so there is no look-ahead.
5. **Invalidation.** A Bid ≤ SL before the fill ends the setup as `INVALIDATED_BEFORE_FILL`.

### V3.5 Stop, target, life and windows

- **Stop and target.** As Part 1: SL = breakout low − s0, where s0 is the spread at the first live tick; TP is solved for R = 1, 2, 3 as in 5.3.
- **Setup life.** A setup may span several days, up to **3 trading days** after the breakout (`EXPIRED_3_DAYS`). Orders are live only inside the FULL window, and nothing is live in the late-spread block.
- **Window.** For E2 the window (FULL/NY) is decided by the **fill time**, not by the breakout time.
- **21:30.** Positions are closed at 21:30 as in 3.1.
- **One setup per event.** Each event gives at most one E2 setup. Proxies stay independent.

### V3.6 Ledgers

`btb_setups_E2_<TF>.csv` has one row per EVENT that entered E2. It holds only bar-derived fields, so it can be reconciled byte-identically in Python:
- the event ID and the pivots `L0/H1/L1/H2/L2/H3…` (times and prices), `n_legs`;
- the spike (bar, low and depth in ATR);
- `p1/p2` (times, prices), `n_pushes`, the line slope;
- the first and last live bar;
- the terminal status: `LIVE_TO_FILL`, `STRUCTURE_FAILED`, `NO_SPIKE`, `LINE_PASSED`, `EXPIRED_3_DAYS`, `INVALIDATED_BEFORE_FILL` or `NO_LEG1`.

The proxy ledger `btb_proxies_<TF>.csv` gains the columns `mode` (E0/E1/E2), `dep_d` (E1), `sample`, `arm_time`, `n_legs` and `n_pushes`.

## V4. Statistics for v2

**Primary cells (pre-registered, 36):**
- **E0:** pooled over L1–L4, per TF × window × R.
- **E1 with D = 1.0:** pooled over L1–L4, per TF × window × R.
- **E2:** pooled over L1–L4, per TF × window × R.

Each mode gives 2 TF × 2 windows × 3 R = 12 cells.

**Diagnostic cells (not decision-making):**
- per level;
- E1 with D = 1.5 and 2.0;
- E2 with n_legs = 3 vs ≥ 4;
- long vs short;
- the spread buckets.

**Report per cell and per sample** (DESIGN, HOLDOUT, ALL): all Part 1 columns plus the arming/setup funnel (events → armed/live → filled).

**Verdict rules:**

| Rule | Detail |
|---|---|
| DESIGN | Part 1 classification (Section 6), with Holm over the 36 primary cells |
| **HOLDOUT (decisive)** | A primary cell is `CONFIRMED` if its HOLDOUT one-sided bootstrap p-value passes **Holm over the E1 + E2 primary cells** (24) at α = 0.05 **and** its DESIGN mean net R > 0 |
| Holdout minimum | `INCONCLUSIVE_LOW_N` uses 30 filled proxies and 10 days on HOLDOUT (3 months), and the Part 1 minima on DESIGN |
| E0 | Reported as the baseline and never confirmed |

No cell is picked as "best". E2 is expected to be **rare** (possibly a few dozen setups in 9 months). If its HOLDOUT is `INCONCLUSIVE_LOW_N`, the report says so and the owner decides whether to extend the data, for example to 2025.

## V5. Code changes (reuse map)

| File | Change |
|---|---|
| `MQL5/Include/ProBTB/BTB_Swings.mqh` | **new**: ZigZag(Z·ATR), 2/2 fractals, leg tracker (V3.1–V3.3), push/trend-line tracker (V3.4) |
| `MQL5/Include/ProBTB/BTB_Setups.mqh` | **new**: E1 arming state machine (V2), E2 setup state machine (V3), setup ledger writer |
| `MQL5/Include/ProBTB/BTB_Proxy.mqh` | extend: mode E0/E1/E2, arming, live-bar gating, new states, `sample` column. **E0 output must stay byte-identical to Part 1 on the DESIGN range** (regression check) |
| `BTB_Types.mqh`, `BTB_Engine.mqh`, `BTB_Expert.mq5` | new enums and inputs: `E1_DepD = {1.0,1.5,2.0}`, `E2_ZigZagATR = 1.0`, `E2_SpikeATR = 2.0`, `E2_SpikeBars = 3`, `E2_LineTolATR = 0.5`, `E2_MaxDays = 3`; one pass for all modes |
| `BTB_Tests.mq5` | new suites (V6) |
| `python/btb_reference/swings.py`, `setups.py` | **new**: independent reproduction of pivots, legs, spike, pushes, line, live bars and `btb_setups_E2_<TF>.csv` (**byte-identical**) |
| `python/btb_reference/study.py` | v2 cells, samples, funnel, Holm on the primary sets, holdout verdict |
| `docs/BTB_RunCard.md`, `config/btb_tester.ini`, `MQL5/Profiles/Tester/BTB_RUN_V2.set` | ToDate `2026.09.26`, `ExperimentId=BTB-V2`, audit end `2026.09.25` |
| TRE engine files | **no change** |

## V6. Blocking tests (added to the existing ones)

**MQL5 and Python:**
- **ZigZag:** pivots on a hand-built bar series, including ties and the exact confirmation bar.
- **Legs:** the owner's chart as a synthetic series (Leg1 containing a breakout → Leg2 → Leg3 → spike → pushes 1, 2 → third push at P) gives `LIVE_TO_FILL` with n_legs = 3 and n_pushes = 2 before the fill. Variants for each terminal status (`STRUCTURE_FAILED` when a low touches the zone during the legs, `NO_SPIKE`, `LINE_PASSED`, `EXPIRED_3_DAYS`, `INVALIDATED_BEFORE_FILL`).
- **Trend line:** `y(i)` values and live-bar gating at ±0.5 ATR, both boundaries included.
- **E1:**
  - arming exactly at `P + Dep` (Bid = P + Dep arms, 1 point less does not);
  - `INVALIDATED_BEFORE_ARM`;
  - no 12-bar expiry;
  - the 21:30 cancel.
- **Short mirrors** of the E1 and E2 cases.
- **E0 regression:** the Part 1 fixtures still pass unchanged.

**Python only:** Holm over 24/36 cells, the holdout verdict and the sample split.

## V7. Phases (same split as Part 1)

**Step A — cloud session (code only; Section 8A applies):**
- implement V2–V6 and run all Python tests;
- do not change the TRE files;
- commit and push to `main`;
- record `BTB-4 — CODE COMPLETE (not compiled)`;
- end with **"Step A done — owner: git pull, then start Step B."**

**Step B — Cowork (Section 8B applies):**
1. Install, compile with 0/0, run `BTB_Tests` and the Python tests.
2. Run the raw audit for 2026-01-01..2026-09-25, which must be `DATA-PASSED`.
3. Run the tester **once** with `BTB_RUN_V2.set`.
4. Check the E0 regression: E0 DESIGN rows equal Part 1 BTB-RUN.
5. Reconcile the event and setup ledgers byte-identically.
6. Write the report to `research/btb_v2/`, commit and record `BTB-4 — COMPLETE`.
7. Tell the owner in Persian:
   - the primary table (E0/E1/E2 × TF × window × R) with DESIGN and HOLDOUT side by side;
   - the verdicts;
   - the E2 funnel;
   - the E2 setup count.

---

# Roadmap Update Log

## 2026-09-30 — Step A: BTB-4 code complete (not compiled)
- E1 (D = 1.0 / 1.5 / 2.0), E2 (ZigZag legs, spike, pushes and trend line, live bars) and the v2 study written in MQL5 and in the independent Python reference; setup ledgers `btb_setups_E2_<TF>.csv`; E0 regression tool.
- TRE files unchanged (rename verification PASS). Python tests pass (67), including the owner-chart E2 test (V6) long and short.
- Closures 35–60 in Section 11; Run Card Section 10 and the V2 configs added.

## 2026-09-30 — PART 2 (BTB-v2) authorized
- Diagnosis of Part 1: E0 filled within seconds of the breakout (no real return); `MISSED_TP_FIRST` removed the textbook case; costs about 5% of R; gross already negative.
- Added E1 (move away ≥ D × risk, then limit at the breakout close; D = 1.0 primary) and E2 (owner's three legs → spike → three pushes along a trend line into the breakeven).
- One tester pass 2026-01-01 → 2026-09-26; 2026-07..09 is the untouched HOLDOUT and decides.

## 2026-09-29 — Roadmap created (owner decisions)
- New strategy, new repository and folder; LSR frozen at its Phase 3 stage.
- Engine taken from LSR `a6ad185` and renamed to TRE (strategy-neutral).
- Entry mode 1 (limit at the breakout close) only; M5 and M15; four level types; FULL and NY windows; R = 1, 2, 3; live-spread stop offset; full-net TP; late-spread block with the spread-normal resume rule; one tester pass for all 48 cells.
- NY window confirmed by the owner as **16:30–21:30**.
- Work split: Step A (cloud session writes code, pushes to `main`) → owner pulls → Step B (Cowork on the owner's machine installs, compiles, runs, reports).

## 2026-09-29 — Step A: BTB-1..3 code complete (not compiled)
- Engine ported from LSR `a6ad185` by rename only; rename verification PASS (empty diff).
- BTB-1..3 written in MQL5 and in the independent Python reference; Python tests pass (36).
- Closures 1–30 recorded in Section 11; Run Card `docs/BTB_RunCard.md` and Step B configs added.

## 2026-09-29 — Step B: BTB-1, BTB-2, BTB-3 complete
- Installed into MT5; 4 programs compile 0 errors / 0 warnings; BTB_Tests 363 passed, 0 failed; Python 36 OK.
- Raw tick audit and tester package DATA-PASSED; single tester pass run; event ledgers byte-identical (RECONCILIATION PASS).
- 48-cell report: 30 INCONCLUSIVE_LOW_N, 8 NEGATIVE, 10 OPEN, 0 POSITIVE_EVIDENCE. Run packet in `research/btb_run/`. Closures 31–33.
