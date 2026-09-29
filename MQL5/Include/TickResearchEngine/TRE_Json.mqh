//+------------------------------------------------------------------+
//| TRE_Json.mqh                                                     |
//| Minimal deterministic JSON writer, UTF-8 file output and SHA-256 |
//| used by reports and the DataManifest (roadmap 0A.6).             |
//+------------------------------------------------------------------+
#ifndef TRE_JSON_MQH
#define TRE_JSON_MQH

#define TRE_JSON_MAX_DEPTH 64

//+------------------------------------------------------------------+
//| Number formatting: fixed digits, trailing zeros stripped.        |
//| Non-finite values are written as null (JSON has no NaN/Inf).     |
//+------------------------------------------------------------------+
string TRE_NumStr(const double v, const int digits = 10)
  {
   if(!MathIsValidNumber(v))
      return "null";
   string s = DoubleToString(v, digits);
   if(StringFind(s, ".") >= 0)
     {
      int n = StringLen(s);
      while(n > 0 && StringGetCharacter(s, n - 1) == '0')
         n--;
      if(n > 0 && StringGetCharacter(s, n - 1) == '.')
         n--;
      s = StringSubstr(s, 0, n);
     }
   if(s == "-0")
      s = "0";
   return s;
  }

//+------------------------------------------------------------------+
//| ISO-8601 broker-server timestamp (no zone suffix: broker time).  |
//+------------------------------------------------------------------+
string TRE_IsoTime(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d", s.year, s.mon, s.day, s.hour, s.min, s.sec);
  }

string TRE_IsoTimeMsc(const long msc)
  {
   if(msc < 0)
      return "";
   return TRE_IsoTime((datetime)(msc / 1000)) + StringFormat(".%03d", (int)(msc % 1000));
  }

string TRE_IsoDate(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return StringFormat("%04d-%02d-%02d", s.year, s.mon, s.day);
  }

//+------------------------------------------------------------------+
class CTRE_Json
  {
private:
   string            m_buf;
   bool              m_first[TRE_JSON_MAX_DEPTH];
   int               m_depth;
   bool              m_afterKey;

   void              Sep(void)
     {
      if(m_afterKey)
        {
         m_afterKey = false;
         return;
        }
      if(m_depth > 0)
        {
         if(!m_first[m_depth - 1])
            m_buf += ",";
         m_first[m_depth - 1] = false;
        }
     }

public:
                     CTRE_Json(void) { Reset(); }

   void              Reset(void)
     {
      m_buf = "";
      m_depth = 0;
      m_afterKey = false;
     }

   static string     Escape(const string s)
     {
      string out = "";
      int n = StringLen(s);
      for(int i = 0; i < n; i++)
        {
         ushort c = StringGetCharacter(s, i);
         if(c == '"')
            out += "\\\"";
         else
            if(c == '\\')
               out += "\\\\";
            else
               if(c == '\n')
                  out += "\\n";
               else
                  if(c == '\r')
                     out += "\\r";
                  else
                     if(c == '\t')
                        out += "\\t";
                     else
                        if(c < 0x20)
                           out += StringFormat("\\u%04X", (int)c);
                        else
                           out += ShortToString(c);
        }
      return out;
     }

   void              BeginObject(void)
     {
      Sep();
      m_buf += "{";
      m_first[m_depth] = true;
      m_depth++;
     }
   void              EndObject(void)   { m_depth--; m_buf += "}"; }
   void              BeginArray(void)
     {
      Sep();
      m_buf += "[";
      m_first[m_depth] = true;
      m_depth++;
     }
   void              EndArray(void)    { m_depth--; m_buf += "]"; }

   void              Key(const string k)
     {
      Sep();
      m_buf += "\"" + Escape(k) + "\":";
      m_afterKey = true;
     }
   void              Str(const string v)                 { Sep(); m_buf += "\"" + Escape(v) + "\""; }
   void              Num(const double v, const int d = 10) { Sep(); m_buf += TRE_NumStr(v, d); }
   void              Int(const long v)                   { Sep(); m_buf += IntegerToString(v); }
   void              Bool(const bool v)                  { Sep(); m_buf += (v ? "true" : "false"); }
   void              Null(void)                          { Sep(); m_buf += "null"; }

   void              KStr(const string k, const string v)                 { Key(k); Str(v); }
   void              KNum(const string k, const double v, const int d = 10) { Key(k); Num(v, d); }
   void              KInt(const string k, const long v)                   { Key(k); Int(v); }
   void              KBool(const string k, const bool v)                  { Key(k); Bool(v); }
   void              KNull(const string k)                                { Key(k); Null(); }
   void              KObj(const string k)                                 { Key(k); BeginObject(); }
   void              KArr(const string k)                                 { Key(k); BeginArray(); }
   void              KTime(const string k, const datetime t)              { Key(k); Str(TRE_IsoTime(t)); }

   int               Depth(void) const { return m_depth; }
   string            Text(void) const  { return m_buf; }
  };

//+------------------------------------------------------------------+
//| UTF-8 bytes of a string without the terminating zero.            |
//+------------------------------------------------------------------+
int TRE_Utf8Bytes(const string text, uchar &bytes[])
  {
   ArrayResize(bytes, 0);
   if(StringLen(text) == 0)
      return 0;
   int n = StringToCharArray(text, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0 && bytes[n - 1] == 0)
      n--;
   ArrayResize(bytes, n);
   return n;
  }

string TRE_HexLower(const uchar &bytes[])
  {
   string s = "";
   int n = ArraySize(bytes);
   for(int i = 0; i < n; i++)
      s += StringFormat("%02x", bytes[i]);
   return s;
  }

string TRE_Sha256Hex(const string text)
  {
   uchar data[], key[], hash[];
   TRE_Utf8Bytes(text, data);
   if(CryptEncode(CRYPT_HASH_SHA256, data, key, hash) <= 0)
      return "";
   return TRE_HexLower(hash);
  }

//+------------------------------------------------------------------+
//| Writes exact UTF-8 bytes (no BOM) so the stored SHA-256 matches  |
//| the file on disk. Returns the hex digest, or "" on failure.      |
//+------------------------------------------------------------------+
string TRE_WriteUtf8File(const string path, const string text, const bool common = true)
  {
   uchar data[], key[], hash[];
   TRE_Utf8Bytes(text, data);
   int flags = FILE_WRITE | FILE_BIN | (common ? FILE_COMMON : 0);
   int h = FileOpen(path, flags);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("TRE: cannot open '%s' for writing (error %d)", path, GetLastError());
      return "";
     }
   if(ArraySize(data) > 0)
      FileWriteArray(h, data, 0, ArraySize(data));
   FileClose(h);
   if(CryptEncode(CRYPT_HASH_SHA256, data, key, hash) <= 0)
      return "";
   return TRE_HexLower(hash);
  }

#endif // TRE_JSON_MQH
//+------------------------------------------------------------------+
