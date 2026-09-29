//+------------------------------------------------------------------+
//| BTB_Window.mqh                                                   |
//| Roadmap Section 3: late-spread block and the spread-normal       |
//| resume rule, per broker trading day, from the M1 stream.         |
//|                                                                  |
//| Per-M1 spread sample = Ask - Bid (points) of the last tick of    |
//| the minute. Reference(d) = median of the samples of the previous |
//| trading day in [10:00, 21:30). ResumeTime(d) = close of the      |
//| first M1 bar at/after NextTradableSessionStart(d) whose sample   |
//| and the samples of the 4 bars before it (all at/after the start) |
//| are each <= 1.5 x Reference(d); not met by 16:30 ->              |
//| ABNORMAL_SPREAD_DAY with ResumeTime = 16:30.                     |
//| FULL = [ResumeTime, 21:30), NY = [max(16:30, ResumeTime), 21:30),|
//| both intersected with the actual trade session. An event belongs |
//| to a window if its breakout candle closes inside it.             |
//+------------------------------------------------------------------+
#ifndef BTB_WINDOW_MQH
#define BTB_WINDOW_MQH

#include "BTB_Types.mqh"

struct BTB_DayRec
  {
   datetime          date;
   datetime          session_start;   // NextTradableSessionStart(d); 0 = none on this date
   bool              has_ref;
   datetime          ref_date;
   double            ref;             // reference spread (points)
   int               ref_n;           // samples behind the reference
   int               status;          // ENUM_BTB_DAY_STATUS
   datetime          resume;          // ResumeTime(d) once NORMAL/ABNORMAL
   int               run;             // consecutive qualifying samples at/after the session start
   int               m1_bars;
  };

class CBTB_DayTracker
  {
private:
   CTRE_SessionSchedule *m_sched;
   BTB_DayRec        m_days[];
   int               m_n;
   int               m_samples[];     // current day's samples in [10:00, 21:30)
   int               m_nSamples;
   bool              m_haveLastRef;   // most recent finished day that has samples
   datetime          m_lastRefDate;
   double            m_lastRef;
   int               m_lastRefN;
   bool              m_finished;

   void              StartDay(const datetime d)
     {
      datetime s = 0;
      datetime ns = 0;
      if(m_sched.NextSessionStartAfter(d - TRE_SECONDS_PER_DAY + BTB_LATE_BLOCK_SEC, ns) &&
         ns >= d && ns < d + TRE_SECONDS_PER_DAY)
         s = ns;
      if(m_n >= ArraySize(m_days))
         ArrayResize(m_days, m_n + 1, 256);
      int i = m_n++;
      m_days[i].date = d;
      m_days[i].session_start = s;
      m_days[i].has_ref = m_haveLastRef;
      m_days[i].ref_date = m_haveLastRef ? m_lastRefDate : (datetime)0;
      m_days[i].ref = m_haveLastRef ? m_lastRef : 0.0;
      m_days[i].ref_n = m_haveLastRef ? m_lastRefN : 0;
      if(s == 0)
         m_days[i].status = BTB_DAY_NO_SESSION;
      else
         m_days[i].status = m_haveLastRef ? BTB_DAY_PENDING : BTB_DAY_WARMUP;
      m_days[i].resume = 0;
      m_days[i].run = 0;
      m_days[i].m1_bars = 0;
      m_nSamples = 0;
     }

   void              FinalizeLast(void)
     {
      if(m_n == 0)
         return;
      int i = m_n - 1;
      if(m_days[i].status == BTB_DAY_PENDING)
        {
         m_days[i].status = BTB_DAY_ABNORMAL;
         m_days[i].resume = m_days[i].date + BTB_NY_START_SEC;
        }
      if(m_nSamples > 0)
        {
         int s[];
         ArrayResize(s, m_nSamples);
         for(int k = 0; k < m_nSamples; k++)
            s[k] = m_samples[k];
         m_haveLastRef = true;
         m_lastRefDate = m_days[i].date;
         m_lastRef = BTB_MedianInt(s);
         m_lastRefN = m_nSamples;
        }
     }

public:
                     CBTB_DayTracker(void) { m_sched = NULL; m_n = 0; m_nSamples = 0; m_haveLastRef = false; m_finished = false; }

   void              Init(CTRE_SessionSchedule *sched)
     {
      m_sched = sched;
      m_n = 0;
      ArrayResize(m_days, 0);
      ArrayResize(m_samples, 0);
      m_nSamples = 0;
      m_haveLastRef = false;
      m_lastRefDate = 0;
      m_lastRef = 0.0;
      m_lastRefN = 0;
      m_finished = false;
     }

   //--- One completed M1 bar and its spread sample (points). Call before the level source.
   void              OnM1(const TRE_Bar &b, const int spreadPts)
     {
      datetime d = TRE_BrokerDayStart(b.time);
      if(m_n == 0 || d != m_days[m_n - 1].date)
        {
         FinalizeLast();
         StartDay(d);
        }
      int i = m_n - 1;
      m_days[i].m1_bars++;
      int sod = (int)(b.time - d);
      if(sod >= BTB_REF_FROM_SEC && sod < BTB_REF_TO_SEC)
        {
         if(m_nSamples >= ArraySize(m_samples))
            ArrayResize(m_samples, m_nSamples + 1, 1024);
         m_samples[m_nSamples++] = spreadPts;
        }
      if(m_days[i].status == BTB_DAY_PENDING && b.time >= m_days[i].session_start)
        {
         if((double)spreadPts <= BTB_RESUME_MULT * m_days[i].ref)
            m_days[i].run++;
         else
            m_days[i].run = 0;
         datetime closeT = b.time + 60;
         if(m_days[i].run >= BTB_RESUME_BARS && closeT <= d + BTB_NY_START_SEC)
           {
            m_days[i].status = BTB_DAY_NORMAL;
            m_days[i].resume = closeT;
           }
         else
            if(closeT >= d + BTB_NY_START_SEC)
              {
               m_days[i].status = BTB_DAY_ABNORMAL;
               m_days[i].resume = d + BTB_NY_START_SEC;
              }
        }
     }

   //--- End of data: the last day is complete.
   void              Finish(void)
     {
      if(m_finished)
         return;
      FinalizeLast();
      m_finished = true;
     }

   int               Find(const datetime d) const
     {
      for(int i = m_n - 1; i >= 0; i--)
        {
         if(m_days[i].date == d)
            return i;
         if(m_days[i].date < d)
            break;
        }
      return -1;
     }

   //--- ENUM_BTB_DAY_STATUS of broker date d, or -1 when the date has no M1 bar.
   int               Status(const datetime d) const
     {
      int i = Find(d);
      return i < 0 ? -1 : m_days[i].status;
     }

   //--- ResumeTime(d) once decided (NORMAL/ABNORMAL), else 0.
   datetime          ResumeOf(const datetime d) const
     {
      int i = Find(d);
      if(i < 0 || (m_days[i].status != BTB_DAY_NORMAL && m_days[i].status != BTB_DAY_ABNORMAL))
         return 0;
      return m_days[i].resume;
     }

   //--- Window membership of a breakout candle of broker day d that closes at closeT.
   void              Window(const datetime d, const datetime closeT, bool &inFull, bool &inNy) const
     {
      inFull = false;
      inNy = false;
      int i = Find(d);
      if(i < 0)
         return;
      int st = m_days[i].status;
      if(st == BTB_DAY_WARMUP || st == BTB_DAY_NO_SESSION)
         return;
      datetime r = 0;
      if(st == BTB_DAY_PENDING)
         r = (closeT >= d + BTB_NY_START_SEC ? (datetime)(d + BTB_NY_START_SEC) : (datetime)0);
      else
         r = m_days[i].resume;
      if(r == 0)
         return;
      inFull = (closeT >= r && closeT < d + BTB_LATE_BLOCK_SEC && m_sched.IsInSession(closeT));
      inNy = (inFull && closeT >= d + BTB_NY_START_SEC);
     }

   int               DayCount(void) const { return m_n; }
   datetime          DayDate(const int i) const { return m_days[i].date; }
   datetime          DaySessionStart(const int i) const { return m_days[i].session_start; }
   bool              DayHasRef(const int i) const { return m_days[i].has_ref; }
   double            DayRef(const int i) const { return m_days[i].ref; }
   int               DayRefN(const int i) const { return m_days[i].ref_n; }
   datetime          DayRefDate(const int i) const { return m_days[i].ref_date; }
   int               DayStatus(const int i) const { return m_days[i].status; }
   datetime          DayResume(const int i) const { return m_days[i].resume; }
   int               CountStatus(const int st) const
     {
      int c = 0;
      for(int i = 0; i < m_n; i++)
         if(m_days[i].status == st)
            c++;
      return c;
     }

   string            CsvHeader(void) const
     {
      return "date,weekday,session_start,ref_date,ref_spread_pts,ref_samples,resume_time,ny_start,status,m1_bars";
     }

   string            CsvRow(const int i) const
     {
      bool known = (m_days[i].status == BTB_DAY_NORMAL || m_days[i].status == BTB_DAY_ABNORMAL);
      datetime ny = m_days[i].date + BTB_NY_START_SEC;
      if(m_days[i].resume > ny)
         ny = m_days[i].resume;
      return TRE_IsoDate(m_days[i].date) + "," + TRE_WeekdayName(TRE_DayOfWeek(m_days[i].date)) + "," +
             (m_days[i].session_start > 0 ? TRE_IsoTime(m_days[i].session_start) : "") + "," +
             (m_days[i].has_ref ? TRE_IsoDate(m_days[i].ref_date) : "") + "," +
             (m_days[i].has_ref ? DoubleToString(m_days[i].ref, 1) : "NA") + "," +
             IntegerToString(m_days[i].ref_n) + "," +
             (known ? TRE_IsoTime(m_days[i].resume) : "") + "," +
             (known ? TRE_IsoTime(ny) : "") + "," +
             BTB_DayStatusName(m_days[i].status) + "," + IntegerToString(m_days[i].m1_bars);
     }

   //--- btb_days.csv (UTF-8, LF). Returns false if the file cannot be opened.
   bool              WriteCsv(const string path) const
     {
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      BTB_WriteLine(h, CsvHeader());
      for(int i = 0; i < m_n; i++)
         BTB_WriteLine(h, CsvRow(i));
      FileClose(h);
      return true;
     }
  };

#endif // BTB_WINDOW_MQH
//+------------------------------------------------------------------+
