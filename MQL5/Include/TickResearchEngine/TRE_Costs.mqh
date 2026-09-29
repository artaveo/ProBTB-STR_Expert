//+------------------------------------------------------------------+
//| TRE_Costs.mqh                                                    |
//| Commission, slippage, latency and the entry spread/cost gate     |
//| (roadmap 1.7, 0B.22, 0C.9 execution buffer).                     |
//+------------------------------------------------------------------+
#ifndef TRE_COSTS_MQH
#define TRE_COSTS_MQH

#include "TRE_Types.mqh"
#include "TRE_Json.mqh"
#include "TRE_Quote.mqh"
#include "TRE_SymbolSpec.mqh"

struct TRE_CostModel
  {
   ENUM_TRE_COMMISSION_MODE      commission_mode;
   double                        commission_rate_percent;     // 0.0016 means 0.0016 %
   ENUM_TRE_CONTRACT_SIZE_SOURCE contract_size_source;
   double                        schedule_contract_size;      // used only with BROKER_SCHEDULE
   ENUM_TRE_COMMISSION_BASIS     commission_basis;
   ENUM_TRE_COST_SCHEDULE_LABEL  schedule_label;
   string                        schedule_date;               // YYYY-MM-DD of the frozen schedule
   ENUM_TRE_SLIPPAGE_MODE        slippage_mode;
   int                           entry_slippage_points;
   int                           exit_slippage_points;
   ENUM_TRE_LATENCY_MODE         latency_mode;
   int                           fixed_execution_delay_ms;
   bool                          max_entry_spread_enabled;
   double                        max_entry_spread_strategy_pips;
   double                        max_entry_known_nonspread_cost_r;
  };

void TRE_CostModelDefaults(TRE_CostModel &m)
  {
   m.commission_mode                  = TRE_COMMISSION_FUNDEDNEXT_OFFICIAL_METALS;
   m.commission_rate_percent          = TRE_BASELINE_COMMISSION_RATE_PERCENT;
   m.contract_size_source             = TRE_CONTRACT_SIZE_SYMBOL;
   m.schedule_contract_size           = 0.0;
   m.commission_basis                 = TRE_COMMISSION_BASIS_OPEN_PRICE;
   m.schedule_label                   = TRE_COST_SCHEDULE_CURRENT_OFFICIAL;
   m.schedule_date                    = "2026-09-28";
   m.slippage_mode                    = TRE_SLIPPAGE_NONE;
   m.entry_slippage_points            = 0;
   m.exit_slippage_points             = 0;
   m.latency_mode                     = TRE_LATENCY_ZERO;
   m.fixed_execution_delay_ms         = 0;
   m.max_entry_spread_enabled         = true;
   m.max_entry_spread_strategy_pips   = 3.0;
   m.max_entry_known_nonspread_cost_r = 0.10;
  }

bool TRE_IsPreRegisteredSlippage(const int points)
  {
   return points == 0 || points == 1 || points == 2 || points == 5;
  }

bool TRE_IsPreRegisteredLatency(const int ms)
  {
   return ms == 100 || ms == 250 || ms == 500;
  }

//+------------------------------------------------------------------+
//| Only roadmap-declared stress values are accepted (1.7).          |
//+------------------------------------------------------------------+
bool TRE_ValidateCostModel(const TRE_CostModel &m, string &error)
  {
   error = "";
   if(!(m.commission_rate_percent > 0.0))
     {
      error = "CommissionRatePercent must be positive";
      return false;
     }
   if(m.contract_size_source == TRE_CONTRACT_SIZE_BROKER_SCHEDULE && !(m.schedule_contract_size > 0.0))
     {
      error = "CommissionScheduleContractSize must be positive when CommissionContractSizeSource = BROKER_SCHEDULE";
      return false;
     }
   if(StringLen(m.schedule_date) != 10)
     {
      error = "CostScheduleDate must be YYYY-MM-DD";
      return false;
     }
   if(m.slippage_mode == TRE_SLIPPAGE_NONE)
     {
      if(m.entry_slippage_points != 0 || m.exit_slippage_points != 0)
        {
         error = "SlippageMode NONE requires EntrySlippagePoints = ExitSlippagePoints = 0";
         return false;
        }
     }
   else
     {
      if(!TRE_IsPreRegisteredSlippage(m.entry_slippage_points) || !TRE_IsPreRegisteredSlippage(m.exit_slippage_points))
        {
         error = "slippage stress points must be one of the pre-registered values 1, 2, 5 (or 0 for an unstressed leg)";
         return false;
        }
      if(m.entry_slippage_points == 0 && m.exit_slippage_points == 0)
        {
         error = "SlippageMode FIXED_ADVERSE_POINTS requires a non-zero Entry or Exit slippage";
         return false;
        }
     }
   if(m.latency_mode == TRE_LATENCY_ZERO)
     {
      if(m.fixed_execution_delay_ms != 0)
        {
         error = "LatencyMode ZERO requires FixedExecutionDelayMs = 0";
         return false;
        }
     }
   else
      if(!TRE_IsPreRegisteredLatency(m.fixed_execution_delay_ms))
        {
         error = "FixedExecutionDelayMs must be one of the pre-registered values 100, 250, 500";
         return false;
        }
   if(!(m.max_entry_spread_strategy_pips > 0.0))
     {
      error = "MaxEntrySpreadStrategyPips must be positive";
      return false;
     }
   if(!(m.max_entry_known_nonspread_cost_r >= 0.0))
     {
      error = "MaxEntryKnownNonSpreadCostR must be non-negative";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Commission (FUNDEDNEXT_OFFICIAL_METALS):                         |
//| VolumeLots × ContractSize × OpeningPrice × Rate%, charged once on|
//| the opening transaction. Stored unrounded.                       |
//+------------------------------------------------------------------+
double TRE_CommissionContractSize(const TRE_CostModel &m, const TRE_SymbolSpec &s)
  {
   return m.contract_size_source == TRE_CONTRACT_SIZE_SYMBOL ? s.contract_size : m.schedule_contract_size;
  }

double TRE_CommissionCurrency(const TRE_CostModel &m, const double volumeLots,
                              const double contractSize, const double openingPrice)
  {
   return volumeLots * contractSize * openingPrice * (m.commission_rate_percent / 100.0);
  }

//+------------------------------------------------------------------+
//| Slippage — deterministic adverse direction.                      |
//| Long entry Ask+E, Short entry Bid−E, Long exit Bid−X, Short exit |
//| Ask+X (points × SYMBOL_POINT).                                   |
//+------------------------------------------------------------------+
double TRE_AdverseEntryPrice(const TRE_CostModel &m, const ENUM_TRE_DIRECTION dir,
                             const TRE_Quote &q, const double point)
  {
   double slip = (m.slippage_mode == TRE_SLIPPAGE_FIXED_ADVERSE_POINTS ? m.entry_slippage_points * point : 0.0);
   return dir == TRE_DIR_LONG ? q.ask + slip : q.bid - slip;
  }

double TRE_AdverseExitPrice(const TRE_CostModel &m, const ENUM_TRE_DIRECTION dir,
                            const TRE_Quote &q, const double point)
  {
   double slip = (m.slippage_mode == TRE_SLIPPAGE_FIXED_ADVERSE_POINTS ? m.exit_slippage_points * point : 0.0);
   return dir == TRE_DIR_LONG ? q.bid - slip : q.ask + slip;
  }

//+------------------------------------------------------------------+
//| DeclaredRiskExecutionBufferPoints (0C.9):                        |
//| max(Entry, Exit) when a non-zero fixed-adverse stress is active, |
//| otherwise 0.                                                     |
//+------------------------------------------------------------------+
int TRE_DeclaredRiskExecutionBufferPoints(const TRE_CostModel &m)
  {
   if(m.slippage_mode != TRE_SLIPPAGE_FIXED_ADVERSE_POINTS)
      return 0;
   return (int)MathMax(m.entry_slippage_points, m.exit_slippage_points);
  }

//+------------------------------------------------------------------+
//| Latency: execution uses the first executable tick at or after    |
//| decision time + FixedExecutionDelayMs (0 for ZERO).              |
//+------------------------------------------------------------------+
long TRE_EarliestExecutionMsc(const TRE_CostModel &m, const long decisionMsc)
  {
   return decisionMsc + (m.latency_mode == TRE_LATENCY_FIXED_MS ? (long)m.fixed_execution_delay_ms : 0);
  }

//+------------------------------------------------------------------+
//| Entry spread / cost admission gate (1.7). Violation = value      |
//| strictly above the frozen maximum. Rejected candidates stay in   |
//| the ledger with this reason.                                     |
//+------------------------------------------------------------------+
struct TRE_CostGateResult
  {
   bool                      passed;
   ENUM_TRE_COST_GATE_REASON reason;
   double                    spread_price;
   double                    spread_strategy_pips;
   double                    known_nonspread_cost_currency;
   double                    known_nonspread_cost_r;
  };

void TRE_EvaluateEntryCostGate(const TRE_CostModel &m, const double spreadPrice, const double strategyPipSize,
                               const double knownNonSpreadCostCurrency, const double plannedRisk1RCurrency,
                               TRE_CostGateResult &r)
  {
   r.passed = false;
   r.reason = TRE_COST_GATE_INVALID_INPUT;
   r.spread_price = spreadPrice;
   r.spread_strategy_pips = (strategyPipSize > 0.0 ? spreadPrice / strategyPipSize : EMPTY_VALUE);
   r.known_nonspread_cost_currency = knownNonSpreadCostCurrency;
   r.known_nonspread_cost_r = (plannedRisk1RCurrency > 0.0 ? knownNonSpreadCostCurrency / plannedRisk1RCurrency : EMPTY_VALUE);

   if(!(strategyPipSize > 0.0) || !(plannedRisk1RCurrency > 0.0) || !(spreadPrice > 0.0) || knownNonSpreadCostCurrency < 0.0)
      return;

   if(m.max_entry_spread_enabled && r.spread_strategy_pips > m.max_entry_spread_strategy_pips + TRE_EPS)
     {
      r.reason = TRE_COST_GATE_SPREAD_TOO_WIDE;
      return;
     }
   if(r.known_nonspread_cost_r > m.max_entry_known_nonspread_cost_r + TRE_EPS)
     {
      r.reason = TRE_COST_GATE_NONSPREAD_COST_TOO_HIGH;
      return;
     }
   r.passed = true;
   r.reason = TRE_COST_GATE_PASS;
  }

//+------------------------------------------------------------------+
//| Cost/execution contract snapshot for the run package.            |
//+------------------------------------------------------------------+
void TRE_WriteCostModelJson(CTRE_Json &j, const TRE_CostModel &m, const double resolvedContractSize,
                            const ENUM_TRE_STOP_PROFILE stopProfile, const ENUM_TRE_PRICE_SOURCE priceSource,
                            const double strategyPipSize)
  {
   j.BeginObject();
   j.KStr("contract_id", TRE_PHASE1_CONTRACT_ID);
   j.KObj("quote_model");
   j.KStr("signal_bar_price_source", TRE_PriceSourceName(priceSource));
   j.KStr("open_long", "ASK");
   j.KStr("open_short", "BID");
   j.KStr("close_long", "BID");
   j.KStr("close_short", "ASK");
   j.KStr("spread", "ASK - BID of the same event tick");
   j.KBool("midpoint_execution_for_pnl", false);
   j.EndObject();
   j.KObj("stop_execution");
   j.KStr("profile", TRE_StopProfileName(stopProfile));
   j.KStr("long_trigger", stopProfile == TRE_STOP_LIVE_NATIVE ? "BID <= SL" : "MID <= SL (sensitivity only)");
   j.KStr("short_trigger", stopProfile == TRE_STOP_LIVE_NATIVE ? "ASK >= SL" : "MID >= SL (sensitivity only)");
   j.KStr("long_exit", "BID");
   j.KStr("short_exit", "ASK");
   j.EndObject();
   j.KNum("strategy_pip_size", strategyPipSize, 8);
   j.KObj("commission");
   j.KStr("mode", TRE_CommissionModeName(m.commission_mode));
   j.KStr("formula", "VolumeLots * ContractSize * OpeningPrice * CommissionRatePercent / 100, once on the opening transaction");
   j.KNum("rate_percent", m.commission_rate_percent, 8);
   j.KStr("contract_size_source", TRE_ContractSizeSourceName(m.contract_size_source));
   j.KNum("contract_size", resolvedContractSize, 8);
   j.KStr("pricing_basis", TRE_CommissionBasisName(m.commission_basis));
   j.KStr("schedule_label", TRE_CostScheduleLabelName(m.schedule_label));
   j.KStr("schedule_date", m.schedule_date);
   j.KStr("rounding", "none (stored unrounded)");
   j.EndObject();
   j.KObj("slippage");
   j.KStr("mode", TRE_SlippageModeName(m.slippage_mode));
   j.KInt("entry_points", m.entry_slippage_points);
   j.KInt("exit_points", m.exit_slippage_points);
   j.KStr("direction", "Long entry Ask+E; Short entry Bid-E; Long exit Bid-X; Short exit Ask+X");
   j.KStr("pre_registered_stress_points", TRE_SLIPPAGE_STRESS_POINTS_LIST);
   j.KInt("declared_risk_execution_buffer_points", TRE_DeclaredRiskExecutionBufferPoints(m));
   j.EndObject();
   j.KObj("latency");
   j.KStr("mode", TRE_LatencyModeName(m.latency_mode));
   j.KInt("fixed_execution_delay_ms", m.fixed_execution_delay_ms);
   j.KStr("rule", "execute on the first executable tick at or after decision time + delay");
   j.KStr("pre_registered_stress_ms", TRE_LATENCY_STRESS_MS_LIST);
   j.EndObject();
   j.KObj("swap");
   j.KStr("rule", "recorded from actual deal/position swap when it occurs; never forecast at entry");
   j.EndObject();
   j.KObj("entry_cost_gate");
   j.KBool("max_entry_spread_enabled", m.max_entry_spread_enabled);
   j.KNum("max_entry_spread_strategy_pips", m.max_entry_spread_strategy_pips, 6);
   j.KNum("max_entry_known_nonspread_cost_r", m.max_entry_known_nonspread_cost_r, 6);
   j.KStr("violation", "observed value strictly greater than the frozen maximum");
   j.EndObject();
   j.KArr("cost_attribution_components");
   j.Str("entry_spread");
   j.Str("exit_spread");
   j.Str("commission");
   j.Str("swap");
   j.Str("slippage");
   j.Str("gap_deviation");
   j.EndArray();
   j.EndObject();
  }

#endif // TRE_COSTS_MQH
//+------------------------------------------------------------------+
