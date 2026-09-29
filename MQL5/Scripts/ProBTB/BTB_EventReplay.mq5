//+------------------------------------------------------------------+
//| BTB_EventReplay.mq5                                              |
//| Deterministic replay of the BTB event layer (roadmap 3–4) from   |
//| an exported M1 file (Common\Files\<Folder>\bars_M1_BID.csv with  |
//| the spread_pts column) and the exported broker session schedule  |
//| (session_schedule.csv). Writes btb_days.csv, btb_events_<TF>.csv |
//| and btb_setups_E2_<TF>.csv exactly as BTB_Expert does, so a run  |
//| package or a synthetic fixture can be re-derived and reconciled  |
//| with the Python reference. No market access, no trading, no      |
//| proxies.                                                         |
//+------------------------------------------------------------------+
#property copyright   "Pro BTB"
#property version     "2.00"
#property description "BTB event replay from exported M1 bars (no trading)"
#property script_show_inputs

#include "../../Include/ProBTB/BTB_Engine.mqh"

input string InpFolder                = "BTB\\BTB-V2";           // Package folder under Common\Files
input string InpBarsFile              = "bars_M1_BID.csv";       // M1 bar file inside the folder
input string InpSessionFile           = "session_schedule.csv";  // Broker session schedule inside the folder
input string InpQuarantineFile        = "data_quarantine_windows.csv"; // Quarantine CSV inside the folder ("" = none)
input string InpOutputSubfolder       = "replay";                // Ledger output subfolder
input int    InpDigits                = 2;                       // Symbol digits
input double InpE2ZigZagATR           = BTB_E2_ZIGZAG_ATR;       // E2_ZigZagATR
input double InpE2SpikeATR            = BTB_E2_SPIKE_ATR;        // E2_SpikeATR
input int    InpE2SpikeBars           = BTB_E2_SPIKE_BARS;       // E2_SpikeBars
input double InpE2LineTolATR          = BTB_E2_LINE_TOL_ATR;     // E2_LineTolATR
input int    InpE2MaxDays             = BTB_E2_MAX_DAYS;         // E2_MaxDays
input bool   InpCloseTerminalWhenDone = false;                   // Close terminal after the run (CI use)

#define BTB_REPLAY_TF_COUNT 2

//--- Quarantine windows read from the package (same file the Python reference reads).
class CBTB_ReplayQuarantine : public CBTB_QuarantineCheck
  {
public:
   CTRE_DataQuarantine *file;
   virtual bool      Overlaps(const datetime from, const datetime toExclusive)
     {
      return file != NULL && file.Overlaps(from, toExclusive);
     }
  };

ENUM_TRE_TIMEFRAME   g_tfs[BTB_REPLAY_TF_COUNT] = {TRE_TF_M5, TRE_TF_M15};
CTRE_SessionSchedule g_sched;
CTRE_DataQuarantine  g_quar;
CBTB_DayTracker      g_days;
CBTB_LevelSource     g_levels;
CBTB_LevelEngine     g_eng[BTB_REPLAY_TF_COUNT];
CBTB_E2Setups        g_e2[BTB_REPLAY_TF_COUNT];

datetime ParseIso(const string s)
  {
   string t = s;
   StringReplace(t, "-", ".");
   StringReplace(t, "T", " ");
   return StringToTime(t);
  }

bool LoadSchedule(const string path, string &error)
  {
   g_sched.Clear();
   int h = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      error = StringFormat("cannot open %s (error %d)", path, GetLastError());
      return false;
     }
   string header = FileReadString(h);
   if(header != "weekday,from_sec,to_sec")
     {
      error = "unexpected session header " + header;
      FileClose(h);
      return false;
     }
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(line == "")
         continue;
      string f[];
      if(StringSplit(line, ',', f) != 3)
        {
         error = "bad session line " + line;
         FileClose(h);
         return false;
        }
      if(!g_sched.AddBrokerInterval((int)StringToInteger(f[0]), (int)StringToInteger(f[1]), (int)StringToInteger(f[2]), error))
        {
         FileClose(h);
         return false;
        }
     }
   FileClose(h);
   if(!g_sched.HasAnySession())
     {
      error = "the session schedule is empty";
      return false;
     }
   return true;
  }

void OnStart(void)
  {
   string err;
   string dir = InpFolder + "\\";
   if(!LoadSchedule(dir + InpSessionFile, err))
     {
      Print("BTB replay: ", err);
      return;
     }
   if(InpQuarantineFile != "" && !g_quar.LoadCsv(dir + InpQuarantineFile, err))
     {
      Print("BTB replay: ", err);
      return;
     }
   g_days.Init(GetPointer(g_sched));
   g_levels.Init(GetPointer(g_days));
   BTB_E2Config e2cfg;
   BTB_E2ConfigDefaults(e2cfg);
   e2cfg.zigzag_atr = InpE2ZigZagATR;
   e2cfg.spike_atr = InpE2SpikeATR;
   e2cfg.spike_bars = InpE2SpikeBars;
   e2cfg.line_tol_atr = InpE2LineTolATR;
   e2cfg.max_days = InpE2MaxDays;
   for(int i = 0; i < BTB_REPLAY_TF_COUNT; i++)
     {
      g_eng[i].Init(g_tfs[i], GetPointer(g_days), GetPointer(g_levels), InpDigits);
      g_e2[i].Init(TRE_TimeframeName(g_tfs[i]), TRE_TimeframeSeconds(g_tfs[i]), InpDigits, e2cfg, GetPointer(g_days));
     }

   int h = FileOpen(dir + InpBarsFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("BTB replay: cannot open %s%s (error %d)", dir, InpBarsFile, GetLastError());
      return;
     }
   string header = FileReadString(h);
   if(header != "time,open,high,low,close,ticks,spread_pts")
     {
      Print("BTB replay: unexpected header ", header);
      FileClose(h);
      return;
     }
   long n = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(line == "")
         continue;
      string f[];
      if(StringSplit(line, ',', f) != 7)
        {
         PrintFormat("BTB replay: bad line %I64d: %s", n + 2, line);
         FileClose(h);
         return;
        }
      TRE_Bar b;
      b.time = ParseIso(f[0]);
      b.period = 60;
      b.open = StringToDouble(f[1]);
      b.high = StringToDouble(f[2]);
      b.low = StringToDouble(f[3]);
      b.close = StringToDouble(f[4]);
      b.ticks = StringToInteger(f[5]);
      int spreadPts = (int)StringToInteger(f[6]);
      g_days.OnM1(b, spreadPts);
      g_levels.OnM1(b);
      for(int i = 0; i < BTB_REPLAY_TF_COUNT; i++)
        {
         g_eng[i].OnM1(b);
         g_e2[i].Sync(GetPointer(g_eng[i]));
        }
      n++;
     }
   FileClose(h);
   for(int i = 0; i < BTB_REPLAY_TF_COUNT; i++)
     {
      g_eng[i].Flush();
      g_e2[i].Sync(GetPointer(g_eng[i]));
      g_e2[i].Finish();
     }
   g_days.Finish();

   string out = dir + InpOutputSubfolder + "\\";
   CBTB_ReplayQuarantine q;
   q.file = NULL;
   if(InpQuarantineFile != "")
      q.file = GetPointer(g_quar);
   if(!g_days.WriteCsv(out + "btb_days.csv"))
      Print("BTB replay: cannot write btb_days.csv");
   string summary = "";
   for(int i = 0; i < BTB_REPLAY_TF_COUNT; i++)
     {
      string tf = TRE_TimeframeName(g_tfs[i]);
      if(!g_eng[i].WriteCsv(out + "btb_events_" + tf + ".csv", q))
         PrintFormat("BTB replay: cannot write btb_events_%s.csv", tf);
      if(!g_e2[i].WriteCsv(out + "btb_setups_E2_" + tf + ".csv", q))
         PrintFormat("BTB replay: cannot write btb_setups_E2_%s.csv", tf);
      summary += StringFormat(" %s: bars=%d event_rows=%d EVENT=%d", tf, g_eng[i].BarCount(), g_eng[i].EventCount(),
                              g_eng[i].CountStatus(BTB_EV_EVENT));
     }
   TRE_WriteUtf8File(out + "replay_done.txt", StringFormat("m1_bars=%I64d days=%d%s\n", n, g_days.DayCount(), summary), true);
   PrintFormat("BTB replay done: m1_bars=%I64d days=%d%s -> Common\\Files\\%s", n, g_days.DayCount(), summary, out);
   if(InpCloseTerminalWhenDone)
      TerminalClose(0);
  }
//+------------------------------------------------------------------+
