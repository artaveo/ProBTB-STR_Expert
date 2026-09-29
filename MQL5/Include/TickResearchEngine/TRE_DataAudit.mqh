//+------------------------------------------------------------------+
//| TRE_DataAudit.mqh                                                |
//| Tick/data-quality audit (roadmap 1.4).                           |
//|                                                                  |
//| AuditEligibleMinute    = broker-scheduled tradeable minute in the|
//|                          declared range (not in a declared       |
//|                          closed-market interval).                |
//| PotentialFallbackMinute = eligible minute with zero usable raw   |
//|                          tick records OR failed M1 reconciliation|
//| CriticalDataGap        = continuously tradeable interval between |
//|                          consecutive usable raw ticks longer than|
//|                          CriticalDataGapThresholdMinutes.        |
//| MarketClosure          = tick-free segment with no M1 bar inside |
//|                          touching a session start/end (holiday,  |
//|                          early close); not eligible, not a gap.  |
//| Quarantine             = every PFM minute + every minute that    |
//|                          overlaps a critical gap; no new entries.|
//| PotentialFallbackMinute is never labelled "generated ticks".     |
//+------------------------------------------------------------------+
#ifndef TRE_DATAAUDIT_MQH
#define TRE_DATAAUDIT_MQH

#include "TRE_Types.mqh"
#include "TRE_Json.mqh"
#include "TRE_Quote.mqh"
#include "TRE_Sessions.mqh"
#include "TRE_Timeframes.mqh"

#define TRE_AUDIT_MAX_LISTED_ROWS 20000

//+------------------------------------------------------------------+
//| Tick-record anomaly counters (shared by raw and stream audits).  |
//+------------------------------------------------------------------+
struct TRE_TickAnomalies
  {
   long              records;
   long              usable;
   long              non_monotonic;       // time_msc strictly earlier than the previous record
   long              duplicate_timestamp; // same time_msc as the previous record
   long              exact_duplicate;     // identical to the previous record in every field
   long              nonpositive_spread;  // ask <= bid with positive prices
   long              invalid_price;       // non-finite or non-positive bid/ask
   long              first_msc;
   long              last_msc;
   double            min_spread;
   double            max_spread;
  };

void TRE_TickAnomaliesReset(TRE_TickAnomalies &a)
  {
   a.records = 0;
   a.usable = 0;
   a.non_monotonic = 0;
   a.duplicate_timestamp = 0;
   a.exact_duplicate = 0;
   a.nonpositive_spread = 0;
   a.invalid_price = 0;
   a.first_msc = -1;
   a.last_msc = -1;
   a.min_spread = EMPTY_VALUE;
   a.max_spread = EMPTY_VALUE;
  }

bool TRE_TickIsUsable(const MqlTick &t)
  {
   if(!MathIsValidNumber(t.bid) || !MathIsValidNumber(t.ask))
      return false;
   return t.bid > 0.0 && t.ask > 0.0 && t.ask > t.bid;
  }

//--- Records one tick; returns true if usable.
bool TRE_TickAnomaliesObserve(TRE_TickAnomalies &a, const MqlTick &t, const bool havePrev, const MqlTick &prev)
  {
   a.records++;
   if(a.first_msc < 0)
      a.first_msc = t.time_msc;
   if(havePrev)
     {
      if(t.time_msc < prev.time_msc)
         a.non_monotonic++;
      else
         if(t.time_msc == prev.time_msc)
           {
            a.duplicate_timestamp++;
            if(t.bid == prev.bid && t.ask == prev.ask && t.last == prev.last &&
               t.volume == prev.volume && t.flags == prev.flags && t.volume_real == prev.volume_real)
               a.exact_duplicate++;
           }
     }
   if(t.time_msc > a.last_msc)
      a.last_msc = t.time_msc;

   if(!MathIsValidNumber(t.bid) || !MathIsValidNumber(t.ask) || t.bid <= 0.0 || t.ask <= 0.0)
     {
      a.invalid_price++;
      return false;
     }
   double spread = t.ask - t.bid;
   if(spread <= 0.0)
     {
      a.nonpositive_spread++;
      return false;
     }
   a.usable++;
   if(a.min_spread == EMPTY_VALUE || spread < a.min_spread)
      a.min_spread = spread;
   if(a.max_spread == EMPTY_VALUE || spread > a.max_spread)
      a.max_spread = spread;
   return true;
  }

void TRE_WriteTickAnomaliesJson(CTRE_Json &j, const TRE_TickAnomalies &a)
  {
   j.BeginObject();
   j.KInt("records", a.records);
   j.KInt("usable_records", a.usable);
   j.KStr("first_record_time", TRE_IsoTimeMsc(a.first_msc));
   j.KStr("last_record_time", TRE_IsoTimeMsc(a.last_msc));
   j.KInt("non_monotonic_timestamps", a.non_monotonic);
   j.KInt("duplicate_timestamps", a.duplicate_timestamp);
   j.KInt("exact_duplicate_records", a.exact_duplicate);
   j.KInt("nonpositive_spreads", a.nonpositive_spread);
   j.KInt("invalid_or_nonpositive_prices", a.invalid_price);
   if(a.min_spread == EMPTY_VALUE)
     {
      j.KNull("min_usable_spread");
      j.KNull("max_usable_spread");
     }
   else
     {
      j.KNum("min_usable_spread", a.min_spread, 8);
      j.KNum("max_usable_spread", a.max_spread, 8);
     }
   j.EndObject();
  }

//+------------------------------------------------------------------+
//| Raw real-tick record audit, processed in contiguous chunks.      |
//| Per-minute evidence is collected for the whole declared range;   |
//| closures, gaps, PFM classes and the quarantine are resolved in   |
//| Finalize() (roadmap 1.4, 1.12 item 16).                          |
//+------------------------------------------------------------------+
#define TRE_MINUTE_BAR_NONE     0
#define TRE_MINUTE_BAR_MATCH    1
#define TRE_MINUTE_BAR_MISMATCH 2

#define TRE_MINUTE_STATE_NORMAL     0
#define TRE_MINUTE_STATE_CLOSURE    1   // automatically detected market closure
#define TRE_MINUTE_STATE_GAP        2   // overlaps a critical data gap

class CTRE_RawTickAudit
  {
private:
   CTRE_SessionSchedule *m_sched;
   CTRE_ClosureCalendar *m_cal;
   ENUM_TRE_PRICE_SOURCE m_src;
   double            m_tolerance;
   datetime          m_rangeStart;
   datetime          m_rangeEnd;       // exclusive
   datetime          m_auditedTo;      // exclusive end of processed chunks
   int               m_thresholdSec;
   string            m_sourceLabel;
   bool              m_finalized;

   TRE_TickAnomalies m_anom;
   bool              m_havePrev;
   MqlTick           m_prev;
   bool              m_haveUsable;
   long              m_lastUsableMsc;

   int               m_minutes;
   int               m_minTicks[];
   uchar             m_minBar[];
   uchar             m_minState[];

   datetime          m_candFrom[];     // tick-free tradeable segments > threshold
   datetime          m_candTo[];

   long              m_eligible;
   long              m_ok;
   long              m_pfmNoTicksNoBar;
   long              m_pfmNoTicksWithBar;
   long              m_pfmRecon;
   long              m_quarantined;
   long              m_closedByCalendar;
   long              m_closedAuto;
   long              m_ticksOutsideSchedule;
   long              m_chunkErrors;

   datetime          m_pfmTime[];
   int               m_pfmClass[];
   datetime          m_gapFrom[];
   datetime          m_gapTo[];
   datetime          m_closFrom[];
   datetime          m_closTo[];
   datetime          m_qFrom[];
   datetime          m_qTo[];
   string            m_qReason[];

   static void       Push(datetime &a[], datetime &b[], const datetime x, const datetime y)
     {
      int n = ArraySize(a);
      ArrayResize(a, n + 1);
      ArrayResize(b, n + 1);
      a[n] = x;
      b[n] = y;
     }

   void              CheckGap(const datetime a, const datetime b)
     {
      if(b - a <= m_thresholdSec)
         return;
      datetime sf[], st[];
      int n = TRE_TradeableSegments(m_sched, m_cal, a, b, sf, st);
      for(int i = 0; i < n; i++)
         if(st[i] - sf[i] > m_thresholdSec)
            Push(m_candFrom, m_candTo, sf[i], st[i]);
     }

   int               MinuteIndex(const datetime t) const { return (int)((t - m_rangeStart) / 60); }

   //--- Any M1 bar among the minutes lying fully inside [s, e)?
   bool              AnyBarInside(const datetime s, const datetime e) const
     {
      int first = (int)((s - m_rangeStart + 59) / 60);
      int last = (int)((e - m_rangeStart) / 60) - 1;
      if(first < 0)
         first = 0;
      if(last >= m_minutes)
         last = m_minutes - 1;
      for(int i = first; i <= last; i++)
         if(m_minBar[i] != TRE_MINUTE_BAR_NONE)
            return true;
      return false;
     }

   void              MarkMinutes(const datetime s, const datetime e, const uchar state, const bool fullyInsideOnly)
     {
      int first = fullyInsideOnly ? (int)((s - m_rangeStart + 59) / 60) : (int)((s - m_rangeStart) / 60);
      int last = fullyInsideOnly ? (int)((e - m_rangeStart) / 60) - 1 : (int)((e - 1 - m_rangeStart) / 60);
      if(first < 0)
         first = 0;
      if(last >= m_minutes)
         last = m_minutes - 1;
      for(int i = first; i <= last; i++)
         if(m_minState[i] == TRE_MINUTE_STATE_NORMAL)
            m_minState[i] = state;
     }

   void              AddQuarantine(const datetime s, const datetime e, const string reason)
     {
      int n = ArraySize(m_qFrom);
      if(n > 0 && s <= m_qTo[n - 1])
        {
         if(e > m_qTo[n - 1])
            m_qTo[n - 1] = e;
         if(StringFind(m_qReason[n - 1], reason) < 0)
            m_qReason[n - 1] += "+" + reason;
         return;
        }
      ArrayResize(m_qFrom, n + 1);
      ArrayResize(m_qTo, n + 1);
      ArrayResize(m_qReason, n + 1);
      m_qFrom[n] = s;
      m_qTo[n] = e;
      m_qReason[n] = reason;
     }

public:
                     CTRE_RawTickAudit(void) { m_sched = NULL; m_cal = NULL; m_minutes = 0; }

   void              Init(CTRE_SessionSchedule *sched, CTRE_ClosureCalendar *cal, const ENUM_TRE_PRICE_SOURCE src,
                          const double point, const datetime rangeStart, const datetime rangeEndExclusive,
                          const string sourceLabel)
     {
      m_sched = sched;
      m_cal = cal;
      m_src = src;
      m_tolerance = 0.5 * point;
      m_rangeStart = rangeStart;
      m_rangeEnd = rangeEndExclusive;
      m_auditedTo = rangeStart;
      m_thresholdSec = TRE_CRITICAL_DATA_GAP_THRESHOLD_MIN * 60;
      m_sourceLabel = sourceLabel;
      m_finalized = false;
      TRE_TickAnomaliesReset(m_anom);
      m_havePrev = false;
      m_haveUsable = false;
      m_lastUsableMsc = 0;
      m_minutes = (int)MathMax(0, (m_rangeEnd - m_rangeStart) / 60);
      ArrayResize(m_minTicks, m_minutes);
      ArrayResize(m_minBar, m_minutes);
      ArrayResize(m_minState, m_minutes);
      if(m_minutes > 0)
        {
         ArrayInitialize(m_minTicks, 0);
         ArrayInitialize(m_minBar, TRE_MINUTE_BAR_NONE);
         ArrayInitialize(m_minState, TRE_MINUTE_STATE_NORMAL);
        }
      ArrayResize(m_candFrom, 0);
      ArrayResize(m_candTo, 0);
      m_eligible = 0;
      m_ok = 0;
      m_pfmNoTicksNoBar = 0;
      m_pfmNoTicksWithBar = 0;
      m_pfmRecon = 0;
      m_quarantined = 0;
      m_closedByCalendar = 0;
      m_closedAuto = 0;
      m_ticksOutsideSchedule = 0;
      m_chunkErrors = 0;
      ArrayResize(m_pfmTime, 0);
      ArrayResize(m_pfmClass, 0);
      ArrayResize(m_gapFrom, 0);
      ArrayResize(m_gapTo, 0);
      ArrayResize(m_closFrom, 0);
      ArrayResize(m_closTo, 0);
      ArrayResize(m_qFrom, 0);
      ArrayResize(m_qTo, 0);
      ArrayResize(m_qReason, 0);
     }

   datetime          AuditedTo(void) const  { return m_auditedTo; }
   datetime          RangeStart(void) const { return m_rangeStart; }
   datetime          RangeEnd(void) const   { return m_rangeEnd; }

   void              MarkChunkError(const datetime chunkEnd)
     {
      m_chunkErrors++;
      m_auditedTo = chunkEnd;
     }

   //+---------------------------------------------------------------+
   //| ticks: raw records with time in [chunkStart, chunkEnd), in     |
   //| source order. rates: M1 bars with time in [chunkStart,chunkEnd)|
   //| sorted ascending. Chunks must be contiguous and minute-aligned.|
   //+---------------------------------------------------------------+
   void              ProcessChunk(const MqlTick &ticks[], const int nTicks, const MqlRates &rates[], const int nRates,
                                  const datetime chunkStart, const datetime chunkEnd)
     {
      int minutes = (int)((chunkEnd - chunkStart) / 60);
      if(minutes <= 0)
         return;
      int cnt[];
      double o[], h[], l[], c[];
      ArrayResize(cnt, minutes);
      ArrayResize(o, minutes);
      ArrayResize(h, minutes);
      ArrayResize(l, minutes);
      ArrayResize(c, minutes);
      ArrayInitialize(cnt, 0);

      for(int i = 0; i < nTicks; i++)
        {
         bool usable = TRE_TickAnomaliesObserve(m_anom, ticks[i], m_havePrev, m_prev);
         m_prev = ticks[i];
         m_havePrev = true;
         if(!usable)
            continue;
         double px = (m_src == TRE_PRICE_BID ? ticks[i].bid : ticks[i].last);
         if(m_src == TRE_PRICE_LAST && !(px > 0.0))
            continue;

         datetime ts = (datetime)(ticks[i].time_msc / 1000);
         if(!m_sched.IsInSession(ts))
            m_ticksOutsideSchedule++;

         if(m_haveUsable)
            CheckGap((datetime)(m_lastUsableMsc / 1000), ts);
         else
            CheckGap(m_rangeStart, ts);
         if(!m_haveUsable || ticks[i].time_msc > m_lastUsableMsc)
            m_lastUsableMsc = ticks[i].time_msc;
         m_haveUsable = true;

         int m = (int)((ts - chunkStart) / 60);
         if(m < 0 || m >= minutes)
            continue;
         if(cnt[m] == 0)
           {
            o[m] = px;
            h[m] = px;
            l[m] = px;
           }
         else
           {
            if(px > h[m])
               h[m] = px;
            if(px < l[m])
               l[m] = px;
           }
         c[m] = px;
         cnt[m]++;
        }

      int ri = 0;
      for(int m = 0; m < minutes; m++)
        {
         datetime mt = chunkStart + m * 60;
         while(ri < nRates && rates[ri].time < mt)
            ri++;
         int idx = MinuteIndex(mt);
         if(idx < 0 || idx >= m_minutes)
            continue;
         m_minTicks[idx] = cnt[m];
         if(ri < nRates && rates[ri].time == mt)
           {
            bool match = cnt[m] > 0 &&
                         MathAbs(rates[ri].open - o[m]) <= m_tolerance && MathAbs(rates[ri].high - h[m]) <= m_tolerance &&
                         MathAbs(rates[ri].low - l[m]) <= m_tolerance && MathAbs(rates[ri].close - c[m]) <= m_tolerance;
            m_minBar[idx] = match ? TRE_MINUTE_BAR_MATCH : TRE_MINUTE_BAR_MISMATCH;
           }
        }
      m_auditedTo = chunkEnd;
     }

   //+---------------------------------------------------------------+
   //| Resolves closures, critical gaps, minute classes and the       |
   //| data quarantine. Call once after the last chunk.              |
   //+---------------------------------------------------------------+
   void              Finalize(void)
     {
      if(m_finalized)
         return;
      m_finalized = true;
      datetime end = (m_auditedTo < m_rangeEnd ? m_auditedTo : m_rangeEnd);
      if(m_haveUsable)
         CheckGap((datetime)(m_lastUsableMsc / 1000), end);
      else
         CheckGap(m_rangeStart, end);

      //--- 1) tick-free segments: automatic market closure or critical gap
      int nc = ArraySize(m_candFrom);
      for(int i = 0; i < nc; i++)
        {
         datetime s = m_candFrom[i], e = m_candTo[i];
         bool touchesBoundary = m_sched.IsSessionStartAt(s) || m_sched.IsSessionEndAt(e);
         if(touchesBoundary && !AnyBarInside(s, e))
           {
            Push(m_closFrom, m_closTo, s, e);
            MarkMinutes(s, e, TRE_MINUTE_STATE_CLOSURE, true);
           }
         else
           {
            Push(m_gapFrom, m_gapTo, s, e);
            MarkMinutes(s, e, TRE_MINUTE_STATE_GAP, false);
           }
        }

      //--- 2) minute classes and quarantine
      for(int idx = 0; idx < m_minutes; idx++)
        {
         datetime mt = m_rangeStart + idx * 60;
         if(mt >= end)
            break;
         if(!m_sched.IsInSession(mt))
            continue;
         if(m_cal.Contains(mt))
           {
            m_closedByCalendar++;
            continue;
           }
         if(m_minState[idx] == TRE_MINUTE_STATE_CLOSURE)
           {
            m_closedAuto++;
            continue;
           }
         m_eligible++;
         ENUM_TRE_MINUTE_CLASS cls;
         if(m_minTicks[idx] == 0)
            cls = (m_minBar[idx] != TRE_MINUTE_BAR_NONE) ? TRE_MINUTE_PFM_NO_TICKS_WITH_BAR : TRE_MINUTE_PFM_NO_TICKS_NO_BAR;
         else
            cls = (m_minBar[idx] == TRE_MINUTE_BAR_MATCH) ? TRE_MINUTE_OK : TRE_MINUTE_PFM_RECONCILIATION_FAILED;

         switch(cls)
           {
            case TRE_MINUTE_OK:                        m_ok++; break;
            case TRE_MINUTE_PFM_NO_TICKS_NO_BAR:       m_pfmNoTicksNoBar++; break;
            case TRE_MINUTE_PFM_NO_TICKS_WITH_BAR:     m_pfmNoTicksWithBar++; break;
            case TRE_MINUTE_PFM_RECONCILIATION_FAILED: m_pfmRecon++; break;
           }
         if(cls != TRE_MINUTE_OK && ArraySize(m_pfmTime) < TRE_AUDIT_MAX_LISTED_ROWS)
           {
            int n = ArraySize(m_pfmTime);
            ArrayResize(m_pfmTime, n + 1);
            ArrayResize(m_pfmClass, n + 1);
            m_pfmTime[n] = mt;
            m_pfmClass[n] = (int)cls;
           }
         bool inGap = (m_minState[idx] == TRE_MINUTE_STATE_GAP);
         if(cls != TRE_MINUTE_OK || inGap)
           {
            m_quarantined++;
            AddQuarantine(mt, mt + 60, inGap ? "CRITICAL_DATA_GAP" : TRE_MinuteClassName(cls));
           }
        }
     }

   long              EligibleMinutes(void) const    { return m_eligible; }
   long              FallbackMinutes(void) const    { return m_pfmNoTicksNoBar + m_pfmNoTicksWithBar + m_pfmRecon; }
   long              QuarantinedMinutes(void) const { return m_quarantined; }
   long              CriticalGapCount(void) const   { return ArraySize(m_gapFrom); }
   long              ClosureCount(void) const       { return ArraySize(m_closFrom); }
   long              ChunkErrors(void) const        { return m_chunkErrors; }
   double            FallbackShare(void) const
     {
      return m_eligible > 0 ? (double)FallbackMinutes() / (double)m_eligible : EMPTY_VALUE;
     }
   double            QuarantineShare(void) const
     {
      return m_eligible > 0 ? (double)m_quarantined / (double)m_eligible : EMPTY_VALUE;
     }
   bool              CoverageComplete(void) const { return m_auditedTo >= m_rangeEnd; }

   //--- Every critical gap and PFM minute is quarantined, so no critical gap
   //--- is ever left unquarantined; the run fails when the quarantine or the
   //--- PFM share exceeds MaxFallbackMinuteShare.
   ENUM_TRE_DATA_GATE Gate(void) const
     {
      if(!m_finalized || m_chunkErrors > 0 || m_eligible == 0)
         return TRE_DATA_AUDIT_INCOMPLETE;
      if(FallbackShare() > TRE_MAX_FALLBACK_MINUTE_SHARE || QuarantineShare() > TRE_MAX_FALLBACK_MINUTE_SHARE)
         return TRE_DATA_FAILED;
      return TRE_DATA_PASSED;
     }

   bool              Overlaps(const datetime from, const datetime toExclusive) const
     {
      int n = ArraySize(m_qFrom);
      for(int i = 0; i < n; i++)
         if(m_qFrom[i] < toExclusive && from < m_qTo[i])
            return true;
      return false;
     }

   //--- Quarantine lookup for later phases (no new entries inside).
   bool              IsQuarantined(const datetime t) const
     {
      int n = ArraySize(m_qFrom);
      for(int i = 0; i < n; i++)
         if(t >= m_qFrom[i] && t < m_qTo[i])
            return true;
      return false;
     }

   void              WriteJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KStr("audit_source", m_sourceLabel);
      j.KTime("declared_range_start", m_rangeStart);
      j.KTime("declared_range_end_exclusive", m_rangeEnd);
      j.KTime("audited_to_exclusive", m_auditedTo);
      j.KBool("declared_range_fully_audited", CoverageComplete());
      j.KInt("chunk_copy_errors", m_chunkErrors);
      j.KStr("price_source", TRE_PriceSourceName(m_src));
      j.KNum("m1_reconciliation_tolerance_price", m_tolerance, 10);
      j.KObj("raw_tick_records");
      j.Key("anomalies");
      TRE_WriteTickAnomaliesJson(j, m_anom);
      j.KInt("usable_ticks_outside_broker_schedule", m_ticksOutsideSchedule);
      j.EndObject();
      j.KObj("market_closures");
      j.KInt("declared_calendar_minutes", m_closedByCalendar);
      j.KInt("auto_detected_closures", ClosureCount());
      j.KInt("auto_detected_closure_minutes", m_closedAuto);
      j.KStr("auto_rule", "tick-free segment > threshold with no M1 bar inside that starts at a session start or ends at a session end");
      j.EndObject();
      j.KObj("minutes");
      j.KInt("audit_eligible_minutes", m_eligible);
      j.KInt("ok_minutes", m_ok);
      j.KInt("potential_fallback_minutes", FallbackMinutes());
      j.KInt("pfm_no_ticks_no_bar__no_tick_or_sparse_data", m_pfmNoTicksNoBar);
      j.KInt("pfm_no_ticks_with_bar__potential_tester_fallback", m_pfmNoTicksWithBar);
      j.KInt("pfm_reconciliation_failed", m_pfmRecon);
      j.KStr("excluded_session_break_rule", "minutes outside SymbolInfoSessionTrade schedule are not audit-eligible");
      if(m_eligible > 0)
         j.KNum("potential_fallback_minute_share", FallbackShare(), 8);
      else
         j.KNull("potential_fallback_minute_share");
      j.KStr("label_note", "PotentialFallbackMinute is not proof of generated ticks");
      j.EndObject();
      j.KObj("critical_data_gaps");
      j.KInt("threshold_minutes", TRE_CRITICAL_DATA_GAP_THRESHOLD_MIN);
      j.KInt("count", CriticalGapCount());
      j.KInt("unquarantined_count", 0);
      j.KStr("exclusions", "scheduled session breaks, weekends, declared and auto-detected market closures");
      j.EndObject();
      j.KObj("quarantine");
      j.KInt("windows", ArraySize(m_qFrom));
      j.KInt("quarantined_eligible_minutes", m_quarantined);
      if(m_eligible > 0)
         j.KNum("quarantine_share", QuarantineShare(), 8);
      else
         j.KNull("quarantine_share");
      j.KStr("rule", "every PFM minute and every minute overlapping a critical gap; no new entries inside");
      j.EndObject();
      j.KObj("gates");
      j.KNum("max_fallback_minute_share", TRE_MAX_FALLBACK_MINUTE_SHARE, 6);
      j.KNum("max_quarantine_share", TRE_MAX_FALLBACK_MINUTE_SHARE, 6);
      j.KInt("max_unquarantined_critical_data_gap_count", TRE_MAX_CRITICAL_DATA_GAP_COUNT);
      j.KStr("result", TRE_DataGateName(Gate()));
      j.EndObject();
      j.EndObject();
     }

   string            FallbackCsv(void) const
     {
      string s = "minute_broker_time,class\n";
      int n = ArraySize(m_pfmTime);
      for(int i = 0; i < n; i++)
         s += TRE_IsoTime(m_pfmTime[i]) + "," + TRE_MinuteClassName((ENUM_TRE_MINUTE_CLASS)m_pfmClass[i]) + "\n";
      return s;
     }

   string            GapsCsv(void) const
     {
      string s = "gap_from_broker_time,gap_to_broker_time_exclusive,tradeable_seconds,treatment\n";
      int n = ArraySize(m_gapFrom);
      for(int i = 0; i < n; i++)
         s += TRE_IsoTime(m_gapFrom[i]) + "," + TRE_IsoTime(m_gapTo[i]) + "," +
              IntegerToString((long)(m_gapTo[i] - m_gapFrom[i])) + ",QUARANTINED\n";
      return s;
     }

   string            ClosuresCsv(void) const
     {
      string s = "closure_from_broker_time,closure_to_broker_time_exclusive,seconds\n";
      int n = ArraySize(m_closFrom);
      for(int i = 0; i < n; i++)
         s += TRE_IsoTime(m_closFrom[i]) + "," + TRE_IsoTime(m_closTo[i]) + "," +
              IntegerToString((long)(m_closTo[i] - m_closFrom[i])) + "\n";
      return s;
     }

   //--- Same format as CTRE_DataQuarantine::LoadCsv.
   string            QuarantineCsv(void) const
     {
      string s = "# from,to_exclusive,reason (Broker Server Time)\n";
      int n = ArraySize(m_qFrom);
      for(int i = 0; i < n; i++)
         s += TimeToString(m_qFrom[i], TIME_DATE | TIME_SECONDS) + "," +
              TimeToString(m_qTo[i], TIME_DATE | TIME_SECONDS) + "," + m_qReason[i] + "\n";
      return s;
     }
  };

//+------------------------------------------------------------------+
//| Data quarantine loaded from a raw-audit quarantine CSV. Later    |
//| phases admit no new entry while IsQuarantined(t) is true.        |
//+------------------------------------------------------------------+
class CTRE_DataQuarantine
  {
private:
   datetime          m_from[];
   datetime          m_to[];
   string            m_source;

public:
   bool              LoadCsv(const string fileName, string &error)
     {
      ArrayResize(m_from, 0);
      ArrayResize(m_to, 0);
      m_source = fileName;
      error = "";
      if(fileName == "")
         return true;
      int h = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE)
        {
         error = StringFormat("cannot open data quarantine file '%s' in Common\\Files (error %d)", fileName, GetLastError());
         return false;
        }
      int lineNo = 0;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         lineNo++;
         StringTrimLeft(line);
         StringTrimRight(line);
         if(line == "" || StringGetCharacter(line, 0) == '#')
            continue;
         string f[];
         if(StringSplit(line, ',', f) < 2)
           {
            error = StringFormat("quarantine line %d: expected from,to[,reason]", lineNo);
            FileClose(h);
            return false;
           }
         datetime a = StringToTime(f[0]);
         datetime b = StringToTime(f[1]);
         if(a <= 0 || b <= a)
           {
            error = StringFormat("quarantine line %d: invalid interval", lineNo);
            FileClose(h);
            return false;
           }
         int n = ArraySize(m_from);
         ArrayResize(m_from, n + 1);
         ArrayResize(m_to, n + 1);
         m_from[n] = a;
         m_to[n] = b;
        }
      FileClose(h);
      return true;
     }

   int               Count(void) const  { return ArraySize(m_from); }
   string            Source(void) const { return m_source; }

   bool              Overlaps(const datetime from, const datetime toExclusive) const
     {
      int n = ArraySize(m_from);
      for(int i = 0; i < n; i++)
         if(m_from[i] < toExclusive && from < m_to[i])
            return true;
      return false;
     }

   bool              IsQuarantined(const datetime t) const
     {
      int n = ArraySize(m_from);
      for(int i = 0; i < n; i++)
         if(t >= m_from[i] && t < m_to[i])
            return true;
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Tester-side driver: audits completed hours of the declared range |
//| with CopyTicksRange/CopyRates while the run progresses.          |
//+------------------------------------------------------------------+
class CTRE_RawAuditDriver
  {
private:
   string            m_symbol;
   CTRE_RawTickAudit *m_audit;

public:
                     CTRE_RawAuditDriver(void) { m_audit = NULL; }
   void              Init(const string symbol, CTRE_RawTickAudit *audit) { m_symbol = symbol; m_audit = audit; }

   bool              AuditChunk(const datetime from, const datetime to)
     {
      MqlTick ticks[];
      MqlRates rates[];
      int nt = CopyTicksRange(m_symbol, ticks, COPY_TICKS_ALL, (ulong)from * 1000, (ulong)to * 1000 - 1);
      if(nt < 0)
        {
         m_audit.MarkChunkError(to);
         return false;
        }
      int nr = CopyRates(m_symbol, PERIOD_M1, from, to - 1, rates);
      if(nr < 0)
        {
         // No bars in range is reported as -1 by some builds; treat as zero bars only when no ticks exist.
         if(nt > 0)
           {
            m_audit.MarkChunkError(to);
            return false;
           }
         nr = 0;
         ArrayResize(rates, 0);
        }
      m_audit.ProcessChunk(ticks, nt, rates, nr, from, to);
      return true;
     }

   //--- Audits every completed hour strictly before `now`.
   void              Advance(const datetime now)
     {
      datetime limit = now - (now % 3600);
      if(limit > m_audit.RangeEnd())
         limit = m_audit.RangeEnd();
      while(m_audit.AuditedTo() + 3600 <= limit)
        {
         datetime from = m_audit.AuditedTo();
         AuditChunk(from, from + 3600);
        }
     }

   //--- End of run: no further ticks can arrive, so the minute containing
   //--- `lastTick` is complete and is audited too.
   void              Flush(const datetime lastTick)
     {
      datetime limit = lastTick - (lastTick % 60) + 60;
      if(limit > m_audit.RangeEnd())
         limit = m_audit.RangeEnd();
      Advance(lastTick);
      datetime from = m_audit.AuditedTo();
      if(limit > from)
         AuditChunk(from, limit);
      m_audit.Finalize();
     }
  };

//+------------------------------------------------------------------+
//| Selected SignalTimeframe OHLC construction/reconciliation:       |
//| bars built from processed ticks vs the platform's bars.          |
//+------------------------------------------------------------------+
class CTRE_BarReconciler
  {
private:
   string            m_symbol;
   ENUM_TRE_TIMEFRAME m_tf;
   ENUM_TRE_PRICE_SOURCE m_src;
   double            m_tolerance;
   int               m_secs;
   datetime          m_barTime;
   bool              m_haveBar;
   bool              m_firstBar;
   double            m_o, m_h, m_l, m_c;
   long              m_compared, m_matched, m_mismatched, m_missing, m_skipped;
   string            m_rows;
   int               m_rowCount;

   void              CloseBar(void)
     {
      if(m_firstBar)
        {
         m_skipped++;   // first bar after init may be partial — cannot be verified
         m_firstBar = false;
         return;
        }
      MqlRates r[];
      int n = CopyRates(m_symbol, TRE_ToMqlTimeframe(m_tf), m_barTime, m_barTime, r);
      if(n != 1 || r[0].time != m_barTime)
        {
         m_missing++;
         AddRow("MISSING_PLATFORM_BAR", 0, 0, 0, 0);
         return;
        }
      m_compared++;
      if(MathAbs(r[0].open - m_o) <= m_tolerance && MathAbs(r[0].high - m_h) <= m_tolerance &&
         MathAbs(r[0].low - m_l) <= m_tolerance && MathAbs(r[0].close - m_c) <= m_tolerance)
         m_matched++;
      else
        {
         m_mismatched++;
         AddRow("OHLC_MISMATCH", r[0].open, r[0].high, r[0].low, r[0].close);
        }
     }

   void              AddRow(const string kind, const double po, const double ph, const double pl, const double pc)
     {
      if(m_rowCount >= TRE_AUDIT_MAX_LISTED_ROWS)
         return;
      m_rowCount++;
      m_rows += TRE_TimeframeName(m_tf) + "," + TRE_IsoTime(m_barTime) + "," + kind + "," +
                TRE_NumStr(m_o) + "," + TRE_NumStr(m_h) + "," + TRE_NumStr(m_l) + "," + TRE_NumStr(m_c) + "," +
                TRE_NumStr(po) + "," + TRE_NumStr(ph) + "," + TRE_NumStr(pl) + "," + TRE_NumStr(pc) + "\n";
     }

public:
   void              Init(const string symbol, const ENUM_TRE_TIMEFRAME tf, const ENUM_TRE_PRICE_SOURCE src, const double point)
     {
      m_symbol = symbol;
      m_tf = tf;
      m_src = src;
      m_tolerance = 0.5 * point;
      m_secs = TRE_TimeframeSeconds(tf);
      m_haveBar = false;
      m_firstBar = true;
      m_compared = 0;
      m_matched = 0;
      m_mismatched = 0;
      m_missing = 0;
      m_skipped = 0;
      m_rows = "";
      m_rowCount = 0;
     }

   void              OnQuote(const TRE_Quote &q)
     {
      double px = TRE_SignalBarPrice(q, m_src);
      if(!(px > 0.0))
         return;
      datetime bt = q.time - (q.time % m_secs);
      if(m_haveBar && bt != m_barTime)
        {
         CloseBar();
         m_haveBar = false;
        }
      if(!m_haveBar)
        {
         m_barTime = bt;
         m_o = px;
         m_h = px;
         m_l = px;
         m_haveBar = true;
        }
      else
        {
         if(px > m_h)
            m_h = px;
         if(px < m_l)
            m_l = px;
        }
      m_c = px;
     }

   //--- The final bar is left open (it may be incomplete) and is not compared.
   ENUM_TRE_TIMEFRAME Timeframe(void) const { return m_tf; }
   long              Mismatched(void) const { return m_mismatched; }
   long              Missing(void) const    { return m_missing; }

   void              WriteJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KStr("timeframe", TRE_TimeframeName(m_tf));
      j.KStr("price_source", TRE_PriceSourceName(m_src));
      j.KInt("bars_compared", m_compared);
      j.KInt("bars_matched", m_matched);
      j.KInt("bars_mismatched", m_mismatched);
      j.KInt("platform_bars_missing", m_missing);
      j.KInt("bars_skipped_partial_first", m_skipped);
      j.KNum("tolerance_price", m_tolerance, 10);
      j.EndObject();
     }

   string            CsvRows(void) const { return m_rows; }
  };

#endif // TRE_DATAAUDIT_MQH
//+------------------------------------------------------------------+
