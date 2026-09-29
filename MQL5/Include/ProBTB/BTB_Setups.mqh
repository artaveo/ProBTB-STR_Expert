//+------------------------------------------------------------------+
//| BTB_Setups.mqh                                                   |
//| BTB-v2 (roadmap PART 2).                                         |
//|  - E1 geometry lives in BTB_Types.mqh (BTB_StopPrice,            |
//|    BTB_ArmPrice); the E1 arming state machine runs on ticks in   |
//|    CBTB_ProxyBook (BTB_Proxy.mqh).                               |
//|  - CBTB_E2Setups: the bar-level E2 setup machine (V3) and the    |
//|    btb_setups_E2_<TF>.csv ledger, reproduced byte for byte by    |
//|    python/btb_reference/setups.py.                               |
//|                                                                  |
//| Per completed signal bar k, each open setup is advanced:         |
//|  0. a bar on the 4th broker date after the breakout date ends it |
//|     (EXPIRED_3_DAYS);                                            |
//|  1. LINE phase: live if |y(k) - P| <= tol x ATR14(k-1) and the   |
//|     bar lies inside the FULL window; a line past the zone ends   |
//|     it (LINE_PASSED); a live bar that reached P ends it          |
//|     (LIVE_TO_FILL); a bar that reached the far side of the zone  |
//|     ends it (INVALIDATED_BEFORE_FILL);                           |
//|  2. ZigZag pivots confirmed at k (leg 1, legs 2..n);             |
//|  3. spike check over the first 3 bars after the last leg;        |
//|  4. fractals confirmed at k (pushes p1, p2, rolls).              |
//| New setups start after bar k from its EVENT rows (steps 2-4).    |
//| Shorts mirror longs (side s = -1).                               |
//+------------------------------------------------------------------+
#ifndef BTB_SETUPS_MQH
#define BTB_SETUPS_MQH

#include "BTB_Types.mqh"
#include "BTB_Window.mqh"
#include "BTB_Levels.mqh"
#include "BTB_Swings.mqh"

#define BTB_PH_WAIT_LEG1   0
#define BTB_PH_LEGS        1
#define BTB_PH_PUSH1       2
#define BTB_PH_PUSH2       3
#define BTB_PH_LINE        4
#define BTB_PH_DONE        5

#define BTB_SPIKE_NONE      0
#define BTB_SPIKE_PENDING   1
#define BTB_SPIKE_FOUND     2
#define BTB_SPIKE_NOT_FOUND 3

#define BTB_LINE_GONE      -1
#define BTB_LINE_WAIT       0
#define BTB_LINE_LIVE       1

struct BTB_E2Config
  {
   double            zigzag_atr;
   double            spike_atr;
   int               spike_bars;
   double            line_tol_atr;
   int               max_days;
  };

void BTB_E2ConfigDefaults(BTB_E2Config &c)
  {
   c.zigzag_atr = BTB_E2_ZIGZAG_ATR;
   c.spike_atr = BTB_E2_SPIKE_ATR;
   c.spike_bars = BTB_E2_SPIKE_BARS;
   c.line_tol_atr = BTB_E2_LINE_TOL_ATR;
   c.max_days = BTB_E2_MAX_DAYS;
  }

//--- Trend line through (bar1, price1) and (bar2, price2) at bar index k.
double BTB_LineY(const double price1, const int bar1, const double price2, const int bar2, const int k)
  {
   double slope = (price2 - price1) / (bar2 - bar1);
   return price2 + slope * (k - bar2);
  }

//--- LIVE when |y - P| <= tol (both boundaries included); GONE when past the zone.
int BTB_LineState(const int side, const double y, const double p, const double tol)
  {
   if(side > 0 ? (y < p - tol) : (y > p + tol))
      return BTB_LINE_GONE;
   return MathAbs(y - p) <= tol ? BTB_LINE_LIVE : BTB_LINE_WAIT;
  }

struct BTB_E2Setup
  {
   int               ev;            // engine event index (-1 in unit tests)
   string            event_id;
   int               level_type;
   int               side;
   int               b;             // breakout bar index
   double            p;
   double            zlo;
   double            zhi;
   int               phase;
   int               status;        // ENUM_BTB_E2_STATUS
   int               pc;            // pivot cursor
   int               prev_pivot;
   int               seq_first;     // consumed pivots are the contiguous range [seq_first, seq_last]
   int               seq_last;
   int               n_legs;
   int               last_leg;
   int               last_pull;
   int               pull_after;
   int               spike_state;
   int               spike_next;
   int               spike_bar;
   double            spike_price;
   double            spike_depth;
   int               fc;            // cursor over the pull fractals
   int               p1;            // pull-fractal indices
   int               p2;
   int               n_pushes;
   int               first_live;
   int               last_live;
   int               end_bar;
   datetime          last_date;
   int               days_seen;
  };

//+------------------------------------------------------------------+
class CBTB_E2Setups
  {
private:
   string            m_tfName;
   int               m_period;
   int               m_digits;
   BTB_E2Config      m_cfg;
   CBTB_DayTracker  *m_tracker;       // NULL = every bar inside the window (unit tests)
   TRE_Bar           m_bars[];
   int               m_nBars;
   bool              m_atrReady[];
   double            m_atr[];
   CTRE_WilderAtr    m_atrCalc;
   CBTB_ZigZag       m_zz;
   CBTB_Fractals     m_fr;
   BTB_E2Setup       m_st[];
   int               m_n;
   int               m_syncBars;
   int               m_syncEvents;

   bool              Beyond(const int s, const double a, const double b) const { return s > 0 ? a > b : a < b; }
   double            ZoneEdge(const int i) const { return m_st[i].side > 0 ? m_st[i].zhi : m_st[i].zlo; }

   void              End(const int i, const int status, const int k)
     {
      m_st[i].status = status;
      m_st[i].phase = BTB_PH_DONE;
      m_st[i].end_bar = k;
     }

   double            FracPrice(const int i, const int f) const { return m_fr.Price(-m_st[i].side, f); }
   int               FracBar(const int i, const int f) const { return m_fr.Bar(-m_st[i].side, f); }

   bool              PullValid(const int i, const int pv) const
     {
      if(!Beyond(m_st[i].side, m_zz.Price(pv), ZoneEdge(i)))
         return false;
      if(m_st[i].last_pull >= 0 && !Beyond(m_st[i].side, m_zz.Price(pv), m_zz.Price(m_st[i].last_pull)))
         return false;
      return true;
     }

   void              StartSpike(const int i)
     {
      m_st[i].spike_state = BTB_SPIKE_PENDING;
      m_st[i].spike_next = m_zz.Bar(m_st[i].last_leg) + 1;
      m_st[i].pull_after = -1;
     }

   void              ConsumePivot(const int i, const int idx, const int k)
     {
      int s = m_st[i].side;
      int legKind = (s > 0 ? BTB_PIVOT_HIGH : BTB_PIVOT_LOW);
      if(m_st[i].phase == BTB_PH_WAIT_LEG1)
        {
         int prev = m_st[i].prev_pivot;
         if(prev >= 0 && m_zz.Kind(prev) == -legKind && m_zz.Kind(idx) == legKind &&
            m_zz.Bar(prev) <= m_st[i].b && m_st[i].b <= m_zz.Bar(idx))
           {
            m_st[i].seq_first = prev;
            m_st[i].seq_last = idx;
            m_st[i].n_legs = 1;
            m_st[i].last_leg = idx;
            m_st[i].phase = BTB_PH_LEGS;
            return;
           }
         if(m_zz.Bar(idx) > m_st[i].b)
           {
            End(i, BTB_E2_NO_LEG1, k);
            return;
           }
         m_st[i].prev_pivot = idx;
         return;
        }
      //--- BTB_PH_LEGS
      m_st[i].seq_last = idx;
      if(m_zz.Kind(idx) != legKind)
        {
         if(m_st[i].n_legs < BTB_E2_MIN_LEGS)
           {
            if(!PullValid(i, idx))
              {
               End(i, BTB_E2_STRUCTURE_FAILED, k);
               return;
              }
            m_st[i].last_pull = idx;
           }
         else
           {
            m_st[i].pull_after = idx;
            if(m_st[i].spike_state == BTB_SPIKE_NOT_FOUND && !PullValid(i, idx))
               End(i, BTB_E2_NO_SPIKE, k);
           }
         return;
        }
      bool higher = Beyond(s, m_zz.Price(idx), m_zz.Price(m_st[i].last_leg));
      if(m_st[i].n_legs < BTB_E2_MIN_LEGS)
        {
         if(!higher)
           {
            End(i, BTB_E2_STRUCTURE_FAILED, k);
            return;
           }
         m_st[i].n_legs++;
         m_st[i].last_leg = idx;
         if(m_st[i].n_legs >= BTB_E2_MIN_LEGS)
            StartSpike(i);
         return;
        }
      bool pullOk = (m_st[i].pull_after >= 0 && PullValid(i, m_st[i].pull_after));
      if(higher && pullOk)
        {
         m_st[i].last_pull = m_st[i].pull_after;
         m_st[i].n_legs++;
         m_st[i].last_leg = idx;
         StartSpike(i);
        }
      else
         End(i, BTB_E2_NO_SPIKE, k);
     }

   void              StepSpike(const int i, const int k)
     {
      if(m_st[i].phase != BTB_PH_LEGS || m_st[i].spike_state != BTB_SPIKE_PENDING)
         return;
      int hnBar = m_zz.Bar(m_st[i].last_leg);
      double hn = m_zz.Price(m_st[i].last_leg);
      int last = hnBar + m_cfg.spike_bars;
      if(!m_atrReady[hnBar])
         m_st[i].spike_state = BTB_SPIKE_NOT_FOUND;
      else
        {
         double thr = m_cfg.spike_atr * m_atr[hnBar];
         int j = m_st[i].spike_next;
         int stop = (k < last ? k : last);
         while(j <= stop)
           {
            bool hit = (m_st[i].side > 0 ? m_bars[j].low <= hn - thr : m_bars[j].high >= hn + thr);
            if(hit)
              {
               m_st[i].spike_state = BTB_SPIKE_FOUND;
               m_st[i].spike_bar = j;
               m_st[i].spike_price = (m_st[i].side > 0 ? m_bars[j].low : m_bars[j].high);
               m_st[i].spike_depth = MathAbs(hn - m_st[i].spike_price) / m_atr[hnBar];
               break;
              }
            j++;
           }
         m_st[i].spike_next = j;
         if(m_st[i].spike_state == BTB_SPIKE_PENDING && j > last)
            m_st[i].spike_state = BTB_SPIKE_NOT_FOUND;
        }
      if(m_st[i].spike_state == BTB_SPIKE_FOUND)
        {
         m_st[i].phase = BTB_PH_PUSH1;
         m_st[i].fc = 0;
        }
      else
         if(m_st[i].spike_state == BTB_SPIKE_NOT_FOUND && m_st[i].pull_after >= 0 && !PullValid(i, m_st[i].pull_after))
            End(i, BTB_E2_NO_SPIKE, k);
     }

   //--- A confirmed opposite fractal strictly between bars a and b.
   bool              Between(const int i, const int a, const int b) const
     {
      int opp = m_st[i].side;             // long: fractal highs; short: fractal lows
      int n = m_fr.Count(opp);
      for(int f = 0; f < n; f++)
        {
         int fb = m_fr.Bar(opp, f);
         if(fb > a && fb < b)
            return true;
        }
      return false;
     }

   void              StepFractals(const int i, const int k)
     {
      int ph = m_st[i].phase;
      if(ph != BTB_PH_PUSH1 && ph != BTB_PH_PUSH2 && ph != BTB_PH_LINE)
         return;
      int s = m_st[i].side;
      int pullSide = -s;                  // long: fractal lows
      int hnBar = m_zz.Bar(m_st[i].last_leg);
      while(m_st[i].fc < m_fr.Count(pullSide) && m_st[i].phase != BTB_PH_DONE)
        {
         int f = m_st[i].fc;
         m_st[i].fc++;
         if(m_fr.Bar(pullSide, f) <= hnBar)
            continue;
         double fp = m_fr.Price(pullSide, f);
         bool inZone = !Beyond(s, fp, ZoneEdge(i));
         if(m_st[i].phase == BTB_PH_PUSH1)
           {
            if(inZone)
              {
               End(i, BTB_E2_STRUCTURE_FAILED, k);
               return;
              }
            m_st[i].p1 = f;
            m_st[i].n_pushes = 1;
            m_st[i].phase = BTB_PH_PUSH2;
           }
         else
            if(m_st[i].phase == BTB_PH_PUSH2)
              {
               if(inZone)
                 {
                  End(i, BTB_E2_STRUCTURE_FAILED, k);
                  return;
                 }
               if(Beyond(s, FracPrice(i, m_st[i].p1), fp))
                 {
                  if(Between(i, FracBar(i, m_st[i].p1), m_fr.Bar(pullSide, f)))
                    {
                     m_st[i].p2 = f;
                     m_st[i].n_pushes = 2;
                     m_st[i].phase = BTB_PH_LINE;
                    }
                  else
                     m_st[i].p1 = f;                 // push 1 extends
                 }
               else
                  m_st[i].p1 = f;                    // higher low: push 1 restarts
              }
            else
              {
               //--- BTB_PH_LINE
               if(inZone || !Beyond(s, FracPrice(i, m_st[i].p2), fp))
                  continue;
               if(Between(i, FracBar(i, m_st[i].p2), m_fr.Bar(pullSide, f)))
                 {
                  m_st[i].p1 = m_st[i].p2;
                  m_st[i].p2 = f;
                  m_st[i].n_pushes++;
                 }
               else
                  m_st[i].p2 = f;
              }
        }
     }

   void              StepExpiry(const int i, const int k)
     {
      datetime d = TRE_BrokerDayStart(m_bars[k].time);
      if(d != m_st[i].last_date)
        {
         m_st[i].days_seen++;
         m_st[i].last_date = d;
        }
      if(m_st[i].days_seen > m_cfg.max_days)
         End(i, BTB_E2_EXPIRED_3_DAYS, k);
     }

   void              StepLine(const int i, const int k)
     {
      int live = LiveState(i, k, m_bars[k].time);
      if(live == BTB_LINE_GONE)
        {
         End(i, BTB_E2_LINE_PASSED, k);
         return;
        }
      int s = m_st[i].side;
      if(live == BTB_LINE_LIVE)
        {
         if(m_st[i].first_live < 0)
            m_st[i].first_live = k;
         m_st[i].last_live = k;
         if(s > 0 ? m_bars[k].low <= m_st[i].p : m_bars[k].high >= m_st[i].p)
           {
            End(i, BTB_E2_LIVE_TO_FILL, k);
            return;
           }
        }
      if(s > 0 ? m_bars[k].low <= m_st[i].zlo : m_bars[k].high >= m_st[i].zhi)
         End(i, BTB_E2_INVALIDATED_BEFORE_FILL, k);
     }

   void              AdvanceStructure(const int i, const int k)
     {
      while((m_st[i].phase == BTB_PH_WAIT_LEG1 || m_st[i].phase == BTB_PH_LEGS) && m_st[i].pc < m_zz.Count())
        {
         int idx = m_st[i].pc;
         m_st[i].pc++;
         ConsumePivot(i, idx, k);
        }
      if(m_st[i].phase == BTB_PH_DONE)
         return;
      StepSpike(i, k);
      if(m_st[i].phase == BTB_PH_DONE)
         return;
      StepFractals(i, k);
     }

   string            P(const double v) const { return DoubleToString(v, m_digits); }
   string            T(const int k) const { return k >= 0 ? TRE_IsoTime(m_bars[k].time) : ""; }

public:
                     CBTB_E2Setups(void) { m_tracker = NULL; m_nBars = 0; m_n = 0; m_syncBars = 0; m_syncEvents = 0; m_period = 300; m_digits = 2; }

   void              Init(const string tfName, const int period, const int digits, const BTB_E2Config &cfg, CBTB_DayTracker *tracker)
     {
      m_tfName = tfName;
      m_period = period;
      m_digits = digits;
      m_cfg = cfg;
      m_tracker = tracker;
      m_nBars = 0;
      ArrayResize(m_bars, 0);
      ArrayResize(m_atrReady, 0);
      ArrayResize(m_atr, 0);
      m_atrCalc.Init(BTB_ATR_PERIOD);
      m_zz.Init(cfg.zigzag_atr);
      m_fr.Init();
      m_n = 0;
      ArrayResize(m_st, 0);
      m_syncBars = 0;
      m_syncEvents = 0;
     }

   //--- The bar lies inside the FULL window of its day (roadmap V3.5).
   bool              WindowOk(const datetime openTime) const
     {
      if(m_tracker == NULL)
         return true;
      datetime d = TRE_BrokerDayStart(openTime);
      bool full = false, ny = false;
      m_tracker.Window(d, openTime, full, ny);
      return full && openTime + m_period <= d + BTB_LATE_BLOCK_SEC;
     }

   //--- Line test for bar k decided at its open (line, ATR14(k-1), window).
   int               LiveState(const int i, const int k, const datetime openTime) const
     {
      if(k < 1 || k - 1 >= m_nBars || !m_atrReady[k - 1])
         return BTB_LINE_WAIT;
      double y = BTB_LineY(FracPrice(i, m_st[i].p1), FracBar(i, m_st[i].p1), FracPrice(i, m_st[i].p2), FracBar(i, m_st[i].p2), k);
      int state = BTB_LineState(m_st[i].side, y, m_st[i].p, m_cfg.line_tol_atr * m_atr[k - 1]);
      if(state == BTB_LINE_LIVE && !WindowOk(openTime))
         return BTB_LINE_WAIT;
      return state;
     }

   bool              ExpiredAt(const int i, const datetime openTime) const
     {
      datetime d = TRE_BrokerDayStart(openTime);
      int seen = m_st[i].days_seen + (d != m_st[i].last_date ? 1 : 0);
      return seen > m_cfg.max_days;
     }

   //--- Tick level: is the order of setup i live on the forming bar k (open time openTime)?
   bool              TickLive(const int i, const int k, const datetime openTime) const
     {
      if(m_st[i].phase != BTB_PH_LINE || ExpiredAt(i, openTime))
         return false;
      return LiveState(i, k, openTime) == BTB_LINE_LIVE;
     }

   //--- One completed signal bar. Returns its index k.
   int               OnBar(const TRE_Bar &b)
     {
      int k = m_nBars;
      if(m_nBars >= ArraySize(m_bars))
        {
         ArrayResize(m_bars, m_nBars + 1, 4096);
         ArrayResize(m_atrReady, m_nBars + 1, 4096);
         ArrayResize(m_atr, m_nBars + 1, 4096);
        }
      m_bars[k] = b;
      m_atrCalc.Update(b);
      m_atrReady[k] = m_atrCalc.Ready();
      m_atr[k] = m_atrCalc.Value();
      m_nBars++;
      m_zz.OnBar(b, m_atrReady[k], m_atr[k]);
      m_fr.OnBar(b);
      for(int i = 0; i < m_n; i++)
        {
         if(m_st[i].phase == BTB_PH_DONE)
            continue;
         StepExpiry(i, k);
         if(m_st[i].phase == BTB_PH_DONE)
            continue;
         if(m_st[i].phase == BTB_PH_LINE)
           {
            StepLine(i, k);
            if(m_st[i].phase == BTB_PH_DONE)
               continue;
           }
         AdvanceStructure(i, k);
        }
      return k;
     }

   //--- A Part 1 EVENT on bar k (the last bar fed): the setup starts at once.
   int               AddEvent(const int ev, const string eventId, const int levelType, const int side, const int k)
     {
      if(m_n >= ArraySize(m_st))
         ArrayResize(m_st, m_n + 1, 1024);
      int i = m_n++;
      m_st[i].ev = ev;
      m_st[i].event_id = eventId;
      m_st[i].level_type = levelType;
      m_st[i].side = side;
      m_st[i].b = k;
      m_st[i].p = m_bars[k].close;
      m_st[i].zlo = m_bars[k].low;
      m_st[i].zhi = m_bars[k].high;
      m_st[i].phase = BTB_PH_WAIT_LEG1;
      m_st[i].status = BTB_E2_OPEN;
      m_st[i].pc = 0;
      m_st[i].prev_pivot = -1;
      m_st[i].seq_first = -1;
      m_st[i].seq_last = -1;
      m_st[i].n_legs = 0;
      m_st[i].last_leg = -1;
      m_st[i].last_pull = -1;
      m_st[i].pull_after = -1;
      m_st[i].spike_state = BTB_SPIKE_NONE;
      m_st[i].spike_next = 0;
      m_st[i].spike_bar = -1;
      m_st[i].spike_price = 0.0;
      m_st[i].spike_depth = 0.0;
      m_st[i].fc = 0;
      m_st[i].p1 = -1;
      m_st[i].p2 = -1;
      m_st[i].n_pushes = 0;
      m_st[i].first_live = -1;
      m_st[i].last_live = -1;
      m_st[i].end_bar = -1;
      m_st[i].last_date = TRE_BrokerDayStart(m_bars[k].time);
      m_st[i].days_seen = 0;
      AdvanceStructure(i, k);
      return i;
     }

   //--- Pulls the engine's new completed bars and, after each bar, its EVENT rows.
   void              Sync(CBTB_LevelEngine *eng)
     {
      int nb = eng.BarCount();
      while(m_syncBars < nb)
        {
         TRE_Bar b;
         eng.GetBar(m_syncBars, b);
         int k = OnBar(b);
         while(m_syncEvents < eng.EventCount() && eng.EventBarIndex(m_syncEvents) <= k)
           {
            int e = m_syncEvents;
            if(eng.EventBarIndex(e) == k && eng.EventStatus(e) == BTB_EV_EVENT)
               AddEvent(e, eng.EventId(e), eng.EventLevelType(e), eng.EventSide(e), k);
            m_syncEvents++;
           }
         m_syncBars++;
        }
     }

   void              Finish(void)
     {
      int last = m_nBars - 1;
      for(int i = 0; i < m_n; i++)
         if(m_st[i].phase != BTB_PH_DONE)
            End(i, BTB_E2_END_OF_DATA, last);
     }

   //--- accessors
   int               BarCount(void) const { return m_nBars; }
   int               SetupCount(void) const { return m_n; }
   int               Event(const int i) const { return m_st[i].ev; }
   bool              Ended(const int i) const { return m_st[i].phase == BTB_PH_DONE; }
   int               Status(const int i) const { return m_st[i].status; }
   int               Phase(const int i) const { return m_st[i].phase; }
   int               NLegs(const int i) const { return m_st[i].n_legs; }
   int               NPushes(const int i) const { return m_st[i].n_pushes; }
   int               FirstLive(const int i) const { return m_st[i].first_live; }
   int               LastLive(const int i) const { return m_st[i].last_live; }
   int               EndBar(const int i) const { return m_st[i].end_bar; }
   int               SpikeBar(const int i) const { return m_st[i].spike_bar; }
   int               P1Bar(const int i) const { return m_st[i].p1 >= 0 ? FracBar(i, m_st[i].p1) : -1; }
   int               P2Bar(const int i) const { return m_st[i].p2 >= 0 ? FracBar(i, m_st[i].p2) : -1; }
   double            P1Price(const int i) const { return m_st[i].p1 >= 0 ? FracPrice(i, m_st[i].p1) : 0.0; }
   double            P2Price(const int i) const { return m_st[i].p2 >= 0 ? FracPrice(i, m_st[i].p2) : 0.0; }
   double            Limit(const int i) const { return m_st[i].p; }
   double            ZoneLow(const int i) const { return m_st[i].zlo; }
   double            ZoneHigh(const int i) const { return m_st[i].zhi; }
   datetime          BreakTime(const int i) const { return m_bars[m_st[i].b].time; }
   //--- pivot bars of the consumed sequence L0, H1, L1, ... (n = count)
   int               SeqCount(const int i) const { return m_st[i].seq_first < 0 ? 0 : m_st[i].seq_last - m_st[i].seq_first + 1; }
   int               SeqBar(const int i, const int j) const { return m_zz.Bar(m_st[i].seq_first + j); }
   //--- structure (tests)
   int               PivotCount(void) const { return m_zz.Count(); }
   int               PivotKind(const int j) const { return m_zz.Kind(j); }
   double            PivotPrice(const int j) const { return m_zz.Price(j); }
   int               PivotBar(const int j) const { return m_zz.Bar(j); }
   int               PivotConf(const int j) const { return m_zz.Conf(j); }
   bool              AtrReady(const int k) const { return m_atrReady[k]; }
   double            Atr(const int k) const { return m_atr[k]; }

   string            CsvHeader(void) const
     {
      return "event_id,tf,level_type,side,sample,break_bar_time,limit_price,zone_low,zone_high,pivots,n_legs,"
             "spike_time,spike_price,spike_depth_atr,p1_time,p1_price,p2_time,p2_price,n_pushes,slope,"
             "first_live_bar,last_live_bar,end_bar_time,status,in_quarantine";
     }

   string            CsvRow(const int i, CBTB_QuarantineCheck &q) const
     {
      datetime bt = m_bars[m_st[i].b].time;
      string seq = "";
      for(int j = m_st[i].seq_first; m_st[i].seq_first >= 0 && j <= m_st[i].seq_last; j++)
         seq += (j > m_st[i].seq_first ? ";" : "") + TRE_IsoTime(m_bars[m_zz.Bar(j)].time) + "@" + P(m_zz.Price(j));
      bool spike = (m_st[i].spike_bar >= 0);
      bool hasP1 = (m_st[i].p1 >= 0), hasP2 = (m_st[i].p2 >= 0);
      string slope = "NA";
      if(hasP2)
         slope = DoubleToString((FracPrice(i, m_st[i].p2) - FracPrice(i, m_st[i].p1)) / (FracBar(i, m_st[i].p2) - FracBar(i, m_st[i].p1)), 8);
      return m_st[i].event_id + "," + m_tfName + "," + BTB_LevelTypeName(m_st[i].level_type) + "," + BTB_SideName(m_st[i].side) + "," +
             BTB_SampleName(bt) + "," + TRE_IsoTime(bt) + "," + P(m_st[i].p) + "," + P(m_st[i].zlo) + "," + P(m_st[i].zhi) + "," +
             seq + "," + IntegerToString(m_st[i].n_legs) + "," +
             (spike ? T(m_st[i].spike_bar) : "") + "," + (spike ? P(m_st[i].spike_price) : "NA") + "," +
             (spike ? DoubleToString(m_st[i].spike_depth, 6) : "NA") + "," +
             (hasP1 ? T(FracBar(i, m_st[i].p1)) : "") + "," + (hasP1 ? P(FracPrice(i, m_st[i].p1)) : "NA") + "," +
             (hasP2 ? T(FracBar(i, m_st[i].p2)) : "") + "," + (hasP2 ? P(FracPrice(i, m_st[i].p2)) : "NA") + "," +
             IntegerToString(m_st[i].n_pushes) + "," + slope + "," +
             T(m_st[i].first_live) + "," + T(m_st[i].last_live) + "," + T(m_st[i].end_bar) + "," +
             BTB_E2StatusName(m_st[i].status) + "," + (q.Overlaps(bt, bt + m_period) ? "1" : "0");
     }

   //--- btb_setups_E2_<TF>.csv (UTF-8, LF): one row per EVENT that entered E2.
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

#endif // BTB_SETUPS_MQH
//+------------------------------------------------------------------+
