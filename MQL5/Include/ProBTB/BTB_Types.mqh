//+------------------------------------------------------------------+
//| BTB_Types.mqh                                                    |
//| Pro BTB (Back To Breakeven) — level types, sides, window flags,  |
//| day/proxy states, exit reasons and the frozen constants of       |
//| ProBTB_Roadmap.md Sections 2–5. Nothing here is an input.        |
//+------------------------------------------------------------------+
#ifndef BTB_TYPES_MQH
#define BTB_TYPES_MQH

#include "../TickResearchEngine/TRE_Types.mqh"
#include "../TickResearchEngine/TRE_Json.mqh"
#include "../TickResearchEngine/TRE_BrokerTime.mqh"
#include "../TickResearchEngine/TRE_Sessions.mqh"

#define BTB_CONTRACT_ID            "BTB-EVENTS-PROXIES-2026-09-29"
#define BTB_ROADMAP_FILENAME       "ProBTB_Roadmap.md"
#define BTB_OUTPUT_ROOT            "BTB"
#define BTB_ID_HEX_CHARS           16

//--- Section 3: windows and the spread-normal resume rule (Broker Server Time)
#define BTB_LATE_BLOCK_SEC         (21*3600+30*60)   // 21:30 — late-spread block starts; pending cancelled, open closed
#define BTB_NY_START_SEC           (16*3600+30*60)   // 16:30 — NY window start and resume deadline
#define BTB_REF_FROM_SEC           (10*3600)         // reference spread samples in [10:00, 21:30)
#define BTB_REF_TO_SEC             BTB_LATE_BLOCK_SEC
#define BTB_RESUME_MULT            1.5
#define BTB_RESUME_BARS            5
#define BTB_ASIAN_END_SEC          (8*3600)          // L2 range [ResumeTime, 08:00)

//--- Section 4: levels
#define BTB_ATR_PERIOD             14
#define BTB_SWING_SIDE_BARS        2
#define BTB_L3_LIFE_H1_BARS        120
#define BTB_L4_MIN_N               20
#define BTB_L4_MAX_N               96
#define BTB_L4_ATR_MULT            2.5
#define BTB_L4_COOLDOWN_BARS       20

//--- Section 5: proxies
#define BTB_R_COUNT                3                 // R = 1, 2, 3
#define BTB_ORDER_LIFE_BARS        12
#define BTB_GAP_EXIT_SECONDS       300

#define BTB_LONG                   1
#define BTB_SHORT                  -1

//--- Window flags (Section 3.3); an event carries both.
#define BTB_WINDOW_FULL            1
#define BTB_WINDOW_NY              2

enum ENUM_BTB_LEVEL_TYPE
  {
   BTB_L1 = 0,   // PDH/PDL
   BTB_L2 = 1,   // Asian range high/low
   BTB_L3 = 2,   // H1 2/2 swing high/low
   BTB_L4 = 3    // consolidation box top/bottom
  };

enum ENUM_BTB_DAY_STATUS
  {
   BTB_DAY_WARMUP     = 0,   // no reference spread yet (first trading day)
   BTB_DAY_NO_SESSION = 1,   // no broker session start on this date
   BTB_DAY_PENDING    = 2,   // internal: resume not yet decided
   BTB_DAY_NORMAL     = 3,
   BTB_DAY_ABNORMAL   = 4    // ABNORMAL_SPREAD_DAY: ResumeTime = 16:30
  };

enum ENUM_BTB_EVENT_STATUS
  {
   BTB_EV_EVENT         = 0,
   BTB_EV_OPEN_BEYOND   = 1,
   BTB_EV_WARMUP        = 2,
   BTB_EV_IN_QUARANTINE = 3   // applied when the ledger is written
  };

enum ENUM_BTB_PROXY_STATE
  {
   BTB_PX_WAIT_PLACEMENT          = 0,   // internal
   BTB_PX_PENDING                 = 1,   // internal
   BTB_PX_OPEN                    = 2,   // internal
   BTB_PX_CLOSED                  = 3,   // ledger: FILLED or FILLED_AT_PLACEMENT
   BTB_PX_EXPIRED_12_BARS         = 4,
   BTB_PX_MISSED_TP_FIRST         = 5,
   BTB_PX_CANCELLED_WINDOW_END    = 6,
   BTB_PX_INVALID_STOP_GEOMETRY   = 7,
   BTB_PX_NOT_PLACED_END_OF_DATA  = 8,
   BTB_PX_NOT_FILLED_END_OF_DATA  = 9
  };

enum ENUM_BTB_EXIT_REASON
  {
   BTB_EXIT_NONE              = 0,
   BTB_EXIT_TP                = 1,
   BTB_EXIT_SL                = 2,
   BTB_EXIT_SESSION_CLOSE     = 3,
   BTB_EXIT_GAP_TP            = 4,
   BTB_EXIT_GAP_SL            = 5,
   BTB_EXIT_GAP_SESSION_CLOSE = 6,
   BTB_EXIT_END_OF_DATA       = 7
  };

//+------------------------------------------------------------------+
//| Names                                                            |
//+------------------------------------------------------------------+
string BTB_LevelTypeName(const int t)
  {
   switch(t)
     {
      case BTB_L1: return "L1";
      case BTB_L2: return "L2";
      case BTB_L3: return "L3";
      case BTB_L4: return "L4";
     }
   return "UNKNOWN";
  }

string BTB_SideName(const int side) { return side > 0 ? "LONG" : "SHORT"; }

string BTB_DayStatusName(const int s)
  {
   switch(s)
     {
      case BTB_DAY_WARMUP:     return "WARMUP";
      case BTB_DAY_NO_SESSION: return "NO_SESSION_START";
      case BTB_DAY_PENDING:    return "PENDING";
      case BTB_DAY_NORMAL:     return "NORMAL";
      case BTB_DAY_ABNORMAL:   return "ABNORMAL_SPREAD_DAY";
     }
   return "UNKNOWN";
  }

string BTB_EventStatusName(const int s)
  {
   switch(s)
     {
      case BTB_EV_EVENT:         return "EVENT";
      case BTB_EV_OPEN_BEYOND:   return "OPEN_BEYOND_LEVEL";
      case BTB_EV_WARMUP:        return "WARMUP";
      case BTB_EV_IN_QUARANTINE: return "IN_QUARANTINE";
     }
   return "UNKNOWN";
  }

string BTB_ProxyStateName(const int s, const bool atPlacement)
  {
   switch(s)
     {
      case BTB_PX_WAIT_PLACEMENT:         return "WAIT_PLACEMENT";
      case BTB_PX_PENDING:                return "PENDING";
      case BTB_PX_OPEN:                   return "OPEN";
      case BTB_PX_CLOSED:                 return atPlacement ? "FILLED_AT_PLACEMENT" : "FILLED";
      case BTB_PX_EXPIRED_12_BARS:        return "EXPIRED_12_BARS";
      case BTB_PX_MISSED_TP_FIRST:        return "MISSED_TP_FIRST";
      case BTB_PX_CANCELLED_WINDOW_END:   return "CANCELLED_WINDOW_END";
      case BTB_PX_INVALID_STOP_GEOMETRY:  return "INVALID_STOP_GEOMETRY";
      case BTB_PX_NOT_PLACED_END_OF_DATA: return "NOT_PLACED_END_OF_DATA";
      case BTB_PX_NOT_FILLED_END_OF_DATA: return "NOT_FILLED_END_OF_DATA";
     }
   return "UNKNOWN";
  }

string BTB_ExitReasonName(const int r)
  {
   switch(r)
     {
      case BTB_EXIT_NONE:              return "";
      case BTB_EXIT_TP:                return "TP";
      case BTB_EXIT_SL:                return "SL";
      case BTB_EXIT_SESSION_CLOSE:     return "SESSION_CLOSE";
      case BTB_EXIT_GAP_TP:            return "GAP_TP";
      case BTB_EXIT_GAP_SL:            return "GAP_SL";
      case BTB_EXIT_GAP_SESSION_CLOSE: return "GAP_SESSION_CLOSE";
      case BTB_EXIT_END_OF_DATA:       return "END_OF_DATA";
     }
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| Stable event id (roadmap 4.3): first 16 hex characters of the    |
//| SHA-256 of "BTB|tf|level|side|source_time|break_bar_time".       |
//+------------------------------------------------------------------+
string BTB_EventId(const string tf, const int levelType, const int side, const datetime sourceTime, const datetime barTime)
  {
   string canonical = "BTB|" + tf + "|" + BTB_LevelTypeName(levelType) + "|" + BTB_SideName(side) + "|" +
                      TRE_IsoTime(sourceTime) + "|" + TRE_IsoTime(barTime);
   return StringSubstr(TRE_Sha256Hex(canonical), 0, BTB_ID_HEX_CHARS);
  }

//--- Median of integer samples: middle value, or the mean of the two middle values.
double BTB_MedianInt(const int &values[])
  {
   int n = ArraySize(values);
   if(n <= 0)
      return 0.0;
   int s[];
   ArrayResize(s, n);
   for(int i = 0; i < n; i++)
      s[i] = values[i];
   ArraySort(s);
   if(n % 2 == 1)
      return (double)s[n / 2];
   return (s[n / 2 - 1] + s[n / 2]) / 2.0;
  }

//--- Stratification buckets (roadmap 5.5).
string BTB_HourBucket(const int hour)
  {
   return hour < 8 ? "H00_08" : hour < 13 ? "H08_13" : hour < 17 ? "H13_17" : "H17_24";
  }

string BTB_SpreadBucket(const double pips)
  {
   return pips < 3.0 ? "LT3" : pips < 5.0 ? "3_5" : pips < 8.0 ? "5_8" : "GE8";
  }

string BTB_BoxBucket(const int n)
  {
   if(n < BTB_L4_MIN_N)
      return "NA";
   return n < 40 ? "20_39" : n < 60 ? "40_59" : "60_96";
  }

//--- Exit precedence on one tick (roadmap 5.4): the stop wins over the
//--- target, and a live stop/target wins over the 21:30 close.
int BTB_ResolveExit(const bool stopHit, const bool tpHit, const bool sessionEnd, const bool gap)
  {
   if(stopHit)
      return gap ? BTB_EXIT_GAP_SL : BTB_EXIT_SL;
   if(tpHit)
      return gap ? BTB_EXIT_GAP_TP : BTB_EXIT_TP;
   if(sessionEnd)
      return gap ? BTB_EXIT_GAP_SESSION_CLOSE : BTB_EXIT_SESSION_CLOSE;
   return BTB_EXIT_NONE;
  }

//--- One UTF-8 line (LF) to an open binary file (streamed ledgers).
void BTB_WriteLine(const int h, const string line)
  {
   uchar bytes[];
   TRE_Utf8Bytes(line + "\n", bytes);
   FileWriteArray(h, bytes, 0, ArraySize(bytes));
  }

//+------------------------------------------------------------------+
//| Quarantine overlap callback used when ledgers are written.       |
//+------------------------------------------------------------------+
class CBTB_QuarantineCheck
  {
public:
   virtual bool      Overlaps(const datetime from, const datetime toExclusive) { return false; }
  };

//+------------------------------------------------------------------+
//| Run package folder Common\Files\BTB\<ExperimentId>\ with the     |
//| SHA-256 index of every file (same contract as CTRE_RunOutput,    |
//| whose output root is fixed to TRE).                              |
//+------------------------------------------------------------------+
class CBTB_RunOutput
  {
private:
   string            m_dir;
   string            m_files[];
   string            m_sha[];
   int               m_failures;

   void              Index(const string fileName, const string sha)
     {
      for(int i = 0; i < ArraySize(m_files); i++)
         if(m_files[i] == fileName)
           {
            m_sha[i] = sha;
            return;
           }
      int n = ArraySize(m_files);
      ArrayResize(m_files, n + 1);
      ArrayResize(m_sha, n + 1);
      m_files[n] = fileName;
      m_sha[n] = sha;
     }

public:
   void              Init(const string experimentId)
     {
      m_dir = BTB_OUTPUT_ROOT + "\\" + experimentId + "\\";
      ArrayResize(m_files, 0);
      ArrayResize(m_sha, 0);
      m_failures = 0;
     }

   string            Dir(void) const { return m_dir; }
   int               Failures(void) const { return m_failures; }

   string            Write(const string fileName, const string text)
     {
      string sha = TRE_WriteUtf8File(m_dir + fileName, text, true);
      if(sha == "")
        {
         m_failures++;
         return "";
        }
      Index(fileName, sha);
      return sha;
     }

   //--- Indexes a file written directly (streamed ledgers) by hashing it from disk.
   string            RegisterFile(const string fileName)
     {
      string sha = "";
      int h = FileOpen(m_dir + fileName, FILE_READ | FILE_BIN | FILE_COMMON);
      if(h != INVALID_HANDLE)
        {
         uchar data[], key[], hash[];
         ulong size = FileSize(h);
         if(size > 0)
            FileReadArray(h, data, 0, (int)size);
         FileClose(h);
         if(CryptEncode(CRYPT_HASH_SHA256, data, key, hash) > 0)
            sha = TRE_HexLower(hash);
        }
      if(sha == "")
        {
         m_failures++;
         return "";
        }
      Index(fileName, sha);
      return sha;
     }

   void              WriteIndexJson(CTRE_Json &j) const
     {
      j.BeginArray();
      for(int i = 0; i < ArraySize(m_files); i++)
        {
         j.BeginObject();
         j.KStr("file", m_files[i]);
         j.KStr("sha256", m_sha[i]);
         j.EndObject();
        }
      j.EndArray();
     }
  };

#endif // BTB_TYPES_MQH
//+------------------------------------------------------------------+
