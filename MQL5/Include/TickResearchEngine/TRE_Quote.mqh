//+------------------------------------------------------------------+
//| TRE_Quote.mqh                                                    |
//| Execution quote model (roadmap 0.4, 1.6).                        |
//| Open: Long=Ask, Short=Bid. Close: Long=Bid, Short=Ask.           |
//| No midpoint execution for P/L; MidPrice only for the named       |
//| RESEARCH_MID_STOP trigger.                                       |
//+------------------------------------------------------------------+
#ifndef TRE_QUOTE_MQH
#define TRE_QUOTE_MQH

#include "TRE_Types.mqh"

struct TRE_Quote
  {
   ulong             seq;        // source sequence number (tick order is preserved)
   long              time_msc;
   datetime          time;
   double            bid;
   double            ask;
   double            last;
   ulong             volume;
   uint              flags;
  };

void TRE_QuoteFromTick(const MqlTick &t, const ulong seq, TRE_Quote &q)
  {
   q.seq      = seq;
   q.time_msc = t.time_msc;
   q.time     = t.time;
   q.bid      = t.bid;
   q.ask      = t.ask;
   q.last     = t.last;
   q.volume   = t.volume;
   q.flags    = t.flags;
  }

double TRE_Spread(const TRE_Quote &q)   { return q.ask - q.bid; }
double TRE_MidPrice(const TRE_Quote &q) { return (q.bid + q.ask) / 2.0; }

//--- Usable = finite, positive prices and strictly positive spread.
bool TRE_QuoteIsUsable(const TRE_Quote &q)
  {
   if(!MathIsValidNumber(q.bid) || !MathIsValidNumber(q.ask))
      return false;
   return q.bid > 0.0 && q.ask > 0.0 && q.ask > q.bid;
  }

//--- Declared bar price source for all OHLC-derived logic (0B.16).
double TRE_SignalBarPrice(const TRE_Quote &q, const ENUM_TRE_PRICE_SOURCE src)
  {
   return src == TRE_PRICE_BID ? q.bid : q.last;
  }

double TRE_OpenQuote(const ENUM_TRE_DIRECTION dir, const TRE_Quote &q)
  {
   return dir == TRE_DIR_LONG ? q.ask : q.bid;
  }

double TRE_CloseQuote(const ENUM_TRE_DIRECTION dir, const TRE_Quote &q)
  {
   return dir == TRE_DIR_LONG ? q.bid : q.ask;
  }

//+------------------------------------------------------------------+
//| Stop trigger per execution profile (roadmap 0.4).                |
//| LIVE_NATIVE_STOP: Long Bid <= SL, Short Ask >= SL.               |
//| RESEARCH_MID_STOP: MidPrice crosses SL (sensitivity only).       |
//| The exit itself is always executed on Bid (long) / Ask (short).  |
//+------------------------------------------------------------------+
bool TRE_StopTriggered(const ENUM_TRE_STOP_PROFILE profile, const ENUM_TRE_DIRECTION dir,
                       const TRE_Quote &q, const double stopPrice)
  {
   double ref;
   if(profile == TRE_STOP_LIVE_NATIVE)
      ref = (dir == TRE_DIR_LONG ? q.bid : q.ask);
   else
      ref = TRE_MidPrice(q);
   return dir == TRE_DIR_LONG ? (ref <= stopPrice) : (ref >= stopPrice);
  }

#endif // TRE_QUOTE_MQH
//+------------------------------------------------------------------+
