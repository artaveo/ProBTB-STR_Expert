//+------------------------------------------------------------------+
//| BTB_Levels.mqh                                                   |
//| Roadmap Section 4: the four level engines and break detection.   |
//|                                                                  |
//| CBTB_LevelSource (shared, fed with every completed M1 bar after  |
//| the day tracker): L1 PDH/PDL, L2 Asian range, L3 H1 2/2 swings.  |
//| CBTB_LevelEngine (one per signal timeframe): Bid bars from M1,   |
//| Wilder ATR(14), L4 consolidation box, breakout / open-beyond /   |
//| consumption / cooldown rules and btb_events_<TF>.csv.            |
//|                                                                  |
//| A level is usable from the first signal bar whose open time is   |
//| at or after the time the level is complete (LSR apply-time rule).|
//| Long breakout: open <= level and close > level. Short: open >=   |
//| level and close < level. The first bar that opens or closes      |
//| beyond an active level consumes it; if it opened beyond, the row |
//| is OPEN_BEYOND_LEVEL. Several levels of one type and side broken |
//| by one candle give one row (the farthest level).                 |
//+------------------------------------------------------------------+
#ifndef BTB_LEVELS_MQH
#define BTB_LEVELS_MQH

#include "BTB_Types.mqh"
#include "BTB_Window.mqh"
#include "../TickResearchEngine/TRE_Bars.mqh"
#include "../TickResearchEngine/TRE_Timeframes.mqh"

struct BTB_Level
  {
   int               type;         // ENUM_BTB_LEVEL_TYPE (L1..L3)
   int               side;         // BTB_LONG (high level) / BTB_SHORT (low level)
   double            price;
   datetime          source_time;
   datetime          avail;        // usable for signal bars with open time >= avail
   datetime          valid_to;     // L1/L2: bars with open time >= valid_to are past the life; 0 = none
   int               expiry_h1;    // L3: index of the H1 bar whose close ends the life; -1 = none
  };

//+------------------------------------------------------------------+
class CBTB_LevelSource
  {
private:
   CBTB_DayTracker  *m_tracker;
   BTB_Level         m_levels[];
   int               m_nLevels;
   bool              m_haveFirst;
   datetime          m_firstDate;
   bool              m_haveDay;
   datetime          m_day;
   double            m_hi;
   double            m_lo;
   bool              m_havePrev;
   datetime          m_prevDay;
   double            m_prevHi;
   double            m_prevLo;
   bool              m_asianHave;
   bool              m_asianDone;
   double            m_asianHi;
   double            m_asianLo;
   CTRE_TfAggregator m_h1;
   TRE_Bar           m_h1Bars[];
   int               m_nH1;

   void              AddLevel(const int type, const int side, const double price, const datetime sourceTime,
                              const datetime avail, const datetime validTo, const int expiryH1)
     {
      if(m_nLevels >= ArraySize(m_levels))
         ArrayResize(m_levels, m_nLevels + 1, 1024);
      int i = m_nLevels++;
      m_levels[i].type = type;
      m_levels[i].side = side;
      m_levels[i].price = price;
      m_levels[i].source_time = sourceTime;
      m_levels[i].avail = avail;
      m_levels[i].valid_to = validTo;
      m_levels[i].expiry_h1 = expiryH1;
     }

   void              FinishAsian(void)
     {
      if(!m_asianDone && m_asianHave)
        {
         datetime r = m_tracker.ResumeOf(m_day);
         AddLevel(BTB_L2, BTB_LONG, m_asianHi, r, m_day + BTB_ASIAN_END_SEC, m_day + BTB_LATE_BLOCK_SEC, -1);
         AddLevel(BTB_L2, BTB_SHORT, m_asianLo, r, m_day + BTB_ASIAN_END_SEC, m_day + BTB_LATE_BLOCK_SEC, -1);
        }
      m_asianDone = true;
     }

   void              OnH1(const TRE_Bar &h)
     {
      if(m_nH1 >= ArraySize(m_h1Bars))
         ArrayResize(m_h1Bars, m_nH1 + 1, 1024);
      m_h1Bars[m_nH1++] = h;
      int k = m_nH1 - 1;
      int c = k - BTB_SWING_SIDE_BARS;
      if(c - BTB_SWING_SIDE_BARS < 0)
         return;
      bool isHigh = true, isLow = true;
      for(int j = c - BTB_SWING_SIDE_BARS; j <= c + BTB_SWING_SIDE_BARS; j++)
        {
         if(j == c)
            continue;
         if(!(m_h1Bars[c].high > m_h1Bars[j].high))
            isHigh = false;
         if(!(m_h1Bars[c].low < m_h1Bars[j].low))
            isLow = false;
        }
      datetime avail = m_h1Bars[k].time + 3600;
      if(isHigh)
         AddLevel(BTB_L3, BTB_LONG, m_h1Bars[c].high, m_h1Bars[c].time, avail, 0, k + BTB_L3_LIFE_H1_BARS);
      if(isLow)
         AddLevel(BTB_L3, BTB_SHORT, m_h1Bars[c].low, m_h1Bars[c].time, avail, 0, k + BTB_L3_LIFE_H1_BARS);
     }

public:
                     CBTB_LevelSource(void) { m_tracker = NULL; m_nLevels = 0; m_nH1 = 0; }

   void              Init(CBTB_DayTracker *tracker)
     {
      m_tracker = tracker;
      m_nLevels = 0;
      ArrayResize(m_levels, 0);
      m_haveFirst = false;
      m_firstDate = 0;
      m_haveDay = false;
      m_day = 0;
      m_hi = 0.0;
      m_lo = 0.0;
      m_havePrev = false;
      m_prevDay = 0;
      m_prevHi = 0.0;
      m_prevLo = 0.0;
      m_asianHave = false;
      m_asianDone = false;
      m_asianHi = 0.0;
      m_asianLo = 0.0;
      m_h1.Init(3600);
      m_nH1 = 0;
      ArrayResize(m_h1Bars, 0);
     }

   //--- One completed M1 bar (after CBTB_DayTracker::OnM1 for the same bar).
   void              OnM1(const TRE_Bar &b)
     {
      datetime d = TRE_BrokerDayStart(b.time);
      if(!m_haveFirst)
        {
         m_firstDate = d;
         m_haveFirst = true;
        }
      if(m_haveDay && d != m_day)
        {
         FinishAsian();
         //--- the first data date may be partial: never a PDH/PDL source (LSR rule)
         if(m_day != m_firstDate)
           {
            m_havePrev = true;
            m_prevDay = m_day;
            m_prevHi = m_hi;
            m_prevLo = m_lo;
           }
         m_haveDay = false;
        }
      if(!m_haveDay)
        {
         if(m_havePrev)
           {
            AddLevel(BTB_L1, BTB_LONG, m_prevHi, m_prevDay, d, d + TRE_SECONDS_PER_DAY, -1);
            AddLevel(BTB_L1, BTB_SHORT, m_prevLo, m_prevDay, d, d + TRE_SECONDS_PER_DAY, -1);
           }
         m_day = d;
         m_haveDay = true;
         m_hi = b.high;
         m_lo = b.low;
         m_asianHave = false;
         m_asianDone = false;
        }
      else
        {
         if(b.high > m_hi)
            m_hi = b.high;
         if(b.low < m_lo)
            m_lo = b.low;
        }
      if(!m_asianDone)
        {
         if(b.time >= d + BTB_ASIAN_END_SEC)
            FinishAsian();
         else
           {
            datetime r = m_tracker.ResumeOf(d);
            if(r > 0 && m_tracker.Status(d) == BTB_DAY_NORMAL && b.time >= r)
              {
               if(!m_asianHave)
                 {
                  m_asianHi = b.high;
                  m_asianLo = b.low;
                  m_asianHave = true;
                 }
               else
                 {
                  if(b.high > m_asianHi)
                     m_asianHi = b.high;
                  if(b.low < m_asianLo)
                     m_asianLo = b.low;
                 }
              }
           }
        }
      TRE_Bar h;
      if(m_h1.OnM1(b, h))
         OnH1(h);
     }

   int               LevelCount(void) const { return m_nLevels; }
   int               LevelType(const int i) const { return m_levels[i].type; }
   int               LevelSide(const int i) const { return m_levels[i].side; }
   double            LevelPrice(const int i) const { return m_levels[i].price; }
   datetime          LevelSourceTime(const int i) const { return m_levels[i].source_time; }
   datetime          LevelAvail(const int i) const { return m_levels[i].avail; }
   int               LevelExpiryH1(const int i) const { return m_levels[i].expiry_h1; }
   int               H1Count(void) const { return m_nH1; }
   datetime          H1Close(const int i) const { return m_h1Bars[i].time + 3600; }

   //--- The level's life is over for a signal bar that opens at t.
   bool              LevelExpired(const int i, const datetime t) const
     {
      if(m_levels[i].valid_to > 0 && t >= m_levels[i].valid_to)
         return true;
      int ex = m_levels[i].expiry_h1;
      if(ex >= 0 && m_nH1 > ex && H1Close(ex) <= t)
         return true;
      return false;
     }
  };

//+------------------------------------------------------------------+
struct BTB_EventRec
  {
   string            id;
   int               level_type;
   int               side;
   double            level_price;
   datetime          source_time;
   int               box_n;
   datetime          bar_time;
   double            open;
   double            high;
   double            low;
   double            close;
   bool              atr_ready;
   double            atr;
   bool              in_full;
   bool              in_ny;
   int               status;      // ENUM_BTB_EVENT_STATUS (IN_QUARANTINE only when written)
   int               bar_index;   // index of the breakout bar in the engine's bar list (not written)
  };

//+------------------------------------------------------------------+
class CBTB_LevelEngine
  {
private:
   ENUM_TRE_TIMEFRAME m_tf;
   string            m_tfName;
   int               m_period;
   int               m_digits;
   CBTB_DayTracker  *m_tracker;
   CBTB_LevelSource *m_source;
   CTRE_TfAggregator m_agg;
   CTRE_WilderAtr    m_atr;
   TRE_Bar           m_bars[];
   int               m_nBars;
   BTB_EventRec      m_events[];
   int               m_nEvents;
   int               m_cursor;
   int               m_active[];        // L1-L3 level indices in arrival order
   int               m_l4Last[2];       // bar index of the last L4 breakout: [0] long, [1] short

   static bool       Crosses(const int side, const double price, const TRE_Bar &b)
     {
      return side > 0 ? (b.open > price || b.close > price) : (b.open < price || b.close < price);
     }

   static bool       Breaks(const int side, const double price, const TRE_Bar &b)
     {
      return side > 0 ? (b.open <= price && b.close > price) : (b.open >= price && b.close < price);
     }

   void              Emit(const int levelType, const int side, const double price, const datetime sourceTime, const int boxN,
                          const TRE_Bar &b, const bool breakout, const bool atrReady, const double atr,
                          const bool inFull, const bool inNy, const int dayStatus)
     {
      if(m_nEvents >= ArraySize(m_events))
         ArrayResize(m_events, m_nEvents + 1, 1024);
      int e = m_nEvents++;
      m_events[e].id = BTB_EventId(m_tfName, levelType, side, sourceTime, b.time);
      m_events[e].level_type = levelType;
      m_events[e].side = side;
      m_events[e].level_price = price;
      m_events[e].source_time = sourceTime;
      m_events[e].box_n = boxN;
      m_events[e].bar_time = b.time;
      m_events[e].open = b.open;
      m_events[e].high = b.high;
      m_events[e].low = b.low;
      m_events[e].close = b.close;
      m_events[e].atr_ready = atrReady;
      m_events[e].atr = atr;
      m_events[e].in_full = inFull;
      m_events[e].in_ny = inNy;
      m_events[e].bar_index = m_nBars;
      if(!breakout)
         m_events[e].status = BTB_EV_OPEN_BEYOND;
      else
         m_events[e].status = (dayStatus == BTB_DAY_WARMUP ? BTB_EV_WARMUP : BTB_EV_EVENT);
     }

   void              ProcessBar(const TRE_Bar &b)
     {
      int k = m_nBars;
      int nl = m_source.LevelCount();
      while(m_cursor < nl)
        {
         if(m_source.LevelType(m_cursor) <= BTB_L3)
           {
            int n = ArraySize(m_active);
            ArrayResize(m_active, n + 1, 256);
            m_active[n] = m_cursor;
           }
         m_cursor++;
        }
      bool atrReady = m_atr.Ready();
      double atr = m_atr.Value();
      datetime d = TRE_BrokerDayStart(b.time);
      datetime closeT = b.time + m_period;
      bool inFull = false, inNy = false;
      m_tracker.Window(d, closeT, inFull, inNy);
      int dayStatus = m_tracker.Status(d);

      //--- L1-L3: drop levels past their life, then evaluate each type and side
      int keep[];
      for(int j = 0; j < ArraySize(m_active); j++)
         if(!m_source.LevelExpired(m_active[j], b.time))
           {
            int n = ArraySize(keep);
            ArrayResize(keep, n + 1, 256);
            keep[n] = m_active[j];
           }
      int nk = ArraySize(keep);
      bool consumed[];
      ArrayResize(consumed, nk);
      for(int j = 0; j < nk; j++)
         consumed[j] = false;
      for(int lt = BTB_L1; lt <= BTB_L3; lt++)
         for(int s = 0; s < 2; s++)
           {
            int side = (s == 0 ? BTB_LONG : BTB_SHORT);
            int best = -1, bestBrk = -1;
            for(int j = 0; j < nk; j++)
              {
               int li = keep[j];
               if(m_source.LevelType(li) != lt || m_source.LevelSide(li) != side || m_source.LevelAvail(li) > b.time)
                  continue;
               double px = m_source.LevelPrice(li);
               if(!Crosses(side, px, b))
                  continue;
               consumed[j] = true;
               if(best < 0 || (side > 0 ? px > m_source.LevelPrice(best) : px < m_source.LevelPrice(best)))
                  best = li;
               if(Breaks(side, px, b) &&
                  (bestBrk < 0 || (side > 0 ? px > m_source.LevelPrice(bestBrk) : px < m_source.LevelPrice(bestBrk))))
                  bestBrk = li;
              }
            if(best < 0)
               continue;
            int chosen = (bestBrk >= 0 ? bestBrk : best);
            Emit(lt, side, m_source.LevelPrice(chosen), m_source.LevelSourceTime(chosen), 0, b, bestBrk >= 0,
                 atrReady, atr, inFull, inNy, dayStatus);
           }
      ArrayResize(m_active, 0, 256);
      for(int j = 0; j < nk; j++)
         if(!consumed[j])
           {
            int n = ArraySize(m_active);
            ArrayResize(m_active, n + 1, 256);
            m_active[n] = keep[j];
           }

      //--- L4: longest box over bars [k-N, k-1], N in [20, 96], range <= 2.5 x ATR(14) at bar k-1
      if(k >= BTB_L4_MIN_N && atrReady && atr > 0.0)
        {
         double thr = BTB_L4_ATR_MULT * atr;
         double hi = 0.0, lo = 0.0, top = 0.0, bottom = 0.0;
         int bestN = 0;
         int maxN = (k < BTB_L4_MAX_N ? k : BTB_L4_MAX_N);
         for(int n = 1; n <= maxN; n++)
           {
            if(n == 1)
              {
               hi = m_bars[k - n].high;
               lo = m_bars[k - n].low;
              }
            else
              {
               if(m_bars[k - n].high > hi)
                  hi = m_bars[k - n].high;
               if(m_bars[k - n].low < lo)
                  lo = m_bars[k - n].low;
              }
            if(hi - lo <= thr)
              {
               if(n >= BTB_L4_MIN_N)
                 {
                  bestN = n;
                  top = hi;
                  bottom = lo;
                 }
              }
            else
               break;
           }
         if(bestN >= BTB_L4_MIN_N)
           {
            datetime src = m_bars[k - bestN].time;
            for(int s = 0; s < 2; s++)
              {
               int side = (s == 0 ? BTB_LONG : BTB_SHORT);
               if(k - m_l4Last[s] <= BTB_L4_COOLDOWN_BARS)
                  continue;
               double px = (side > 0 ? top : bottom);
               if(!Crosses(side, px, b))
                  continue;
               bool brk = Breaks(side, px, b);
               Emit(BTB_L4, side, px, src, bestN, b, brk, atrReady, atr, inFull, inNy, dayStatus);
               if(brk)
                  m_l4Last[s] = k;
              }
           }
        }

      m_atr.Update(b);
      if(m_nBars >= ArraySize(m_bars))
         ArrayResize(m_bars, m_nBars + 1, 4096);
      m_bars[m_nBars++] = b;
     }

   string            P(const double p) const { return DoubleToString(p, m_digits); }

public:
                     CBTB_LevelEngine(void) { m_tracker = NULL; m_source = NULL; m_nBars = 0; m_nEvents = 0; m_cursor = 0; }

   bool              Init(const ENUM_TRE_TIMEFRAME tf, CBTB_DayTracker *tracker, CBTB_LevelSource *source, const int digits)
     {
      m_tf = tf;
      m_tfName = TRE_TimeframeName(tf);
      m_period = TRE_TimeframeSeconds(tf);
      m_digits = digits;
      m_tracker = tracker;
      m_source = source;
      m_agg.Init(m_period);
      m_atr.Init(BTB_ATR_PERIOD);
      m_nBars = 0;
      ArrayResize(m_bars, 0);
      m_nEvents = 0;
      ArrayResize(m_events, 0);
      m_cursor = 0;
      ArrayResize(m_active, 0);
      m_l4Last[0] = -1000000;
      m_l4Last[1] = -1000000;
      return m_period > 0 && m_tracker != NULL && m_source != NULL;
     }

   //--- One completed M1 bar (after the day tracker and the level source).
   void              OnM1(const TRE_Bar &m1)
     {
      TRE_Bar done;
      if(m_agg.OnM1(m1, done))
         ProcessBar(done);
     }

   //--- Tick-time advance: completes the signal bar on the first tick at/after
   //--- its close, so the breakout is known on the placement tick. Produces the
   //--- same ledger as the M1-only path.
   void              OnTime(const datetime t)
     {
      TRE_Bar done;
      if(m_agg.CompleteIfPast(t, done))
         ProcessBar(done);
     }

   void              Flush(void)
     {
      TRE_Bar done;
      if(m_agg.Flush(done))
         ProcessBar(done);
     }

   //--- Test hook: a breakout EVENT on bar b (proxy tests).
   void              InjectEvent(const int levelType, const int side, const double price, const datetime sourceTime,
                                 const TRE_Bar &b, const bool inFull, const bool inNy)
     {
      Emit(levelType, side, price, sourceTime, levelType == BTB_L4 ? BTB_L4_MIN_N : 0, b, true, false, 0.0, inFull, inNy, BTB_DAY_NORMAL);
     }

   ENUM_TRE_TIMEFRAME Timeframe(void) const { return m_tf; }
   string            TimeframeName(void) const { return m_tfName; }
   int               Period(void) const { return m_period; }
   int               BarCount(void) const { return m_nBars; }
   int               EventCount(void) const { return m_nEvents; }
   string            EventId(const int i) const { return m_events[i].id; }
   int               EventLevelType(const int i) const { return m_events[i].level_type; }
   int               EventSide(const int i) const { return m_events[i].side; }
   double            EventLevelPrice(const int i) const { return m_events[i].level_price; }
   datetime          EventSourceTime(const int i) const { return m_events[i].source_time; }
   int               EventBoxN(const int i) const { return m_events[i].box_n; }
   datetime          EventBarTime(const int i) const { return m_events[i].bar_time; }
   datetime          EventCloseTime(const int i) const { return m_events[i].bar_time + m_period; }
   double            EventOpen(const int i) const { return m_events[i].open; }
   double            EventHigh(const int i) const { return m_events[i].high; }
   double            EventLow(const int i) const { return m_events[i].low; }
   double            EventClose(const int i) const { return m_events[i].close; }
   bool              EventInFull(const int i) const { return m_events[i].in_full; }
   bool              EventInNy(const int i) const { return m_events[i].in_ny; }
   int               EventStatus(const int i) const { return m_events[i].status; }
   int               EventBarIndex(const int i) const { return m_events[i].bar_index; }
   bool              GetBar(const int k, TRE_Bar &b) const
     {
      if(k < 0 || k >= m_nBars)
         return false;
      b = m_bars[k];
      return true;
     }
   int               CountStatus(const int st) const
     {
      int c = 0;
      for(int i = 0; i < m_nEvents; i++)
         if(m_events[i].status == st)
            c++;
      return c;
     }
   int               CountType(const int lt, const int side) const
     {
      int c = 0;
      for(int i = 0; i < m_nEvents; i++)
         if(m_events[i].level_type == lt && m_events[i].side == side)
            c++;
      return c;
     }

   string            CsvHeader(void) const
     {
      return "event_id,tf,level_type,side,level_price,level_source_time,box_n,break_bar_time,break_close_time,"
             "break_open,break_high,break_low,break_close,atr14,in_full,in_ny,status";
     }

   //--- Status as written: an EVENT whose breakout candle overlaps the data quarantine is IN_QUARANTINE.
   int               WrittenStatus(const int i, CBTB_QuarantineCheck &q) const
     {
      if(m_events[i].status == BTB_EV_EVENT && q.Overlaps(m_events[i].bar_time, m_events[i].bar_time + m_period))
         return BTB_EV_IN_QUARANTINE;
      return m_events[i].status;
     }

   string            CsvRow(const int i, CBTB_QuarantineCheck &q) const
     {
      bool atrOk = m_events[i].atr_ready && m_events[i].atr > 0.0;
      return m_events[i].id + "," + m_tfName + "," + BTB_LevelTypeName(m_events[i].level_type) + "," +
             BTB_SideName(m_events[i].side) + "," + P(m_events[i].level_price) + "," + TRE_IsoTime(m_events[i].source_time) + "," +
             (m_events[i].level_type == BTB_L4 ? IntegerToString(m_events[i].box_n) : "NA") + "," +
             TRE_IsoTime(m_events[i].bar_time) + "," + TRE_IsoTime(m_events[i].bar_time + m_period) + "," +
             P(m_events[i].open) + "," + P(m_events[i].high) + "," + P(m_events[i].low) + "," + P(m_events[i].close) + "," +
             (atrOk ? DoubleToString(m_events[i].atr, 8) : "NA") + "," +
             (m_events[i].in_full ? "1" : "0") + "," + (m_events[i].in_ny ? "1" : "0") + "," +
             BTB_EventStatusName(WrittenStatus(i, q));
     }

   //--- btb_events_<TF>.csv (UTF-8, LF).
   bool              WriteCsv(const string path, CBTB_QuarantineCheck &q) const
     {
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      BTB_WriteLine(h, CsvHeader());
      for(int i = 0; i < m_nEvents; i++)
         BTB_WriteLine(h, CsvRow(i, q));
      FileClose(h);
      return true;
     }
  };

#endif // BTB_LEVELS_MQH
//+------------------------------------------------------------------+
