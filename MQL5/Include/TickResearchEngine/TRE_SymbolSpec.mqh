//+------------------------------------------------------------------+
//| TRE_SymbolSpec.mqh                                               |
//| Symbol specification snapshot and strategy price units           |
//| (roadmap 0.3, 1.4 symbol items, 1.5, 4.4 tick alignment).        |
//+------------------------------------------------------------------+
#ifndef TRE_SYMBOLSPEC_MQH
#define TRE_SYMBOLSPEC_MQH

#include "TRE_Types.mqh"
#include "TRE_Json.mqh"

#define TRE_BASELINE_STRATEGY_PIP_SIZE 0.10

struct TRE_SymbolSpec
  {
   string            symbol;
   datetime          snapshot_time;
   int               digits;
   double            point;
   double            tick_size;
   double            tick_value;
   double            tick_value_profit;
   double            tick_value_loss;
   double            contract_size;
   double            volume_min;
   double            volume_max;
   double            volume_step;
   double            volume_limit;
   long              stops_level;
   long              freeze_level;
   long              trade_mode;
   long              trade_calc_mode;
   long              trade_exe_mode;
   long              filling_mode;
   long              order_mode;
   long              chart_mode;
   string            currency_base;
   string            currency_profit;
   string            currency_margin;
   long              swap_mode;
   double            swap_long;
   double            swap_short;
   long              swap_rollover3days;
   bool              spread_float;
   long              spread_current;
  };

bool TRE_CaptureSymbolSpec(const string symbol, const datetime snapshotTime, TRE_SymbolSpec &s, string &error)
  {
   error = "";
   if(!SymbolSelect(symbol, true))
     {
      error = "SymbolSelect failed for " + symbol;
      return false;
     }
   s.symbol             = symbol;
   s.snapshot_time      = snapshotTime;
   s.digits             = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   s.point              = SymbolInfoDouble(symbol, SYMBOL_POINT);
   s.tick_size          = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   s.tick_value         = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   s.tick_value_profit  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   s.tick_value_loss    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   s.contract_size      = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   s.volume_min         = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   s.volume_max         = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   s.volume_step        = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   s.volume_limit       = SymbolInfoDouble(symbol, SYMBOL_VOLUME_LIMIT);
   s.stops_level        = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   s.freeze_level       = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   s.trade_mode         = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   s.trade_calc_mode    = SymbolInfoInteger(symbol, SYMBOL_TRADE_CALC_MODE);
   s.trade_exe_mode     = SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE);
   s.filling_mode       = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   s.order_mode         = SymbolInfoInteger(symbol, SYMBOL_ORDER_MODE);
   s.chart_mode         = SymbolInfoInteger(symbol, SYMBOL_CHART_MODE);
   s.currency_base      = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   s.currency_profit    = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   s.currency_margin    = SymbolInfoString(symbol, SYMBOL_CURRENCY_MARGIN);
   s.swap_mode          = SymbolInfoInteger(symbol, SYMBOL_SWAP_MODE);
   s.swap_long          = SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG);
   s.swap_short         = SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT);
   s.swap_rollover3days = SymbolInfoInteger(symbol, SYMBOL_SWAP_ROLLOVER3DAYS);
   s.spread_float       = (bool)SymbolInfoInteger(symbol, SYMBOL_SPREAD_FLOAT);
   s.spread_current     = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   return true;
  }

bool TRE_ValidateSymbolSpec(const TRE_SymbolSpec &s, string &error)
  {
   error = "";
   if(s.point <= 0.0)          { error = "SYMBOL_POINT must be positive"; return false; }
   if(s.tick_size <= 0.0)      { error = "SYMBOL_TRADE_TICK_SIZE must be positive"; return false; }
   if(s.contract_size <= 0.0)  { error = "SYMBOL_TRADE_CONTRACT_SIZE must be positive"; return false; }
   if(s.volume_step <= 0.0)    { error = "SYMBOL_VOLUME_STEP must be positive"; return false; }
   if(s.volume_min <= 0.0)     { error = "SYMBOL_VOLUME_MIN must be positive"; return false; }
   if(s.volume_max < s.volume_min) { error = "SYMBOL_VOLUME_MAX is below SYMBOL_VOLUME_MIN"; return false; }
   if(s.stops_level < 0 || s.freeze_level < 0) { error = "negative stops/freeze level"; return false; }
   return true;
  }

void TRE_WriteSymbolSpecJson(CTRE_Json &j, const TRE_SymbolSpec &s)
  {
   j.BeginObject();
   j.KStr("symbol", s.symbol);
   j.KTime("snapshot_broker_time", s.snapshot_time);
   j.KInt("digits", s.digits);
   j.KNum("point", s.point, 12);
   j.KNum("tick_size", s.tick_size, 12);
   j.KNum("tick_value", s.tick_value, 10);
   j.KNum("tick_value_profit", s.tick_value_profit, 10);
   j.KNum("tick_value_loss", s.tick_value_loss, 10);
   j.KNum("contract_size", s.contract_size, 8);
   j.KNum("volume_min", s.volume_min, 8);
   j.KNum("volume_max", s.volume_max, 8);
   j.KNum("volume_step", s.volume_step, 8);
   j.KNum("volume_limit", s.volume_limit, 8);
   j.KInt("stops_level_points", s.stops_level);
   j.KInt("freeze_level_points", s.freeze_level);
   j.KInt("trade_mode", s.trade_mode);
   j.KInt("trade_calc_mode", s.trade_calc_mode);
   j.KInt("trade_exe_mode", s.trade_exe_mode);
   j.KInt("filling_mode", s.filling_mode);
   j.KInt("order_mode", s.order_mode);
   j.KInt("chart_mode", s.chart_mode);
   j.KStr("currency_base", s.currency_base);
   j.KStr("currency_profit", s.currency_profit);
   j.KStr("currency_margin", s.currency_margin);
   j.KInt("swap_mode", s.swap_mode);
   j.KNum("swap_long", s.swap_long, 8);
   j.KNum("swap_short", s.swap_short, 8);
   j.KInt("swap_rollover3days", s.swap_rollover3days);
   j.KBool("spread_float", s.spread_float);
   j.KInt("spread_current_points", s.spread_current);
   j.EndObject();
  }

//+------------------------------------------------------------------+
//| Strategy price units. The strategy pip is an explicit input and  |
//| never inferred from SYMBOL_POINT (roadmap 0.3, 1.5). All distance|
//| logic is stored in raw price units; pips/points/ticks are views. |
//+------------------------------------------------------------------+
class CTRE_PriceUnits
  {
private:
   double            m_pip;
   double            m_point;
   double            m_tick;

public:
                     CTRE_PriceUnits(void) { m_pip = TRE_BASELINE_STRATEGY_PIP_SIZE; m_point = 0.0; m_tick = 0.0; }

   bool              Init(const double strategyPipSize, const double point, const double tickSize, string &error)
     {
      error = "";
      if(!(strategyPipSize > 0.0) || !(point > 0.0) || !(tickSize > 0.0))
        {
         error = "StrategyPipSize, SYMBOL_POINT and SYMBOL_TRADE_TICK_SIZE must all be positive";
         return false;
        }
      m_pip = strategyPipSize;
      m_point = point;
      m_tick = tickSize;
      return true;
     }

   double            PipSize(void) const   { return m_pip; }
   double            Point(void) const     { return m_point; }
   double            TickSize(void) const  { return m_tick; }

   double            ToPips(const double priceDistance) const   { return priceDistance / m_pip; }
   double            ToPoints(const double priceDistance) const { return priceDistance / m_point; }
   double            ToTicks(const double priceDistance) const  { return priceDistance / m_tick; }
   double            PipsToPrice(const double pips) const       { return pips * m_pip; }
   double            PointsToPrice(const double points) const   { return points * m_point; }

   void              WriteDistanceJson(CTRE_Json &j, const double priceDistance) const
     {
      j.BeginObject();
      j.KNum("raw_price", priceDistance, 10);
      j.KNum("strategy_pips", ToPips(priceDistance), 6);
      j.KNum("symbol_points", ToPoints(priceDistance), 6);
      j.KNum("ticks", ToTicks(priceDistance), 6);
      j.EndObject();
     }
  };

//+------------------------------------------------------------------+
//| Tick-size alignment (roadmap 4.4): prices are checked, never     |
//| silently rounded by the contract layer.                          |
//+------------------------------------------------------------------+
bool TRE_IsTickAligned(const double price, const double tickSize)
  {
   if(tickSize <= 0.0)
      return false;
   double q = price / tickSize;
   return MathAbs(q - MathRound(q)) <= 1e-6;
  }

//+------------------------------------------------------------------+
//| Minimum stop distance (SYMBOL_TRADE_STOPS_LEVEL) check.          |
//+------------------------------------------------------------------+
bool TRE_IsStopDistanceLegal(const TRE_SymbolSpec &s, const double referencePrice, const double stopPrice)
  {
   double minDist = (double)s.stops_level * s.point;
   return MathAbs(referencePrice - stopPrice) + TRE_EPS >= minDist;
  }

#endif // TRE_SYMBOLSPEC_MQH
//+------------------------------------------------------------------+
