//+------------------------------------------------------------------+
//| BTB_Swings.mqh                                                   |
//| BTB-v2 structure tools (roadmap PART 2, V3.1).                   |
//|                                                                  |
//| ZigZag pivots with reversal threshold Z = mult x ATR14(k), where |
//| ATR14(k) is the Wilder ATR after the detecting bar k. Before the |
//| first pivot the candidates are the first bar's low and high; the |
//| first bar k >= 1 with high >= low0 + Z makes a pivot LOW at bar  |
//| 0 (tested first), with low <= high0 - Z a pivot HIGH at bar 0.   |
//| Afterwards the swing extreme is tracked (strictly beyond, so a   |
//| tie keeps the first bar). A bar that makes a new extreme         |
//| continues the swing; any other bar reaching extreme -/+ Z        |
//| confirms the pivot, and the opposite swing is tracked again over |
//| the bars after the pivot bar up to the detecting bar. No         |
//| reversal is detected while ATR14 is not ready.                   |
//| 2/2 fractals: strictly beyond the two bars on each side,         |
//| confirmed at the close of the second right bar (LSR swing rule). |
//+------------------------------------------------------------------+
#ifndef BTB_SWINGS_MQH
#define BTB_SWINGS_MQH

#include "BTB_Types.mqh"
#include "../TickResearchEngine/TRE_Bars.mqh"

#define BTB_PIVOT_HIGH  1
#define BTB_PIVOT_LOW  -1

struct BTB_Pivot
  {
   int               kind;     // BTB_PIVOT_HIGH / BTB_PIVOT_LOW
   double            price;
   int               bar;      // extreme bar (first on ties)
   int               conf;     // detecting bar; confirmation time = its close
  };

struct BTB_Fractal
  {
   double            price;
   int               bar;      // fractal bar c
   int               conf;     // c + 2
  };

//+------------------------------------------------------------------+
class CBTB_ZigZag
  {
private:
   double            m_mult;
   BTB_Pivot         m_piv[];
   int               m_n;
   TRE_Bar           m_bars[];
   int               m_nBars;
   int               m_dir;
   bool              m_haveExt;
   double            m_ext;
   int               m_extBar;

   void              Restart(const int direction, const int after, const int k)
     {
      m_dir = direction;
      m_haveExt = false;
      m_ext = 0.0;
      m_extBar = -1;
      for(int j = after + 1; j <= k; j++)
        {
         double v = (direction > 0 ? m_bars[j].high : m_bars[j].low);
         if(!m_haveExt || (direction > 0 ? v > m_ext : v < m_ext))
           {
            m_ext = v;
            m_extBar = j;
            m_haveExt = true;
           }
        }
     }

   int               AddPivot(const int kind, const double price, const int bar, const int conf)
     {
      if(m_n >= ArraySize(m_piv))
         ArrayResize(m_piv, m_n + 1, 1024);
      m_piv[m_n].kind = kind;
      m_piv[m_n].price = price;
      m_piv[m_n].bar = bar;
      m_piv[m_n].conf = conf;
      return m_n++;
     }

public:
                     CBTB_ZigZag(void) { m_mult = 1.0; m_n = 0; m_nBars = 0; m_dir = 0; m_haveExt = false; m_ext = 0.0; m_extBar = -1; }

   void              Init(const double mult)
     {
      m_mult = mult;
      m_n = 0;
      ArrayResize(m_piv, 0);
      m_nBars = 0;
      ArrayResize(m_bars, 0);
      m_dir = 0;
      m_haveExt = false;
      m_ext = 0.0;
      m_extBar = -1;
     }

   //--- Bar k = the number of bars fed so far. Returns the index of a new pivot, or -1.
   int               OnBar(const TRE_Bar &b, const bool atrReady, const double atr)
     {
      int k = m_nBars;
      if(m_nBars >= ArraySize(m_bars))
         ArrayResize(m_bars, m_nBars + 1, 4096);
      m_bars[m_nBars++] = b;
      if(k == 0)
         return -1;
      if(m_dir == 0)
        {
         if(!atrReady)
            return -1;
         double z = m_mult * atr;
         if(b.high >= m_bars[0].low + z)
           {
            int p = AddPivot(BTB_PIVOT_LOW, m_bars[0].low, 0, k);
            Restart(1, 0, k);
            return p;
           }
         if(b.low <= m_bars[0].high - z)
           {
            int p = AddPivot(BTB_PIVOT_HIGH, m_bars[0].high, 0, k);
            Restart(-1, 0, k);
            return p;
           }
         return -1;
        }
      if(m_dir > 0)
        {
         if(!m_haveExt || b.high > m_ext)
           {
            m_ext = b.high;                                   // new extreme: the swing continues
            m_extBar = k;
            m_haveExt = true;
           }
         else
            if(atrReady && b.low <= m_ext - m_mult * atr)
              {
               int p = AddPivot(BTB_PIVOT_HIGH, m_ext, m_extBar, k);
               Restart(-1, m_piv[p].bar, k);
               return p;
              }
        }
      else
        {
         if(!m_haveExt || b.low < m_ext)
           {
            m_ext = b.low;
            m_extBar = k;
            m_haveExt = true;
           }
         else
            if(atrReady && b.high >= m_ext + m_mult * atr)
              {
               int p = AddPivot(BTB_PIVOT_LOW, m_ext, m_extBar, k);
               Restart(1, m_piv[p].bar, k);
               return p;
              }
        }
      return -1;
     }

   int               Count(void) const { return m_n; }
   int               Kind(const int i) const { return m_piv[i].kind; }
   double            Price(const int i) const { return m_piv[i].price; }
   int               Bar(const int i) const { return m_piv[i].bar; }
   int               Conf(const int i) const { return m_piv[i].conf; }
   int               Dir(void) const { return m_dir; }
   double            Ext(void) const { return m_ext; }
   int               ExtBar(void) const { return m_extBar; }
  };

//+------------------------------------------------------------------+
class CBTB_Fractals
  {
private:
   TRE_Bar           m_bars[];
   int               m_nBars;
   BTB_Fractal       m_hi[];
   int               m_nHi;
   BTB_Fractal       m_lo[];
   int               m_nLo;

public:
                     CBTB_Fractals(void) { m_nBars = 0; m_nHi = 0; m_nLo = 0; }

   void              Init(void)
     {
      m_nBars = 0;
      ArrayResize(m_bars, 0);
      m_nHi = 0;
      ArrayResize(m_hi, 0);
      m_nLo = 0;
      ArrayResize(m_lo, 0);
     }

   void              OnBar(const TRE_Bar &b)
     {
      int k = m_nBars;
      if(m_nBars >= ArraySize(m_bars))
         ArrayResize(m_bars, m_nBars + 1, 4096);
      m_bars[m_nBars++] = b;
      int c = k - BTB_SWING_SIDE_BARS;
      if(c - BTB_SWING_SIDE_BARS < 0)
         return;
      bool isHigh = true, isLow = true;
      for(int j = c - BTB_SWING_SIDE_BARS; j <= c + BTB_SWING_SIDE_BARS; j++)
        {
         if(j == c)
            continue;
         if(!(m_bars[c].high > m_bars[j].high))
            isHigh = false;
         if(!(m_bars[c].low < m_bars[j].low))
            isLow = false;
        }
      if(isHigh)
        {
         if(m_nHi >= ArraySize(m_hi))
            ArrayResize(m_hi, m_nHi + 1, 1024);
         m_hi[m_nHi].price = m_bars[c].high;
         m_hi[m_nHi].bar = c;
         m_hi[m_nHi].conf = k;
         m_nHi++;
        }
      if(isLow)
        {
         if(m_nLo >= ArraySize(m_lo))
            ArrayResize(m_lo, m_nLo + 1, 1024);
         m_lo[m_nLo].price = m_bars[c].low;
         m_lo[m_nLo].bar = c;
         m_lo[m_nLo].conf = k;
         m_nLo++;
        }
     }

   //--- side > 0: highs; side < 0: lows
   int               Count(const int side) const { return side > 0 ? m_nHi : m_nLo; }
   double            Price(const int side, const int i) const { return side > 0 ? m_hi[i].price : m_lo[i].price; }
   int               Bar(const int side, const int i) const { return side > 0 ? m_hi[i].bar : m_lo[i].bar; }
   int               Conf(const int side, const int i) const { return side > 0 ? m_hi[i].conf : m_lo[i].conf; }
  };

#endif // BTB_SWINGS_MQH
//+------------------------------------------------------------------+
