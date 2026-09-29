//+------------------------------------------------------------------+
//| TRE_Timeframes.mqh                                               |
//| TimeframeSet parsing/canonicalisation and LiveTimeframe rule     |
//| (roadmap 1.1, architecture rules 2, 11, 12).                     |
//+------------------------------------------------------------------+
#ifndef TRE_TIMEFRAMES_MQH
#define TRE_TIMEFRAMES_MQH

#include "TRE_Types.mqh"

#define TRE_DEFAULT_TIMEFRAME_SET "M5,M15,H1"

string TRE_TimeframeName(const ENUM_TRE_TIMEFRAME tf)
  {
   switch(tf)
     {
      case TRE_TF_M1:  return "M1";
      case TRE_TF_M5:  return "M5";
      case TRE_TF_M15: return "M15";
      case TRE_TF_M30: return "M30";
      case TRE_TF_H1:  return "H1";
     }
   return "UNKNOWN";
  }

ENUM_TIMEFRAMES TRE_ToMqlTimeframe(const ENUM_TRE_TIMEFRAME tf)
  {
   switch(tf)
     {
      case TRE_TF_M1:  return PERIOD_M1;
      case TRE_TF_M5:  return PERIOD_M5;
      case TRE_TF_M15: return PERIOD_M15;
      case TRE_TF_M30: return PERIOD_M30;
      case TRE_TF_H1:  return PERIOD_H1;
     }
   return PERIOD_CURRENT;
  }

int TRE_TimeframeSeconds(const ENUM_TRE_TIMEFRAME tf)
  {
   switch(tf)
     {
      case TRE_TF_M1:  return 60;
      case TRE_TF_M5:  return 300;
      case TRE_TF_M15: return 900;
      case TRE_TF_M30: return 1800;
      case TRE_TF_H1:  return 3600;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Token must already be trimmed and upper-cased.                   |
//+------------------------------------------------------------------+
bool TRE_TryParseTimeframeToken(const string token, ENUM_TRE_TIMEFRAME &tf)
  {
   if(token == "M1")  { tf = TRE_TF_M1;  return true; }
   if(token == "M5")  { tf = TRE_TF_M5;  return true; }
   if(token == "M15") { tf = TRE_TF_M15; return true; }
   if(token == "M30") { tf = TRE_TF_M30; return true; }
   if(token == "H1")  { tf = TRE_TF_H1;  return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| A parsed TimeframeSet, always stored in canonical enum order.    |
//+------------------------------------------------------------------+
struct TRE_TimeframeSet
  {
   int                count;
   ENUM_TRE_TIMEFRAME items[TRE_TF_COUNT];
  };

void TRE_TimeframeSetClear(TRE_TimeframeSet &set)
  {
   set.count = 0;
   for(int i = 0; i < TRE_TF_COUNT; i++)
      set.items[i] = TRE_TF_M1;
  }

bool TRE_TimeframeSetContains(const TRE_TimeframeSet &set, const ENUM_TRE_TIMEFRAME tf)
  {
   for(int i = 0; i < set.count; i++)
      if(set.items[i] == tf)
         return true;
   return false;
  }

string TRE_TimeframeSetToString(const TRE_TimeframeSet &set)
  {
   string s = "";
   for(int i = 0; i < set.count; i++)
     {
      if(i > 0)
         s += ",";
      s += TRE_TimeframeName(set.items[i]);
     }
   return s;
  }

//+------------------------------------------------------------------+
//| Comma-separated, case-insensitive, whitespace-tolerant.          |
//| Empty entries, unsupported values and duplicates fail; duplicates|
//| are never silently removed. Output is canonical M1,M5,M15,M30,H1.|
//+------------------------------------------------------------------+
bool TRE_ParseTimeframeSet(const string text, TRE_TimeframeSet &set, string &error)
  {
   TRE_TimeframeSetClear(set);
   error = "";

   string whole = text;
   StringTrimLeft(whole);
   StringTrimRight(whole);
   if(whole == "")
     {
      error = "TimeframeSet is empty";
      return false;
     }

   string parts[];
   int n = StringSplit(text, ',', parts);
   if(n <= 0)
     {
      error = "TimeframeSet is empty";
      return false;
     }

   bool seen[TRE_TF_COUNT];
   ArrayInitialize(seen, false);

   for(int i = 0; i < n; i++)
     {
      string tok = parts[i];
      StringTrimLeft(tok);
      StringTrimRight(tok);
      StringToUpper(tok);
      if(tok == "")
        {
         error = StringFormat("TimeframeSet entry %d is empty", i + 1);
         return false;
        }
      ENUM_TRE_TIMEFRAME tf = TRE_TF_M1;
      if(!TRE_TryParseTimeframeToken(tok, tf))
        {
         error = StringFormat("TimeframeSet entry %d '%s' is not one of M1/M5/M15/M30/H1", i + 1, tok);
         return false;
        }
      if(seen[(int)tf])
        {
         error = StringFormat("TimeframeSet entry %d '%s' is a duplicate", i + 1, tok);
         return false;
        }
      seen[(int)tf] = true;
     }

   for(int k = 0; k < TRE_TF_COUNT; k++)
      if(seen[k])
        {
         set.items[set.count] = (ENUM_TRE_TIMEFRAME)k;
         set.count++;
        }
   return true;
  }

//+------------------------------------------------------------------+
//| LiveTimeframe must be exactly one member of TimeframeSet.        |
//+------------------------------------------------------------------+
bool TRE_ValidateLiveTimeframe(const TRE_TimeframeSet &set, const ENUM_TRE_TIMEFRAME live, string &error)
  {
   error = "";
   if(!TRE_TimeframeSetContains(set, live))
     {
      error = StringFormat("LiveTimeframe %s is not a member of TimeframeSet %s",
                           TRE_TimeframeName(live), TRE_TimeframeSetToString(set));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Research (tester) runs every TimeframeSet member; live runs only |
//| the one fixed LiveTimeframe.                                     |
//+------------------------------------------------------------------+
void TRE_ResolveActiveTimeframes(const TRE_TimeframeSet &set,
                                 const ENUM_TRE_TIMEFRAME live,
                                 const ENUM_TRE_RUN_CONTEXT ctx,
                                 TRE_TimeframeSet &active)
  {
   if(ctx == TRE_CONTEXT_RESEARCH)
     {
      active = set;
      return;
     }
   TRE_TimeframeSetClear(active);
   active.items[0] = live;
   active.count = 1;
  }

#endif // TRE_TIMEFRAMES_MQH
//+------------------------------------------------------------------+
