//+------------------------------------------------------------------+
//| TRE_AccountRules.mqh                                             |
//| External AccountRuleEngine (roadmap 0B.10, 0B.11).               |
//| Kept separate from the internal strategy risk budget (0C.9).     |
//|                                                                  |
//| FUNDEDNEXT_STELLAR_2STEP:                                        |
//|   DailyLossFloor        = −InitialBalance × 5 %                  |
//|   MaximumLossFloorEquity =  InitialBalance × 90 %                |
//|   DailyNetResult = Closed + Floating + Commission + Swap + Fees   |
//|   (signed P/L amounts, each counted once, since daily reset).    |
//|   Breach: DailyNetResult < DailyLossFloor OR                     |
//|           Equity < MaximumLossFloorEquity.                       |
//|   Near-breach: distance to either floor <= SafetyBuffer where    |
//|   SafetyBuffer = AccountRuleSafetyBufferR × DayRiskUnitCurrency. |
//+------------------------------------------------------------------+
#ifndef TRE_ACCOUNTRULES_MQH
#define TRE_ACCOUNTRULES_MQH

#include "TRE_Types.mqh"
#include "TRE_Json.mqh"
#include "TRE_BrokerTime.mqh"

struct TRE_AccountRuleProfile
  {
   ENUM_TRE_ACCOUNT_RULE_PROFILE profile;
   ENUM_TRE_ACCOUNT_RULE_MODE    mode;
   double                        initial_balance;
   string                        currency;
   double                        daily_loss_rate;
   double                        max_loss_rate;
   double                        safety_buffer_r;
   string                        daily_reset_rule;
   string                        source;
  };

bool TRE_LoadAccountRuleProfile(const ENUM_TRE_ACCOUNT_RULE_PROFILE profile, const ENUM_TRE_ACCOUNT_RULE_MODE mode,
                                const double initialBalance, const string currency, const double safetyBufferR,
                                TRE_AccountRuleProfile &p, string &error)
  {
   error = "";
   if(!(initialBalance > 0.0))
     {
      error = "AccountInitialBalance must be positive";
      return false;
     }
   if(currency == "")
     {
      error = "AccountCurrency must be declared";
      return false;
     }
   if(!(safetyBufferR >= 0.0))
     {
      error = "AccountRuleSafetyBufferR must be non-negative";
      return false;
     }
   p.profile = profile;
   p.mode = mode;
   p.initial_balance = initialBalance;
   p.currency = currency;
   p.safety_buffer_r = safetyBufferR;
   switch(profile)
     {
      case TRE_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP:
         p.daily_loss_rate = 0.05;
         p.max_loss_rate = 0.10;
         p.daily_reset_rule = "first broker-server timestamp at or after 00:00:00 of the new broker day";
         p.source = "FundedNext official Stellar 2-Step documentation as frozen in roadmap 0B.10 (2026-09-28)";
         return true;
     }
   error = "unsupported AccountRuleProfile";
   return false;
  }

//--- Signed P/L components since the last daily reset (costs are negative).
struct TRE_AccountRuleInputs
  {
   double            closed_result;
   double            floating_result;
   double            commission;
   double            swap;
   double            fees;
   double            balance;
   double            equity;
   double            day_risk_unit_currency;
  };

struct TRE_AccountRuleEval
  {
   double                      daily_net_result;
   double                      daily_loss_floor;
   double                      max_loss_floor_equity;
   double                      daily_distance;
   double                      max_distance;
   double                      safety_buffer_currency;
   bool                        daily_breach;
   bool                        max_breach;
   bool                        daily_near;
   bool                        max_near;
   ENUM_TRE_ACCOUNT_RULE_STATE state;
  };

class CTRE_AccountRuleEngine
  {
private:
   TRE_AccountRuleProfile m_p;
   CTRE_BrokerDayClock m_clock;
   bool              m_breachLatched;
   datetime          m_breachTime;
   string            m_breachRule;

public:
                     CTRE_AccountRuleEngine(void)
     {
      m_breachLatched = false;
      m_breachTime = 0;
      m_breachRule = "";
     }

   void              Init(const TRE_AccountRuleProfile &p)
     {
      m_p = p;
      m_clock.Reset();
      m_breachLatched = false;
      m_breachTime = 0;
      m_breachRule = "";
     }

   //--- Returns true when t is the daily reset timestamp.
   bool              OnTimestamp(const datetime t) { return m_clock.Observe(t); }
   datetime          ResetTimestamp(void) const     { return m_clock.ResetTimestamp(); }

   double            DailyLossFloor(void) const      { return -m_p.initial_balance * m_p.daily_loss_rate; }
   double            MaxLossFloorEquity(void) const  { return m_p.initial_balance * (1.0 - m_p.max_loss_rate); }
   bool              BreachLatched(void) const       { return m_breachLatched; }

   static double     DailyNetResult(const TRE_AccountRuleInputs &in)
     {
      return in.closed_result + in.floating_result + in.commission + in.swap + in.fees;
     }

   //--- Pure evaluation; additionalLoss (>= 0) projects a worst case.
   void              Evaluate(const TRE_AccountRuleInputs &in, const double additionalLoss, TRE_AccountRuleEval &e) const
     {
      e.daily_net_result = DailyNetResult(in) - additionalLoss;
      e.daily_loss_floor = DailyLossFloor();
      e.max_loss_floor_equity = MaxLossFloorEquity();
      e.daily_distance = e.daily_net_result - e.daily_loss_floor;
      e.max_distance = (in.equity - additionalLoss) - e.max_loss_floor_equity;
      e.safety_buffer_currency = m_p.safety_buffer_r * in.day_risk_unit_currency;
      e.daily_breach = e.daily_net_result < e.daily_loss_floor;
      e.max_breach = (in.equity - additionalLoss) < e.max_loss_floor_equity;
      e.daily_near = !e.daily_breach && e.daily_distance <= e.safety_buffer_currency + TRE_MONEY_EPS;
      e.max_near = !e.max_breach && e.max_distance <= e.safety_buffer_currency + TRE_MONEY_EPS;
      if(e.daily_breach || e.max_breach || m_breachLatched)
         e.state = TRE_ACCOUNT_BREACH;
      else
         if(e.daily_near || e.max_near)
            e.state = TRE_ACCOUNT_NEAR_BREACH;
         else
            e.state = TRE_ACCOUNT_OK;
     }

   //--- Current (non-projected) state; an actual floor crossing latches BREACH
   //--- for the remainder of the run (the account has failed its rules).
   ENUM_TRE_ACCOUNT_RULE_STATE Update(const datetime t, const TRE_AccountRuleInputs &in, TRE_AccountRuleEval &e)
     {
      Evaluate(in, 0.0, e);
      if(!m_breachLatched && (e.daily_breach || e.max_breach))
        {
         m_breachLatched = true;
         m_breachTime = t;
         m_breachRule = e.daily_breach ? "DAILY_LOSS" : "MAXIMUM_LOSS";
        }
      return e.state;
     }

   void              WriteProfileJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KStr("account_rule_profile", TRE_AccountRuleProfileName(m_p.profile));
      j.KStr("account_rule_mode", TRE_AccountRuleModeName(m_p.mode));
      j.KNum("initial_balance", m_p.initial_balance, 2);
      j.KStr("currency", m_p.currency);
      j.KNum("daily_loss_rate", m_p.daily_loss_rate, 6);
      j.KNum("daily_loss_floor_amount", DailyLossFloor(), 2);
      j.KNum("maximum_loss_rate", m_p.max_loss_rate, 6);
      j.KNum("maximum_loss_floor_equity", MaxLossFloorEquity(), 2);
      j.KNum("safety_buffer_r", m_p.safety_buffer_r, 6);
      j.KStr("safety_buffer_currency_rule", "AccountRuleSafetyBufferR * DayRiskUnitCurrency");
      j.KStr("daily_net_result_formula", "ClosedTradeResult + CurrentFloatingResult + AccountAppliedCommission + AccountAppliedSwap + AccountAppliedFees (each once)");
      j.KStr("breach_rule", "DailyNetResult < DailyLossFloor OR Equity < MaximumLossFloorEquity; latched for the run");
      j.KStr("near_breach_rule", "projected distance to either floor <= safety buffer");
      j.KStr("daily_reset", m_p.daily_reset_rule);
      j.KStr("news_rule", "News proximity recorded; OBSERVE_ONLY; MarketStrategyResult reported separately from AccountRuleAdjustedResult");
      j.KStr("source", m_p.source);
      j.EndObject();
     }

   void              WriteStateJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KBool("breach_latched", m_breachLatched);
      if(m_breachLatched)
        {
         j.KTime("breach_time", m_breachTime);
         j.KStr("breach_rule", m_breachRule);
        }
      j.KInt("daily_resets_observed", m_clock.ResetCount());
      if(m_clock.ResetCount() > 0)
         j.KTime("last_reset_timestamp", m_clock.ResetTimestamp());
      j.EndObject();
     }
  };

//+------------------------------------------------------------------+
//| Live adapter: DailyNetResult components from the trade server.   |
//| Closed/commission/swap/fee from BUY/SELL deals since the reset;  |
//| floating = POSITION_PROFIT + POSITION_SWAP of open positions.    |
//| A position's accumulated swap is counted in floating while open  |
//| and in the exit deal's DEAL_SWAP once closed — never both.       |
//+------------------------------------------------------------------+
bool TRE_CollectLiveAccountRuleInputs(const datetime resetTime, const double dayRiskUnitCurrency, TRE_AccountRuleInputs &in)
  {
   in.closed_result = 0.0;
   in.floating_result = 0.0;
   in.commission = 0.0;
   in.swap = 0.0;
   in.fees = 0.0;
   in.balance = AccountInfoDouble(ACCOUNT_BALANCE);
   in.equity = AccountInfoDouble(ACCOUNT_EQUITY);
   in.day_risk_unit_currency = dayRiskUnitCurrency;

   if(!HistorySelect(resetTime, TimeCurrent() + 1))
      return false;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      in.closed_result += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      in.commission    += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      in.swap          += HistoryDealGetDouble(ticket, DEAL_SWAP);
      in.fees          += HistoryDealGetDouble(ticket, DEAL_FEE);
     }
   int positions = PositionsTotal();
   for(int i = 0; i < positions; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      in.floating_result += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return true;
  }

#endif // TRE_ACCOUNTRULES_MQH
//+------------------------------------------------------------------+
