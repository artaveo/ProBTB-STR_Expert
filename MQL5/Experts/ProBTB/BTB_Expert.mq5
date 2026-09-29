//+------------------------------------------------------------------+
//| BTB_Expert.mq5                                                   |
//| Pro BTB (Back To Breakeven) — research EA (BTB-1..3 + BTB-4).     |
//|                                                                  |
//| This EA does NOT trade. In one Strategy Tester pass it           |
//|  - validates the Phase 1 contract (symbol, sessions, costs),     |
//|  - audits the real ticks (TRE raw-tick audit, data quarantine),  |
//|  - builds Bid M1 bars and M5 / M15 signal bars from the ticks,   |
//|  - applies the late-spread block and spread-normal resume rule,  |
//|  - detects L1-L4 breakout events on both timeframes,             |
//|  - simulates Buy/Sell Limit proxies for R = 1, 2, 3 on ticks,    |
//|    for E0 (Part 1), E1 (departure first, D = 1.0/1.5/2.0) and E2 |
//|    (three legs, spike, pushes along a trend line), PART 2,       |
//| and writes the run package to Common\Files\BTB\<ExperimentId>\.  |
//+------------------------------------------------------------------+
#property copyright   "Pro BTB"
#property version     "2.00"
#property description "BTB-1..4 — contract, data audit, breakout events, E0/E1/E2 limit-order proxies (no trading)"

#include "../../Include/ProBTB/BTB_Engine.mqh"

//--- Run identity (DataManifest)
input group "Run identity (DataManifest)"
input string   InpExperimentId               = "BTB-V2";         // ExperimentId
input string   InpCodeCommitSHA              = "";               // CodeCommitSHA (git rev-parse HEAD)
input string   InpRoadmapSHA256              = "";               // RoadmapSHA256 (sha256 of ProBTB_Roadmap.md)

//--- Data audit (copy the dates from the tester)
input group "Tick/data-quality audit"
input datetime InpAuditRequestedStartDate    = D'2026.01.01';    // AuditRequestedStartDate (copy from tester)
input datetime InpAuditRequestedEndDate      = D'2026.09.25';    // AuditRequestedEndDate (inclusive date; tester ToDate 2026.09.26)
input string   InpClosedMarketCalendarFile   = "";               // ClosedMarketCalendarFile (Common\Files CSV, optional)
input string   InpDataQuarantineFile         = "";               // DataQuarantineFile (raw-audit quarantine CSV, optional)

//--- Symbol units and costs
input group "Symbol units and costs"
input double   InpStrategyPipSize            = 0.10;             // StrategyPipSize
input double   InpCommissionRatePercent      = 0.0016;           // CommissionRatePercent (%)
input string   InpCostScheduleDate           = "2026-09-28";     // CostScheduleDate (YYYY-MM-DD)
input bool     InpExportReferenceBars        = true;             // ExportReferenceBars (M1 CSV for the Python reference)

//--- PART 2 (roadmap V5): pre-registered, not to be tuned
input group "BTB-v2 entries E1 / E2 (pre-registered)"
input string   InpE1DepD                     = BTB_E1_DEP_D_LIST; // E1_DepD (departure multiples; 1.0 primary)
input double   InpE2ZigZagATR                = BTB_E2_ZIGZAG_ATR; // E2_ZigZagATR
input double   InpE2SpikeATR                 = BTB_E2_SPIKE_ATR;  // E2_SpikeATR
input int      InpE2SpikeBars                = BTB_E2_SPIKE_BARS; // E2_SpikeBars
input double   InpE2LineTolATR               = BTB_E2_LINE_TOL_ATR; // E2_LineTolATR
input int      InpE2MaxDays                  = BTB_E2_MAX_DAYS;   // E2_MaxDays

#define BTB_TF_COUNT 2
#define BTB_M1_FILE  "bars_M1_BID.csv"

//--- Quarantine lookup used when writing the ledgers.
class CBTB_EAQuarantine : public CBTB_QuarantineCheck
  {
public:
   CTRE_RawTickAudit *raw;
   CTRE_DataQuarantine *file;
   virtual bool      Overlaps(const datetime from, const datetime toExclusive)
     {
      if(raw != NULL && raw.Overlaps(from, toExclusive))
         return true;
      return file != NULL && file.Overlaps(from, toExclusive);
     }
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
ENUM_TRE_TIMEFRAME     g_tfs[BTB_TF_COUNT] = {TRE_TF_M5, TRE_TF_M15};
TRE_SymbolSpec         g_spec;
CTRE_PriceUnits        g_units;
CTRE_SessionSchedule   g_sched;
CTRE_ClosureCalendar   g_calendar;
CTRE_DataQuarantine    g_quarantine;
CTRE_StrategyWindow    g_window;
TRE_CostModel          g_costs;
CTRE_InputRecorder     g_inputs;
CBTB_RunOutput         g_out;
CTRE_RawTickAudit      g_rawAudit;
CTRE_RawAuditDriver    g_rawDriver;
CTRE_MT5Economics     *g_econ = NULL;
CTRE_M1Builder         g_m1;
CBTB_DayTracker        g_days;
CBTB_LevelSource       g_levels;
CBTB_LevelEngine       g_eng[BTB_TF_COUNT];
CBTB_ProxyBook         g_book[BTB_TF_COUNT];
CBTB_E2Setups          g_e2[BTB_TF_COUNT];
BTB_E2Config           g_e2cfg;
double                 g_deps[];
int                    g_m1File = INVALID_HANDLE;
long                   g_m1Count = 0;
datetime               g_firstM1 = 0;
int                    g_lastSpreadPts = 0;
string                 g_sessionCsv = "";

TRE_TickAnomalies      g_stream;
bool                   g_havePrev = false;
MqlTick                g_prevTick;
ulong                  g_seq = 0;
long                   g_ticksInSession = 0;
long                   g_ticksBeforeRange = 0;
long                   g_ticksAfterRange = 0;
datetime               g_rangeStart = 0;
datetime               g_rangeEndExclusive = 0;
bool                   g_initialized = false;
string                 g_initTime = "";
string                 g_eventsSha[BTB_TF_COUNT];
string                 g_setupsSha[BTB_TF_COUNT];

//+------------------------------------------------------------------+
void RecordInputs(void)
  {
   g_inputs.Add("ExperimentId", InpExperimentId, "BTB-V2");
   g_inputs.Add("CodeCommitSHA", InpCodeCommitSHA, "");
   g_inputs.Add("RoadmapSHA256", InpRoadmapSHA256, "");
   g_inputs.Add("AuditRequestedStartDate", TRE_IsoDate(InpAuditRequestedStartDate), "2026-01-01");
   g_inputs.Add("AuditRequestedEndDate", TRE_IsoDate(InpAuditRequestedEndDate), "2026-09-25");
   g_inputs.Add("ClosedMarketCalendarFile", InpClosedMarketCalendarFile, "");
   g_inputs.Add("DataQuarantineFile", InpDataQuarantineFile, "");
   g_inputs.AddNum("StrategyPipSize", InpStrategyPipSize, 0.10);
   g_inputs.AddNum("CommissionRatePercent", InpCommissionRatePercent, TRE_BASELINE_COMMISSION_RATE_PERCENT);
   g_inputs.Add("CostScheduleDate", InpCostScheduleDate, "2026-09-28");
   g_inputs.AddBool("ExportReferenceBars", InpExportReferenceBars, true);
   g_inputs.Add("E1_DepD", InpE1DepD, BTB_E1_DEP_D_LIST);
   g_inputs.AddNum("E2_ZigZagATR", InpE2ZigZagATR, BTB_E2_ZIGZAG_ATR);
   g_inputs.AddNum("E2_SpikeATR", InpE2SpikeATR, BTB_E2_SPIKE_ATR);
   g_inputs.AddInt("E2_SpikeBars", InpE2SpikeBars, BTB_E2_SPIKE_BARS);
   g_inputs.AddNum("E2_LineTolATR", InpE2LineTolATR, BTB_E2_LINE_TOL_ATR);
   g_inputs.AddInt("E2_MaxDays", InpE2MaxDays, BTB_E2_MAX_DAYS);
   //--- frozen research decisions (roadmap 2); recorded, not inputs
   g_inputs.Add("SignalTimeframes", "M5,M15", "M5,M15");
   g_inputs.Add("SignalBarPriceSource", "BID", "BID");
   g_inputs.Add("StopExecutionProfile", "LIVE_NATIVE_STOP", "LIVE_NATIVE_STOP");
   g_inputs.Add("EntryMode", "MODE1_LIMIT_AT_BREAKOUT_CLOSE", "MODE1_LIMIT_AT_BREAKOUT_CLOSE");  // limit price of every mode
   g_inputs.Add("RTargets", "1,2,3", "1,2,3");
   g_inputs.Add("EntryModes", "E0,E1,E2", "E0,E1,E2");
   g_inputs.Add("HoldoutStart", "2026-07-01", "2026-07-01");
   g_inputs.Add("Windows", "FULL,NY", "FULL,NY");
   g_inputs.Add("LateBlockStart", "21:30", "21:30");
   g_inputs.Add("NYWindow", "16:30-21:30", "16:30-21:30");
   g_inputs.Add("SlippageMode", "NONE", "NONE");
   g_inputs.AddInt("FixedExecutionDelayMs", 0, 0);
  }

//+------------------------------------------------------------------+
int Fail(const string what)
  {
   PrintFormat("BTB INIT FAILED: %s", what);
   return INIT_PARAMETERS_INCORRECT;
  }

//--- Raw broker-declared session intervals for the Python reference and the replay script.
string SessionScheduleCsv(const string symbol)
  {
   string s = "weekday,from_sec,to_sec\n";
   for(int d = 0; d < 7; d++)
      for(uint idx = 0; idx < TRE_MAX_SESSIONS_PER_DAY; idx++)
        {
         datetime from = 0, to = 0;
         if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)d, idx, from, to))
            break;
         s += IntegerToString(d) + "," + IntegerToString((long)from) + "," + IntegerToString((long)to) + "\n";
        }
   return s;
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   string err;
   g_initialized = false;
   g_inputs.Clear();
   RecordInputs();

   if(!MQLInfoInteger(MQL_TESTER))
      return Fail("BTB_Expert is a research EA and runs only in the Strategy Tester");
   if(!TRE_ValidateExperimentId(InpExperimentId, err))
      return Fail(err);
   g_out.Init(InpExperimentId);

   //--- Symbol specification and price units
   if(!TRE_CaptureSymbolSpec(_Symbol, TimeCurrent(), g_spec, err))
      return Fail(err);
   if(!TRE_ValidateSymbolSpec(g_spec, err))
      return Fail(err);
   if(!g_units.Init(InpStrategyPipSize, g_spec.point, g_spec.tick_size, err))
      return Fail(err);
   string accCcy = AccountInfoString(ACCOUNT_CURRENCY);
   if(g_spec.currency_profit != accCcy)
      return Fail(StringFormat("symbol profit currency %s differs from the deposit currency %s; commission conversion is not specified",
                               g_spec.currency_profit, accCcy));

   //--- Sessions and the late-spread block (Mode 1)
   if(!g_sched.LoadFromSymbol(_Symbol, err))
      return Fail(err);
   if(!g_window.Init(TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD, "00:00", "24:00", GetPointer(g_sched), err))
      return Fail(err);
   g_sessionCsv = SessionScheduleCsv(_Symbol);

   //--- Costs: official metals commission, no slippage, zero latency (roadmap 2, 5.1)
   TRE_CostModelDefaults(g_costs);
   g_costs.commission_rate_percent = InpCommissionRatePercent;
   g_costs.schedule_date = InpCostScheduleDate;
   if(!TRE_ValidateCostModel(g_costs, err))
      return Fail(err);

   //--- Audit declaration (end date inclusive -> exclusive broker-day boundary)
   g_rangeStart = TRE_BrokerDayStart(InpAuditRequestedStartDate);
   g_rangeEndExclusive = TRE_BrokerDayStart(InpAuditRequestedEndDate) + TRE_SECONDS_PER_DAY;
   if(g_rangeEndExclusive <= g_rangeStart)
      return Fail("AuditRequestedEndDate must not be before AuditRequestedStartDate");
   if(!g_calendar.LoadCsv(InpClosedMarketCalendarFile, err))
      return Fail(err);
   if(!g_quarantine.LoadCsv(InpDataQuarantineFile, err))
      return Fail(err);
   g_rawAudit.Init(GetPointer(g_sched), GetPointer(g_calendar), TRE_PRICE_BID, g_spec.point,
                   g_rangeStart, g_rangeEndExclusive, "TESTER_CopyTicksRange_COPY_TICKS_ALL");
   g_rawDriver.Init(_Symbol, GetPointer(g_rawAudit));

   //--- PART 2 parameters
   if(!BTB_ParseDepList(InpE1DepD, g_deps, err))
      return Fail(err);
   BTB_E2ConfigDefaults(g_e2cfg);
   g_e2cfg.zigzag_atr = InpE2ZigZagATR;
   g_e2cfg.spike_atr = InpE2SpikeATR;
   g_e2cfg.spike_bars = InpE2SpikeBars;
   g_e2cfg.line_tol_atr = InpE2LineTolATR;
   g_e2cfg.max_days = InpE2MaxDays;
   if(!(g_e2cfg.zigzag_atr > 0.0) || !(g_e2cfg.spike_atr > 0.0) || g_e2cfg.spike_bars < 1 || !(g_e2cfg.line_tol_atr > 0.0) || g_e2cfg.max_days < 1)
      return Fail("E2 parameters must be positive");

   //--- BTB layers: one day tracker and level source, one engine, E2 machine and proxy book per timeframe
   g_econ = new CTRE_MT5Economics(_Symbol);
   g_days.Init(GetPointer(g_sched));
   g_levels.Init(GetPointer(g_days));
   double contractSize = TRE_CommissionContractSize(g_costs, g_spec);
   for(int i = 0; i < BTB_TF_COUNT; i++)
     {
      if(!g_eng[i].Init(g_tfs[i], GetPointer(g_days), GetPointer(g_levels), g_spec.digits))
         return Fail("cannot initialise the level engine for " + TRE_TimeframeName(g_tfs[i]));
      g_book[i].Init(GetPointer(g_eng[i]), g_econ, g_spec, g_costs, InpStrategyPipSize, contractSize);
      g_e2[i].Init(TRE_TimeframeName(g_tfs[i]), TRE_TimeframeSeconds(g_tfs[i]), g_spec.digits, g_e2cfg, GetPointer(g_days));
      g_book[i].ConfigureV2(g_deps, GetPointer(g_e2[i]));
     }
   g_m1.Init(TRE_PRICE_BID, g_spec.digits);
   g_m1Count = 0;
   g_firstM1 = 0;
   g_lastSpreadPts = 0;
   g_m1File = INVALID_HANDLE;
   if(InpExportReferenceBars)
     {
      g_m1File = FileOpen(g_out.Dir() + BTB_M1_FILE, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(g_m1File == INVALID_HANDLE)
         return Fail("cannot open the M1 reference-bar export file");
      BTB_WriteLine(g_m1File, "time,open,high,low,close,ticks,spread_pts");
     }

   TRE_TickAnomaliesReset(g_stream);
   g_havePrev = false;
   g_seq = 0;
   g_initTime = TRE_IsoTime(TimeCurrent());
   g_initialized = true;

   WriteContractSnapshots();
   PrintFormat("BTB initialised: signal timeframes M5,M15, output=Common\\Files\\%s", g_out.Dir());
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| One completed Bid M1 bar: export, day tracker, level source,     |
//| then every signal-timeframe engine (roadmap 7: one M1 stream).   |
//+------------------------------------------------------------------+
void OnCompletedM1(const TRE_Bar &m1, const int spreadPts)
  {
   if(g_m1Count == 0)
      g_firstM1 = m1.time;
   g_m1Count++;
   if(g_m1File != INVALID_HANDLE)
      BTB_WriteLine(g_m1File, TRE_IsoTime(m1.time) + "," + DoubleToString(m1.open, g_spec.digits) + "," +
                    DoubleToString(m1.high, g_spec.digits) + "," + DoubleToString(m1.low, g_spec.digits) + "," +
                    DoubleToString(m1.close, g_spec.digits) + "," + IntegerToString(m1.ticks) + "," + IntegerToString(spreadPts));
   g_days.OnM1(m1, spreadPts);
   g_levels.OnM1(m1);
   for(int i = 0; i < BTB_TF_COUNT; i++)
      g_eng[i].OnM1(m1);
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!g_initialized)
      return;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;

   g_seq++;
   bool usable = TRE_TickAnomaliesObserve(g_stream, t, g_havePrev, g_prevTick);
   g_prevTick = t;
   g_havePrev = true;

   TRE_Quote q;
   TRE_QuoteFromTick(t, g_seq, q);
   if(q.time < g_rangeStart)
      g_ticksBeforeRange++;
   else
      if(q.time >= g_rangeEndExclusive)
         g_ticksAfterRange++;
   if(g_sched.IsInSession(q.time))
      g_ticksInSession++;

   if(usable)
     {
      //--- the M1 bar that this tick completes carries the spread of the previous usable tick
      TRE_Bar m1;
      if(g_m1.OnQuote(q, m1))
         OnCompletedM1(m1, g_lastSpreadPts);
      g_lastSpreadPts = (int)MathRound((q.ask - q.bid) / g_spec.point);
      for(int i = 0; i < BTB_TF_COUNT; i++)
        {
         g_eng[i].OnTime(q.time);
         g_e2[i].Sync(GetPointer(g_eng[i]));
         g_book[i].OnEngineUpdate();
         g_book[i].OnQuote(q);
        }
     }

   g_rawDriver.Advance(q.time);
  }

//+------------------------------------------------------------------+
void WriteContractSnapshots(void)
  {
   CTRE_Json j;
   j.BeginObject();
   j.KStr("contract_id", TRE_PHASE1_CONTRACT_ID);
   j.KStr("btb_contract_id", BTB_CONTRACT_ID);
   j.KStr("server_time_basis", TRE_SERVER_TIME_BASIS);
   j.Key("symbol_specification");
   TRE_WriteSymbolSpecJson(j, g_spec);
   j.KObj("price_units");
   j.KNum("strategy_pip_size", g_units.PipSize(), 8);
   j.KStr("strategy_pip_source", "explicit input (never inferred from SYMBOL_POINT)");
   j.KNum("symbol_point", g_units.Point(), 12);
   j.KNum("tick_size", g_units.TickSize(), 12);
   j.EndObject();
   j.Key("trading_session_schedule");
   g_sched.WriteJson(j);
   j.Key("late_spread_block");
   g_window.WriteJson(j);
   j.KArr("late_block_sample");
   for(int k = 0; k < 14; k++)
     {
      datetime day = g_rangeStart + k * TRE_SECONDS_PER_DAY;
      datetime bs, be;
      j.BeginObject();
      j.KStr("broker_date", TRE_IsoDate(day));
      j.KStr("weekday", TRE_WeekdayName(TRE_DayOfWeek(day)));
      if(g_window.LateBlockOfDay(day, bs, be))
        {
         j.KTime("late_block_start", bs);
         j.KTime("late_block_end_exclusive", be);
        }
      else
         j.KNull("late_block_start");
      j.EndObject();
     }
   j.EndArray();
   j.Key("declared_closed_market_calendar");
   g_calendar.WriteJson(j);
   j.EndObject();
   g_out.Write("symbol_session_snapshot.json", j.Text());
   g_out.Write("session_schedule.csv", g_sessionCsv);

   j.Reset();
   j.BeginObject();
   j.Key("cost_model");
   TRE_WriteCostModelJson(j, g_costs, TRE_CommissionContractSize(g_costs, g_spec), TRE_STOP_LIVE_NATIVE, TRE_PRICE_BID, InpStrategyPipSize);
   j.KObj("btb_proxy_contract");
   j.KStr("entry", "Buy/Sell Limit exactly at the breakout close (Bid chart price) on the tick grid; placed on the first tick at/after the breakout close");
   j.KStr("fill", "Buy Limit: first tick with Ask <= P; Sell Limit: first tick with Bid >= P; fill at exactly P; FILLED_AT_PLACEMENT when on the placement tick");
   j.KStr("stop", "long: breakout low - s0; short: breakout high + s0; s0 = Ask - Bid at placement; aligned outward; LIVE_NATIVE_STOP at the executable quote");
   j.KStr("planned_risk_1r", "OrderCalcProfit loss P -> SL (1 lot) + commission (1 lot at P, published formula applied once)");
   j.KStr("target", "profit(P -> TP) - commission = k x PlannedRisk1R, k in {1,2,3}; aligned outward; fills at TP when Bid >= TP (long) / Ask <= TP (short)");
   j.KStr("order_life", "EXPIRED_12_BARS at breakout close + 12 signal bars; MISSED_TP_FIRST; CANCELLED_WINDOW_END at 21:30; data quarantine -> IN_QUARANTINE");
   j.KStr("exits", "TP, SL, SESSION_CLOSE (21:30), GAP_* (tick gap > 300 s), END_OF_DATA; stop wins on one tick");
   j.KStr("size", "1-lot proxy per event and R; no portfolio, no admission gate");
   j.EndObject();
   j.KObj("btb_v2_contract");
   j.KStr("contract_id", BTB_V2_CONTRACT_ID);
   j.KStr("e0", "Part 1 proxy (above), unchanged");
   j.KStr("e1", "reference tick = first tick at/after the breakout close: SL_ref = breakout extreme -/+ its spread; armed when the Bid reaches P +/- D x |P - SL_ref| (aligned away from P); "
          "the arming tick is the placement tick (s0, SL, TP as E0); before arming a stop trigger on SL_ref = INVALIDATED_BEFORE_ARM; armed: fill / stop trigger "
          "(INVALIDATED_BEFORE_FILL) / 21:30 (CANCELLED_WINDOW_END); unarmed at 21:30 = NOT_ARMED_WINDOW_END; no 12-bar expiry, no MISSED_TP_FIRST; D = " + InpE1DepD);
   j.KStr("e2", "bar-level setup (btb_setups_E2_<TF>.csv): ZigZag legs (>= 3, higher highs / higher lows beyond the zone), spike >= " +
          TRE_NumStr(g_e2cfg.spike_atr) + " x ATR14 within " + IntegerToString(g_e2cfg.spike_bars) + " bars, 2/2 fractal pushes, trend line; "
          "the limit at P is live only on bars with |y - P| <= " + TRE_NumStr(g_e2cfg.line_tol_atr) + " x ATR14 inside the FULL window; "
          "s0 / SL / TP from the first live tick; window of the fill decides FULL / NY; life " + IntegerToString(g_e2cfg.max_days) + " trading days");
   j.KStr("sample", "DESIGN before 2026-07-01, HOLDOUT from 2026-07-01 (break-candle date)");
   j.EndObject();
   j.EndObject();
   g_out.Write("execution_contract.json", j.Text());
  }

//+------------------------------------------------------------------+
//| Flush bars, finish proxies and days, write the ledgers and the   |
//| reference config. Returns the combined event-ledger checksum.    |
//+------------------------------------------------------------------+
string FinalizeLedgers(void)
  {
   TRE_Bar m1;
   if(g_m1.Flush(m1))
      OnCompletedM1(m1, g_lastSpreadPts);
   for(int i = 0; i < BTB_TF_COUNT; i++)
     {
      g_eng[i].Flush();
      g_e2[i].Sync(GetPointer(g_eng[i]));
      g_e2[i].Finish();
      g_book[i].OnEngineUpdate();
      g_book[i].Finish();
     }
   g_days.Finish();
   if(g_m1File != INVALID_HANDLE)
     {
      FileClose(g_m1File);
      g_m1File = INVALID_HANDLE;
      g_out.RegisterFile(BTB_M1_FILE);
     }

   CBTB_EAQuarantine q;
   q.raw = GetPointer(g_rawAudit);
   q.file = GetPointer(g_quarantine);
   if(!g_days.WriteCsv(g_out.Dir() + "btb_days.csv"))
      Print("BTB: cannot write btb_days.csv");
   g_out.RegisterFile("btb_days.csv");
   string combined = "";
   for(int i = 0; i < BTB_TF_COUNT; i++)
     {
      string tf = TRE_TimeframeName(g_tfs[i]);
      if(!g_eng[i].WriteCsv(g_out.Dir() + "btb_events_" + tf + ".csv", q))
         PrintFormat("BTB: cannot write btb_events_%s.csv", tf);
      g_eventsSha[i] = g_out.RegisterFile("btb_events_" + tf + ".csv");
      combined += tf + ":" + g_eventsSha[i] + ";";
      if(!g_book[i].WriteCsv(g_out.Dir() + "btb_proxies_" + tf + ".csv", q))
         PrintFormat("BTB: cannot write btb_proxies_%s.csv", tf);
      g_out.RegisterFile("btb_proxies_" + tf + ".csv");
      if(!g_e2[i].WriteCsv(g_out.Dir() + "btb_setups_E2_" + tf + ".csv", q))
         PrintFormat("BTB: cannot write btb_setups_E2_%s.csv", tf);
      g_setupsSha[i] = g_out.RegisterFile("btb_setups_E2_" + tf + ".csv");
     }

   //--- configuration consumed by the independent Python reference
   CTRE_Json j;
   j.BeginObject();
   j.KStr("contract_id", BTB_CONTRACT_ID);
   j.KStr("symbol", _Symbol);
   j.KInt("digits", g_spec.digits);
   j.KNum("point", g_spec.point, 12);
   j.KNum("tick_size", g_spec.tick_size, 12);
   j.KNum("strategy_pip_size", InpStrategyPipSize, 8);
   j.KStr("signal_bar_price_source", "BID");
   j.KStr("m1_bars_file", BTB_M1_FILE);
   j.KStr("session_file", "session_schedule.csv");
   j.KArr("timeframes");
   for(int i = 0; i < BTB_TF_COUNT; i++)
      j.Str(TRE_TimeframeName(g_tfs[i]));
   j.EndArray();
   j.KInt("atr_period", BTB_ATR_PERIOD);
   j.KStr("quarantine_file", "data_quarantine_windows.csv");
   j.KStr("declared_quarantine_file", InpDataQuarantineFile);
   j.KStr("holdout_start", "2026-07-01");
   j.KObj("e2");
   j.KNum("zigzag_atr", g_e2cfg.zigzag_atr, 8);
   j.KNum("spike_atr", g_e2cfg.spike_atr, 8);
   j.KInt("spike_bars", g_e2cfg.spike_bars);
   j.KNum("line_tol_atr", g_e2cfg.line_tol_atr, 8);
   j.KInt("max_days", g_e2cfg.max_days);
   j.EndObject();
   j.KStr("e1_dep_d", InpE1DepD);
   j.EndObject();
   g_out.Write("reference_config.json", j.Text());

   //--- event / proxy summary
   j.Reset();
   j.BeginObject();
   j.KStr("contract_id", BTB_CONTRACT_ID);
   j.KInt("m1_bars", g_m1Count);
   j.KStr("first_m1_bar", g_m1Count > 0 ? TRE_IsoTime(g_firstM1) : "");
   j.KObj("days");
   j.KInt("total", g_days.DayCount());
   j.KInt("NORMAL", g_days.CountStatus(BTB_DAY_NORMAL));
   j.KInt("ABNORMAL_SPREAD_DAY", g_days.CountStatus(BTB_DAY_ABNORMAL));
   j.KInt("WARMUP", g_days.CountStatus(BTB_DAY_WARMUP));
   j.KInt("NO_SESSION_START", g_days.CountStatus(BTB_DAY_NO_SESSION));
   j.EndObject();
   j.KArr("timeframes");
   for(int i = 0; i < BTB_TF_COUNT; i++)
     {
      j.BeginObject();
      j.KStr("timeframe", TRE_TimeframeName(g_tfs[i]));
      j.KInt("bars", g_eng[i].BarCount());
      j.KInt("event_rows", g_eng[i].EventCount());
      j.KInt("EVENT", g_eng[i].CountStatus(BTB_EV_EVENT));
      j.KInt("OPEN_BEYOND_LEVEL", g_eng[i].CountStatus(BTB_EV_OPEN_BEYOND));
      j.KInt("WARMUP", g_eng[i].CountStatus(BTB_EV_WARMUP));
      j.KInt("proxies", g_book[i].ProxyCount());
      j.KInt("closed", g_book[i].CountState(BTB_PX_CLOSED));
      j.KInt("EXPIRED_12_BARS", g_book[i].CountState(BTB_PX_EXPIRED_12_BARS));
      j.KInt("MISSED_TP_FIRST", g_book[i].CountState(BTB_PX_MISSED_TP_FIRST));
      j.KInt("CANCELLED_WINDOW_END", g_book[i].CountState(BTB_PX_CANCELLED_WINDOW_END));
      j.KInt("INVALID_STOP_GEOMETRY", g_book[i].CountState(BTB_PX_INVALID_STOP_GEOMETRY));
      j.KInt("proxies_E0", g_book[i].CountMode(BTB_MODE_E0));
      j.KInt("proxies_E1", g_book[i].CountMode(BTB_MODE_E1));
      j.KInt("proxies_E2", g_book[i].CountMode(BTB_MODE_E2));
      j.KInt("closed_E0", g_book[i].CountModeState(BTB_MODE_E0, BTB_PX_CLOSED));
      j.KInt("closed_E1", g_book[i].CountModeState(BTB_MODE_E1, BTB_PX_CLOSED));
      j.KInt("closed_E2", g_book[i].CountModeState(BTB_MODE_E2, BTB_PX_CLOSED));
      j.KInt("e2_setups", g_e2[i].SetupCount());
      j.KStr("events_sha256", g_eventsSha[i]);
      j.KStr("setups_E2_sha256", g_setupsSha[i]);
      j.EndObject();
     }
   j.EndArray();
   j.EndObject();
   g_out.Write("event_summary.json", j.Text());
   return TRE_Sha256Hex(combined);
  }

//+------------------------------------------------------------------+
void WriteFinalPackage(const int deinitReason)
  {
   if(g_havePrev)
      g_rawDriver.Flush((datetime)(g_stream.last_msc / 1000));
   else
      g_rawAudit.Finalize();
   string ledgerChecksum = FinalizeLedgers();

   //--- data-quality report
   CTRE_Json j;
   j.BeginObject();
   j.KStr("contract_id", TRE_PHASE1_CONTRACT_ID);
   j.KObj("coverage");
   j.KTime("declared_requested_start", g_rangeStart);
   j.KTime("declared_requested_end_exclusive", g_rangeEndExclusive);
   j.KStr("declaration_rule", "manual Run Card declaration copied from the tester UI; never inferred from runtime data");
   j.KStr("first_processed_tick", TRE_IsoTimeMsc(g_stream.first_msc));
   j.KStr("last_processed_tick", TRE_IsoTimeMsc(g_stream.last_msc));
   j.KInt("processed_ticks_before_declared_start", g_ticksBeforeRange);
   j.KInt("processed_ticks_after_declared_end", g_ticksAfterRange);
   bool mismatch = (g_ticksBeforeRange > 0 || g_ticksAfterRange > 0 || g_stream.records == 0);
   j.KStr("declared_vs_observed", mismatch ? "MISMATCH" : "OBSERVED_WITHIN_DECLARED_RANGE");
   j.EndObject();
   j.Key("processed_tick_stream");
   TRE_WriteTickAnomaliesJson(j, g_stream);
   j.KObj("session_counts");
   j.KInt("ticks_in_actual_trade_session", g_ticksInSession);
   j.EndObject();
   j.Key("raw_real_tick_audit");
   g_rawAudit.WriteJson(j);
   j.EndObject();
   g_out.Write("data_quality_report.json", j.Text());
   g_out.Write("potential_fallback_minutes.csv", g_rawAudit.FallbackCsv());
   g_out.Write("critical_data_gaps.csv", g_rawAudit.GapsCsv());
   g_out.Write("detected_market_closures.csv", g_rawAudit.ClosuresCsv());
   g_out.Write("data_quarantine_windows.csv", g_rawAudit.QuarantineCsv());
   g_out.Write("run_card_inputs.txt", g_inputs.RunCardText());

   //--- DataManifest (written last; indexes every file above)
   j.Reset();
   j.BeginObject();
   j.KStr("schema_version", TRE_MANIFEST_SCHEMA_VERSION);
   j.KStr("engine", TRE_ENGINE_NAME);
   j.KStr("strategy", "ProBTB");
   j.KStr("phase", "BTB-4 (PART 2: E0 / E1 / E2)");
   j.KStr("contract_id", TRE_PHASE1_CONTRACT_ID);
   j.KStr("btb_contract_id", BTB_CONTRACT_ID);
   j.KStr("btb_v2_contract_id", BTB_V2_CONTRACT_ID);
   j.KStr("experiment_id", InpExperimentId);
   j.KStr("run_context", TRE_RunContextName(TRE_CONTEXT_RESEARCH));
   j.KStr("init_broker_time", g_initTime);
   j.KStr("finalized_broker_time", TRE_IsoTime(TimeCurrent()));
   j.KInt("deinit_reason", deinitReason);
   j.KObj("code");
   j.KStr("code_sha", InpCodeCommitSHA);
   j.KStr("roadmap_file", BTB_ROADMAP_FILENAME);
   j.KStr("roadmap_sha256", InpRoadmapSHA256);
   j.KStr("engine_source", "Liquidity-Sweep-Reversal-STR_Expert a6ad185 (rename only)");
   j.EndObject();
   j.KObj("platform");
   j.KInt("mt5_build", TerminalInfoInteger(TERMINAL_BUILD));
   j.KStr("terminal_company", TerminalInfoString(TERMINAL_COMPANY));
   j.KBool("strategy_tester", (bool)MQLInfoInteger(MQL_TESTER));
   j.KStr("declared_tester_model", "Every tick based on real ticks (Run Card declaration)");
   j.EndObject();
   j.KObj("broker");
   j.KStr("company", AccountInfoString(ACCOUNT_COMPANY));
   j.KStr("server", AccountInfoString(ACCOUNT_SERVER));
   j.KStr("account_currency", AccountInfoString(ACCOUNT_CURRENCY));
   j.EndObject();
   j.KStr("server_time_basis", TRE_SERVER_TIME_BASIS);
   j.KStr("symbol", _Symbol);
   j.KObj("timeframes");
   j.KStr("signal_timeframes", "M5,M15");
   j.KStr("isolation", "each signal timeframe has its own bars, ATR, levels state and proxies; the tick stream, M1 bars, day tracker and L1-L3 sources are shared");
   j.EndObject();
   j.KObj("range");
   j.KTime("requested_start", g_rangeStart);
   j.KTime("requested_end_exclusive", g_rangeEndExclusive);
   j.KStr("actual_first_tick", TRE_IsoTimeMsc(g_stream.first_msc));
   j.KStr("actual_last_tick", TRE_IsoTimeMsc(g_stream.last_msc));
   j.EndObject();
   j.KObj("tick_source");
   j.KStr("execution_stream", "OnTick SymbolInfoTick, source order preserved (sequence numbers)");
   j.KStr("raw_audit_source", "CopyTicksRange COPY_TICKS_ALL + CopyRates M1");
   j.KNum("potential_fallback_minute_share", g_rawAudit.FallbackShare(), 8);
   j.KInt("critical_data_gap_count", g_rawAudit.CriticalGapCount());
   j.KInt("auto_detected_market_closures", g_rawAudit.ClosureCount());
   j.KNum("quarantine_share", g_rawAudit.QuarantineShare(), 8);
   j.KStr("data_gate", TRE_DataGateName(g_rawAudit.Gate()));
   j.KStr("data_quarantine_file", InpDataQuarantineFile);
   j.KInt("data_quarantine_windows_loaded", g_quarantine.Count());
   j.EndObject();
   j.KObj("execution_model");
   j.KStr("stop_execution_profile", "LIVE_NATIVE_STOP");
   j.KStr("commission", TRE_CommissionModeName(g_costs.commission_mode) + " @ " + TRE_NumStr(g_costs.commission_rate_percent) + "%, " +
          TRE_CostScheduleLabelName(g_costs.schedule_label) + " " + g_costs.schedule_date);
   j.KStr("slippage", "NONE");
   j.KStr("latency", "ZERO 0ms");
   j.EndObject();
   j.KArr("scenario_ids");
   j.Str("BASELINE");
   j.EndArray();
   j.KInt("declared_trial_count", 36);
   j.KStr("trial_note", "36 primary cells (E0 / E1 D=1.0 / E2 x TF x window x R); HOLDOUT verdict over the 24 E1 + E2 cells");
   j.KArr("random_seeds");
   j.EndArray();
   j.KStr("ledger_checksum", ledgerChecksum);
   j.KStr("ledger_note", "sha256 over '<TF>:<sha256(btb_events_<TF>.csv)>;' for M5 then M15");
   j.KObj("event_ledgers_sha256");
   for(int i = 0; i < BTB_TF_COUNT; i++)
      j.KStr(TRE_TimeframeName(g_tfs[i]), g_eventsSha[i]);
   j.EndObject();
   j.KObj("setup_ledgers_sha256");
   for(int i = 0; i < BTB_TF_COUNT; i++)
      j.KStr(TRE_TimeframeName(g_tfs[i]), g_setupsSha[i]);
   j.EndObject();
   j.Key("inputs");
   g_inputs.WriteJson(j);
   j.Key("files");
   g_out.WriteIndexJson(j);
   j.EndObject();
   string sha = g_out.Write("manifest.json", j.Text());

   PrintFormat("BTB package written to Common\\Files\\%s (manifest sha256 %s, write failures %d)", g_out.Dir(), sha, g_out.Failures());
   PrintFormat("BTB data gate: %s  fallback share=%s  quarantine share=%s  critical gaps=%I64d  auto closures=%I64d",
               TRE_DataGateName(g_rawAudit.Gate()), TRE_NumStr(g_rawAudit.FallbackShare(), 6), TRE_NumStr(g_rawAudit.QuarantineShare(), 6),
               g_rawAudit.CriticalGapCount(), g_rawAudit.ClosureCount());
   for(int i = 0; i < BTB_TF_COUNT; i++)
      PrintFormat("BTB %s: bars=%d event_rows=%d EVENT=%d e2_setups=%d proxies=%d closed E0/E1/E2=%d/%d/%d", TRE_TimeframeName(g_tfs[i]),
                  g_eng[i].BarCount(), g_eng[i].EventCount(), g_eng[i].CountStatus(BTB_EV_EVENT), g_e2[i].SetupCount(), g_book[i].ProxyCount(),
                  g_book[i].CountModeState(BTB_MODE_E0, BTB_PX_CLOSED), g_book[i].CountModeState(BTB_MODE_E1, BTB_PX_CLOSED),
                  g_book[i].CountModeState(BTB_MODE_E2, BTB_PX_CLOSED));
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_initialized)
      WriteFinalPackage(reason);
   if(g_econ != NULL)
     {
      delete g_econ;
      g_econ = NULL;
     }
   g_initialized = false;
  }
//+------------------------------------------------------------------+
