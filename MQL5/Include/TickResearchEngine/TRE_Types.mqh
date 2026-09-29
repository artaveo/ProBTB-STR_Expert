//+------------------------------------------------------------------+
//| TRE_Types.mqh                                                    |
//| Liquidity Sweep Reversal — Phase 1 shared enums and constants.   |
//| Every value here is taken from Liquidity_Sweep_Reversal_Roadmap. |
//+------------------------------------------------------------------+
#ifndef TRE_TYPES_MQH
#define TRE_TYPES_MQH

#define TRE_ENGINE_NAME            "TickResearchEngine"
#define TRE_PHASE1_CONTRACT_ID     "TRE-PHASE1-CONTRACT-2026-09-28"
#define TRE_ROADMAP_FILENAME       "Liquidity_Sweep_Reversal_Roadmap.md"
#define TRE_SECONDS_PER_DAY        86400
#define TRE_EPS                    1e-9
#define TRE_MONEY_EPS              1e-8

//--- Frozen session constants (roadmap 1.3). Not inputs.
#define TRE_LATE_BLOCK_START_SEC   (21*3600+30*60)   // 21:30
#define TRE_NY_WINDOW_START_SEC    (16*3600+30*60)   // 16:30
#define TRE_NY_WINDOW_END_SEC      (21*3600+30*60)   // 21:30 (exclusive)

//--- Pre-registered data gates (roadmap 1.4). Not inputs.
#define TRE_MAX_FALLBACK_MINUTE_SHARE        0.01
#define TRE_CRITICAL_DATA_GAP_THRESHOLD_MIN  5
#define TRE_MAX_CRITICAL_DATA_GAP_COUNT      0

//--- Pre-registered stress values (roadmap 1.7). Not optimized.
#define TRE_SLIPPAGE_STRESS_POINTS_LIST      "1,2,5"
#define TRE_LATENCY_STRESS_MS_LIST           "100,250,500"

//--- Roadmap baseline commission rate (roadmap 1.7).
#define TRE_BASELINE_COMMISSION_RATE_PERCENT 0.0016

//+------------------------------------------------------------------+
//| Timeframes (roadmap 1.1). Enum order is the canonical order.     |
//+------------------------------------------------------------------+
enum ENUM_TRE_TIMEFRAME
  {
   TRE_TF_M1  = 0,
   TRE_TF_M5  = 1,
   TRE_TF_M15 = 2,
   TRE_TF_M30 = 3,
   TRE_TF_H1  = 4
  };
#define TRE_TF_COUNT 5

enum ENUM_TRE_RUN_CONTEXT
  {
   TRE_CONTEXT_RESEARCH = 0,   // Strategy Tester: every TimeframeSet member, isolated state
   TRE_CONTEXT_LIVE     = 1    // Live chart: exactly one fixed LiveTimeframe
  };

//+------------------------------------------------------------------+
//| Sessions (roadmap 1.3)                                           |
//+------------------------------------------------------------------+
enum ENUM_TRE_SESSION_MODE
  {
   TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD = 1, // Mode 1 — Full Day Except Late Spread Window
   TRE_SESSION_NY_WINDOW                   = 2, // Mode 2 — NY Window [16:30,21:30)
   TRE_SESSION_CUSTOM                      = 3  // Mode 3 — Custom [TradeStartTime,TradeEndTime)
  };

//+------------------------------------------------------------------+
//| Price source / execution profile (roadmap 0B.16, 0.4)            |
//+------------------------------------------------------------------+
enum ENUM_TRE_PRICE_SOURCE
  {
   TRE_PRICE_BID  = 0,  // BID (baseline)
   TRE_PRICE_LAST = 1   // LAST (distinct research study state)
  };

enum ENUM_TRE_STOP_PROFILE
  {
   TRE_STOP_LIVE_NATIVE  = 0, // LIVE_NATIVE_STOP (primary)
   TRE_STOP_RESEARCH_MID = 1  // RESEARCH_MID_STOP (sensitivity only)
  };

enum ENUM_TRE_DIRECTION
  {
   TRE_DIR_LONG  = 1,
   TRE_DIR_SHORT = -1
  };

//+------------------------------------------------------------------+
//| Costs (roadmap 1.7)                                              |
//+------------------------------------------------------------------+
enum ENUM_TRE_COMMISSION_MODE
  {
   TRE_COMMISSION_FUNDEDNEXT_OFFICIAL_METALS = 0 // FUNDEDNEXT_OFFICIAL_METALS
  };

enum ENUM_TRE_CONTRACT_SIZE_SOURCE
  {
   TRE_CONTRACT_SIZE_SYMBOL          = 0, // SYMBOL_TRADE_CONTRACT_SIZE
   TRE_CONTRACT_SIZE_BROKER_SCHEDULE = 1  // Frozen broker schedule value
  };

enum ENUM_TRE_COMMISSION_BASIS
  {
   TRE_COMMISSION_BASIS_OPEN_PRICE = 0 // OPEN_PRICE
  };

enum ENUM_TRE_COST_SCHEDULE_LABEL
  {
   TRE_COST_SCHEDULE_CURRENT_OFFICIAL = 0, // Current official schedule (not historical)
   TRE_COST_SCHEDULE_DATED_HISTORICAL = 1  // Dated historical schedule
  };

enum ENUM_TRE_SLIPPAGE_MODE
  {
   TRE_SLIPPAGE_NONE                 = 0, // NONE
   TRE_SLIPPAGE_FIXED_ADVERSE_POINTS = 1  // FIXED_ADVERSE_POINTS
  };

enum ENUM_TRE_LATENCY_MODE
  {
   TRE_LATENCY_ZERO     = 0, // ZERO
   TRE_LATENCY_FIXED_MS = 1  // FIXED_MS
  };

enum ENUM_TRE_COST_GATE_REASON
  {
   TRE_COST_GATE_PASS                 = 0,
   TRE_COST_GATE_SPREAD_TOO_WIDE      = 1,
   TRE_COST_GATE_NONSPREAD_COST_TOO_HIGH = 2,
   TRE_COST_GATE_INVALID_INPUT        = 3
  };

//+------------------------------------------------------------------+
//| Account rules (roadmap 0B.10)                                    |
//+------------------------------------------------------------------+
enum ENUM_TRE_ACCOUNT_RULE_PROFILE
  {
   TRE_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP = 0 // FUNDEDNEXT_STELLAR_2STEP
  };

enum ENUM_TRE_ACCOUNT_RULE_MODE
  {
   TRE_ACCOUNT_RULES_APPLY_OFFICIAL = 0 // APPLY_OFFICIAL_ACCOUNT_RULES
  };

enum ENUM_TRE_ACCOUNT_RULE_STATE
  {
   TRE_ACCOUNT_OK          = 0,
   TRE_ACCOUNT_NEAR_BREACH = 1,
   TRE_ACCOUNT_BREACH      = 2
  };

//+------------------------------------------------------------------+
//| Risk admission (roadmap 0B.9, 0C.9, 1.8–1.11)                    |
//+------------------------------------------------------------------+
enum ENUM_TRE_PROFIT_TARGET_BASIS
  {
   TRE_PROFIT_TARGET_NET_EQUITY = 0 // NET_EQUITY
  };

enum ENUM_TRE_ADMISSION_REASON
  {
   TRE_ADMIT_OK                            = 0,
   TRE_REJECT_INVALID_PROPOSAL             = 1,
   TRE_REJECT_ACCOUNT_RULE_BREACH          = 2,
   TRE_REJECT_ACCOUNT_RULE_NEAR_BREACH     = 3,
   TRE_REJECT_DAILY_PROFIT_TARGET_REACHED  = 4,
   TRE_REJECT_MAX_CONCURRENT_POSITIONS     = 5,
   TRE_REJECT_DIRECTIONAL_POSITION_CAP     = 6,
   TRE_REJECT_DAILY_LOSS_FLOOR             = 7,
   TRE_REJECT_AGGREGATE_RISK_CEILING       = 8,
   TRE_REJECT_DIRECTIONAL_RISK_CEILING     = 9
  };

enum ENUM_TRE_SIZING_REASON
  {
   TRE_SIZING_OK                        = 0,
   TRE_SIZING_INVALID_INPUT             = 1,
   TRE_SIZING_INVALID_STOP_SIDE         = 2,
   TRE_SIZING_ECONOMICS_UNAVAILABLE     = 3,
   TRE_SIZING_VOLUME_BELOW_MIN          = 4,
   TRE_SIZING_INSUFFICIENT_MARGIN       = 5,
   TRE_SIZING_SPEC_INCOMPLETE_MID_STOP  = 6
  };

//+------------------------------------------------------------------+
//| Data audit (roadmap 1.4)                                         |
//+------------------------------------------------------------------+
enum ENUM_TRE_MINUTE_CLASS
  {
   TRE_MINUTE_OK                        = 0,
   TRE_MINUTE_PFM_NO_TICKS_NO_BAR       = 1, // no-tick/sparse data
   TRE_MINUTE_PFM_NO_TICKS_WITH_BAR     = 2, // potential tester fallback
   TRE_MINUTE_PFM_RECONCILIATION_FAILED = 3  // raw ticks contradict the M1 bar
  };

enum ENUM_TRE_DATA_GATE
  {
   TRE_DATA_PASSED           = 0,
   TRE_DATA_FAILED           = 1,
   TRE_DATA_AUDIT_INCOMPLETE = 2
  };

//+------------------------------------------------------------------+
//| Enum → roadmap string                                            |
//+------------------------------------------------------------------+
string TRE_SessionModeName(const ENUM_TRE_SESSION_MODE m)
  {
   switch(m)
     {
      case TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD: return "FULL_DAY_EXCEPT_LATE_SPREAD_WINDOW";
      case TRE_SESSION_NY_WINDOW:                   return "NY_WINDOW";
      case TRE_SESSION_CUSTOM:                      return "CUSTOM";
     }
   return "UNKNOWN";
  }

string TRE_PriceSourceName(const ENUM_TRE_PRICE_SOURCE s)
  { return s == TRE_PRICE_BID ? "BID" : "LAST"; }

string TRE_StopProfileName(const ENUM_TRE_STOP_PROFILE p)
  { return p == TRE_STOP_LIVE_NATIVE ? "LIVE_NATIVE_STOP" : "RESEARCH_MID_STOP"; }

string TRE_DirectionName(const ENUM_TRE_DIRECTION d)
  { return d == TRE_DIR_LONG ? "LONG" : "SHORT"; }

string TRE_CommissionModeName(const ENUM_TRE_COMMISSION_MODE m)
  { return "FUNDEDNEXT_OFFICIAL_METALS"; }

string TRE_ContractSizeSourceName(const ENUM_TRE_CONTRACT_SIZE_SOURCE s)
  { return s == TRE_CONTRACT_SIZE_SYMBOL ? "SYMBOL_TRADE_CONTRACT_SIZE" : "BROKER_SCHEDULE"; }

string TRE_CommissionBasisName(const ENUM_TRE_COMMISSION_BASIS b)
  { return "OPEN_PRICE"; }

string TRE_CostScheduleLabelName(const ENUM_TRE_COST_SCHEDULE_LABEL l)
  { return l == TRE_COST_SCHEDULE_CURRENT_OFFICIAL ? "CURRENT_OFFICIAL_SCHEDULE" : "DATED_HISTORICAL_SCHEDULE"; }

string TRE_SlippageModeName(const ENUM_TRE_SLIPPAGE_MODE m)
  { return m == TRE_SLIPPAGE_NONE ? "NONE" : "FIXED_ADVERSE_POINTS"; }

string TRE_LatencyModeName(const ENUM_TRE_LATENCY_MODE m)
  { return m == TRE_LATENCY_ZERO ? "ZERO" : "FIXED_MS"; }

string TRE_AccountRuleProfileName(const ENUM_TRE_ACCOUNT_RULE_PROFILE p)
  { return "FUNDEDNEXT_STELLAR_2STEP"; }

string TRE_AccountRuleModeName(const ENUM_TRE_ACCOUNT_RULE_MODE m)
  { return "APPLY_OFFICIAL_ACCOUNT_RULES"; }

string TRE_AccountRuleStateName(const ENUM_TRE_ACCOUNT_RULE_STATE s)
  {
   switch(s)
     {
      case TRE_ACCOUNT_OK:          return "OK";
      case TRE_ACCOUNT_NEAR_BREACH: return "NEAR_BREACH";
      case TRE_ACCOUNT_BREACH:      return "BREACH";
     }
   return "UNKNOWN";
  }

string TRE_ProfitTargetBasisName(const ENUM_TRE_PROFIT_TARGET_BASIS b)
  { return "NET_EQUITY"; }

string TRE_RunContextName(const ENUM_TRE_RUN_CONTEXT c)
  { return c == TRE_CONTEXT_RESEARCH ? "RESEARCH_TESTER" : "LIVE"; }

string TRE_AdmissionReasonName(const ENUM_TRE_ADMISSION_REASON r)
  {
   switch(r)
     {
      case TRE_ADMIT_OK:                           return "ADMITTED";
      case TRE_REJECT_INVALID_PROPOSAL:            return "INVALID_PROPOSAL";
      case TRE_REJECT_ACCOUNT_RULE_BREACH:         return "ACCOUNT_RULE_BREACH";
      case TRE_REJECT_ACCOUNT_RULE_NEAR_BREACH:    return "ACCOUNT_RULE_NEAR_BREACH";
      case TRE_REJECT_DAILY_PROFIT_TARGET_REACHED: return "DAILY_PROFIT_TARGET_REACHED";
      case TRE_REJECT_MAX_CONCURRENT_POSITIONS:    return "MAX_CONCURRENT_POSITIONS";
      case TRE_REJECT_DIRECTIONAL_POSITION_CAP:    return "DIRECTIONAL_POSITION_CAP";
      case TRE_REJECT_DAILY_LOSS_FLOOR:            return "DAILY_LOSS_FLOOR";
      case TRE_REJECT_AGGREGATE_RISK_CEILING:      return "AGGREGATE_RISK_CEILING";
      case TRE_REJECT_DIRECTIONAL_RISK_CEILING:    return "DIRECTIONAL_RISK_CEILING";
     }
   return "UNKNOWN";
  }

string TRE_SizingReasonName(const ENUM_TRE_SIZING_REASON r)
  {
   switch(r)
     {
      case TRE_SIZING_OK:                       return "OK";
      case TRE_SIZING_INVALID_INPUT:            return "INVALID_INPUT";
      case TRE_SIZING_INVALID_STOP_SIDE:        return "INVALID_STOP_SIDE";
      case TRE_SIZING_ECONOMICS_UNAVAILABLE:    return "ECONOMICS_UNAVAILABLE";
      case TRE_SIZING_VOLUME_BELOW_MIN:         return "VOLUME_BELOW_MIN";
      case TRE_SIZING_INSUFFICIENT_MARGIN:      return "INSUFFICIENT_MARGIN";
      case TRE_SIZING_SPEC_INCOMPLETE_MID_STOP: return "SPEC_INCOMPLETE_RESEARCH_MID_STOP_BUFFER";
     }
   return "UNKNOWN";
  }

string TRE_CostGateReasonName(const ENUM_TRE_COST_GATE_REASON r)
  {
   switch(r)
     {
      case TRE_COST_GATE_PASS:                    return "PASS";
      case TRE_COST_GATE_SPREAD_TOO_WIDE:         return "ENTRY_SPREAD_TOO_WIDE";
      case TRE_COST_GATE_NONSPREAD_COST_TOO_HIGH: return "KNOWN_NONSPREAD_COST_TOO_HIGH";
      case TRE_COST_GATE_INVALID_INPUT:           return "INVALID_INPUT";
     }
   return "UNKNOWN";
  }

string TRE_MinuteClassName(const ENUM_TRE_MINUTE_CLASS c)
  {
   switch(c)
     {
      case TRE_MINUTE_OK:                        return "OK";
      case TRE_MINUTE_PFM_NO_TICKS_NO_BAR:       return "PFM_NO_TICKS_NO_BAR";
      case TRE_MINUTE_PFM_NO_TICKS_WITH_BAR:     return "PFM_NO_TICKS_WITH_BAR";
      case TRE_MINUTE_PFM_RECONCILIATION_FAILED: return "PFM_RECONCILIATION_FAILED";
     }
   return "UNKNOWN";
  }

string TRE_DataGateName(const ENUM_TRE_DATA_GATE g)
  {
   switch(g)
     {
      case TRE_DATA_PASSED:           return "DATA-PASSED";
      case TRE_DATA_FAILED:           return "DATA-FAILED";
      case TRE_DATA_AUDIT_INCOMPLETE: return "AUDIT-INCOMPLETE";
     }
   return "UNKNOWN";
  }

#endif // TRE_TYPES_MQH
//+------------------------------------------------------------------+
