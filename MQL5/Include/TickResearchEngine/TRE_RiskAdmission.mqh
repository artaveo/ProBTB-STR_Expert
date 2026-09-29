//+------------------------------------------------------------------+
//| TRE_RiskAdmission.mqh                                            |
//| Canonical daily-risk admission (roadmap 0B.9, 0C.9, 1.9–1.11).   |
//|                                                                  |
//| DayRiskUnitCurrency = StartOfBrokerDayEquity × RiskPerTrade%     |
//| DailyLossFloor      = StartOfBrokerDayEquity − MaxDailyLossR×Unit|
//| ProjectedWorstCaseEquity = CurrentEquity − Σ IncrementalOpenLoss |
//|                            − NewTradeWorstCaseLoss               |
//| Admission needs every internal gate AND the external             |
//| AccountRuleEngine; the two budgets are never merged.             |
//| The daily guard blocks new risk only; it never force-closes.     |
//+------------------------------------------------------------------+
#ifndef TRE_RISKADMISSION_MQH
#define TRE_RISKADMISSION_MQH

#include "TRE_Types.mqh"
#include "TRE_Json.mqh"
#include "TRE_BrokerTime.mqh"
#include "TRE_AccountRules.mqh"

struct TRE_RiskConfig
  {
   double                       risk_per_trade_percent;
   bool                         daily_loss_guard_enabled;
   double                       max_daily_loss_r;
   int                          max_concurrent_positions;
   double                       max_aggregate_open_worst_case_risk_r;
   double                       max_directional_open_worst_case_risk_r;
   bool                         directional_position_cap_enabled;
   int                          max_directional_positions;
   bool                         max_total_drawdown_enabled;
   double                       max_total_drawdown_r;
   bool                         max_consecutive_loss_guard_enabled;
   int                          max_consecutive_losses;
   bool                         daily_profit_target_enabled;
   double                       daily_profit_target_r;
   ENUM_TRE_PROFIT_TARGET_BASIS profit_target_basis;
  };

void TRE_RiskConfigDefaults(TRE_RiskConfig &c)
  {
   c.risk_per_trade_percent                 = 0.50;
   c.daily_loss_guard_enabled               = true;
   c.max_daily_loss_r                       = 3.0;
   c.max_concurrent_positions               = 3;
   c.max_aggregate_open_worst_case_risk_r   = 3.0;
   c.max_directional_open_worst_case_risk_r = 2.0;
   c.directional_position_cap_enabled       = false;
   c.max_directional_positions              = 3;
   c.max_total_drawdown_enabled             = false;
   c.max_total_drawdown_r                   = 0.0;
   c.max_consecutive_loss_guard_enabled     = false;
   c.max_consecutive_losses                 = 0;
   c.daily_profit_target_enabled            = false;
   c.daily_profit_target_r                  = 9.0;
   c.profit_target_basis                    = TRE_PROFIT_TARGET_NET_EQUITY;
  }

bool TRE_ValidateRiskConfig(const TRE_RiskConfig &c, string &error)
  {
   error = "";
   if(!(c.risk_per_trade_percent > 0.0) || c.risk_per_trade_percent > 100.0)
     { error = "RiskPerTradePercent must be in (0, 100]"; return false; }
   if(!(c.max_daily_loss_r > 0.0))
     { error = "MaxDailyLossR must be positive"; return false; }
   if(c.max_concurrent_positions < 1)
     { error = "MaxConcurrentPositions must be >= 1"; return false; }
   if(!(c.max_aggregate_open_worst_case_risk_r > 0.0) || !(c.max_directional_open_worst_case_risk_r > 0.0))
     { error = "aggregate/directional worst-case risk ceilings must be positive"; return false; }
   if(c.directional_position_cap_enabled && c.max_directional_positions < 1)
     { error = "MaxDirectionalPositions must be >= 1 when enabled"; return false; }
   if(c.daily_profit_target_enabled && !(c.daily_profit_target_r > 0.0))
     { error = "DailyProfitTargetR must be positive when enabled"; return false; }
   // Roadmap 1.10/5.6 declare these inputs but not their formulas (peak basis,
   // R basis, streak reset). Enabling them is SPEC-INCOMPLETE until Phase 5 (0B.13).
   if(c.max_total_drawdown_enabled)
     { error = "MaxTotalDrawdownEnabled: formula not yet specified (SPEC-INCOMPLETE, roadmap 0B.13); keep OFF"; return false; }
   if(c.max_consecutive_loss_guard_enabled)
     { error = "MaxConsecutiveLossGuardEnabled: formula not yet specified (SPEC-INCOMPLETE, roadmap 0B.13); keep OFF"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Start-of-broker-day equity basis for one isolated context.       |
//+------------------------------------------------------------------+
class CTRE_DailyRiskState
  {
private:
   CTRE_BrokerDayClock m_clock;
   double            m_startEquity;
   double            m_dayRiskUnit;

public:
                     CTRE_DailyRiskState(void) { m_startEquity = 0.0; m_dayRiskUnit = 0.0; }

   //--- Call on every processed tick with the context's current equity.
   bool              Observe(const datetime t, const double equity, const double riskPerTradePercent)
     {
      if(!m_clock.Observe(t))
         return false;
      m_startEquity = equity;
      m_dayRiskUnit = equity * riskPerTradePercent / 100.0;
      return true;
     }

   double            StartOfDayEquity(void) const { return m_startEquity; }
   double            DayRiskUnit(void) const      { return m_dayRiskUnit; }
   datetime          Day(void) const              { return m_clock.Day(); }
   datetime          ResetTimestamp(void) const   { return m_clock.ResetTimestamp(); }
   int               ResetCount(void) const       { return m_clock.ResetCount(); }
   double            DailyLossFloor(const double maxDailyLossR) const
     {
      return m_startEquity - maxDailyLossR * m_dayRiskUnit;
     }
  };

//+------------------------------------------------------------------+
//| Open trade worst case: loss from the current executable exit     |
//| quote to its currently valid stop, plus the declared buffer.     |
//| The path part is clamped at 0 (a quote already beyond the stop   |
//| adds no further path loss). Caller computes it with symbol       |
//| economics; the original risk is never subtracted a second time.  |
//+------------------------------------------------------------------+
struct TRE_OpenRiskItem
  {
   ENUM_TRE_DIRECTION dir;
   double             incremental_worst_case_loss;
  };

struct TRE_AdmissionProposal
  {
   ENUM_TRE_DIRECTION dir;
   double             new_trade_worst_case_loss;   // from TRE_SizePosition (incl. buffer + known costs)
  };

struct TRE_AdmissionTrace
  {
   bool                        admitted;
   ENUM_TRE_ADMISSION_REASON   final_reason;
   double                      day_risk_unit;
   double                      start_of_day_equity;
   double                      current_equity;
   double                      open_incremental_loss;
   double                      open_directional_incremental_loss;
   double                      projected_worst_case_equity;
   double                      daily_loss_floor;
   double                      aggregate_r_after;
   double                      directional_r_after;
   double                      net_daily_pnl_r;
   int                         open_positions;
   int                         open_directional_positions;
   bool                        account_rule_ok;
   ENUM_TRE_ACCOUNT_RULE_STATE account_rule_state;
   bool                        profit_target_ok;
   bool                        concurrent_ok;
   bool                        directional_cap_ok;
   bool                        daily_floor_ok;
   bool                        aggregate_ok;
   bool                        directional_risk_ok;
  };

//+------------------------------------------------------------------+
//| Evaluates every gate (full trace), then picks the first failure  |
//| in fixed precedence: external account rules first, then         |
//| profit target, concurrency, directional cap, daily floor,        |
//| aggregate ceiling, directional ceiling.                          |
//+------------------------------------------------------------------+
bool TRE_EvaluateAdmission(const TRE_RiskConfig &cfg,
                           const double startOfDayEquity, const double dayRiskUnit,
                           const double currentEquity,
                           const TRE_OpenRiskItem &open[],
                           const TRE_AdmissionProposal &prop,
                           const CTRE_AccountRuleEngine &acct,
                           const TRE_AccountRuleInputs &acctIn,
                           TRE_AdmissionTrace &tr)
  {
   tr.admitted = false;
   tr.final_reason = TRE_REJECT_INVALID_PROPOSAL;
   tr.day_risk_unit = dayRiskUnit;
   tr.start_of_day_equity = startOfDayEquity;
   tr.current_equity = currentEquity;
   tr.open_incremental_loss = 0.0;
   tr.open_directional_incremental_loss = 0.0;
   tr.open_positions = ArraySize(open);
   tr.open_directional_positions = 0;

   for(int i = 0; i < tr.open_positions; i++)
     {
      double l = MathMax(0.0, open[i].incremental_worst_case_loss);
      tr.open_incremental_loss += l;
      if(open[i].dir == prop.dir)
        {
         tr.open_directional_incremental_loss += l;
         tr.open_directional_positions++;
        }
     }

   tr.daily_loss_floor = startOfDayEquity - cfg.max_daily_loss_r * dayRiskUnit;
   tr.projected_worst_case_equity = currentEquity - tr.open_incremental_loss - prop.new_trade_worst_case_loss;
   tr.aggregate_r_after = (dayRiskUnit > 0.0 ? (tr.open_incremental_loss + prop.new_trade_worst_case_loss) / dayRiskUnit : EMPTY_VALUE);
   tr.directional_r_after = (dayRiskUnit > 0.0 ? (tr.open_directional_incremental_loss + prop.new_trade_worst_case_loss) / dayRiskUnit : EMPTY_VALUE);
   tr.net_daily_pnl_r = (dayRiskUnit > 0.0 ? (currentEquity - startOfDayEquity) / dayRiskUnit : EMPTY_VALUE);

   TRE_AccountRuleEval ae;
   acct.Evaluate(acctIn, tr.open_incremental_loss + MathMax(0.0, prop.new_trade_worst_case_loss), ae);
   tr.account_rule_state = ae.state;
   tr.account_rule_ok = (ae.state == TRE_ACCOUNT_OK);

   tr.profit_target_ok = true;
   tr.concurrent_ok = true;
   tr.directional_cap_ok = true;
   tr.daily_floor_ok = true;
   tr.aggregate_ok = true;
   tr.directional_risk_ok = true;

   if(!(dayRiskUnit > 0.0) || !(prop.new_trade_worst_case_loss > 0.0))
      return false;

   if(cfg.daily_profit_target_enabled)
      tr.profit_target_ok = (currentEquity - startOfDayEquity) < cfg.daily_profit_target_r * dayRiskUnit - TRE_MONEY_EPS;
   tr.concurrent_ok = tr.open_positions < cfg.max_concurrent_positions;
   if(cfg.directional_position_cap_enabled)
      tr.directional_cap_ok = tr.open_directional_positions < cfg.max_directional_positions;
   if(cfg.daily_loss_guard_enabled)
      tr.daily_floor_ok = tr.projected_worst_case_equity + TRE_MONEY_EPS >= tr.daily_loss_floor;
   tr.aggregate_ok = tr.aggregate_r_after <= cfg.max_aggregate_open_worst_case_risk_r + TRE_EPS;
   tr.directional_risk_ok = tr.directional_r_after <= cfg.max_directional_open_worst_case_risk_r + TRE_EPS;

   if(ae.state == TRE_ACCOUNT_BREACH)
      tr.final_reason = TRE_REJECT_ACCOUNT_RULE_BREACH;
   else
      if(ae.state == TRE_ACCOUNT_NEAR_BREACH)
         tr.final_reason = TRE_REJECT_ACCOUNT_RULE_NEAR_BREACH;
      else
         if(!tr.profit_target_ok)
            tr.final_reason = TRE_REJECT_DAILY_PROFIT_TARGET_REACHED;
         else
            if(!tr.concurrent_ok)
               tr.final_reason = TRE_REJECT_MAX_CONCURRENT_POSITIONS;
            else
               if(!tr.directional_cap_ok)
                  tr.final_reason = TRE_REJECT_DIRECTIONAL_POSITION_CAP;
               else
                  if(!tr.daily_floor_ok)
                     tr.final_reason = TRE_REJECT_DAILY_LOSS_FLOOR;
                  else
                     if(!tr.aggregate_ok)
                        tr.final_reason = TRE_REJECT_AGGREGATE_RISK_CEILING;
                     else
                        if(!tr.directional_risk_ok)
                           tr.final_reason = TRE_REJECT_DIRECTIONAL_RISK_CEILING;
                        else
                          {
                           tr.final_reason = TRE_ADMIT_OK;
                           tr.admitted = true;
                          }
   return tr.admitted;
  }

void TRE_WriteRiskConfigJson(CTRE_Json &j, const TRE_RiskConfig &c)
  {
   j.BeginObject();
   j.KNum("risk_per_trade_percent", c.risk_per_trade_percent, 6);
   j.KStr("risk_basis", "START_OF_BROKER_DAY_EQUITY");
   j.KBool("daily_loss_guard_enabled", c.daily_loss_guard_enabled);
   j.KNum("max_daily_loss_r", c.max_daily_loss_r, 6);
   j.KInt("max_concurrent_positions", c.max_concurrent_positions);
   j.KNum("max_aggregate_open_worst_case_risk_r", c.max_aggregate_open_worst_case_risk_r, 6);
   j.KNum("max_directional_open_worst_case_risk_r", c.max_directional_open_worst_case_risk_r, 6);
   j.KBool("directional_position_cap_enabled", c.directional_position_cap_enabled);
   j.KInt("max_directional_positions", c.max_directional_positions);
   j.KBool("max_total_drawdown_enabled", c.max_total_drawdown_enabled);
   j.KNum("max_total_drawdown_r", c.max_total_drawdown_r, 6);
   j.KBool("max_consecutive_loss_guard_enabled", c.max_consecutive_loss_guard_enabled);
   j.KInt("max_consecutive_losses", c.max_consecutive_losses);
   j.KBool("daily_profit_target_enabled", c.daily_profit_target_enabled);
   j.KNum("daily_profit_target_r", c.daily_profit_target_r, 6);
   j.KStr("profit_target_basis", TRE_ProfitTargetBasisName(c.profit_target_basis));
   j.KStr("admission_formula", "ProjectedWorstCaseEquity = CurrentEquity - sum(IncrementalWorstCaseOpenLoss) - NewTradeWorstCaseLoss >= StartOfBrokerDayEquity - MaxDailyLossR * DayRiskUnitCurrency");
   j.KStr("gate_precedence", "ACCOUNT_RULE_BREACH, ACCOUNT_RULE_NEAR_BREACH, DAILY_PROFIT_TARGET, MAX_CONCURRENT, DIRECTIONAL_CAP, DAILY_LOSS_FLOOR, AGGREGATE_CEILING, DIRECTIONAL_CEILING");
   j.KStr("floating_loss_policy", "admission guard only; never force-closes open positions");
   j.EndObject();
  }

#endif // TRE_RISKADMISSION_MQH
//+------------------------------------------------------------------+
