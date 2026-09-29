//+------------------------------------------------------------------+
//| TRE_Bars.mqh                                                     |
//| Single-pass bar construction (roadmap 2.10A, 1.12 item 6).       |
//| Ticks -> M1 bars (declared price source) -> SignalTimeframe bars.|
//| A bar is complete when the first bar of a later period arrives,  |
//| or at the end-of-run flush. Bar close time = open + period.      |
//+------------------------------------------------------------------+
#ifndef TRE_BARS_MQH
#define TRE_BARS_MQH

#include "TRE_Types.mqh"
#include "TRE_Quote.mqh"

struct TRE_Bar
  {
   datetime          time;     // open time (period start)
   int               period;   // seconds
   double            open;
   double            high;
   double            low;
   double            close;
   long              ticks;
  };

datetime TRE_BarCloseTime(const TRE_Bar &b) { return b.time + b.period; }

//+------------------------------------------------------------------+
//| M1 bars from usable quotes.                                      |
//+------------------------------------------------------------------+
class CTRE_M1Builder
  {
private:
   ENUM_TRE_PRICE_SOURCE m_src;
   int               m_digits;
   bool              m_have;
   TRE_Bar           m_cur;

public:
   //--- Prices are normalized to the symbol digits so every consumer, including
   //--- the Python reference reading the exported CSV, sees identical doubles.
   void              Init(const ENUM_TRE_PRICE_SOURCE src, const int digits) { m_src = src; m_digits = digits; m_have = false; }

   //--- Returns true when `completed` holds the bar that just closed.
   bool              OnQuote(const TRE_Quote &q, TRE_Bar &completed)
     {
      double px = TRE_SignalBarPrice(q, m_src);
      if(!(px > 0.0))
         return false;
      px = NormalizeDouble(px, m_digits);
      datetime bt = q.time - (q.time % 60);
      bool done = false;
      if(m_have && bt != m_cur.time)
        {
         completed = m_cur;
         done = true;
         m_have = false;
        }
      if(!m_have)
        {
         m_cur.time = bt;
         m_cur.period = 60;
         m_cur.open = px;
         m_cur.high = px;
         m_cur.low = px;
         m_cur.close = px;
         m_cur.ticks = 1;
         m_have = true;
        }
      else
        {
         if(px > m_cur.high)
            m_cur.high = px;
         if(px < m_cur.low)
            m_cur.low = px;
         m_cur.close = px;
         m_cur.ticks++;
        }
      return done;
     }

   bool              Flush(TRE_Bar &completed)
     {
      if(!m_have)
         return false;
      completed = m_cur;
      m_have = false;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| SignalTimeframe bars aggregated from completed M1 bars.          |
//+------------------------------------------------------------------+
class CTRE_TfAggregator
  {
private:
   int               m_period;
   bool              m_have;
   TRE_Bar           m_cur;

public:
   void              Init(const int periodSeconds) { m_period = periodSeconds; m_have = false; }
   int               Period(void) const { return m_period; }

   //--- Feed one completed M1 bar; returns true when `completed` holds a finished TF bar.
   bool              OnM1(const TRE_Bar &m1, TRE_Bar &completed)
     {
      datetime bt = m1.time - (m1.time % m_period);
      bool done = false;
      if(m_have && bt != m_cur.time)
        {
         completed = m_cur;
         done = true;
         m_have = false;
        }
      if(!m_have)
        {
         m_cur.time = bt;
         m_cur.period = m_period;
         m_cur.open = m1.open;
         m_cur.high = m1.high;
         m_cur.low = m1.low;
         m_cur.close = m1.close;
         m_cur.ticks = m1.ticks;
         m_have = true;
        }
      else
        {
         if(m1.high > m_cur.high)
            m_cur.high = m1.high;
         if(m1.low < m_cur.low)
            m_cur.low = m1.low;
         m_cur.close = m1.close;
         m_cur.ticks += m1.ticks;
        }
      return done;
     }

   //--- Completes the open bar as soon as time t is at or past its period end.
   bool              CompleteIfPast(const datetime t, TRE_Bar &completed)
     {
      if(!m_have || t < m_cur.time + m_period)
         return false;
      completed = m_cur;
      m_have = false;
      return true;
     }

   bool              Flush(TRE_Bar &completed)
     {
      if(!m_have)
         return false;
      completed = m_cur;
      m_have = false;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| Wilder ATR(n): TR_1 = H-L; ATR_n = mean(TR_1..TR_n);             |
//| ATR_k = (ATR_{k-1}*(n-1) + TR_k)/n. Undefined before n bars.     |
//+------------------------------------------------------------------+
class CTRE_WilderAtr
  {
private:
   int               m_n;
   int               m_count;
   double            m_sum;
   double            m_atr;
   bool              m_havePrev;
   double            m_prevClose;

public:
   void              Init(const int n)
     {
      m_n = n;
      m_count = 0;
      m_sum = 0.0;
      m_atr = 0.0;
      m_havePrev = false;
      m_prevClose = 0.0;
     }

   void              Update(const TRE_Bar &b)
     {
      double tr = b.high - b.low;
      if(m_havePrev)
        {
         double a = MathAbs(b.high - m_prevClose);
         double c = MathAbs(b.low - m_prevClose);
         if(a > tr)
            tr = a;
         if(c > tr)
            tr = c;
        }
      m_prevClose = b.close;
      m_havePrev = true;
      m_count++;
      if(m_count < m_n)
         m_sum += tr;
      else
         if(m_count == m_n)
           {
            m_sum += tr;
            m_atr = m_sum / m_n;
           }
         else
            m_atr = (m_atr * (m_n - 1) + tr) / m_n;
     }

   bool              Ready(void) const { return m_count >= m_n; }
   double            Value(void) const { return m_atr; }
  };

#endif // TRE_BARS_MQH
//+------------------------------------------------------------------+
