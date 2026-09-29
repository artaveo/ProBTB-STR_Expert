//+------------------------------------------------------------------+
//| BTB_Tests.mq5                                                    |
//| The single blocking test script of Pro BTB (roadmap 1.5, 8A).    |
//| 1) every TRE suite ported from LSR a6ad185 LSR_Tests.mq5 (same   |
//|    assertions as LSR Phase 1, rename only) plus the TRE bar/ATR  |
//|    suite; 2) the new BTB suites (windows, levels, events, tick   |
//|    path, proxies). Pure fixtures: no broker data, no trading.    |
//| Result: Experts log + Common\Files\BTB\tests\btb_tests.txt       |
//+------------------------------------------------------------------+
#property copyright   "Pro BTB"
#property version     "1.00"
#property description "Blocking tests for TRE and BTB-1..3 (no trading)"
#property script_show_inputs

#include "../../Include/ProBTB/BTB_Engine.mqh"

input bool InpCloseTerminalWhenDone = false; // Close terminal after the run (CI use)

int    g_pass = 0;
int    g_fail = 0;
string g_report = "";
string g_suite = "";

void Suite(const string name)
  {
   g_suite = name;
   g_report += "\n[" + name + "]\n";
  }

void Check(const bool cond, const string name)
  {
   if(cond)
     {
      g_pass++;
      g_report += "  PASS " + name + "\n";
     }
   else
     {
      g_fail++;
      g_report += "  FAIL " + name + "\n";
      PrintFormat("FAIL [%s] %s", g_suite, name);
     }
  }

void CheckNear(const double actual, const double expected, const double tol, const string name)
  {
   bool ok = MathAbs(actual - expected) <= tol;
   Check(ok, name + (ok ? "" : StringFormat(" (actual %.10f expected %.10f)", actual, expected)));
  }

void CheckStr(const string actual, const string expected, const string name)
  {
   bool ok = (actual == expected);
   Check(ok, name + (ok ? "" : " (actual '" + actual + "' expected '" + expected + "')"));
  }

void MkTick(MqlTick &k, const datetime t, const int ms, const double bid, const double ask)
  {
   ZeroMemory(k);
   k.time = t;
   k.time_msc = (long)t * 1000 + ms;
   k.bid = bid;
   k.ask = ask;
   k.flags = TICK_FLAG_BID | TICK_FLAG_ASK;
  }

void MkQuote(TRE_Quote &q, const double bid, const double ask)
  {
   q.seq = 1;
   q.time = D'2026.01.05 10:00';
   q.time_msc = (long)q.time * 1000;
   q.bid = bid;
   q.ask = ask;
   q.last = 0.0;
   q.volume = 0;
   q.flags = 0;
  }

//--- Mon–Fri [01:00, 23:57), weekend closed — an XAUUSD-like broker schedule.
void BuildGoldSchedule(CTRE_SessionSchedule &s)
  {
   string e;
   s.Clear();
   for(int d = 1; d <= 5; d++)
      s.AddBrokerInterval(d, 3600, 23 * 3600 + 57 * 60, e);
  }

//+------------------------------------------------------------------+
void TestJson(void)
  {
   Suite("JSON / hashing");
   CheckStr(TRE_NumStr(1.50), "1.5", "NumStr strips trailing zeros");
   CheckStr(TRE_NumStr(2.0), "2", "NumStr integer value");
   CheckStr(TRE_NumStr(-0.0), "0", "NumStr negative zero");
   CheckStr(TRE_NumStr(7.145952, 8), "7.145952", "NumStr 8 digits");
   CheckStr(CTRE_Json::Escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd", "Escape quote, backslash, newline");
   CTRE_Json j;
   j.BeginObject();
   j.KInt("a", 1);
   j.KArr("b");
   j.Bool(true);
   j.Null();
   j.Str("x");
   j.EndArray();
   j.KObj("c");
   j.EndObject();
   j.EndObject();
   CheckStr(j.Text(), "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{}}", "builder commas and nesting");
   CheckStr(TRE_Sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256('abc')");
   CheckStr(TRE_IsoTimeMsc((long)D'2026.01.05 01:02:03' * 1000 + 45), "2026-01-05T01:02:03.045", "ISO time with ms");
  }

//+------------------------------------------------------------------+
void TestTimeframes(void)
  {
   Suite("1.1 TimeframeSet");
   TRE_TimeframeSet s;
   string e;
   Check(TRE_ParseTimeframeSet("M5,M15,H1", s, e) && s.count == 3, "default parses");
   CheckStr(TRE_TimeframeSetToString(s), "M5,M15,H1", "default canonical");
   Check(TRE_ParseTimeframeSet(" h1 , m5 ", s, e), "case-insensitive, whitespace-tolerant");
   CheckStr(TRE_TimeframeSetToString(s), "M5,H1", "canonical order after reorder");
   Check(TRE_ParseTimeframeSet("H1,M1,M30,M15,M5", s, e), "all five allowed");
   CheckStr(TRE_TimeframeSetToString(s), "M1,M5,M15,M30,H1", "canonical enum order");
   Check(!TRE_ParseTimeframeSet("M5,,H1", s, e), "empty middle entry fails");
   Check(!TRE_ParseTimeframeSet("M5,", s, e), "trailing empty entry fails");
   Check(!TRE_ParseTimeframeSet("M5,m5", s, e), "duplicate fails (not silently removed)");
   Check(!TRE_ParseTimeframeSet("M2", s, e), "unsupported value fails");
   Check(!TRE_ParseTimeframeSet("H4", s, e), "H4 not allowed");
   Check(!TRE_ParseTimeframeSet("", s, e), "empty string fails");
   Check(!TRE_ParseTimeframeSet("   ", s, e), "whitespace-only fails");
   Check(!TRE_ParseTimeframeSet("M 5", s, e), "internal whitespace fails");

   TRE_ParseTimeframeSet("M5,M15,H1", s, e);
   Check(TRE_ValidateLiveTimeframe(s, TRE_TF_M5, e), "LiveTimeframe M5 member");
   Check(!TRE_ValidateLiveTimeframe(s, TRE_TF_M1, e), "LiveTimeframe M1 not member fails");
   TRE_TimeframeSet a;
   TRE_ResolveActiveTimeframes(s, TRE_TF_M15, TRE_CONTEXT_RESEARCH, a);
   Check(a.count == 3, "research runs every selected timeframe");
   TRE_ResolveActiveTimeframes(s, TRE_TF_M15, TRE_CONTEXT_LIVE, a);
   Check(a.count == 1 && a.items[0] == TRE_TF_M15, "live runs exactly the one LiveTimeframe");
   Check(TRE_TimeframeSeconds(TRE_TF_M15) == 900 && TRE_TimeframeSeconds(TRE_TF_H1) == 3600, "timeframe seconds");
  }

//+------------------------------------------------------------------+
void TestBrokerTime(void)
  {
   Suite("1.2 Broker time");
   datetime t = D'2026.01.05 13:45:10';
   Check(TRE_BrokerDayStart(t) == D'2026.01.05', "broker day start");
   Check(TRE_SecondsOfDay(t) == 13 * 3600 + 45 * 60 + 10, "seconds of day");
   Check(TRE_DayOfWeek(D'2026.01.05') == 1, "2026-01-05 is Monday");
   Check(TRE_BrokerMonthKey(t) == 202601, "month key");
   CTRE_BrokerDayClock c;
   Check(c.Observe(D'2026.01.05 00:00:07'), "first observation opens a day");
   Check(!c.Observe(D'2026.01.05 23:59:59'), "same day does not reset");
   Check(c.Observe(D'2026.01.06 00:00:00'), "00:00:00 resets");
   Check(c.ResetTimestamp() == D'2026.01.06 00:00:00', "reset timestamp is first tick at/after 00:00");
   Check(c.Observe(D'2026.01.08 03:00:00') && c.ResetTimestamp() == D'2026.01.08 03:00:00', "gap day: reset at first observed tick");
  }

//+------------------------------------------------------------------+
void TestSessions(void)
  {
   Suite("1.3 Sessions");
   string e;
   int sec;
   Check(TRE_ParseHHMM("16:30", false, sec, e) && sec == 16 * 3600 + 30 * 60, "HH:MM parses");
   Check(TRE_ParseHHMM("24:00", true, sec, e) && sec == 86400, "24:00 allowed for end");
   Check(!TRE_ParseHHMM("24:00", false, sec, e), "24:00 rejected for start");
   Check(!TRE_ParseHHMM("9:00", false, sec, e), "H:MM rejected");
   Check(!TRE_ParseHHMM("25:00", true, sec, e), "25:00 rejected");
   Check(!TRE_ParseHHMM("10:60", true, sec, e), "minute 60 rejected");

   CTRE_SessionSchedule gold;
   BuildGoldSchedule(gold);
   Check(gold.IsInSession(D'2026.01.05 01:00'), "session start inclusive");
   Check(!gold.IsInSession(D'2026.01.05 23:57'), "session end exclusive");
   Check(!gold.IsInSession(D'2026.01.10 12:00'), "Saturday closed");
   datetime ns;
   Check(gold.NextSessionStartAfter(D'2026.01.05 21:30', ns) && ns == D'2026.01.06 01:00', "next start after Mon 21:30 is Tue 01:00");
   Check(gold.NextSessionStartAfter(D'2026.01.09 21:30', ns) && ns == D'2026.01.12 01:00', "next start after Fri 21:30 is Mon 01:00");
   Check(gold.NextSessionStartAfter(D'2026.01.06 01:00', ns) && ns == D'2026.01.07 01:00', "strictly after: equal start excluded");
   Check(!gold.AddBrokerInterval(2, 3600, 3600, e), "zero-length broker interval rejected");

   //--- Mode 1
   CTRE_StrategyWindow w1;
   Check(w1.Init(TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD, "00:00", "24:00", GetPointer(gold), e), "Mode 1 init");
   Check(w1.IsEntryAllowed(D'2026.01.05 21:29:59'), "Mode 1: 21:29:59 allowed");
   Check(!w1.IsEntryAllowed(D'2026.01.05 21:30:00'), "Mode 1: 21:30 blocked");
   Check(!w1.IsEntryAllowed(D'2026.01.05 23:00'), "Mode 1: 23:00 blocked");
   Check(w1.IsInLateSpreadBlock(D'2026.01.06 00:30'), "Mode 1: block continues past midnight");
   Check(w1.IsEntryAllowed(D'2026.01.06 01:00'), "Mode 1: next session start allowed");
   Check(w1.IsInLateSpreadBlock(D'2026.01.10 12:00'), "Mode 1: Friday block spans weekend");
   Check(w1.IsEntryAllowed(D'2026.01.12 01:00'), "Mode 1: Monday open allowed");
   datetime bs, be;
   Check(w1.LateBlockOfDay(D'2026.01.09', bs, be) && bs == D'2026.01.09 21:30' && be == D'2026.01.12 01:00', "Mode 1: Friday block [21:30, Mon 01:00)");

   CTRE_SessionSchedule split;
   split.AddBrokerInterval(1, 3600, 21 * 3600, e);
   split.AddBrokerInterval(1, 22 * 3600, 86400, e);
   split.AddBrokerInterval(2, 3600, 21 * 3600, e);
   CTRE_StrategyWindow w1b;
   w1b.Init(TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD, "00:00", "24:00", GetPointer(split), e);
   Check(w1b.IsInLateSpreadBlock(D'2026.01.05 21:45'), "Mode 1: same-day later session — 21:45 in block");
   Check(!w1b.IsInLateSpreadBlock(D'2026.01.05 22:00') && w1b.IsEntryAllowed(D'2026.01.05 23:00'), "Mode 1: block ends at same-day 22:00 session");

   CTRE_SessionSchedule wrap;
   wrap.AddBrokerInterval(1, 22 * 3600, 2 * 3600, e);
   wrap.AddBrokerInterval(2, 22 * 3600, 2 * 3600, e);
   Check(wrap.IsInSession(D'2026.01.06 01:00'), "wrapped interval continues after midnight");
   Check(wrap.NextSessionStartAfter(D'2026.01.05 23:00', ns) && ns == D'2026.01.06 22:00', "midnight continuation is not a session start");

   //--- Mode 2
   CTRE_StrategyWindow w2;
   Check(w2.Init(TRE_SESSION_NY_WINDOW, "00:00", "24:00", GetPointer(gold), e), "Mode 2 init");
   Check(!w2.IsEntryAllowed(D'2026.01.05 16:29:59'), "Mode 2: 16:29:59 outside");
   Check(w2.IsEntryAllowed(D'2026.01.05 16:30'), "Mode 2: 16:30 inside");
   Check(w2.IsEntryAllowed(D'2026.01.05 21:29:59'), "Mode 2: 21:29:59 inside");
   Check(!w2.IsEntryAllowed(D'2026.01.05 21:30'), "Mode 2: 21:30 exclusive end");
   Check(!w2.IsEntryAllowed(D'2026.01.10 17:00'), "Mode 2: Saturday — no actual session");

   //--- Mode 3
   CTRE_StrategyWindow w3;
   Check(w3.Init(TRE_SESSION_CUSTOM, "00:00", "24:00", GetPointer(gold), e), "Mode 3 00:00->24:00 valid");
   Check(w3.IsEntryAllowed(D'2026.01.05 23:56') && !w3.IsEntryAllowed(D'2026.01.05 00:30'), "Mode 3 full day intersects actual session");
   Check(!w3.Init(TRE_SESSION_CUSTOM, "10:00", "10:00", GetPointer(gold), e), "Mode 3 Start=End invalid");
   Check(!w3.Init(TRE_SESSION_CUSTOM, "00:00", "00:00", GetPointer(gold), e), "Mode 3 00:00->00:00 invalid");
   Check(!w3.Init(TRE_SESSION_CUSTOM, "24:00", "10:00", GetPointer(gold), e), "Mode 3 start 24:00 invalid");
   Check(w3.Init(TRE_SESSION_CUSTOM, "22:00", "02:00", GetPointer(gold), e), "Mode 3 wrap-midnight valid");
   Check(w3.IsEntryAllowed(D'2026.01.05 22:00') && w3.IsEntryAllowed(D'2026.01.06 01:30'), "Mode 3 wrap: both sides inside");
   Check(!w3.IsEntryAllowed(D'2026.01.06 02:00') && !w3.IsEntryAllowed(D'2026.01.05 21:59'), "Mode 3 wrap: boundaries");
   Check(!w3.IsEntryAllowed(D'2026.01.06 00:30'), "Mode 3 wrap: inside window but outside actual session");
   Check(w3.Init(TRE_SESSION_CUSTOM, "08:00", "12:00", GetPointer(gold), e) && w3.IsEntryAllowed(D'2026.01.05 11:59') && !w3.IsEntryAllowed(D'2026.01.05 12:00'), "Mode 3 same-day window");
  }

//+------------------------------------------------------------------+
void TestUnitsAndQuotes(void)
  {
   Suite("1.5/1.6 Units and quotes");
   CTRE_PriceUnits u;
   string e;
   Check(u.Init(0.10, 0.01, 0.01, e), "units init");
   CheckNear(u.ToPips(0.35), 3.5, 1e-12, "0.35 = 3.5 strategy pips");
   CheckNear(u.ToPoints(0.35), 35.0, 1e-9, "0.35 = 35 points");
   CheckNear(u.PipsToPrice(3.0), 0.30, 1e-12, "3 pips = 0.30");
   Check(!u.Init(0.0, 0.01, 0.01, e), "zero pip size rejected");
   Check(TRE_IsTickAligned(2000.01, 0.01) && !TRE_IsTickAligned(2000.015, 0.01), "tick alignment");

   TRE_Quote q;
   MkQuote(q, 1999.90, 2000.10);
   CheckNear(TRE_Spread(q), 0.20, 1e-9, "spread = ask - bid");
   Check(TRE_OpenQuote(TRE_DIR_LONG, q) == 2000.10 && TRE_OpenQuote(TRE_DIR_SHORT, q) == 1999.90, "open long Ask / short Bid");
   Check(TRE_CloseQuote(TRE_DIR_LONG, q) == 1999.90 && TRE_CloseQuote(TRE_DIR_SHORT, q) == 2000.10, "close long Bid / short Ask");
   Check(TRE_SignalBarPrice(q, TRE_PRICE_BID) == 1999.90, "signal bar source BID");
   Check(TRE_QuoteIsUsable(q), "usable quote");
   TRE_Quote z;
   MkQuote(z, 2000.0, 2000.0);
   Check(!TRE_QuoteIsUsable(z), "zero spread not usable");

   // Native stop fires on Bid; spread widening alone can trigger native but not mid.
   Check(TRE_StopTriggered(TRE_STOP_LIVE_NATIVE, TRE_DIR_LONG, q, 1999.95), "native long: Bid <= SL");
   Check(!TRE_StopTriggered(TRE_STOP_RESEARCH_MID, TRE_DIR_LONG, q, 1999.95), "mid long: Mid above SL");
   Check(!TRE_StopTriggered(TRE_STOP_LIVE_NATIVE, TRE_DIR_LONG, q, 1999.89), "native long: Bid above SL");
   Check(TRE_StopTriggered(TRE_STOP_LIVE_NATIVE, TRE_DIR_SHORT, q, 2000.10), "native short: Ask >= SL (equal)");
   Check(!TRE_StopTriggered(TRE_STOP_LIVE_NATIVE, TRE_DIR_SHORT, q, 2000.11), "native short: Ask below SL");
   Check(TRE_StopTriggered(TRE_STOP_RESEARCH_MID, TRE_DIR_SHORT, q, 1999.99), "mid short: Mid >= SL");
  }

//+------------------------------------------------------------------+
void TestCosts(void)
  {
   Suite("1.7 Costs");
   TRE_CostModel m;
   TRE_CostModelDefaults(m);
   string e;
   Check(TRE_ValidateCostModel(m, e), "defaults valid");
   CheckNear(TRE_CommissionCurrency(m, 1.0, 100.0, 4466.22), 7.145952, 1e-9, "published XAUUSD example formula (1 lot @ 4466.22)");
   CheckNear(TRE_CommissionCurrency(m, 0.5, 100.0, 2000.0), 1.6, 1e-12, "0.5 lot @ 2000");
   Check(TRE_DeclaredRiskExecutionBufferPoints(m) == 0, "buffer 0 at baseline");
   Check(TRE_EarliestExecutionMsc(m, 1000) == 1000, "latency ZERO");

   TRE_Quote q;
   MkQuote(q, 2000.00, 2000.20);
   Check(TRE_AdverseEntryPrice(m, TRE_DIR_LONG, q, 0.01) == 2000.20, "no slippage: long entry = Ask");

   TRE_CostModel s = m;
   s.slippage_mode = TRE_SLIPPAGE_FIXED_ADVERSE_POINTS;
   s.entry_slippage_points = 2;
   s.exit_slippage_points = 5;
   Check(TRE_ValidateCostModel(s, e), "FIXED 2/5 valid");
   CheckNear(TRE_AdverseEntryPrice(s, TRE_DIR_LONG, q, 0.01), 2000.22, 1e-9, "long entry Ask+2pt");
   CheckNear(TRE_AdverseEntryPrice(s, TRE_DIR_SHORT, q, 0.01), 1999.98, 1e-9, "short entry Bid-2pt");
   CheckNear(TRE_AdverseExitPrice(s, TRE_DIR_LONG, q, 0.01), 1999.95, 1e-9, "long exit Bid-5pt");
   CheckNear(TRE_AdverseExitPrice(s, TRE_DIR_SHORT, q, 0.01), 2000.25, 1e-9, "short exit Ask+5pt");
   Check(TRE_DeclaredRiskExecutionBufferPoints(s) == 5, "buffer = max(entry, exit)");

   TRE_CostModel bad = m;
   bad.entry_slippage_points = 1;
   Check(!TRE_ValidateCostModel(bad, e), "NONE with non-zero points rejected");
   bad = s;
   bad.entry_slippage_points = 3;
   Check(!TRE_ValidateCostModel(bad, e), "non-registered slippage 3 rejected");
   bad = s;
   bad.entry_slippage_points = 0;
   bad.exit_slippage_points = 0;
   Check(!TRE_ValidateCostModel(bad, e), "FIXED with 0/0 rejected");
   bad = m;
   bad.fixed_execution_delay_ms = 100;
   Check(!TRE_ValidateCostModel(bad, e), "latency ZERO with delay rejected");
   TRE_CostModel lat = m;
   lat.latency_mode = TRE_LATENCY_FIXED_MS;
   lat.fixed_execution_delay_ms = 250;
   Check(TRE_ValidateCostModel(lat, e), "latency 250ms valid");
   Check(TRE_EarliestExecutionMsc(lat, 1000) == 1250, "latency adds delay");
   lat.fixed_execution_delay_ms = 300;
   Check(!TRE_ValidateCostModel(lat, e), "latency 300ms rejected");
   bad = m;
   bad.contract_size_source = TRE_CONTRACT_SIZE_BROKER_SCHEDULE;
   Check(!TRE_ValidateCostModel(bad, e), "broker-schedule contract size requires a value");

   TRE_CostGateResult g;
   TRE_EvaluateEntryCostGate(m, 0.30, 0.10, 50.0, 500.0, g);
   Check(g.passed, "spread exactly 3.0 pips and cost exactly 0.10R pass");
   TRE_EvaluateEntryCostGate(m, 0.31, 0.10, 0.0, 500.0, g);
   Check(!g.passed && g.reason == TRE_COST_GATE_SPREAD_TOO_WIDE, "3.1 pips rejected");
   TRE_EvaluateEntryCostGate(m, 0.20, 0.10, 50.01, 500.0, g);
   Check(!g.passed && g.reason == TRE_COST_GATE_NONSPREAD_COST_TOO_HIGH, "0.10002R cost rejected");
   TRE_CostModel off = m;
   off.max_entry_spread_enabled = false;
   TRE_EvaluateEntryCostGate(off, 0.50, 0.10, 0.0, 500.0, g);
   Check(g.passed, "spread gate disabled");
   TRE_EvaluateEntryCostGate(m, 0.20, 0.10, 0.0, 0.0, g);
   Check(!g.passed && g.reason == TRE_COST_GATE_INVALID_INPUT, "zero 1R is invalid input");
  }

//+------------------------------------------------------------------+
void TestSizing(void)
  {
   Suite("1.8 Position sizing");
   TRE_SymbolSpec spec;
   spec.point = 0.01;
   spec.tick_size = 0.01;
   spec.contract_size = 100.0;
   spec.volume_min = 0.01;
   spec.volume_max = 100.0;
   spec.volume_step = 0.01;
   spec.stops_level = 0;
   TRE_CostModel m;
   TRE_CostModelDefaults(m);
   CTRE_LinearEconomics econ(100.0, 100.0);

   CheckNear(TRE_FloorToVolumeStep(0.999999, 0.01), 0.99, 1e-12, "floor 0.999999 -> 0.99");
   CheckNear(TRE_FloorToVolumeStep(1.0, 0.01), 1.0, 1e-12, "exact step kept");
   CheckNear(TRE_FloorToVolumeStep(0.3, 0.1), 0.3, 1e-12, "0.3/0.1 float edge kept");

   TRE_SizingRequest r;
   r.dir = TRE_DIR_LONG;
   r.entry_quote = 2000.00;
   r.stop_price = 1995.00;
   r.risk_budget_currency = 500.0;
   r.free_margin = 1e9;
   TRE_SizingResult res;
   Check(TRE_SizePosition(r, spec, m, TRE_STOP_LIVE_NATIVE, econ, res), "long sizing ok");
   CheckNear(res.worst_loss_per_lot, 503.2, 1e-9, "worst loss per lot = 500 path + 3.2 commission");
   CheckNear(res.volume, 0.99, 1e-12, "volume rounded down (0.9936 -> 0.99)");
   Check(res.worst_loss_currency <= 500.0 + 1e-9, "worst-case loss never exceeds 1R");

   r.dir = TRE_DIR_SHORT;
   r.stop_price = 2005.00;
   Check(TRE_SizePosition(r, spec, m, TRE_STOP_LIVE_NATIVE, econ, res) && MathAbs(res.volume - 0.99) < 1e-12, "short sizing symmetric");

   TRE_CostModel s = m;
   s.slippage_mode = TRE_SLIPPAGE_FIXED_ADVERSE_POINTS;
   s.entry_slippage_points = 2;
   s.exit_slippage_points = 5;
   r.dir = TRE_DIR_LONG;
   r.stop_price = 1995.00;
   Check(TRE_SizePosition(r, spec, s, TRE_STOP_LIVE_NATIVE, econ, res), "stressed sizing ok");
   CheckNear(res.exec_entry_price, 2000.02, 1e-9, "exec entry includes entry slippage");
   CheckNear(res.worst_exit_price, 1994.95, 1e-9, "worst exit includes buffer");
   CheckNear(res.volume, 0.98, 1e-12, "stressed volume 0.98");
   Check(res.worst_loss_currency <= 500.0 + 1e-9, "stressed worst-case within 1R");

   r.stop_price = 2001.0;
   Check(!TRE_SizePosition(r, spec, m, TRE_STOP_LIVE_NATIVE, econ, res) && res.reason == TRE_SIZING_INVALID_STOP_SIDE, "stop on wrong side rejected");
   r.stop_price = 1995.0;
   r.risk_budget_currency = 5.0;
   Check(!TRE_SizePosition(r, spec, m, TRE_STOP_LIVE_NATIVE, econ, res) && res.reason == TRE_SIZING_VOLUME_BELOW_MIN, "below minimum volume rejected (never rounded up)");
   r.risk_budget_currency = 500.0;
   TRE_SymbolSpec capped = spec;
   capped.volume_max = 0.5;
   Check(TRE_SizePosition(r, capped, m, TRE_STOP_LIVE_NATIVE, econ, res) && MathAbs(res.volume - 0.5) < 1e-12, "capped at volume max");
   r.free_margin = 1000.0;   // margin/lot = 2000
   Check(TRE_SizePosition(r, spec, m, TRE_STOP_LIVE_NATIVE, econ, res) && MathAbs(res.volume - 0.5) < 1e-12, "reduced to available margin");
   r.free_margin = 10.0;
   Check(!TRE_SizePosition(r, spec, m, TRE_STOP_LIVE_NATIVE, econ, res) && res.reason == TRE_SIZING_INSUFFICIENT_MARGIN, "insufficient margin rejected");
   r.free_margin = 1e9;
   Check(!TRE_SizePosition(r, spec, m, TRE_STOP_RESEARCH_MID, econ, res) && res.reason == TRE_SIZING_SPEC_INCOMPLETE_MID_STOP, "MID-stop sizing is SPEC-INCOMPLETE");

   spec.stops_level = 50;
   Check(TRE_IsStopDistanceLegal(spec, 2000.0, 1999.5) && !TRE_IsStopDistanceLegal(spec, 2000.0, 1999.6), "stops level distance");
  }

//+------------------------------------------------------------------+
void MkAcctIn(TRE_AccountRuleInputs &in, const double closed, const double floating, const double comm,
              const double swap, const double equity)
  {
   in.closed_result = closed;
   in.floating_result = floating;
   in.commission = comm;
   in.swap = swap;
   in.fees = 0.0;
   in.balance = equity;
   in.equity = equity;
   in.day_risk_unit_currency = 500.0;
  }

void TestAccountRules(void)
  {
   Suite("0B.10 AccountRuleEngine");
   TRE_AccountRuleProfile p;
   string e;
   Check(TRE_LoadAccountRuleProfile(TRE_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, TRE_ACCOUNT_RULES_APPLY_OFFICIAL, 100000.0, "USD", 0.10, p, e), "profile loads");
   Check(!TRE_LoadAccountRuleProfile(TRE_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, TRE_ACCOUNT_RULES_APPLY_OFFICIAL, 0.0, "USD", 0.10, p, e), "zero balance rejected");
   TRE_LoadAccountRuleProfile(TRE_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, TRE_ACCOUNT_RULES_APPLY_OFFICIAL, 100000.0, "USD", 0.10, p, e);
   CTRE_AccountRuleEngine a;
   a.Init(p);
   CheckNear(a.DailyLossFloor(), -5000.0, 1e-9, "daily floor = -5% of initial balance");
   CheckNear(a.MaxLossFloorEquity(), 90000.0, 1e-9, "max-loss floor equity = 90%");

   TRE_AccountRuleInputs in;
   TRE_AccountRuleEval ev;
   MkAcctIn(in, -3000.0, -1000.0, -50.0, -10.0, 95940.0);
   CheckNear(CTRE_AccountRuleEngine::DailyNetResult(in), -4060.0, 1e-9, "DailyNetResult sums components once");
   a.Evaluate(in, 0.0, ev);
   Check(ev.state == TRE_ACCOUNT_OK, "940 above floor with 50 buffer: OK");
   CheckNear(ev.safety_buffer_currency, 50.0, 1e-9, "buffer = 0.10R x 500");
   a.Evaluate(in, 900.0, ev);
   Check(ev.state == TRE_ACCOUNT_NEAR_BREACH && ev.daily_near, "projected distance 40 <= 50: NEAR_BREACH");
   a.Evaluate(in, 940.0, ev);
   Check(ev.state == TRE_ACCOUNT_NEAR_BREACH && !ev.daily_breach, "exactly on the floor is near-breach, not breach");
   a.Evaluate(in, 950.0, ev);
   Check(ev.state == TRE_ACCOUNT_BREACH && ev.daily_breach, "below daily floor: BREACH");

   MkAcctIn(in, 0.0, 0.0, 0.0, 0.0, 90040.0);
   a.Evaluate(in, 0.0, ev);
   Check(ev.state == TRE_ACCOUNT_NEAR_BREACH && ev.max_near, "equity 40 above max-loss floor: NEAR_BREACH");
   MkAcctIn(in, 0.0, 0.0, 0.0, 0.0, 89999.0);
   Check(a.Update(D'2026.01.05 10:00', in, ev) == TRE_ACCOUNT_BREACH && ev.max_breach, "equity below max-loss floor: BREACH");
   MkAcctIn(in, 0.0, 0.0, 0.0, 0.0, 100000.0);
   Check(a.Update(D'2026.01.05 10:01', in, ev) == TRE_ACCOUNT_BREACH && a.BreachLatched(), "breach is latched for the run");

   CTRE_AccountRuleEngine b;
   b.Init(p);
   Check(b.OnTimestamp(D'2026.01.05 00:00:05'), "first reset");
   Check(!b.OnTimestamp(D'2026.01.05 12:00'), "no intraday reset");
   Check(b.OnTimestamp(D'2026.01.06 00:00:00') && b.ResetTimestamp() == D'2026.01.06 00:00:00', "reset at 00:00 broker time");
  }

//+------------------------------------------------------------------+
void AddOpen(TRE_OpenRiskItem &arr[], const ENUM_TRE_DIRECTION dir, const double loss)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].dir = dir;
   arr[n].incremental_worst_case_loss = loss;
  }

void TestRiskAdmission(void)
  {
   Suite("0C.9/1.9 Risk admission");
   TRE_RiskConfig c;
   TRE_RiskConfigDefaults(c);
   string e;
   Check(TRE_ValidateRiskConfig(c, e), "defaults valid");
   TRE_RiskConfig bad = c;
   bad.max_total_drawdown_enabled = true;
   Check(!TRE_ValidateRiskConfig(bad, e), "MaxTotalDrawdown enabled = SPEC-INCOMPLETE");
   bad = c;
   bad.max_consecutive_loss_guard_enabled = true;
   Check(!TRE_ValidateRiskConfig(bad, e), "MaxConsecutiveLossGuard enabled = SPEC-INCOMPLETE");

   CTRE_DailyRiskState d;
   Check(d.Observe(D'2026.01.05 00:00:01', 100000.0, 0.5), "day opens");
   CheckNear(d.DayRiskUnit(), 500.0, 1e-9, "1R = 0.5% of start-of-day equity");
   CheckNear(d.DailyLossFloor(3.0), 98500.0, 1e-9, "daily floor = start - 3R");
   Check(!d.Observe(D'2026.01.05 15:00', 99000.0, 0.5) && d.StartOfDayEquity() == 100000.0, "intraday equity does not rebase");
   Check(d.Observe(D'2026.01.06 00:00:00', 99000.0, 0.5) && MathAbs(d.DayRiskUnit() - 495.0) < 1e-9, "new day rebases 1R");

   TRE_AccountRuleProfile p;
   TRE_LoadAccountRuleProfile(TRE_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, TRE_ACCOUNT_RULES_APPLY_OFFICIAL, 100000.0, "USD", 0.10, p, e);
   CTRE_AccountRuleEngine acct;
   acct.Init(p);
   TRE_AccountRuleInputs ai;
   MkAcctIn(ai, 0.0, 0.0, 0.0, 0.0, 100000.0);

   TRE_OpenRiskItem none[];
   TRE_AdmissionProposal prop;
   prop.dir = TRE_DIR_LONG;
   prop.new_trade_worst_case_loss = 500.0;
   TRE_AdmissionTrace tr;
   Check(TRE_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, none, prop, acct, ai, tr), "clean book admits 1R");
   CheckNear(tr.aggregate_r_after, 1.0, 1e-12, "aggregate 1R");

   TRE_OpenRiskItem three[];
   AddOpen(three, TRE_DIR_LONG, 100);
   AddOpen(three, TRE_DIR_SHORT, 100);
   AddOpen(three, TRE_DIR_SHORT, 100);
   prop.new_trade_worst_case_loss = 100.0;
   TRE_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, three, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_MAX_CONCURRENT_POSITIONS, "4th position rejected");

   TRE_OpenRiskItem dir[];
   AddOpen(dir, TRE_DIR_LONG, 500);
   prop.new_trade_worst_case_loss = 600.0;
   TRE_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, dir, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_DIRECTIONAL_RISK_CEILING, "same-direction 2.2R > 2.0R rejected");
   prop.dir = TRE_DIR_SHORT;
   Check(TRE_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, dir, prop, acct, ai, tr), "opposite direction 1.2R admitted");

   TRE_OpenRiskItem agg[];
   AddOpen(agg, TRE_DIR_LONG, 700);
   AddOpen(agg, TRE_DIR_SHORT, 700);
   prop.dir = TRE_DIR_LONG;
   prop.new_trade_worst_case_loss = 700.0;
   MkAcctIn(ai, 1000.0, 0.0, 0.0, 0.0, 101000.0);
   TRE_EvaluateAdmission(c, 100000.0, 500.0, 101000.0, agg, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_AGGREGATE_RISK_CEILING, "aggregate 4.2R > 3.0R rejected");

   MkAcctIn(ai, -1000.0, 0.0, 0.0, 0.0, 99000.0);
   prop.new_trade_worst_case_loss = 600.0;
   TRE_EvaluateAdmission(c, 100000.0, 500.0, 99000.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_DAILY_LOSS_FLOOR, "projected 98400 < 98500 rejected");
   prop.new_trade_worst_case_loss = 500.0;
   Check(TRE_EvaluateAdmission(c, 100000.0, 500.0, 99000.0, none, prop, acct, ai, tr), "projected exactly at floor admitted");
   TRE_RiskConfig noGuard = c;
   noGuard.daily_loss_guard_enabled = false;
   prop.new_trade_worst_case_loss = 600.0;
   Check(TRE_EvaluateAdmission(noGuard, 100000.0, 500.0, 99000.0, none, prop, acct, ai, tr), "guard OFF skips daily floor");

   TRE_OpenRiskItem open1[];
   AddOpen(open1, TRE_DIR_LONG, 400);
   prop.new_trade_worst_case_loss = 200.0;
   MkAcctIn(ai, -1500.0, 0.0, 0.0, 0.0, 98500.0);
   TRE_EvaluateAdmission(c, 100000.0, 500.0, 98500.0, open1, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_DAILY_LOSS_FLOOR, "open-trade incremental loss counts toward floor");

   TRE_RiskConfig pt = c;
   pt.daily_profit_target_enabled = true;
   MkAcctIn(ai, 4500.0, 0.0, 0.0, 0.0, 104500.0);
   prop.new_trade_worst_case_loss = 500.0;
   TRE_EvaluateAdmission(pt, 100000.0, 500.0, 104500.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_DAILY_PROFIT_TARGET_REACHED, "+9R reached blocks new entries");
   MkAcctIn(ai, 4499.0, 0.0, 0.0, 0.0, 104499.0);
   Check(TRE_EvaluateAdmission(pt, 100000.0, 500.0, 104499.0, none, prop, acct, ai, tr), "below +9R admits");

   TRE_RiskConfig cap = c;
   cap.directional_position_cap_enabled = true;
   cap.max_directional_positions = 1;
   TRE_OpenRiskItem oneLong[];
   AddOpen(oneLong, TRE_DIR_LONG, 100);
   MkAcctIn(ai, 0.0, 0.0, 0.0, 0.0, 100000.0);
   prop.dir = TRE_DIR_LONG;
   TRE_EvaluateAdmission(cap, 100000.0, 500.0, 100000.0, oneLong, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_DIRECTIONAL_POSITION_CAP, "directional position cap");
   prop.dir = TRE_DIR_SHORT;
   Check(TRE_EvaluateAdmission(cap, 100000.0, 500.0, 100000.0, oneLong, prop, acct, ai, tr), "cap counts directions separately");

   MkAcctIn(ai, -4460.0, 0.0, 0.0, 0.0, 95540.0);
   prop.new_trade_worst_case_loss = 500.0;
   TRE_EvaluateAdmission(c, 95540.0, 500.0, 95540.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_ACCOUNT_RULE_NEAR_BREACH && tr.daily_floor_ok, "external account rule rejects even when internal budget passes");

   prop.new_trade_worst_case_loss = 0.0;
   MkAcctIn(ai, 0.0, 0.0, 0.0, 0.0, 100000.0);
   TRE_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == TRE_REJECT_INVALID_PROPOSAL, "zero-risk proposal invalid");
  }

//+------------------------------------------------------------------+
//| Raw-tick audit fixtures: Mon 2026-01-05 01:00–02:00, 6 ticks per |
//| minute, M1 bars derived from the same Bid values.                |
//+------------------------------------------------------------------+
void BuildAuditFixture(MqlTick &ticks[], MqlRates &rates[], const bool degrade)
  {
   ArrayResize(ticks, 0);
   ArrayResize(rates, 0);
   datetime base = D'2026.01.05 01:00';
   for(int m = 0; m < 60; m++)
     {
      datetime mt = base + m * 60;
      bool dropTicks = degrade && ((m >= 10 && m <= 16) || (m >= 40 && m <= 49));
      bool dropBar = degrade && ((m >= 13 && m <= 16) || (m >= 40 && m <= 49));
      double first = 2000.0 + m * 0.1;
      if(!dropTicks)
         for(int s = 0; s < 6; s++)
           {
            int n = ArraySize(ticks);
            ArrayResize(ticks, n + 1);
            double bid = first + s * 0.01;
            MkTick(ticks[n], mt + s * 10, 0, bid, bid + 0.20);
           }
      if(!dropBar)
        {
         int r = ArraySize(rates);
         ArrayResize(rates, r + 1);
         ZeroMemory(rates[r]);
         rates[r].time = mt;
         rates[r].open = first;
         rates[r].high = first + 0.05;
         rates[r].low = first;
         rates[r].close = first + 0.05;
         rates[r].tick_volume = 6;
         if(degrade && m == 30)
            rates[r].high += 0.50;   // contradicts raw ticks
        }
     }
  }

//+------------------------------------------------------------------+
//| Day fixture: `minutes` minutes from `base`, 6 ticks per minute.  |
//| drops[k] = {fromMinute, toMinute, dropBar}; ticks always dropped.|
//+------------------------------------------------------------------+
void BuildDayFixture(MqlTick &ticks[], MqlRates &rates[], const datetime base, const int minutes,
                     const int &drops[][3], const int nDrops)
  {
   ArrayResize(ticks, 0, minutes * 6);
   ArrayResize(rates, 0, minutes);
   for(int m = 0; m < minutes; m++)
     {
      bool dropTicks = false, dropBar = false;
      for(int k = 0; k < nDrops; k++)
         if(m >= drops[k][0] && m <= drops[k][1])
           {
            dropTicks = true;
            dropBar = (drops[k][2] != 0);
           }
      datetime mt = base + m * 60;
      double first = 2000.0 + (m % 100) * 0.1;
      if(!dropTicks)
         for(int s = 0; s < 6; s++)
           {
            int n = ArraySize(ticks);
            ArrayResize(ticks, n + 1, minutes * 6);
            double bid = first + s * 0.01;
            MkTick(ticks[n], mt + s * 10, 0, bid, bid + 0.20);
           }
      if(!dropBar)
        {
         int r = ArraySize(rates);
         ArrayResize(rates, r + 1, minutes);
         ZeroMemory(rates[r]);
         rates[r].time = mt;
         rates[r].open = first;
         rates[r].high = first + 0.05;
         rates[r].low = first;
         rates[r].close = first + 0.05;
        }
     }
  }

//--- Feeds fixtures to the audit in hourly chunks, as CTRE_RawAuditDriver does.
void FeedHourly(CTRE_RawTickAudit &audit, const MqlTick &ticks[], const MqlRates &rates[],
                const datetime from, const datetime to)
  {
   for(datetime c = from; c < to; c += 3600)
     {
      MqlTick ct[];
      MqlRates cr[];
      for(int i = 0; i < ArraySize(ticks); i++)
         if(ticks[i].time >= c && ticks[i].time < c + 3600)
           {
            int n = ArraySize(ct);
            ArrayResize(ct, n + 1);
            ct[n] = ticks[i];
           }
      for(int i = 0; i < ArraySize(rates); i++)
         if(rates[i].time >= c && rates[i].time < c + 3600)
           {
            int n = ArraySize(cr);
            ArrayResize(cr, n + 1);
            cr[n] = rates[i];
           }
      audit.ProcessChunk(ct, ArraySize(ct), cr, ArraySize(cr), c, c + 3600);
     }
  }

CTRE_SessionSchedule g_auditSched;
CTRE_ClosureCalendar g_auditCal;
CTRE_ClosureCalendar g_noCal;

void TestDataAudit(void)
  {
   Suite("1.4 Data-quality audit");
   string e;
   BuildGoldSchedule(g_auditSched);
   MqlTick ticks[];
   MqlRates rates[];

   //--- Clean hour
   BuildAuditFixture(ticks, rates, false);
   CTRE_RawTickAudit clean;
   clean.Init(GetPointer(g_auditSched), GetPointer(g_noCal), TRE_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   clean.ProcessChunk(ticks, ArraySize(ticks), rates, ArraySize(rates), D'2026.01.05 01:00', D'2026.01.05 02:00');
   Check(clean.Gate() == TRE_DATA_AUDIT_INCOMPLETE, "gate is AUDIT-INCOMPLETE before Finalize");
   clean.Finalize();
   Check(clean.EligibleMinutes() == 60 && clean.FallbackMinutes() == 0, "clean hour: 60 eligible, 0 fallback");
   Check(clean.CriticalGapCount() == 0 && clean.ClosureCount() == 0, "clean hour: session start after range start is not a gap");
   Check(clean.QuarantinedMinutes() == 0 && clean.Gate() == TRE_DATA_PASSED, "clean gate DATA-PASSED, nothing quarantined");

   //--- Degraded hour with a declared closure 01:40–01:50
   g_auditCal.Clear();
   Check(g_auditCal.Add(D'2026.01.05 01:40', D'2026.01.05 01:50', "fixture closure", e), "closure declared");
   BuildAuditFixture(ticks, rates, true);
   CTRE_RawTickAudit a;
   a.Init(GetPointer(g_auditSched), GetPointer(g_auditCal), TRE_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   a.ProcessChunk(ticks, ArraySize(ticks), rates, ArraySize(rates), D'2026.01.05 01:00', D'2026.01.05 02:00');
   a.Finalize();
   Check(a.EligibleMinutes() == 50, "declared closure minutes are not eligible (60 - 10)");
   Check(a.FallbackMinutes() == 8, "fallback = 3 no-tick+bar, 4 no-tick-no-bar, 1 reconciliation failure");
   CheckNear(a.FallbackShare(), 8.0 / 50.0, 1e-12, "fallback share");
   Check(a.CriticalGapCount() == 1 && a.ClosureCount() == 0, "mid-session 7-minute gap is a critical gap, not a closure");
   Check(a.QuarantinedMinutes() == 9, "quarantine = 8 PFM minutes + partial gap minute 01:09");
   Check(a.IsQuarantined(D'2026.01.05 01:12') && a.IsQuarantined(D'2026.01.05 01:30:30') && !a.IsQuarantined(D'2026.01.05 01:20'), "quarantine lookup");
   Check(a.Gate() == TRE_DATA_FAILED, "quarantine share 18% -> DATA-FAILED");
   Check(StringFind(a.GapsCsv(), "2026-01-05T01:09:50,2026-01-05T01:17:00,430,QUARANTINED") >= 0, "gap interval recorded as quarantined");
   Check(StringFind(a.FallbackCsv(), "2026-01-05T01:30:00,PFM_RECONCILIATION_FAILED") >= 0, "reconciliation failure listed");

   //--- Boundary helpers
   Check(g_auditSched.IsSessionStartAt(D'2026.01.05 01:00') && !g_auditSched.IsSessionStartAt(D'2026.01.05 01:01'), "session start boundary");
   Check(g_auditSched.IsSessionEndAt(D'2026.01.05 23:57') && !g_auditSched.IsSessionEndAt(D'2026.01.05 23:56'), "session end boundary");
   CTRE_SessionSchedule full;
   full.AddBrokerInterval(1, 4500, 86400, e);
   Check(full.IsSessionEndAt(D'2026.01.06 00:00'), "24:00 end boundary seen at next midnight");

   //--- Full-day fixture, Mon [01:00, 23:00): a holiday-style early close,
   //--- a Feb-20-style no-bar hole and a bar-without-ticks (fallback) hole.
   CTRE_SessionSchedule day;
   day.AddBrokerInterval(1, 3600, 23 * 3600, e);
   int drops[3][3] = {{600, 607, 1}, {700, 701, 0}, {1280, 1319, 1}};   // fromMinute, toMinute, dropBar
   BuildDayFixture(ticks, rates, D'2026.01.05 01:00', 1320, drops, 3);
   CTRE_RawTickAudit d;
   d.Init(GetPointer(day), GetPointer(g_noCal), TRE_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   FeedHourly(d, ticks, rates, D'2026.01.05', D'2026.01.06');
   d.Finalize();
   Check(d.ClosureCount() == 1, "early close (no ticks, no bars, reaches session end) auto-detected as closure");
   Check(d.EligibleMinutes() == 1280, "closure minutes excluded from eligible (1320 - 40)");
   Check(d.CriticalGapCount() == 1, "mid-session no-bar hole stays a critical gap");
   Check(d.FallbackMinutes() == 10, "PFM = 8 no-bar + 2 bar-without-ticks");
   Check(d.QuarantinedMinutes() == 11, "quarantine = 10 PFM + partial gap minute");
   Check(d.IsQuarantined(D'2026.01.05 11:03') && d.IsQuarantined(D'2026.01.05 12:41') && !d.IsQuarantined(D'2026.01.05 12:00'), "both holes quarantined");
   Check(!d.IsQuarantined(D'2026.01.05 22:30'), "closure is not quarantine");
   Check(d.Gate() == TRE_DATA_PASSED, "quarantine share 0.86% <= 1% -> DATA-PASSED");
   Check(StringFind(d.ClosuresCsv(), "2026-01-05T22:19:50,2026-01-05T23:00:00") >= 0, "closure interval recorded");

   //--- Same day, but bars still exist after the last tick: never a closure.
   int drops2[1][3] = {{1280, 1319, 0}};
   BuildDayFixture(ticks, rates, D'2026.01.05 01:00', 1320, drops2, 1);
   CTRE_RawTickAudit d2;
   d2.Init(GetPointer(day), GetPointer(g_noCal), TRE_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   FeedHourly(d2, ticks, rates, D'2026.01.05', D'2026.01.06');
   d2.Finalize();
   Check(d2.ClosureCount() == 0 && d2.CriticalGapCount() == 1, "bars without ticks at session end is a gap, not a closure");
   Check(d2.Gate() == TRE_DATA_FAILED, "40 fallback minutes -> DATA-FAILED");

   //--- Quarantine CSV round-trip
   string qpath = "TRE\\tests\\quarantine_fixture.csv";
   TRE_WriteUtf8File(qpath, d.QuarantineCsv(), true);
   CTRE_DataQuarantine q;
   Check(q.LoadCsv(qpath, e) && q.Count() == 2, "quarantine CSV loads (2 windows)");
   Check(q.IsQuarantined(D'2026.01.05 11:05') && !q.IsQuarantined(D'2026.01.05 11:30'), "loaded quarantine lookup");

   //--- Tradeable segments across a session break and a weekend
   datetime sf[], st[];
   int n = TRE_TradeableSegments(g_auditSched, g_noCal, D'2026.01.05 23:56', D'2026.01.06 01:03', sf, st);
   Check(n == 2 && st[0] - sf[0] == 60 && st[1] - sf[1] == 180, "daily break excluded (60s + 180s)");
   n = TRE_TradeableSegments(g_auditSched, g_noCal, D'2026.01.09 23:56:50', D'2026.01.12 01:00:05', sf, st);
   Check(n == 2 && st[0] - sf[0] == 10 && st[1] - sf[1] == 5, "weekend excluded");
   n = TRE_TradeableSegments(g_auditSched, g_noCal, D'2026.01.05 10:00', D'2026.01.05 10:06:01', sf, st);
   Check(n == 1 && st[0] - sf[0] == 361, "continuous in-session interval");

   //--- Tick anomalies
   TRE_TickAnomalies an;
   TRE_TickAnomaliesReset(an);
   MqlTick t1, t2, t3, t4, t5, prev;
   MkTick(t1, D'2026.01.05 10:00', 500, 2000.0, 2000.2);
   MkTick(t2, D'2026.01.05 10:00', 500, 2000.0, 2000.2);
   MkTick(t3, D'2026.01.05 10:00', 100, 2000.0, 2000.2);
   MkTick(t4, D'2026.01.05 10:00', 600, 0.0, 2000.2);
   MkTick(t5, D'2026.01.05 10:00', 700, 2000.0, 2000.0);
   ZeroMemory(prev);
   TRE_TickAnomaliesObserve(an, t1, false, prev);
   TRE_TickAnomaliesObserve(an, t2, true, t1);
   TRE_TickAnomaliesObserve(an, t3, true, t2);
   TRE_TickAnomaliesObserve(an, t4, true, t3);
   TRE_TickAnomaliesObserve(an, t5, true, t4);
   Check(an.records == 5 && an.usable == 3, "5 records, 3 usable");
   Check(an.duplicate_timestamp == 1 && an.exact_duplicate == 1, "duplicate timestamp + exact duplicate");
   Check(an.non_monotonic == 1, "non-monotonic timestamp");
   Check(an.invalid_price == 1 && an.nonpositive_spread == 1, "invalid price and zero spread");

   //--- Closure calendar file round-trip
   string path = "TRE\\tests\\closure_fixture.csv";
   int h = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, "# start,end,reason\n2026.01.01 00:00,2026.01.02 01:00,New Year\n");
      FileClose(h);
     }
   CTRE_ClosureCalendar cal;
   Check(cal.LoadCsv(path, e) && cal.Count() == 1, "closure CSV loads");
   Check(cal.Contains(D'2026.01.01 12:00') && !cal.Contains(D'2026.01.02 01:00'), "closure end exclusive");
  }

//+------------------------------------------------------------------+
void TestManifest(void)
  {
   Suite("0A.6 Manifest helpers");
   string e;
   Check(TRE_ValidateExperimentId("TRE-P1-SMOKE_2026.01", e), "experiment id valid");
   Check(!TRE_ValidateExperimentId("bad id", e) && !TRE_ValidateExperimentId("", e) && !TRE_ValidateExperimentId("..\\x", e), "unsafe experiment ids rejected");
   CTRE_InputRecorder r;
   r.Add("TimeframeSet", "M5,M15,H1", "M5,M15,H1");
   r.AddNum("RiskPerTradePercent", 0.25, 0.50);
   Check(r.NonDefaultCount() == 1, "non-default input detected");
   Check(StringFind(r.RunCardText(), "* RiskPerTradePercent = 0.25") >= 0, "run card marks non-default");
   string sha = TRE_WriteUtf8File("TRE\\tests\\sha_fixture.txt", "abc", true);
   CheckStr(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "written file hash matches content hash");
  }


//+------------------------------------------------------------------+
//| TRE bars / ATR — LSR 2.10A suite (TRE_Bars is ported; the LSR    |
//| stable-id check lives in LSR_Liquidity, which is not ported, and |
//| is replaced by the BTB event-id check below).                    |
//+------------------------------------------------------------------+
datetime P2_BASE = D'2026.01.05 10:00';

void P2Bar(TRE_Bar &b, const datetime t, const double o, const double h, const double l, const double c)
  {
   b.time = t;
   b.period = 60;
   b.open = o;
   b.high = h;
   b.low = l;
   b.close = c;
   b.ticks = 1;
  }

void TestTreBars(void)
  {
   Suite("TRE Bars / ATR (LSR 2.10A)");
   CTRE_TfAggregator agg;
   agg.Init(300);
   TRE_Bar out[];
   for(int i = 0; i < 10; i++)
     {
      TRE_Bar m, d;
      P2Bar(m, P2_BASE + i * 60, 2000 + i, 2000.5 + i, 1999.5 + i, 2000.2 + i);
      if(agg.OnM1(m, d))
        {
         int n = ArraySize(out);
         ArrayResize(out, n + 1);
         out[n] = d;
        }
     }
   TRE_Bar last;
   if(agg.Flush(last))
     {
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = last;
     }
   Check(ArraySize(out) == 2, "10 M1 bars -> 2 M5 bars");
   Check(out[0].time == P2_BASE && out[0].open == 2000 && out[0].high == 2004.5 && out[0].low == 1999.5 && out[0].close == 2004.2, "M5 OHLC aggregation");
   Check(out[1].time == P2_BASE + 300, "second M5 bar time");

   CTRE_WilderAtr atr;
   atr.Init(3);
   double bars[4][4] = {{10, 12, 9, 11}, {11, 13, 10, 12}, {12, 15, 11, 14}, {14, 14.5, 12, 13}};
   for(int i = 0; i < 4; i++)
     {
      TRE_Bar b;
      P2Bar(b, i * 60, bars[i][0], bars[i][1], bars[i][2], bars[i][3]);
      atr.Update(b);
      if(i == 1)
         Check(!atr.Ready(), "ATR not ready before n bars");
     }
   CheckNear(atr.Value(), ((10.0 / 3) * 2 + 2.5) / 3, 1e-12, "Wilder ATR recursion");
  }

//+------------------------------------------------------------------+
//| BTB fixtures — identical to python/tests/test_btb_levels.py      |
//+------------------------------------------------------------------+
//--- FundedNext XAUUSD: Mon–Fri [01:15, 24:00)
void BuildBtbGold(CTRE_SessionSchedule &s)
  {
   string e;
   s.Clear();
   for(int d = 1; d <= 5; d++)
      s.AddBrokerInterval(d, 4500, 86400, e);
  }

void BtbSpec(TRE_SymbolSpec &s, const long stopsLevel)
  {
   s.symbol = "XAUUSD";
   s.snapshot_time = 0;
   s.digits = 2;
   s.point = 0.01;
   s.tick_size = 0.01;
   s.tick_value = 1.0;
   s.tick_value_profit = 1.0;
   s.tick_value_loss = 1.0;
   s.contract_size = 100.0;
   s.volume_min = 0.01;
   s.volume_max = 100.0;
   s.volume_step = 0.01;
   s.volume_limit = 0.0;
   s.stops_level = stopsLevel;
   s.freeze_level = 0;
   s.trade_mode = 0;
   s.trade_calc_mode = 0;
   s.trade_exe_mode = 0;
   s.filling_mode = 0;
   s.order_mode = 0;
   s.chart_mode = 0;
   s.currency_base = "USD";
   s.currency_profit = "USD";
   s.currency_margin = "USD";
   s.swap_mode = 0;
   s.swap_long = 0.0;
   s.swap_short = 0.0;
   s.swap_rollover3days = 3;
   s.spread_float = true;
   s.spread_current = 0;
  }

void MkBtbQuote(TRE_Quote &q, const ulong seq, const datetime t, const int ms, const double bid, const double ask)
  {
   q.seq = seq;
   q.time = t;
   q.time_msc = (long)t * 1000 + ms;
   q.bid = bid;
   q.ask = ask;
   q.last = 0.0;
   q.volume = 0;
   q.flags = 0;
  }

//--- Day tracker + level source + one M5 engine + proxy book, fed either with
//--- completed M1 bars (M1) or with ticks exactly as BTB_Expert::OnTick (Tick).
class CBtbFlow
  {
public:
   CTRE_SessionSchedule sched;
   CBTB_DayTracker   days;
   CBTB_LevelSource  src;
   CBTB_LevelEngine  eng;
   CBTB_ProxyBook    book;
   CTRE_M1Builder    m1;
   CTRE_LinearEconomics *econ;
   ulong             seq;
   int               lastSpread;

                     CBtbFlow(void) { econ = new CTRE_LinearEconomics(100.0, 100.0); seq = 0; lastSpread = 0; }
                    ~CBtbFlow(void) { delete econ; }

   void              Init(const long stopsLevel)
     {
      BuildBtbGold(sched);
      days.Init(GetPointer(sched));
      src.Init(GetPointer(days));
      eng.Init(TRE_TF_M5, GetPointer(days), GetPointer(src), 2);
      TRE_SymbolSpec spec;
      BtbSpec(spec, stopsLevel);
      TRE_CostModel cm;
      TRE_CostModelDefaults(cm);
      book.Init(GetPointer(eng), econ, spec, cm, 0.10, 100.0);
      m1.Init(TRE_PRICE_BID, 2);
      seq = 0;
      lastSpread = 0;
     }

   void              M1(const datetime t, const double o, const double h, const double l, const double c, const int spread)
     {
      TRE_Bar b;
      b.time = t;
      b.period = 60;
      b.open = o;
      b.high = h;
      b.low = l;
      b.close = c;
      b.ticks = 1;
      days.OnM1(b, spread);
      src.OnM1(b);
      eng.OnM1(b);
     }

   //--- One bar per minute in [date+fromSec, date+toSec], flat at price (+/-0.05).
   void              Flat(const datetime date, const int fromSec, const int toSec, const double price, const int spread,
                          const int earlySpread, const int earlyUntilSec)
     {
      for(datetime t = date + fromSec; t <= date + toSec; t += 60)
        {
         int sp = (earlyUntilSec > 0 && t < date + earlyUntilSec) ? earlySpread : spread;
         M1(t, price, price + 0.05, price - 0.05, price, sp);
        }
     }

   void              FlatDay(const datetime date, const double price, const int spread)
     {
      Flat(date, 4500, 86340, price, spread, 0, 0);
     }

   //--- One M5 bar from five M1 bars: open, high, low, then close.
   void              Bar5(const datetime t, const double o, const double h, const double l, const double c)
     {
      M1(t, o, o, o, o, 20);
      M1(t + 60, o, h, MathMin(o, h), h, 20);
      M1(t + 120, h, h, l, l, 20);
      M1(t + 180, l, l, l, l, 20);
      M1(t + 240, l, MathMax(c, l), c, c, 20);
     }

   //--- Tick path (BTB_Expert::OnTick order).
   void              Tick(const datetime t, const int ms, const double bid, const double ask)
     {
      TRE_Quote q;
      MkBtbQuote(q, ++seq, t, ms, bid, ask);
      TRE_Bar b;
      if(m1.OnQuote(q, b))
        {
         days.OnM1(b, lastSpread);
         src.OnM1(b);
         eng.OnM1(b);
        }
      lastSpread = (int)MathRound((ask - bid) / 0.01);
      eng.OnTime(q.time);
      book.OnEngineUpdate();
      book.OnQuote(q);
     }

   //--- Proxy-only path: quotes reach the book, not the bar engine.
   void              Quote(const datetime t, const int ms, const double bid, const double ask)
     {
      TRE_Quote q;
      MkBtbQuote(q, ++seq, t, ms, bid, ask);
      book.OnEngineUpdate();
      book.OnQuote(q);
     }

   void              EndTicks(void)
     {
      TRE_Bar b;
      if(m1.Flush(b))
        {
         days.OnM1(b, lastSpread);
         src.OnM1(b);
         eng.OnM1(b);
        }
      eng.Flush();
      book.OnEngineUpdate();
      book.Finish();
      days.Finish();
     }

   void              EndBars(void)
     {
      eng.Flush();
      days.Finish();
     }

   //--- Index of the nth event (0-based) of a level type and side, or -1.
   int               FindEvent(const int lt, const int side, const int nth) const
     {
      int c = 0;
      for(int i = 0; i < eng.EventCount(); i++)
         if(eng.EventLevelType(i) == lt && eng.EventSide(i) == side)
           {
            if(c == nth)
               return i;
            c++;
           }
      return -1;
     }

   //--- Injects an L1 EVENT on the M5 bar at t (proxy tests).
   void              Event(const int side, const datetime t, const double o, const double h, const double l, const double c, const bool inNy)
     {
      TRE_Bar b;
      b.time = t;
      b.period = 300;
      b.open = o;
      b.high = h;
      b.low = l;
      b.close = c;
      b.ticks = 1;
      eng.InjectEvent(BTB_L1, side, side > 0 ? h - 0.5 : l + 0.5, t - 86400, b, true, inNy);
     }
  };

//+------------------------------------------------------------------+
void TestBtbTypes(void)
  {
   Suite("BTB types, ids and buckets");
   CheckStr(BTB_EventId("M5", BTB_L1, BTB_LONG, D'2026.01.06', D'2026.01.07 10:00'), "6f9e405d28b397e2",
            "event id = sha256('BTB|M5|L1|LONG|2026-01-06T00:00:00|2026-01-07T10:00:00')[:16]");
   int even[] = {30, 20, 25, 26};
   int odd[] = {3};
   CheckNear(BTB_MedianInt(even), 25.5, 1e-12, "median of an even count = mean of the two middle values");
   CheckNear(BTB_MedianInt(odd), 3.0, 1e-12, "median of one sample");
   Check(even[0] == 30, "median does not reorder the caller's samples");
   CheckStr(BTB_LevelTypeName(BTB_L4) + BTB_SideName(BTB_SHORT), "L4SHORT", "level and side names");
   CheckStr(BTB_DayStatusName(BTB_DAY_ABNORMAL), "ABNORMAL_SPREAD_DAY", "abnormal day name");
   CheckStr(BTB_EventStatusName(BTB_EV_OPEN_BEYOND), "OPEN_BEYOND_LEVEL", "open-beyond status name");
   CheckStr(BTB_ProxyStateName(BTB_PX_CLOSED, true) + "," + BTB_ProxyStateName(BTB_PX_CLOSED, false), "FILLED_AT_PLACEMENT,FILLED", "fill state names");
   CheckStr(BTB_SpreadBucket(2.99) + BTB_SpreadBucket(3.0) + BTB_SpreadBucket(5.0) + BTB_SpreadBucket(8.0), "LT33_55_8GE8", "spread buckets <3, 3-5, 5-8, >=8 pips");
   CheckStr(BTB_BoxBucket(20) + BTB_BoxBucket(39) + BTB_BoxBucket(40) + BTB_BoxBucket(60) + BTB_BoxBucket(96) + BTB_BoxBucket(0),
            "20_3920_3940_5960_9660_96NA", "box_n buckets");
   CheckStr(BTB_HourBucket(7) + BTB_HourBucket(8) + BTB_HourBucket(16) + BTB_HourBucket(17), "H00_08H08_13H13_17H17_24", "hour buckets");
   //--- exit precedence on one tick (roadmap 5.4): stop wins; live SL/TP before the 21:30 close
   Check(BTB_ResolveExit(true, true, false, false) == BTB_EXIT_SL, "SL and TP on one tick -> SL");
   Check(BTB_ResolveExit(true, true, true, true) == BTB_EXIT_GAP_SL, "gap tick with both barriers -> GAP_SL");
   Check(BTB_ResolveExit(false, true, true, false) == BTB_EXIT_TP, "TP before the session close");
   Check(BTB_ResolveExit(true, false, true, false) == BTB_EXIT_SL, "SL before the session close");
   Check(BTB_ResolveExit(false, false, true, false) == BTB_EXIT_SESSION_CLOSE, "21:30 close");
   Check(BTB_ResolveExit(false, false, true, true) == BTB_EXIT_GAP_SESSION_CLOSE, "21:30 close after a gap");
   Check(BTB_ResolveExit(false, false, false, true) == BTB_EXIT_NONE, "no exit");
  }

//+------------------------------------------------------------------+
void TestBtbWindow(void)
  {
   Suite("BTB 3 Windows and the spread-normal resume rule");
   datetime mon = D'2026.01.05', tue = D'2026.01.06', wed = D'2026.01.07';
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 30, 0, 0);
      h.days.Finish();
      Check(h.days.Status(mon) == BTB_DAY_WARMUP, "first trading day is a warm-up day");
      bool f, n;
      h.days.Window(mon, D'2026.01.05 12:00', f, n);
      Check(!f && !n, "warm-up day has no window");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 30, 0, 0);
      h.Flat(tue, 4500, 86340, 2000.0, 40, 100, 7200);
      h.days.Finish();
      int i = h.days.Find(tue);
      Check(i >= 0 && h.days.DayHasRef(i) && h.days.DayRef(i) == 30.0 && h.days.DayRefN(i) == 690, "reference = median of the 690 samples in [10:00, 21:30)");
      Check(h.days.DaySessionStart(i) == D'2026.01.06 01:15', "NextTradableSessionStart = 01:15");
      Check(h.days.DayStatus(i) == BTB_DAY_NORMAL && h.days.DayResume(i) == D'2026.01.06 02:05', "resume = close of the 5th normal bar (02:05)");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 20, 0, 0);
      for(datetime t = tue + 4500; t <= tue + 86340; t += 60)
         h.M1(t, 2000.0, 2000.05, 1999.95, 2000.0, t == D'2026.01.06 01:17' ? 31 : 30);
      int i = h.days.Find(tue);
      Check(h.days.DayResume(i) == D'2026.01.06 01:23', "30 <= 1.5 x 20 qualifies; 31 resets the run");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 20, 0, 0);
      h.Flat(tue, 4500, 86340, 2000.0, 20, 90, 16 * 3600 + 26 * 60);
      int i = h.days.Find(tue);
      Check(h.days.DayStatus(i) == BTB_DAY_ABNORMAL && h.days.DayResume(i) == D'2026.01.06 16:30', "not met by 16:30 -> ABNORMAL_SPREAD_DAY, resume 16:30");
      bool f, n;
      h.days.Window(tue, D'2026.01.06 16:25', f, n);
      Check(!f && !n, "abnormal day: 16:25 outside");
      h.days.Window(tue, D'2026.01.06 16:30', f, n);
      Check(f && n, "abnormal day: 16:30 inside FULL and NY");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 20, 0, 0);
      h.Flat(tue, 4500, 86340, 2000.0, 20, 90, 16 * 3600 + 25 * 60);
      int i = h.days.Find(tue);
      Check(h.days.DayStatus(i) == BTB_DAY_NORMAL && h.days.DayResume(i) == D'2026.01.06 16:30', "resume exactly at 16:30 is NORMAL");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 20, 0, 0);
      h.Flat(tue, 4500, 86340, 2000.0, 20, 0, 0);
      Check(h.days.ResumeOf(tue) == D'2026.01.06 01:20', "resume 01:20 on a normal morning");
      bool f, n;
      h.days.Window(tue, D'2026.01.06 01:15', f, n);
      Check(!f && !n, "01:15 before resume: outside");
      h.days.Window(tue, D'2026.01.06 01:20', f, n);
      Check(f && !n, "01:20: FULL only");
      h.days.Window(tue, D'2026.01.06 16:29', f, n);
      Check(f && !n, "16:29: FULL only");
      h.days.Window(tue, D'2026.01.06 16:30', f, n);
      Check(f && n, "16:30: FULL and NY");
      h.days.Window(tue, D'2026.01.06 21:29', f, n);
      Check(f && n, "21:29: FULL and NY");
      h.days.Window(tue, D'2026.01.06 21:30', f, n);
      Check(!f && !n, "21:30: late-spread block");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 20, 0, 0);
      h.Flat(tue, 4500, 9 * 3600, 2000.0, 50, 0, 0);
      h.Flat(wed, 4500, 86340, 2000.0, 25, 0, 0);
      int i = h.days.Find(wed);
      Check(h.days.DayRefDate(i) == mon && h.days.DayRef(i) == 20.0, "reference skips a day without samples in [10:00, 21:30)");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(D'2026.01.09', 4500, 86340, 2000.0, 20, 0, 0);
      h.Flat(D'2026.01.10', 36000, 39600, 2000.0, 20, 0, 0);
      h.days.Finish();
      Check(h.days.Status(D'2026.01.10') == BTB_DAY_NO_SESSION, "Saturday bars: NO_SESSION_START");
      CheckStr(h.days.CsvRow(0), "2026-01-09,FRIDAY,2026-01-09T01:15:00,,NA,0,,,WARMUP,1365", "days.csv row format (warm-up)");
     }
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(mon, 4500, 86340, 2000.0, 30, 0, 0);
      h.Flat(tue, 4500, 86340, 2000.0, 40, 100, 7200);
      h.days.Finish();
      CheckStr(h.days.CsvRow(1), "2026-01-06,TUESDAY,2026-01-06T01:15:00,2026-01-05,30.0,690,2026-01-06T02:05:00,2026-01-06T16:30:00,NORMAL,1365",
               "days.csv row format (normal)");
     }
  }

//+------------------------------------------------------------------+
void BtbBase(CBtbFlow &h)
  {
   h.FlatDay(D'2026.01.05', 2000.0, 20);   // Monday: first data day, never a PDH/PDL source
   h.FlatDay(D'2026.01.06', 2000.0, 20);   // Tuesday: PDH 2000.05 / PDL 1999.95 source
  }

void TestBtbLevels(void)
  {
   Suite("BTB 4 Levels and breakout events");
   datetime wed = D'2026.01.07';
   //--- L1 breakout, consumption, short side
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 10:00', 2000.00, 2000.40, 1999.90, 2000.30);
      h.Bar5(D'2026.01.07 10:05', 2000.30, 2000.10, 1999.00, 1999.10);
      h.Bar5(D'2026.01.07 10:10', 2000.00, 2000.50, 1999.90, 2000.40);
      h.M1(D'2026.01.07 10:15', 2000.4, 2000.4, 2000.4, 2000.4, 20);
      Check(h.eng.CountType(BTB_L1, BTB_LONG) == 1, "PDH breaks once; the later re-break is consumed");
      int e = h.FindEvent(BTB_L1, BTB_LONG, 0);
      Check(e >= 0 && h.eng.EventLevelPrice(e) == 2000.05 && h.eng.EventStatus(e) == BTB_EV_EVENT && h.eng.EventBarTime(e) == D'2026.01.07 10:00',
            "PDH 2000.05 broken by the 10:00 candle (open <= level, close > level)");
      Check(e >= 0 && h.eng.EventInFull(e) && !h.eng.EventInNy(e), "10:05 close: FULL, not NY");
      Check(e >= 0 && h.eng.EventSourceTime(e) == D'2026.01.06', "L1 source time = previous trading day");
      int s = h.FindEvent(BTB_L1, BTB_SHORT, 0);
      Check(h.eng.CountType(BTB_L1, BTB_SHORT) == 1 && s >= 0 && h.eng.EventBarTime(s) == D'2026.01.07 10:05', "PDL 1999.95 broken down at 10:05");
     }
   //--- open beyond the level: ledgered, consumed, not traded
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 9 * 3600 + 59 * 60, 2001.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 10:00', 2001.00, 2001.20, 2000.90, 2001.10);
      int e = h.FindEvent(BTB_L1, BTB_LONG, 0);
      Check(h.eng.CountType(BTB_L1, BTB_LONG) == 1 && e >= 0 && h.eng.EventStatus(e) == BTB_EV_OPEN_BEYOND &&
            h.eng.EventBarTime(e) == D'2026.01.07 01:15', "first bar opens above PDH: OPEN_BEYOND_LEVEL once");
     }
   //--- open exactly on the level is a breakout; a wick is not
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 10:00', 2000.05, 2000.40, 2000.00, 2000.30);
      h.M1(D'2026.01.07 10:05', 2000.3, 2000.3, 2000.3, 2000.3, 20);
      int e = h.FindEvent(BTB_L1, BTB_LONG, 0);
      Check(e >= 0 && h.eng.EventStatus(e) == BTB_EV_EVENT, "open == level, close > level: EVENT");
     }
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 10:00', 2000.00, 2000.60, 1999.99, 2000.05);
      h.M1(D'2026.01.07 10:05', 2000.0, 2000.0, 2000.0, 2000.0, 20);
      Check(h.eng.CountType(BTB_L1, BTB_LONG) == 0, "wick above, close == level: no breakout");
     }
   //--- L2 Asian range [resume, 08:00), usable from 08:00
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      for(datetime t = wed + 4500; t <= wed + 7 * 3600 + 59 * 60; t += 60)
        {
         double hi = (t == D'2026.01.07 02:55' ? 2003.00 : t == D'2026.01.07 01:15' ? 2009.00 : 2000.05);
         h.M1(t, 2000.0, hi, 1999.95, 2000.0, 20);
        }
      h.Flat(wed, 8 * 3600, 8 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 09:00', 2000.00, 2003.50, 1999.90, 2003.20);
      h.M1(D'2026.01.07 09:05', 2003.2, 2003.2, 2003.2, 2003.2, 20);
      int e = h.FindEvent(BTB_L2, BTB_LONG, 0);
      Check(h.eng.CountType(BTB_L2, BTB_LONG) == 1 && e >= 0 && h.eng.EventLevelPrice(e) == 2003.00 &&
            h.eng.EventSourceTime(e) == D'2026.01.07 01:20', "Asian high 2003.00 from [01:20, 08:00); the 01:15 bar is before resume");
     }
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 7 * 3600 + 54 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 07:55', 2000.00, 2003.50, 1999.90, 2003.20);
      h.M1(D'2026.01.07 08:00', 2003.2, 2003.2, 2003.2, 2003.2, 20);
      Check(h.eng.CountType(BTB_L2, BTB_LONG) + h.eng.CountType(BTB_L2, BTB_SHORT) == 0, "Asian range not usable before 08:00");
     }
   //--- L3 H1 2/2 fractal
     {
      CBtbFlow h;
      h.Init(0);
      double hl[6][2] = {{2000, 2001}, {2000, 2003}, {2000, 2005}, {2000, 2002}, {2000, 2001}, {2000, 2001}};
      datetime t = D'2026.01.06 02:00';
      for(int i = 0; i < 6; i++)
         h.M1(t + i * 3600, hl[i][0], hl[i][1], hl[i][0], hl[i][0], 20);
      int n3 = 0, li = -1;
      for(int i = 0; i < h.src.LevelCount(); i++)
         if(h.src.LevelType(i) == BTB_L3)
           {
            n3++;
            li = i;
           }
      Check(n3 == 1 && li >= 0 && h.src.LevelSide(li) == BTB_LONG && h.src.LevelPrice(li) == 2005 && h.src.LevelSourceTime(li) == t + 2 * 3600,
            "one swing high 2005 at the 04:00 H1 bar");
      Check(li >= 0 && h.src.LevelAvail(li) == t + 5 * 3600, "usable from the close of the second right bar");
      Check(li >= 0 && h.src.LevelExpiryH1(li) == 4 + BTB_L3_LIFE_H1_BARS, "life ends at the close of H1 bar confirm+120");
     }
   //--- L4 consolidation box and cooldown
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      Check(h.eng.CountType(BTB_L4, BTB_LONG) + h.eng.CountType(BTB_L4, BTB_SHORT) == 0, "flat bars inside the box: no L4 row");
      h.Bar5(D'2026.01.07 10:00', 2000.00, 2000.12, 1999.98, 2000.10);
      h.Bar5(D'2026.01.07 10:05', 2000.10, 2000.10, 1999.88, 1999.90);
      h.Bar5(D'2026.01.07 10:10', 1999.90, 2000.25, 1999.90, 2000.20);
      h.M1(D'2026.01.07 10:15', 2000.2, 2000.2, 2000.2, 2000.2, 20);
      int a = h.FindEvent(BTB_L4, BTB_LONG, 0), b = h.FindEvent(BTB_L4, BTB_SHORT, 0);
      Check(a >= 0 && h.eng.EventBarTime(a) == D'2026.01.07 10:00' && h.eng.EventStatus(a) == BTB_EV_EVENT, "box top broken at 10:00");
      Check(a >= 0 && h.eng.EventBoxN(a) == 96 && h.eng.EventLevelPrice(a) == 2000.05 && h.eng.EventSourceTime(a) == D'2026.01.07 10:00' - 96 * 300,
            "longest box N = 96, top 2000.05, source = first box bar");
      Check(b >= 0 && h.eng.EventBarTime(b) == D'2026.01.07 10:05' && h.eng.EventLevelPrice(b) == 1999.95 && h.eng.EventBoxN(b) == 96,
            "other side is not in cooldown: bottom 1999.95 broken at 10:05");
      Check(h.eng.CountType(BTB_L4, BTB_LONG) == 1, "the 10:10 crossing of the new top 2000.12 is inside the 20-bar long cooldown");
     }
     {
      CBtbFlow h;
      h.Init(0);
      datetime t = D'2026.01.07 01:15';
      for(int i = 0; i < 400; i++)
        {
         double p = NormalizeDouble(2000.0 + 0.2 * i, 2);
         h.M1(t + i * 60, p, NormalizeDouble(p + 0.05, 2), NormalizeDouble(p - 0.05, 2), p, 20);
        }
      Check(h.eng.CountType(BTB_L4, BTB_LONG) + h.eng.CountType(BTB_L4, BTB_SHORT) == 0, "steady trend: no box (range > 2.5 ATR)");
     }
   //--- warm-up day
     {
      CBtbFlow h;
      h.Init(0);
      h.Flat(D'2026.01.05', 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.05 10:00', 2000.00, 2000.80, 1999.98, 2000.70);
      h.M1(D'2026.01.05 10:05', 2000.7, 2000.7, 2000.7, 2000.7, 20);
      int a = h.FindEvent(BTB_L4, BTB_LONG, 0);
      Check(a >= 0 && h.eng.EventStatus(a) == BTB_EV_WARMUP && !h.eng.EventInFull(a) && !h.eng.EventInNy(a), "breakout on the warm-up day: WARMUP, no window");
     }
   //--- ledger row format
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(wed, 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 10:00', 2000.00, 2000.40, 1999.90, 2000.30);
      h.M1(D'2026.01.07 10:05', 2000.3, 2000.3, 2000.3, 2000.3, 20);
      int e = h.FindEvent(BTB_L1, BTB_LONG, 0);
      CBTB_QuarantineCheck none;
      Check(e >= 0 && StringFind(h.eng.CsvRow(e, none), "6f9e405d28b397e2,M5,L1,LONG,2000.05,2026-01-06T00:00:00,NA,2026-01-07T10:00:00,2026-01-07T10:05:00,2000.00,2000.40,1999.90,2000.30,") == 0,
            "events.csv row: id, tf, level, side, price, source, box_n, times, OHLC");
      Check(e >= 0 && StringFind(h.eng.CsvRow(e, none), ",1,0,EVENT") > 0, "events.csv row: in_full, in_ny, status");
     }
  }

//+------------------------------------------------------------------+
//| Tick path == M1 path: the ledgers written by BTB_Expert (signal  |
//| bars completed by OnTime) equal the M1-only replay/Python path.  |
//+------------------------------------------------------------------+
int CountEventsOutsideFull(const CBTB_LevelEngine &e)
  {
   int c = 0;
   for(int i = 0; i < e.EventCount(); i++)
      if(e.EventStatus(i) == BTB_EV_EVENT && !e.EventInFull(i))
         c++;
   return c;
  }

void TestBtbTickPath(void)
  {
   Suite("BTB 7 Tick path equals the M1 path");
   CBtbFlow a, b;
   a.Init(0);
   b.Init(0);
   long x = 20260929;
   long lcgMod = ((long)1) << 31;
   double price = 2650.00;
   datetime days[4] = {D'2026.01.05', D'2026.01.06', D'2026.01.07', D'2026.01.08'};
   for(int d = 0; d < 4; d++)
      for(datetime t = days[d] + 4500; t <= days[d] + 86340; t += 60)
        {
         x = (x * 1103515245 + 12345) % lcgMod;
         if(x % 50 == 0)
            continue;                                      // a minute without ticks
         price = NormalizeDouble(price + ((x / 7) % 21 - 10) * 0.07, 2);
         int sod = (int)(t - days[d]);
         int sp = (sod < 2 * 3600 || sod >= BTB_LATE_BLOCK_SEC) ? 90 : 28 + (int)(x % 5);
         a.M1(t, price, price, price, price, sp);
         b.Tick(t + 30, 0, price, NormalizeDouble(price + sp * 0.01, 2));
        }
   a.EndBars();
   b.EndTicks();
   CBTB_QuarantineCheck none;
   Check(a.eng.EventCount() > 10 && a.eng.CountStatus(BTB_EV_EVENT) > 0, "fixture produces breakout events");
   Check(a.eng.EventCount() == b.eng.EventCount(), "same number of event rows");
   bool same = (a.eng.EventCount() == b.eng.EventCount());
   for(int i = 0; same && i < a.eng.EventCount(); i++)
      if(a.eng.CsvRow(i, none) != b.eng.CsvRow(i, none))
        {
         same = false;
         PrintFormat("tick-path mismatch row %d:\n  M1:   %s\n  tick: %s", i, a.eng.CsvRow(i, none), b.eng.CsvRow(i, none));
        }
   Check(same, "every events.csv row identical");
   bool sameDays = (a.days.DayCount() == b.days.DayCount());
   for(int i = 0; sameDays && i < a.days.DayCount(); i++)
      if(a.days.CsvRow(i) != b.days.CsvRow(i))
         sameDays = false;
   Check(sameDays, "every days.csv row identical");
   Check(b.book.ProxyCount() == 3 * b.eng.CountStatus(BTB_EV_EVENT) - 3 * CountEventsOutsideFull(b.eng), "three proxies per EVENT inside FULL");
   Check(b.book.LiveCount() == 0, "no proxy left pending or open after Finish");
  }

//+------------------------------------------------------------------+
void TestBtbProxy(void)
  {
   Suite("BTB 5 Limit-order proxies");
   double c1 = 100.0 * 2000.50 * 0.000016;   // commission, 1 lot at P = 2000.50
   //--- long: placement, exact limit fill, spread-offset SL, TP solve, TP exit, 21:30 close
     {
      CBtbFlow h;
      h.Init(0);
      h.Event(BTB_LONG, D'2026.01.07 10:00', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.Quote(D'2026.01.07 10:04:59', 900, 2000.40, 2000.70);
      Check(h.book.ProxyCount() == 3 && h.book.ProxyState(0) == BTB_PX_WAIT_PLACEMENT, "three proxies wait for the first tick at/after the close");
      h.Quote(D'2026.01.07 10:05:00', 100, 2000.60, 2000.90);
      int p1 = h.book.Find(0, 1), p2 = h.book.Find(0, 2), p3 = h.book.Find(0, 3);
      Check(h.book.ProxyPlaceMsc(p1) == (long)D'2026.01.07 10:05:00' * 1000 + 100, "placed on the first tick at/after the breakout close");
      Check(h.book.ProxyLimit(p1) == 2000.50 && h.book.ProxyState(p1) == BTB_PX_PENDING, "Buy Limit at the breakout close 2000.50, pending (Ask 2000.90)");
      CheckNear(h.book.ProxyS0(p1), 0.30, 1e-9, "s0 = Ask - Bid at placement");
      CheckNear(h.book.ProxySL(p1), 1998.70, 1e-9, "long SL = breakout low - s0");
      CheckNear(h.book.ProxyRisk1R(p1), 180.0 + c1, 1e-6, "PlannedRisk1R = loss(P -> SL) + commission");
      CheckNear(h.book.ProxyTP(p1), 2002.37, 1e-9, "TP1 solved for net 1R, aligned outward");
      CheckNear(h.book.ProxyTP(p2), 2004.20, 1e-9, "TP2 solved for net 2R");
      CheckNear(h.book.ProxyTP(p3), 2006.03, 1e-9, "TP3 solved for net 3R");
      for(int k = 1; k <= 3; k++)
        {
         int p = h.book.Find(0, k);
         double R = h.book.ProxyRisk1R(p);
         double atTp = (h.book.ProxyTP(p) - 2000.50) * 100.0 - c1;
         double oneTickIn = (h.book.ProxyTP(p) - 0.01 - 2000.50) * 100.0 - c1;
         Check(atTp >= k * R - 1e-9 && oneTickIn < k * R, StringFormat("TP%d: net at TP >= %dR and one tick inward < %dR (never reduced)", k, k, k));
        }
      h.Quote(D'2026.01.07 10:06:00', 0, 2000.20, 2000.51);
      Check(h.book.ProxyState(p1) == BTB_PX_PENDING && !h.book.ProxyFilled(p1), "Ask = P + 1 point: no fill");
      h.Quote(D'2026.01.07 10:07:00', 0, 2000.20, 2000.50);
      Check(h.book.ProxyState(p1) == BTB_PX_OPEN && h.book.ProxyFillMsc(p1) == (long)D'2026.01.07 10:07:00' * 1000, "Ask = P: filled");
      Check(!h.book.ProxyAtPlacement(p1) && h.book.ProxyState(p3) == BTB_PX_OPEN, "FILLED (not at placement); all three R filled together");
      CheckNear(h.book.ProxyMae(p1), 0.30, 1e-9, "MAE measured from the fill tick (Bid)");
      h.Quote(D'2026.01.07 10:11:00', 0, 2002.37, 2002.67);   // 240 s after the fill: no gap
      Check(h.book.ProxyState(p1) == BTB_PX_CLOSED && h.book.ProxyExitReason(p1) == BTB_EXIT_TP && h.book.ProxyExitPrice(p1) == 2002.37, "R1 exits at TP, at the TP price");
      Check(h.book.ProxyNetR(p1) >= 1.0 && h.book.ProxyNetR(p1) < 1.0 + 1.0 / h.book.ProxyRisk1R(p1) + 1e-9, "realized net result at TP is at least 1R (full reward)");
      Check(h.book.ProxyState(p2) == BTB_PX_OPEN && h.book.ProxyState(p3) == BTB_PX_OPEN, "R2 and R3 still open");
      h.Quote(D'2026.01.07 21:29:00', 0, 2001.10, 2001.40);
      h.Quote(D'2026.01.07 21:30:05', 0, 2001.00, 2001.30);
      Check(h.book.ProxyExitReason(p2) == BTB_EXIT_SESSION_CLOSE && h.book.ProxyExitPrice(p2) == 2001.00, "21:30: open long closed at Bid (SESSION_CLOSE)");
      Check(h.book.ProxyExitReason(p3) == BTB_EXIT_SESSION_CLOSE && h.book.LiveCount() == 0, "every proxy closed at 21:30");
      CheckNear(h.book.ProxyNetR(p2), (50.0 - c1) / (180.0 + c1), 1e-9, "SESSION_CLOSE net R");
     }
   //--- short: FILLED_AT_PLACEMENT, spread-offset SL above the high, stop at the Ask
     {
      CBtbFlow h;
      h.Init(0);
      double c2 = 100.0 * 1999.50 * 0.000016;
      h.Event(BTB_SHORT, D'2026.01.07 11:00', 2000.00, 2001.00, 1999.00, 1999.50, false);
      h.Quote(D'2026.01.07 11:05:00', 200, 1999.60, 1999.80);
      int p = h.book.Find(0, 1);
      Check(h.book.ProxyState(p) == BTB_PX_OPEN && h.book.ProxyAtPlacement(p), "Sell Limit with Bid >= P at placement: FILLED_AT_PLACEMENT");
      CheckStr(h.book.ProxyStateText(p), "OPEN", "state text while open");
      CheckNear(h.book.ProxySL(p), 2001.20, 1e-9, "short SL = breakout high + s0 (0.20)");
      CheckNear(h.book.ProxyTP(p), 1997.73, 1e-9, "short TP1 aligned outward (down)");
      h.Quote(D'2026.01.07 11:06:00', 0, 2001.00, 2001.19);
      Check(h.book.ProxyState(p) == BTB_PX_OPEN, "Ask below SL: still open (never stopped by the entry spread)");
      h.Quote(D'2026.01.07 11:06:30', 0, 2001.00, 2001.20);
      Check(h.book.ProxyExitReason(p) == BTB_EXIT_SL && h.book.ProxyExitPrice(p) == 2001.20, "Ask >= SL: stopped at the Ask");
      CheckNear(h.book.ProxyNetR(p), -1.0, 1e-9, "stop at SL = -1R net");
      CheckStr(h.book.ProxyStateText(p), "FILLED_AT_PLACEMENT", "ledger state");
      CheckNear(h.book.ProxyRisk1R(p), 170.0 + c2, 1e-6, "short PlannedRisk1R");
     }
   //--- MISSED_TP_FIRST per R, then CANCELLED_WINDOW_END at 21:30
     {
      CBtbFlow h;
      h.Init(0);
      h.Event(BTB_LONG, D'2026.01.08 21:00', 2000.00, 2001.00, 1999.00, 2000.50, true);
      h.Quote(D'2026.01.08 21:05:00', 100, 2000.60, 2000.90);
      h.Quote(D'2026.01.08 21:06:00', 0, 2002.40, 2002.70);
      int p1 = h.book.Find(0, 1), p2 = h.book.Find(0, 2);
      Check(h.book.ProxyState(p1) == BTB_PX_MISSED_TP_FIRST, "Bid >= TP1 before the fill: R1 MISSED_TP_FIRST");
      Check(h.book.ProxyState(p2) == BTB_PX_PENDING, "TP2 not reached: R2 still pending");
      h.Quote(D'2026.01.08 21:29:59', 0, 2001.00, 2001.30);
      Check(h.book.ProxyState(p2) == BTB_PX_PENDING, "21:29:59 still pending");
      h.Quote(D'2026.01.08 21:30:00', 0, 2000.00, 2000.30);
      Check(h.book.ProxyState(p2) == BTB_PX_CANCELLED_WINDOW_END && !h.book.ProxyFilled(p2), "21:30: pending limit cancelled, never filled");
     }
   //--- EXPIRED_12_BARS
     {
      CBtbFlow h;
      h.Init(0);
      h.Event(BTB_LONG, D'2026.01.09 10:00', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.Quote(D'2026.01.09 10:05:00', 100, 2000.60, 2000.90);
      h.Quote(D'2026.01.09 11:04:59', 0, 2001.00, 2001.30);
      Check(h.book.LiveCount() == 3, "still pending just before 12 signal bars");
      h.Quote(D'2026.01.09 11:05:00', 0, 2000.20, 2000.50);
      Check(h.book.CountState(BTB_PX_EXPIRED_12_BARS) == 3 && h.book.CountState(BTB_PX_OPEN) == 0, "12 M5 bars after the close: EXPIRED_12_BARS (expiry checked before the fill)");
     }
   //--- gap exit and END_OF_DATA
     {
      CBtbFlow h;
      h.Init(0);
      h.Event(BTB_LONG, D'2026.01.07 10:00', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.Event(BTB_LONG, D'2026.01.07 12:00', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.Quote(D'2026.01.07 10:05:00', 0, 2000.20, 2000.50);
      Check(h.book.ProxyAtPlacement(h.book.Find(0, 1)), "Buy Limit with Ask <= P at placement: FILLED_AT_PLACEMENT");
      h.Quote(D'2026.01.07 10:11:41', 0, 1998.70, 1999.00);
      Check(h.book.ProxyExitReason(h.book.Find(0, 1)) == BTB_EXIT_GAP_SL, "Bid <= SL after a > 300 s tick gap: GAP_SL");
      h.Quote(D'2026.01.07 12:05:00', 0, 2000.20, 2000.50);
      h.Quote(D'2026.01.07 12:06:00', 0, 2000.80, 2001.10);
      h.book.Finish();
      int q = h.book.Find(1, 2);
      Check(h.book.ProxyExitReason(q) == BTB_EXIT_END_OF_DATA && h.book.ProxyExitPrice(q) == 2000.80, "open at the end of data: END_OF_DATA at the last Bid");
     }
   //--- INVALID_STOP_GEOMETRY and NOT_PLACED_END_OF_DATA
     {
      CBtbFlow h;
      h.Init(500);   // SYMBOL_TRADE_STOPS_LEVEL = 500 points = 5.00
      h.Event(BTB_LONG, D'2026.01.07 10:00', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.Quote(D'2026.01.07 10:05:00', 0, 2000.60, 2000.90);
      Check(h.book.CountState(BTB_PX_INVALID_STOP_GEOMETRY) == 3, "SL closer than SYMBOL_TRADE_STOPS_LEVEL: INVALID_STOP_GEOMETRY");
      h.Event(BTB_LONG, D'2026.01.07 10:10', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.book.OnEngineUpdate();
      h.book.Finish();
      Check(h.book.CountState(BTB_PX_NOT_PLACED_END_OF_DATA) == 3, "event after the last tick: NOT_PLACED_END_OF_DATA");
     }
   //--- only EVENT rows inside FULL get proxies
     {
      CBtbFlow h;
      h.Init(0);
      TRE_Bar b;
      b.time = D'2026.01.07 22:00';
      b.period = 300;
      b.open = 2000.0;
      b.high = 2001.0;
      b.low = 1999.0;
      b.close = 2000.5;
      b.ticks = 1;
      h.eng.InjectEvent(BTB_L2, BTB_LONG, 2000.2, D'2026.01.07 01:20', b, false, false);
      h.book.OnEngineUpdate();
      Check(h.book.ProxyCount() == 0, "event outside the FULL window: ledgered, no proxy");
     }
  }

//+------------------------------------------------------------------+
//| Ledgers, quarantine and the run-package writer.                  |
//+------------------------------------------------------------------+
class CBtbQuarantineWindow : public CBTB_QuarantineCheck
  {
public:
   datetime          from;
   datetime          to;
   virtual bool      Overlaps(const datetime a, const datetime b) { return from < b && a < to; }
  };

void TestBtbLedgers(void)
  {
   Suite("BTB ledgers, quarantine and run package");
   string shaAbc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
   string shaAbcLf = "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb";
   CBTB_RunOutput o;
   o.Init("tests");
   CheckStr(o.Dir(), "BTB\\tests\\", "run package folder Common\\Files\\BTB\\<ExperimentId>\\");
   CheckStr(o.Write("out_fixture.txt", "abc"), shaAbc, "Write returns the SHA-256 of the UTF-8 bytes");
   int fh = FileOpen(o.Dir() + "line_fixture.txt", FILE_WRITE | FILE_BIN | FILE_COMMON);
   BTB_WriteLine(fh, "abc");
   FileClose(fh);
   CheckStr(o.RegisterFile("line_fixture.txt"), shaAbcLf, "BTB_WriteLine writes UTF-8 + LF; RegisterFile hashes from disk");
   CTRE_Json j;
   o.WriteIndexJson(j);
   CheckStr(j.Text(), "[{\"file\":\"out_fixture.txt\",\"sha256\":\"" + shaAbc + "\"},{\"file\":\"line_fixture.txt\",\"sha256\":\"" + shaAbcLf + "\"}]",
            "manifest file index");
   Check(o.Failures() == 0, "no write failures");
   CheckStr(BTB_ExitReasonName(BTB_EXIT_TP) + "," + BTB_ExitReasonName(BTB_EXIT_SL) + "," + BTB_ExitReasonName(BTB_EXIT_SESSION_CLOSE) + "," +
            BTB_ExitReasonName(BTB_EXIT_GAP_TP) + "," + BTB_ExitReasonName(BTB_EXIT_GAP_SL) + "," + BTB_ExitReasonName(BTB_EXIT_GAP_SESSION_CLOSE) + "," +
            BTB_ExitReasonName(BTB_EXIT_END_OF_DATA) + "," + BTB_ExitReasonName(BTB_EXIT_NONE),
            "TP,SL,SESSION_CLOSE,GAP_TP,GAP_SL,GAP_SESSION_CLOSE,END_OF_DATA,", "exit reason names");

   //--- days.csv and events.csv on disk equal the rows in memory
     {
      CBtbFlow h;
      h.Init(0);
      BtbBase(h);
      h.Flat(D'2026.01.07', 4500, 9 * 3600 + 59 * 60, 2000.0, 20, 0, 0);
      h.Bar5(D'2026.01.07 10:00', 2000.00, 2000.40, 1999.90, 2000.30);
      h.M1(D'2026.01.07 10:05', 2000.3, 2000.3, 2000.3, 2000.3, 20);
      h.EndBars();
      Check(h.days.DayCount() == 3 && h.days.CountStatus(BTB_DAY_WARMUP) == 1 && h.days.CountStatus(BTB_DAY_NORMAL) == 2, "day statuses counted");
      string text = h.days.CsvHeader() + "\n";
      for(int i = 0; i < h.days.DayCount(); i++)
         text += h.days.CsvRow(i) + "\n";
      Check(h.days.WriteCsv(o.Dir() + "days_fixture.csv"), "btb_days.csv written");
      CheckStr(o.RegisterFile("days_fixture.csv"), TRE_Sha256Hex(text), "btb_days.csv bytes = header + rows, LF");

      CBtbQuarantineWindow q;
      q.from = D'2026.01.07 10:04';
      q.to = D'2026.01.07 10:05';
      int e = h.FindEvent(BTB_L1, BTB_LONG, 0);
      Check(e >= 0 && h.eng.WrittenStatus(e, q) == BTB_EV_IN_QUARANTINE, "breakout candle overlapping the quarantine: IN_QUARANTINE");
      q.from = D'2026.01.07 10:05';
      q.to = D'2026.01.07 10:10';
      Check(e >= 0 && h.eng.WrittenStatus(e, q) == BTB_EV_EVENT, "quarantine starting at the candle close: EVENT (end exclusive)");
      string etext = h.eng.CsvHeader() + "\n";
      for(int i = 0; i < h.eng.EventCount(); i++)
         etext += h.eng.CsvRow(i, q) + "\n";
      Check(h.eng.WriteCsv(o.Dir() + "events_fixture.csv", q), "btb_events_<TF>.csv written");
      CheckStr(o.RegisterFile("events_fixture.csv"), TRE_Sha256Hex(etext), "btb_events_<TF>.csv bytes = header + rows, LF");
     }

   //--- proxies.csv row and quarantine on the proxy's life
     {
      CBtbFlow h;
      h.Init(0);
      h.Event(BTB_LONG, D'2026.01.07 10:00', 2000.00, 2001.00, 1999.00, 2000.50, false);
      h.Quote(D'2026.01.07 10:05:00', 100, 2000.60, 2000.90);
      h.Quote(D'2026.01.07 10:07:00', 0, 2000.20, 2000.50);
      h.Quote(D'2026.01.07 10:11:00', 0, 2002.37, 2002.67);
      int p1 = h.book.Find(0, 1);
      string cols[];
      int nc = StringSplit(h.book.CsvHeader(), ',', cols);
      Check(nc == 36 && cols[18] == "state" && cols[27] == "net_r", "proxies.csv has 36 columns (study.py contract)");
      CBtbQuarantineWindow q;
      q.from = D'2026.01.07 12:00';
      q.to = D'2026.01.07 13:00';
      string row = h.book.CsvRow(p1, q);
      CheckStr(StringSubstr(row, 0, 260),
               "c7a8654cdea5ee66,M5,L1,LONG,NA,NA,2026-01-07T10:05:00,1,0,1,2026-01-07T10:05:00.100,0.30,3.0000,2000.50,1998.70,2002.37,"
               "183.2008,3.2008,FILLED,2026-01-07T10:07:00.000,119.900,2026-01-07T10:11:00.000,2002.37,TP,0.30,187.0000,183.7992,1.003266,"
               "0.017472,0.163755,", "proxies.csv row: order, fill, exit and result columns");
      Check(StringFind(row, ",0,10,H08_13,3_5") > 0, "proxies.csv row: ambiguous, close hour, hour bucket, spread bucket (0.30 = 3.0 pips)");
      CheckNear(h.book.ProxyS0Pips(p1), 3.0, 1e-12, "s0 in pips from whole points");
      q.from = D'2026.01.07 10:08';
      q.to = D'2026.01.07 10:09';
      CheckStr(h.book.WrittenState(p1, q), "IN_QUARANTINE", "quarantine inside the proxy's life: IN_QUARANTINE");
      q.from = D'2026.01.07 10:11:01';
      q.to = D'2026.01.07 10:30';
      CheckStr(h.book.WrittenState(p1, q), "FILLED", "quarantine after the exit: FILLED");
      int p2 = h.book.Find(0, 2);
      Check(StringFind(h.book.CsvRow(p2, q), ",OPEN,") > 0, "open proxy row before Finish");
     }

   //--- L3 life: 120 H1 bars after the confirmation
     {
      CBtbFlow h;
      h.Init(0);
      double hl[6][2] = {{2000, 2001}, {2000, 2003}, {2000, 2005}, {2000, 2002}, {2000, 2001}, {2000, 2001}};
      datetime t = D'2026.01.06 02:00';
      for(int i = 0; i < 127; i++)
        {
         double lo = (i < 6 ? hl[i][0] : 2000.0), hi = (i < 6 ? hl[i][1] : 2001.0);
         h.M1(t + i * 3600, lo, hi, lo, lo, 20);
        }
      int li = -1;
      for(int i = 0; i < h.src.LevelCount(); i++)
         if(h.src.LevelType(i) == BTB_L3)
            li = i;
      Check(li >= 0 && h.src.H1Count() >= 125, "H1 bars counted");
      Check(li >= 0 && !h.src.LevelExpired(li, h.src.H1Close(124) - 1), "alive before the close of H1 bar 124");
      Check(li >= 0 && h.src.LevelExpired(li, h.src.H1Close(124)), "expired at the close of H1 bar 124 (confirm 4 + 120)");
     }
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   g_pass = 0;
   g_fail = 0;
   g_report = "BTB blocking tests — contracts " + TRE_PHASE1_CONTRACT_ID + ", " + BTB_CONTRACT_ID + "\n";

   //--- TRE (ported LSR Phase 1 suites, same assertions)
   TestJson();
   TestTimeframes();
   TestBrokerTime();
   TestSessions();
   TestUnitsAndQuotes();
   TestCosts();
   TestSizing();
   TestAccountRules();
   TestRiskAdmission();
   TestDataAudit();
   TestManifest();
   TestTreBars();
   //--- BTB-2 / BTB-3
   TestBtbTypes();
   TestBtbWindow();
   TestBtbLevels();
   TestBtbTickPath();
   TestBtbProxy();
   TestBtbLedgers();

   string summary = StringFormat("RESULT: %s  passed=%d failed=%d  build=%d",
                                 g_fail == 0 ? "PASS" : "FAIL", g_pass, g_fail, (int)TerminalInfoInteger(TERMINAL_BUILD));
   g_report += "\n" + summary + "\n";
   TRE_WriteUtf8File("BTB\\tests\\btb_tests.txt", g_report, true);
   Print("BTB tests ", summary);

   if(InpCloseTerminalWhenDone)
      TerminalClose(g_fail == 0 ? 0 : 1);
  }
//+------------------------------------------------------------------+
