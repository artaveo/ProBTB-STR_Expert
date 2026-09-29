//+------------------------------------------------------------------+
//| TRE_RawTickAudit.mq5                                             |
//| Phase 1 raw real-tick audit OUTSIDE the Strategy Tester          |
//| (roadmap 1.4). Reads the terminal's own tick history with        |
//| CopyTicksRange and M1 bars with CopyRates over the declared      |
//| range, applies the same PotentialFallbackMinute / CriticalDataGap|
//| definitions and gates as the EA, and writes                      |
//| Common\Files\TRE\<ExperimentId>\raw_tick_audit_*.                |
//| Run on a chart of the audited symbol. No trading.                |
//+------------------------------------------------------------------+
#property copyright   "Liquidity Sweep Reversal"
#property version     "1.00"
#property description "Phase 1 raw real-tick audit (no trading)"
#property script_show_inputs

#include "../../Include/TickResearchEngine/TRE_Engine.mqh"

input string                InpExperimentId             = "TRE-P1-SMOKE"; // ExperimentId
input datetime              InpAuditRequestedStartDate  = D'2026.01.01';  // AuditRequestedStartDate
input datetime              InpAuditRequestedEndDate    = D'2026.06.30';  // AuditRequestedEndDate (inclusive)
input string                InpClosedMarketCalendarFile = "";             // ClosedMarketCalendarFile (Common\Files CSV)
input ENUM_TRE_PRICE_SOURCE InpSignalBarPriceSource     = TRE_PRICE_BID;  // SignalBarPriceSource

CTRE_SessionSchedule g_sched;
CTRE_ClosureCalendar g_calendar;
CTRE_RawTickAudit    g_audit;
CTRE_RawAuditDriver  g_driver;

void OnStart(void)
  {
   string err;
   if(!TRE_ValidateExperimentId(InpExperimentId, err))
     {
      Print("TRE raw audit: ", err);
      return;
     }
   if(!g_sched.LoadFromSymbol(_Symbol, err) || !g_calendar.LoadCsv(InpClosedMarketCalendarFile, err))
     {
      Print("TRE raw audit: ", err);
      return;
     }
   datetime start = TRE_BrokerDayStart(InpAuditRequestedStartDate);
   datetime endEx = TRE_BrokerDayStart(InpAuditRequestedEndDate) + TRE_SECONDS_PER_DAY;
   if(endEx <= start)
     {
      Print("TRE raw audit: end date before start date");
      return;
     }
   datetime now = TimeCurrent();
   if(endEx > now)
      endEx = now - (now % 60);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_audit.Init(GetPointer(g_sched), GetPointer(g_calendar), InpSignalBarPriceSource, point, start, endEx,
                "TERMINAL_CopyTicksRange_COPY_TICKS_ALL");
   g_driver.Init(_Symbol, GetPointer(g_audit));

   int chunks = 0;
   for(datetime from = start; from < endEx && !IsStopped(); from += 3600)
     {
      datetime to = MathMin(from + 3600, endEx);
      g_driver.AuditChunk(from, to);
      if(++chunks % 240 == 0)
         Comment(StringFormat("TRE raw audit: %s", TRE_IsoTime(to)));
     }
   g_audit.Finalize();
   Comment("");

   CTRE_RunOutput out;
   out.Init(InpExperimentId);
   CTRE_Json j;
   j.BeginObject();
   j.KStr("contract_id", TRE_PHASE1_CONTRACT_ID);
   j.KStr("symbol", _Symbol);
   j.KStr("broker_company", AccountInfoString(ACCOUNT_COMPANY));
   j.KStr("broker_server", AccountInfoString(ACCOUNT_SERVER));
   j.KInt("mt5_build", TerminalInfoInteger(TERMINAL_BUILD));
   j.KStr("server_time_basis", TRE_SERVER_TIME_BASIS);
   j.Key("trading_session_schedule");
   g_sched.WriteJson(j);
   j.Key("declared_closed_market_calendar");
   g_calendar.WriteJson(j);
   j.Key("raw_real_tick_audit");
   g_audit.WriteJson(j);
   j.EndObject();
   out.Write("raw_tick_audit_report.json", j.Text());
   out.Write("raw_tick_audit_fallback_minutes.csv", g_audit.FallbackCsv());
   out.Write("raw_tick_audit_critical_gaps.csv", g_audit.GapsCsv());
   out.Write("raw_tick_audit_market_closures.csv", g_audit.ClosuresCsv());
   out.Write("raw_tick_audit_quarantine_windows.csv", g_audit.QuarantineCsv());

   PrintFormat("TRE raw audit %s: %s  eligible=%I64d fallback=%I64d quarantine share=%s quarantined gaps=%I64d closures=%I64d -> Common\\Files\\%s",
               _Symbol, TRE_DataGateName(g_audit.Gate()), g_audit.EligibleMinutes(), g_audit.FallbackMinutes(),
               TRE_NumStr(g_audit.QuarantineShare(), 6), g_audit.CriticalGapCount(), g_audit.ClosureCount(), out.Dir());
  }
//+------------------------------------------------------------------+
