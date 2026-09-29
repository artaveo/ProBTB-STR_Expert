//+------------------------------------------------------------------+
//| TRE_Sessions.mqh                                                 |
//| Broker trading-session schedule, declared closed-market calendar |
//| and the Mode 1/2/3 StrategyEntryWindow (roadmap 1.3, 1.4).       |
//|                                                                  |
//| StrategyEntryWindow = ActualTradeSession ∩ ConfiguredWindow.     |
//| All window ends are exclusive; all times are Broker Server Time. |
//+------------------------------------------------------------------+
#ifndef TRE_SESSIONS_MQH
#define TRE_SESSIONS_MQH

#include "TRE_Types.mqh"
#include "TRE_BrokerTime.mqh"
#include "TRE_Json.mqh"

#define TRE_MAX_SESSIONS_PER_DAY 16

//+------------------------------------------------------------------+
//| [from_sec, to_sec) inside one broker day, 0 <= from < to <= 86400|
//| continuation=true marks the next-day half of a broker interval   |
//| that wrapped midnight; it is not a new "session start".          |
//+------------------------------------------------------------------+
struct TRE_SessionInterval
  {
   int               from_sec;
   int               to_sec;
   bool              continuation;
  };

string TRE_WeekdayName(const int dow)
  {
   switch(dow)
     {
      case 0: return "SUNDAY";
      case 1: return "MONDAY";
      case 2: return "TUESDAY";
      case 3: return "WEDNESDAY";
      case 4: return "THURSDAY";
      case 5: return "FRIDAY";
      case 6: return "SATURDAY";
     }
   return "UNKNOWN";
  }

string TRE_SecToHHMM(const int sec)
  {
   return StringFormat("%02d:%02d", sec / 3600, (sec % 3600) / 60);
  }

//+------------------------------------------------------------------+
//| "HH:MM" → seconds of day. "24:00" only when allow24 is true.     |
//+------------------------------------------------------------------+
bool TRE_ParseHHMM(const string text, const bool allow24, int &sec, string &error)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   error = "";
   if(StringLen(s) != 5 || StringGetCharacter(s, 2) != ':')
     {
      error = "time '" + text + "' is not HH:MM";
      return false;
     }
   for(int i = 0; i < 5; i++)
     {
      if(i == 2)
         continue;
      ushort c = StringGetCharacter(s, i);
      if(c < '0' || c > '9')
        {
         error = "time '" + text + "' is not HH:MM";
         return false;
        }
     }
   int hh = (int)StringToInteger(StringSubstr(s, 0, 2));
   int mm = (int)StringToInteger(StringSubstr(s, 3, 2));
   if(hh == 24 && mm == 0)
     {
      if(!allow24)
        {
         error = "24:00 is permitted only for TradeEndTime";
         return false;
        }
      sec = TRE_SECONDS_PER_DAY;
      return true;
     }
   if(hh > 23 || mm > 59)
     {
      error = "time '" + text + "' is out of range";
      return false;
     }
   sec = hh * 3600 + mm * 60;
   return true;
  }

//+------------------------------------------------------------------+
//| Weekly broker trade-session schedule (SymbolInfoSessionTrade).   |
//+------------------------------------------------------------------+
class CTRE_SessionSchedule
  {
private:
   TRE_SessionInterval m_iv[7][TRE_MAX_SESSIONS_PER_DAY];
   int               m_count[7];
   string            m_rawText[7];

   bool              Insert(const int dow, const int from, const int to, const bool continuation, string &error)
     {
      if(m_count[dow] >= TRE_MAX_SESSIONS_PER_DAY)
        {
         error = StringFormat("more than %d sessions on weekday %d", TRE_MAX_SESSIONS_PER_DAY, dow);
         return false;
        }
      // keep intervals sorted by from_sec
      int pos = m_count[dow];
      while(pos > 0 && m_iv[dow][pos - 1].from_sec > from)
        {
         m_iv[dow][pos] = m_iv[dow][pos - 1];
         pos--;
        }
      m_iv[dow][pos].from_sec = from;
      m_iv[dow][pos].to_sec = to;
      m_iv[dow][pos].continuation = continuation;
      m_count[dow]++;
      return true;
     }

public:
                     CTRE_SessionSchedule(void) { Clear(); }

   void              Clear(void)
     {
      for(int d = 0; d < 7; d++)
        {
         m_count[d] = 0;
         m_rawText[d] = "";
        }
     }

   //--- Adds one broker-declared interval. to <= from wraps midnight
   //--- into [from,24:00) today and [00:00,to) on the next weekday.
   bool              AddBrokerInterval(const int dow, const int from, const int to, string &error)
     {
      error = "";
      if(dow < 0 || dow > 6 || from < 0 || from >= TRE_SECONDS_PER_DAY || to < 0 || to > TRE_SECONDS_PER_DAY)
        {
         error = StringFormat("invalid session interval weekday=%d from=%d to=%d", dow, from, to);
         return false;
        }
      if(from == to)
        {
         error = StringFormat("ambiguous zero-length session interval on weekday %d at %s", dow, TRE_SecToHHMM(from));
         return false;
        }
      if(m_rawText[dow] != "")
         m_rawText[dow] += ",";
      m_rawText[dow] += TRE_SecToHHMM(from) + "-" + TRE_SecToHHMM(to);

      if(from < to)
         return Insert(dow, from, to, false, error);

      if(!Insert(dow, from, TRE_SECONDS_PER_DAY, false, error))
         return false;
      if(to > 0)
         return Insert((dow + 1) % 7, 0, to, true, error);
      return true;
     }

   bool              LoadFromSymbol(const string symbol, string &error)
     {
      Clear();
      error = "";
      for(int d = 0; d < 7; d++)
        {
         for(uint idx = 0; idx < TRE_MAX_SESSIONS_PER_DAY; idx++)
           {
            datetime from = 0, to = 0;
            if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)d, idx, from, to))
               break;
            if(!AddBrokerInterval(d, (int)from, (int)to, error))
               return false;
           }
        }
      if(!HasAnySession())
        {
         error = "SymbolInfoSessionTrade returned no trading sessions for " + symbol;
         return false;
        }
      return true;
     }

   bool              HasAnySession(void) const
     {
      for(int d = 0; d < 7; d++)
         if(m_count[d] > 0)
            return true;
      return false;
     }

   int               Count(const int dow) const { return m_count[dow]; }

   //--- ActualTradeSession(t)
   bool              IsInSession(const datetime t) const
     {
      int dow = TRE_DayOfWeek(t);
      int sod = TRE_SecondsOfDay(t);
      for(int i = 0; i < m_count[dow]; i++)
         if(sod >= m_iv[dow][i].from_sec && sod < m_iv[dow][i].to_sec)
            return true;
      return false;
     }

   //--- Earliest broker-session start strictly after t, searching the same
   //--- date and later dates (up to one full week).
   bool              NextSessionStartAfter(const datetime t, datetime &start) const
     {
      datetime day0 = TRE_BrokerDayStart(t);
      for(int k = 0; k <= 7; k++)
        {
         datetime day = day0 + k * TRE_SECONDS_PER_DAY;
         int dow = TRE_DayOfWeek(day);
         bool found = false;
         datetime best = 0;
         for(int i = 0; i < m_count[dow]; i++)
           {
            if(m_iv[dow][i].continuation)
               continue;
            datetime s = day + m_iv[dow][i].from_sec;
            if(s > t && (!found || s < best))
              {
               best = s;
               found = true;
              }
           }
         if(found)
           {
            start = best;
            return true;
           }
        }
      return false;
     }

   //--- t is exactly the start of a broker-declared session (not a midnight continuation).
   bool              IsSessionStartAt(const datetime t) const
     {
      int dow = TRE_DayOfWeek(t);
      int sod = TRE_SecondsOfDay(t);
      for(int i = 0; i < m_count[dow]; i++)
         if(!m_iv[dow][i].continuation && m_iv[dow][i].from_sec == sod)
            return true;
      return false;
     }

   //--- t is exactly the exclusive end of a session that does not continue past midnight.
   bool              IsSessionEndAt(const datetime t) const
     {
      int sod = TRE_SecondsOfDay(t);
      int dow = TRE_DayOfWeek(t);
      int endSec = sod;
      if(sod == 0)
        {
         dow = (dow + 6) % 7;
         endSec = TRE_SECONDS_PER_DAY;
        }
      for(int i = 0; i < m_count[dow]; i++)
        {
         if(m_iv[dow][i].to_sec != endSec)
            continue;
         if(endSec == TRE_SECONDS_PER_DAY)
           {
            int next = (dow + 1) % 7;
            bool continues = false;
            for(int k = 0; k < m_count[next]; k++)
               if(m_iv[next][k].continuation)
                  continues = true;
            if(continues)
               continue;
           }
         return true;
        }
      return false;
     }

   //--- Appends the absolute session intervals of broker day `day` (clipped to [a,b)).
   int               DaySegments(const datetime day, const datetime a, const datetime b,
                                 datetime &segFrom[], datetime &segTo[]) const
     {
      int dow = TRE_DayOfWeek(day);
      int added = 0;
      for(int i = 0; i < m_count[dow]; i++)
        {
         datetime s = day + m_iv[dow][i].from_sec;
         datetime e = day + m_iv[dow][i].to_sec;
         if(s < a)
            s = a;
         if(e > b)
            e = b;
         if(e <= s)
            continue;
         int n = ArraySize(segFrom);
         ArrayResize(segFrom, n + 1);
         ArrayResize(segTo, n + 1);
         segFrom[n] = s;
         segTo[n] = e;
         added++;
        }
      return added;
     }

   void              WriteJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KStr("source", "SymbolInfoSessionTrade");
      j.KStr("time_basis", TRE_SERVER_TIME_BASIS);
      j.KArr("weekdays");
      for(int d = 0; d < 7; d++)
        {
         j.BeginObject();
         j.KStr("weekday", TRE_WeekdayName(d));
         j.KStr("broker_declared", m_rawText[d]);
         j.KArr("normalized_intervals");
         for(int i = 0; i < m_count[d]; i++)
           {
            j.BeginObject();
            j.KStr("from", TRE_SecToHHMM(m_iv[d][i].from_sec));
            j.KStr("to_exclusive", TRE_SecToHHMM(m_iv[d][i].to_sec));
            j.KBool("midnight_continuation", m_iv[d][i].continuation);
            j.EndObject();
           }
         j.EndArray();
         j.EndObject();
        }
      j.EndArray();
      j.EndObject();
     }
  };

//+------------------------------------------------------------------+
//| Declared closed-market calendar. Frozen before a run; used only  |
//| to exclude holiday/unscheduled closures from data-gap auditing.  |
//| CSV (FILE_COMMON): start,end_exclusive,reason                    |
//| times as "YYYY.MM.DD HH:MM" broker time; '#' starts a comment.   |
//+------------------------------------------------------------------+
class CTRE_ClosureCalendar
  {
private:
   datetime          m_from[];
   datetime          m_to[];
   string            m_reason[];
   string            m_source;

public:
                     CTRE_ClosureCalendar(void) { Clear(); }
   void              Clear(void)
     {
      ArrayResize(m_from, 0);
      ArrayResize(m_to, 0);
      ArrayResize(m_reason, 0);
      m_source = "";
     }

   bool              Add(const datetime from, const datetime to, const string reason, string &error)
     {
      if(to <= from)
        {
         error = "closure end must be after start: " + reason;
         return false;
        }
      int n = ArraySize(m_from);
      ArrayResize(m_from, n + 1);
      ArrayResize(m_to, n + 1);
      ArrayResize(m_reason, n + 1);
      m_from[n] = from;
      m_to[n] = to;
      m_reason[n] = reason;
      return true;
     }

   bool              LoadCsv(const string fileName, string &error)
     {
      Clear();
      error = "";
      m_source = fileName;
      if(fileName == "")
         return true;
      int h = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h == INVALID_HANDLE)
        {
         error = StringFormat("cannot open closed-market calendar '%s' in Common\\Files (error %d)", fileName, GetLastError());
         return false;
        }
      int lineNo = 0;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         lineNo++;
         StringTrimLeft(line);
         StringTrimRight(line);
         if(line == "" || StringGetCharacter(line, 0) == '#')
            continue;
         string f[];
         int n = StringSplit(line, ',', f);
         if(n < 2)
           {
            error = StringFormat("calendar line %d: expected start,end[,reason]", lineNo);
            FileClose(h);
            return false;
           }
         StringTrimLeft(f[0]);
         StringTrimRight(f[0]);
         StringTrimLeft(f[1]);
         StringTrimRight(f[1]);
         datetime a = StringToTime(f[0]);
         datetime b = StringToTime(f[1]);
         string reason = (n >= 3 ? f[2] : "");
         StringTrimLeft(reason);
         StringTrimRight(reason);
         if(a <= 0 || b <= 0)
           {
            error = StringFormat("calendar line %d: unparseable time", lineNo);
            FileClose(h);
            return false;
           }
         if(!Add(a, b, reason, error))
           {
            error = StringFormat("calendar line %d: %s", lineNo, error);
            FileClose(h);
            return false;
           }
        }
      FileClose(h);
      return true;
     }

   int               Count(void) const { return ArraySize(m_from); }

   bool              Contains(const datetime t) const
     {
      int n = ArraySize(m_from);
      for(int i = 0; i < n; i++)
         if(t >= m_from[i] && t < m_to[i])
            return true;
      return false;
     }

   //--- Removes closures from [a,b); appends remaining pieces.
   void              Subtract(const datetime a, const datetime b, datetime &outFrom[], datetime &outTo[]) const
     {
      datetime curFrom[], curTo[];
      ArrayResize(curFrom, 1);
      ArrayResize(curTo, 1);
      curFrom[0] = a;
      curTo[0] = b;
      int nc = ArraySize(m_from);
      for(int c = 0; c < nc; c++)
        {
         datetime nf[], nt[];
         int m = ArraySize(curFrom);
         for(int i = 0; i < m; i++)
           {
            datetime s = curFrom[i], e = curTo[i];
            if(m_to[c] <= s || m_from[c] >= e)
              {
               int k = ArraySize(nf);
               ArrayResize(nf, k + 1);
               ArrayResize(nt, k + 1);
               nf[k] = s;
               nt[k] = e;
               continue;
              }
            if(m_from[c] > s)
              {
               int k = ArraySize(nf);
               ArrayResize(nf, k + 1);
               ArrayResize(nt, k + 1);
               nf[k] = s;
               nt[k] = m_from[c];
              }
            if(m_to[c] < e)
              {
               int k = ArraySize(nf);
               ArrayResize(nf, k + 1);
               ArrayResize(nt, k + 1);
               nf[k] = m_to[c];
               nt[k] = e;
              }
           }
         ArrayCopy(curFrom, nf);
         ArrayCopy(curTo, nt);
         ArrayResize(curFrom, ArraySize(nf));
         ArrayResize(curTo, ArraySize(nt));
        }
      int m = ArraySize(curFrom);
      for(int i = 0; i < m; i++)
        {
         int k = ArraySize(outFrom);
         ArrayResize(outFrom, k + 1);
         ArrayResize(outTo, k + 1);
         outFrom[k] = curFrom[i];
         outTo[k] = curTo[i];
        }
     }

   void              WriteJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KStr("source_file", m_source);
      j.KArr("closures");
      int n = ArraySize(m_from);
      for(int i = 0; i < n; i++)
        {
         j.BeginObject();
         j.KTime("from", m_from[i]);
         j.KTime("to_exclusive", m_to[i]);
         j.KStr("reason", m_reason[i]);
         j.EndObject();
        }
      j.EndArray();
      j.EndObject();
     }
  };

//+------------------------------------------------------------------+
//| Maximal continuously-tradeable segments inside (a, b):           |
//| broker schedule minus declared closures; adjacent pieces         |
//| (e.g. 24:00 → 00:00 of the next day) are merged.                 |
//+------------------------------------------------------------------+
int TRE_TradeableSegments(const CTRE_SessionSchedule &sched, const CTRE_ClosureCalendar &cal,
                          const datetime a, const datetime b,
                          datetime &segFrom[], datetime &segTo[])
  {
   ArrayResize(segFrom, 0);
   ArrayResize(segTo, 0);
   if(b <= a)
      return 0;

   datetime rawFrom[], rawTo[];
   for(datetime day = TRE_BrokerDayStart(a); day < b; day += TRE_SECONDS_PER_DAY)
      sched.DaySegments(day, a, b, rawFrom, rawTo);

   datetime pf[], pt[];
   int nr = ArraySize(rawFrom);
   for(int i = 0; i < nr; i++)
      cal.Subtract(rawFrom[i], rawTo[i], pf, pt);

   // sort by start (small n: insertion sort)
   int np = ArraySize(pf);
   for(int i = 1; i < np; i++)
     {
      datetime kf = pf[i], kt = pt[i];
      int j = i - 1;
      while(j >= 0 && pf[j] > kf)
        {
         pf[j + 1] = pf[j];
         pt[j + 1] = pt[j];
         j--;
        }
      pf[j + 1] = kf;
      pt[j + 1] = kt;
     }

   for(int i = 0; i < np; i++)
     {
      int n = ArraySize(segFrom);
      if(n > 0 && pf[i] <= segTo[n - 1])
        {
         if(pt[i] > segTo[n - 1])
            segTo[n - 1] = pt[i];
         continue;
        }
      ArrayResize(segFrom, n + 1);
      ArrayResize(segTo, n + 1);
      segFrom[n] = pf[i];
      segTo[n] = pt[i];
     }
   return ArraySize(segFrom);
  }

//+------------------------------------------------------------------+
//| Configured strategy window for Mode 1/2/3.                       |
//+------------------------------------------------------------------+
class CTRE_StrategyWindow
  {
private:
   ENUM_TRE_SESSION_MODE m_mode;
   int               m_customStart;
   int               m_customEnd;
   CTRE_SessionSchedule *m_sched;

public:
                     CTRE_StrategyWindow(void)
     {
      m_mode = TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD;
      m_customStart = 0;
      m_customEnd = TRE_SECONDS_PER_DAY;
      m_sched = NULL;
     }

   bool              Init(const ENUM_TRE_SESSION_MODE mode, const string startText, const string endText,
                          CTRE_SessionSchedule *sched, string &error)
     {
      error = "";
      m_mode = mode;
      m_sched = sched;
      if(m_sched == NULL || !m_sched.HasAnySession())
        {
         error = "no broker trading-session schedule available";
         return false;
        }
      if(mode != TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD && mode != TRE_SESSION_NY_WINDOW && mode != TRE_SESSION_CUSTOM)
        {
         error = "unsupported TradingSessionMode";
         return false;
        }
      // Custom inputs are always validated so an invalid Run Card never passes silently.
      int s = 0, e = 0;
      if(!TRE_ParseHHMM(startText, false, s, error))
        {
         error = "TradeStartTime: " + error;
         return false;
        }
      if(!TRE_ParseHHMM(endText, true, e, error))
        {
         error = "TradeEndTime: " + error;
         return false;
        }
      if(s == e)
        {
         error = "TradeStartTime equals TradeEndTime (only 00:00 -> 24:00 means the full broker day)";
         return false;
        }
      m_customStart = s;
      m_customEnd = e;
      return true;
     }

   ENUM_TRE_SESSION_MODE Mode(void) const { return m_mode; }
   int               CustomStart(void) const { return m_customStart; }
   int               CustomEnd(void) const   { return m_customEnd; }

   //--- Mode 1 late-spread block [21:30 of date d, NextTradableSessionStart).
   bool              LateBlockOfDay(const datetime day, datetime &blockStart, datetime &blockEnd) const
     {
      blockStart = day + TRE_LATE_BLOCK_START_SEC;
      if(!m_sched.NextSessionStartAfter(blockStart, blockEnd))
         return false;
      return true;
     }

   bool              IsInLateSpreadBlock(const datetime t) const
     {
      datetime day = TRE_BrokerDayStart(t);
      // Block ends are non-decreasing in their start date, so the block of
      // date(t) and of the previous date are the only candidates.
      for(int k = 0; k <= 1; k++)
        {
         datetime bs, be;
         datetime d = day - k * TRE_SECONDS_PER_DAY;
         if(!LateBlockOfDay(d, bs, be))
            return (t >= d + TRE_LATE_BLOCK_START_SEC);
         if(t >= bs && t < be)
            return true;
        }
      return false;
     }

   bool              InConfiguredWindow(const datetime t) const
     {
      int sod = TRE_SecondsOfDay(t);
      switch(m_mode)
        {
         case TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD:
            return !IsInLateSpreadBlock(t);
         case TRE_SESSION_NY_WINDOW:
            return sod >= TRE_NY_WINDOW_START_SEC && sod < TRE_NY_WINDOW_END_SEC;
         case TRE_SESSION_CUSTOM:
            if(m_customStart < m_customEnd)
               return sod >= m_customStart && sod < m_customEnd;
            return sod >= m_customStart || sod < m_customEnd;
        }
      return false;
     }

   //--- Controls NEW entries only; open positions are never closed by it.
   bool              IsEntryAllowed(const datetime t) const
     {
      return m_sched.IsInSession(t) && InConfiguredWindow(t);
     }

   void              WriteJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KStr("trading_session_mode", TRE_SessionModeName(m_mode));
      j.KStr("rule", "StrategyEntryWindow = ActualTradeSession AND ConfiguredStrategyWindow; window ends exclusive; new entries only");
      switch(m_mode)
        {
         case TRE_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD:
            j.KStr("configured_window", "NOT [21:30, NextTradableSessionStart)");
            break;
         case TRE_SESSION_NY_WINDOW:
            j.KStr("configured_window", "[16:30, 21:30)");
            break;
         case TRE_SESSION_CUSTOM:
            if(m_customStart < m_customEnd)
               j.KStr("configured_window", "[" + TRE_SecToHHMM(m_customStart) + ", " + TRE_SecToHHMM(m_customEnd) + ")");
            else
               j.KStr("configured_window", "[" + TRE_SecToHHMM(m_customStart) + ", 24:00) U [00:00, " + TRE_SecToHHMM(m_customEnd) + ")");
            break;
        }
      j.KStr("custom_trade_start_time", TRE_SecToHHMM(m_customStart));
      j.KStr("custom_trade_end_time", TRE_SecToHHMM(m_customEnd));
      j.EndObject();
     }
  };

#endif // TRE_SESSIONS_MQH
//+------------------------------------------------------------------+
