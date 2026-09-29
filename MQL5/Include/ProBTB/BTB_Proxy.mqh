//+------------------------------------------------------------------+
//| BTB_Proxy.mqh                                                    |
//| Roadmap Section 5: tick-level Buy/Sell Limit proxies, one per    |
//| EVENT inside the FULL window and per R in {1, 2, 3}.             |
//|                                                                  |
//| Placement: first tick at/after the breakout candle's close.      |
//| P = breakout close (Bid chart price) on the tick grid. A Buy     |
//| Limit fills on the first tick with Ask <= P, a Sell Limit on the |
//| first tick with Bid >= P, always at exactly P.                   |
//| s0 = Ask - Bid at the placement tick. Long SL = breakout low -   |
//| s0, short SL = breakout high + s0, aligned outward.              |
//| PlannedRisk1R = loss(P -> SL, 1 lot) + commission (1 lot at P).  |
//| TP_k: profit(P -> TP) - commission = k x PlannedRisk1R, aligned  |
//| outward. SL: LIVE_NATIVE_STOP at the executable quote; TP fills  |
//| at TP. Pending cancelled at 12 signal bars (EXPIRED_12_BARS),    |
//| on TP reached before the fill (MISSED_TP_FIRST) and at 21:30     |
//| (CANCELLED_WINDOW_END); open proxies close at 21:30 at the       |
//| executable quote (SESSION_CLOSE). Stop wins on one tick.         |
//+------------------------------------------------------------------+
#ifndef BTB_PROXY_MQH
#define BTB_PROXY_MQH

#include "BTB_Types.mqh"
#include "BTB_Levels.mqh"
#include "../TickResearchEngine/TRE_Quote.mqh"
#include "../TickResearchEngine/TRE_SymbolSpec.mqh"
#include "../TickResearchEngine/TRE_Costs.mqh"
#include "../TickResearchEngine/TRE_Sizing.mqh"

struct BTB_ProxyRec
  {
   int               ev;             // engine event index
   int               r;              // 1..3
   int               dir;            // +1 Buy Limit, -1 Sell Limit
   int               state;          // ENUM_BTB_PROXY_STATE
   bool              at_placement;   // filled on the placement tick
   long              due_msc;        // breakout close (placement at the first tick at/after it)
   datetime          window_end;     // 21:30 of the breakout day
   datetime          expiry;         // breakout close + 12 signal bars
   long              place_msc;
   double            s0;
   double            limit;
   double            sl;
   double            tp;
   double            risk1r;
   double            commission;
   double            pp;             // profit per 1.0 price move, 1 lot
   long              fill_msc;
   long              last_msc;
   double            mfe;
   double            mae;
   long              exit_msc;
   double            exit_price;
   double            exit_spread;
   int               exit_reason;
   bool              ambiguous;
   long              end_msc;        // cancel / exit / end time (quarantine overlap)
  };

//+------------------------------------------------------------------+
class CBTB_ProxyBook
  {
private:
   CBTB_LevelEngine *m_eng;
   CTRE_SymbolEconomics *m_econ;
   TRE_SymbolSpec    m_spec;
   TRE_CostModel     m_costs;
   double            m_pipSize;
   double            m_pointsPerPip;
   double            m_contractSize;
   BTB_ProxyRec      m_px[];
   int               m_n;
   int               m_live[];
   int               m_seenEvents;
   bool              m_haveLast;
   TRE_Quote         m_last;

   void              AddProxy(const int e, const int r)
     {
      if(m_n >= ArraySize(m_px))
         ArrayResize(m_px, m_n + 1, 1024);
      int i = m_n++;
      datetime closeT = m_eng.EventCloseTime(e);
      m_px[i].ev = e;
      m_px[i].r = r;
      m_px[i].dir = m_eng.EventSide(e);
      m_px[i].state = BTB_PX_WAIT_PLACEMENT;
      m_px[i].at_placement = false;
      m_px[i].due_msc = (long)closeT * 1000;
      m_px[i].window_end = TRE_BrokerDayStart(m_eng.EventBarTime(e)) + BTB_LATE_BLOCK_SEC;
      m_px[i].expiry = closeT + BTB_ORDER_LIFE_BARS * m_eng.Period();
      m_px[i].place_msc = 0;
      m_px[i].s0 = 0.0;
      m_px[i].limit = 0.0;
      m_px[i].sl = 0.0;
      m_px[i].tp = 0.0;
      m_px[i].risk1r = 0.0;
      m_px[i].commission = 0.0;
      m_px[i].pp = 0.0;
      m_px[i].fill_msc = 0;
      m_px[i].last_msc = 0;
      m_px[i].mfe = 0.0;
      m_px[i].mae = 0.0;
      m_px[i].exit_msc = 0;
      m_px[i].exit_price = 0.0;
      m_px[i].exit_spread = 0.0;
      m_px[i].exit_reason = BTB_EXIT_NONE;
      m_px[i].ambiguous = false;
      m_px[i].end_msc = 0;
      int k = ArraySize(m_live);
      ArrayResize(m_live, k + 1, 256);
      m_live[k] = i;
     }

   void              Retire(const int i)
     {
      int n = ArraySize(m_live);
      for(int k = 0; k < n; k++)
         if(m_live[k] == i)
           {
            for(int j = k; j < n - 1; j++)
               m_live[j] = m_live[j + 1];
            ArrayResize(m_live, n - 1, 256);
            return;
           }
     }

   void              EndPending(const int i, const int state, const long msc)
     {
      m_px[i].state = state;
      m_px[i].end_msc = msc;
      Retire(i);
     }

   double            AlignDown(const double price) const
     {
      return NormalizeDouble(MathFloor(price / m_spec.tick_size + 1e-9) * m_spec.tick_size, m_spec.digits);
     }

   double            AlignUp(const double price) const
     {
      return NormalizeDouble(MathCeil(price / m_spec.tick_size - 1e-9) * m_spec.tick_size, m_spec.digits);
     }

   //--- Placement tick: limit, live-spread stop, 1R, target (roadmap 5.1–5.3).
   void              Place(const int i, const TRE_Quote &q)
     {
      int e = m_px[i].ev;
      int dir = m_px[i].dir;
      m_px[i].place_msc = q.time_msc;
      m_px[i].s0 = q.ask - q.bid;
      double p = NormalizeDouble(MathRound(m_eng.EventClose(e) / m_spec.tick_size) * m_spec.tick_size, m_spec.digits);
      m_px[i].limit = p;
      double sl = (dir > 0 ? AlignDown(m_eng.EventLow(e) - m_px[i].s0) : AlignUp(m_eng.EventHigh(e) + m_px[i].s0));
      m_px[i].sl = sl;
      bool ok = (dir > 0 ? sl < p : sl > p) && TRE_IsStopDistanceLegal(m_spec, p, sl);
      double pnlStop = 0.0, pp = 0.0;
      if(ok)
         ok = m_econ.ProfitPerLot((ENUM_TRE_DIRECTION)dir, p, sl, pnlStop) &&
              m_econ.ProfitPerLot((ENUM_TRE_DIRECTION)dir, p, p + dir * 1.0, pp) && pnlStop < 0.0 && pp > 0.0;
      if(ok)
        {
         m_px[i].commission = TRE_CommissionCurrency(m_costs, 1.0, m_contractSize, p);
         m_px[i].risk1r = -pnlStop + m_px[i].commission;
         m_px[i].pp = pp;
         double gross = m_px[i].r * m_px[i].risk1r + m_px[i].commission;
         double tp = p + dir * gross / pp;
         m_px[i].tp = (dir > 0 ? AlignUp(tp) : AlignDown(tp));
         ok = TRE_IsStopDistanceLegal(m_spec, p, m_px[i].tp) && (dir > 0 ? m_px[i].tp > p : m_px[i].tp < p);
        }
      if(!ok)
        {
         EndPending(i, BTB_PX_INVALID_STOP_GEOMETRY, q.time_msc);
         return;
        }
      m_px[i].state = BTB_PX_PENDING;
      UpdatePending(i, q, true);
     }

   void              UpdatePending(const int i, const TRE_Quote &q, const bool placementTick)
     {
      int dir = m_px[i].dir;
      if(q.time >= m_px[i].window_end)
        {
         EndPending(i, BTB_PX_CANCELLED_WINDOW_END, q.time_msc);
         return;
        }
      if(q.time >= m_px[i].expiry)
        {
         EndPending(i, BTB_PX_EXPIRED_12_BARS, q.time_msc);
         return;
        }
      bool fill = (dir > 0 ? q.ask <= m_px[i].limit : q.bid >= m_px[i].limit);
      if(fill)
        {
         m_px[i].state = BTB_PX_OPEN;
         m_px[i].at_placement = placementTick;
         m_px[i].fill_msc = q.time_msc;
         m_px[i].last_msc = q.time_msc;
         double px0 = (dir > 0 ? q.bid : q.ask);
         double fav0 = dir * (px0 - m_px[i].limit);
         m_px[i].mfe = fav0;
         m_px[i].mae = MathMax(0.0, -fav0);
         UpdateOpen(i, q);
         return;
        }
      bool missed = (dir > 0 ? q.bid >= m_px[i].tp : q.ask <= m_px[i].tp);
      if(missed)
         EndPending(i, BTB_PX_MISSED_TP_FIRST, q.time_msc);
     }

   void              Close(const int i, const TRE_Quote &q, const int reason, const double price, const bool ambiguous)
     {
      m_px[i].exit_msc = q.time_msc;
      m_px[i].exit_price = price;
      m_px[i].exit_spread = q.ask - q.bid;
      m_px[i].exit_reason = reason;
      m_px[i].ambiguous = ambiguous;
      m_px[i].state = BTB_PX_CLOSED;
      m_px[i].end_msc = q.time_msc;
      Retire(i);
     }

   void              UpdateOpen(const int i, const TRE_Quote &q)
     {
      int dir = m_px[i].dir;
      double px = (dir > 0 ? q.bid : q.ask);
      double fav = dir * (px - m_px[i].limit);
      if(fav > m_px[i].mfe)
         m_px[i].mfe = fav;
      if(-fav > m_px[i].mae)
         m_px[i].mae = -fav;
      bool gap = (q.time_msc - m_px[i].last_msc) > (long)BTB_GAP_EXIT_SECONDS * 1000;
      m_px[i].last_msc = q.time_msc;
      bool stopHit = (dir > 0 ? q.bid <= m_px[i].sl : q.ask >= m_px[i].sl);
      bool tpHit = (dir > 0 ? q.bid >= m_px[i].tp : q.ask <= m_px[i].tp);
      bool sessionEnd = (q.time >= m_px[i].window_end);
      int reason = BTB_ResolveExit(stopHit, tpHit, sessionEnd, gap);
      if(reason == BTB_EXIT_NONE)
         return;
      double price = (reason == BTB_EXIT_TP || reason == BTB_EXIT_GAP_TP) ? m_px[i].tp : px;
      Close(i, q, reason, price, stopHit && tpHit);
     }

   string            N(const bool ok, const double v, const int d) const { return ok ? DoubleToString(v, d) : "NA"; }
   string            T(const long msc) const { return msc > 0 ? TRE_IsoTimeMsc(msc) : ""; }

   //--- s0 in strategy pips from whole points (0.30 is 3.0 pips, not 2.999...).
   double            S0Pips(const int i) const { return MathRound(m_px[i].s0 / m_spec.point) / m_pointsPerPip; }

public:
                     CBTB_ProxyBook(void) { m_eng = NULL; m_econ = NULL; m_n = 0; m_seenEvents = 0; m_haveLast = false; }

   void              Init(CBTB_LevelEngine *eng, CTRE_SymbolEconomics *econ, const TRE_SymbolSpec &spec,
                          const TRE_CostModel &costs, const double pipSize, const double contractSize)
     {
      m_eng = eng;
      m_econ = econ;
      m_spec = spec;
      m_costs = costs;
      m_pipSize = pipSize;
      m_pointsPerPip = MathRound(pipSize / spec.point);
      if(m_pointsPerPip < 1.0)
         m_pointsPerPip = 1.0;
      m_contractSize = contractSize;
      m_n = 0;
      ArrayResize(m_px, 0);
      ArrayResize(m_live, 0);
      m_seenEvents = 0;
      m_haveLast = false;
     }

   //--- Call after the engine has consumed the current tick (OnM1/OnTime).
   void              OnEngineUpdate(void)
     {
      int ne = m_eng.EventCount();
      for(int e = m_seenEvents; e < ne; e++)
        {
         if(m_eng.EventStatus(e) != BTB_EV_EVENT || !m_eng.EventInFull(e))
            continue;
         for(int r = 1; r <= BTB_R_COUNT; r++)
            AddProxy(e, r);
        }
      m_seenEvents = ne;
     }

   //--- Call for every usable quote, after OnEngineUpdate for that quote.
   void              OnQuote(const TRE_Quote &q)
     {
      m_last = q;
      m_haveLast = true;
      for(int k = ArraySize(m_live) - 1; k >= 0; k--)
        {
         if(k >= ArraySize(m_live))
            continue;
         int i = m_live[k];
         if(m_px[i].state == BTB_PX_WAIT_PLACEMENT)
           {
            if(q.time_msc >= m_px[i].due_msc)
               Place(i, q);
           }
         else
            if(m_px[i].state == BTB_PX_PENDING)
               UpdatePending(i, q, false);
            else
               if(m_px[i].state == BTB_PX_OPEN)
                  UpdateOpen(i, q);
        }
     }

   //--- End of data: open proxies close at the last quote; nothing else fills.
   void              Finish(void)
     {
      long lastMsc = (m_haveLast ? m_last.time_msc : 0);
      for(int k = ArraySize(m_live) - 1; k >= 0; k--)
        {
         if(k >= ArraySize(m_live))
            continue;
         int i = m_live[k];
         if(m_px[i].state == BTB_PX_OPEN && m_haveLast)
            Close(i, m_last, BTB_EXIT_END_OF_DATA, m_px[i].dir > 0 ? m_last.bid : m_last.ask, false);
         else
            if(m_px[i].state == BTB_PX_PENDING)
               EndPending(i, BTB_PX_NOT_FILLED_END_OF_DATA, lastMsc);
            else
               EndPending(i, m_px[i].state == BTB_PX_WAIT_PLACEMENT ? BTB_PX_NOT_PLACED_END_OF_DATA : BTB_PX_NOT_FILLED_END_OF_DATA, lastMsc);
        }
     }

   int               ProxyCount(void) const { return m_n; }
   int               LiveCount(void) const { return ArraySize(m_live); }
   int               ProxyEvent(const int i) const { return m_px[i].ev; }
   int               ProxyR(const int i) const { return m_px[i].r; }
   int               ProxyDir(const int i) const { return m_px[i].dir; }
   int               ProxyState(const int i) const { return m_px[i].state; }
   string            ProxyStateText(const int i) const { return BTB_ProxyStateName(m_px[i].state, m_px[i].at_placement); }
   bool              ProxyAtPlacement(const int i) const { return m_px[i].at_placement; }
   long              ProxyPlaceMsc(const int i) const { return m_px[i].place_msc; }
   double            ProxyS0(const int i) const { return m_px[i].s0; }
   double            ProxyS0Pips(const int i) const { return S0Pips(i); }
   double            ProxyLimit(const int i) const { return m_px[i].limit; }
   double            ProxySL(const int i) const { return m_px[i].sl; }
   double            ProxyTP(const int i) const { return m_px[i].tp; }
   double            ProxyRisk1R(const int i) const { return m_px[i].risk1r; }
   double            ProxyCommission(const int i) const { return m_px[i].commission; }
   long              ProxyFillMsc(const int i) const { return m_px[i].fill_msc; }
   long              ProxyExitMsc(const int i) const { return m_px[i].exit_msc; }
   double            ProxyExitPrice(const int i) const { return m_px[i].exit_price; }
   int               ProxyExitReason(const int i) const { return m_px[i].exit_reason; }
   double            ProxyMfe(const int i) const { return m_px[i].mfe; }
   double            ProxyMae(const int i) const { return m_px[i].mae; }
   bool              ProxyFilled(const int i) const { return m_px[i].fill_msc > 0; }

   double            ProxyGross(const int i) const
     {
      double g = 0.0;
      if(m_px[i].state == BTB_PX_CLOSED)
         m_econ.ProfitPerLot((ENUM_TRE_DIRECTION)m_px[i].dir, m_px[i].limit, m_px[i].exit_price, g);
      return g;
     }
   double            ProxyNet(const int i) const { return ProxyGross(i) - m_px[i].commission; }
   double            ProxyNetR(const int i) const { return m_px[i].risk1r > 0.0 ? ProxyNet(i) / m_px[i].risk1r : 0.0; }

   //--- Index of the proxy for event e and target r, or -1.
   int               Find(const int e, const int r) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_px[i].ev == e && m_px[i].r == r)
            return i;
      return -1;
     }

   int               CountState(const int st) const
     {
      int c = 0;
      for(int i = 0; i < m_n; i++)
         if(m_px[i].state == st)
            c++;
      return c;
     }

   //--- Ledger state: quarantine overlap (breakout candle .. end of the proxy's life) -> IN_QUARANTINE.
   string            WrittenState(const int i, CBTB_QuarantineCheck &q) const
     {
      int e = m_px[i].ev;
      datetime from = m_eng.EventBarTime(e);
      datetime to = (m_px[i].end_msc > 0 ? (datetime)(m_px[i].end_msc / 1000 + 1) : m_eng.EventCloseTime(e));
      if(to < m_eng.EventCloseTime(e))
         to = m_eng.EventCloseTime(e);
      if(q.Overlaps(from, to))
         return "IN_QUARANTINE";
      return BTB_ProxyStateName(m_px[i].state, m_px[i].at_placement);
     }

   string            CsvHeader(void) const
     {
      return "event_id,tf,level_type,side,box_n,box_bucket,break_close_time,in_full,in_ny,r_target,placement_time,s0,s0_pips,"
             "limit_price,sl,tp,planned_risk_1r,commission,state,fill_time,fill_delay_s,exit_time,exit_price,exit_reason,"
             "spread_at_exit,gross_pnl,net_pnl,net_r,commission_r,s0_r,mae_r,mfe_r,ambiguous,close_hour,hour_bucket,spread_bucket";
     }

   string            CsvRow(const int i, CBTB_QuarantineCheck &q) const
     {
      int e = m_px[i].ev;
      int d = m_spec.digits;
      bool placed = (m_px[i].place_msc > 0);
      bool valid = placed && m_px[i].risk1r > 0.0;
      bool filled = (m_px[i].fill_msc > 0);
      bool closed = (m_px[i].state == BTB_PX_CLOSED);
      double R = m_px[i].risk1r;
      double gross = ProxyGross(i);
      double net = gross - m_px[i].commission;
      double s0Pips = S0Pips(i);
      int boxN = m_eng.EventBoxN(e);
      bool isL4 = (m_eng.EventLevelType(e) == BTB_L4);
      datetime closeT = m_eng.EventCloseTime(e);
      int hour = (int)((closeT % TRE_SECONDS_PER_DAY) / 3600);
      return m_eng.EventId(e) + "," + m_eng.TimeframeName() + "," + BTB_LevelTypeName(m_eng.EventLevelType(e)) + "," +
             BTB_SideName(m_px[i].dir) + "," + (isL4 ? IntegerToString(boxN) : "NA") + "," + (isL4 ? BTB_BoxBucket(boxN) : "NA") + "," +
             TRE_IsoTime(closeT) + "," + (m_eng.EventInFull(e) ? "1" : "0") + "," + (m_eng.EventInNy(e) ? "1" : "0") + "," +
             IntegerToString(m_px[i].r) + "," + T(m_px[i].place_msc) + "," +
             N(placed, m_px[i].s0, d) + "," + N(placed, s0Pips, 4) + "," + N(placed, m_px[i].limit, d) + "," +
             N(valid, m_px[i].sl, d) + "," + N(valid, m_px[i].tp, d) + "," + N(valid, R, 4) + "," + N(valid, m_px[i].commission, 4) + "," +
             WrittenState(i, q) + "," + T(m_px[i].fill_msc) + "," +
             (filled ? DoubleToString((m_px[i].fill_msc - m_px[i].place_msc) / 1000.0, 3) : "NA") + "," +
             (closed ? T(m_px[i].exit_msc) : "") + "," + N(closed, m_px[i].exit_price, d) + "," +
             (closed ? BTB_ExitReasonName(m_px[i].exit_reason) : "") + "," + N(closed, m_px[i].exit_spread, d) + "," +
             N(closed, gross, 4) + "," + N(closed, net, 4) + "," + N(closed, R > 0.0 ? net / R : 0.0, 6) + "," +
             N(valid, R > 0.0 ? m_px[i].commission / R : 0.0, 6) + "," + N(valid, R > 0.0 ? m_px[i].s0 * m_px[i].pp / R : 0.0, 6) + "," +
             N(filled, R > 0.0 ? m_px[i].mae * m_px[i].pp / R : 0.0, 6) + "," + N(filled, R > 0.0 ? m_px[i].mfe * m_px[i].pp / R : 0.0, 6) + "," +
             (closed ? (m_px[i].ambiguous ? "1" : "0") : "NA") + "," + IntegerToString(hour) + "," + BTB_HourBucket(hour) + "," +
             (placed ? BTB_SpreadBucket(s0Pips) : "NA");
     }

   //--- btb_proxies_<TF>.csv (UTF-8, LF): one row per event x R.
   bool              WriteCsv(const string path, CBTB_QuarantineCheck &q) const
     {
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      BTB_WriteLine(h, CsvHeader());
      for(int i = 0; i < m_n; i++)
         BTB_WriteLine(h, CsvRow(i, q));
      FileClose(h);
      return true;
     }
  };

#endif // BTB_PROXY_MQH
//+------------------------------------------------------------------+
