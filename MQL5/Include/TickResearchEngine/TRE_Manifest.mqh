//+------------------------------------------------------------------+
//| TRE_Manifest.mqh                                                 |
//| Exact Inputs record (Run Card) and run-output package writer     |
//| used by the DataManifest (roadmap 0A.6, Phase 1 Gate).           |
//+------------------------------------------------------------------+
#ifndef TRE_MANIFEST_MQH
#define TRE_MANIFEST_MQH

#include "TRE_Types.mqh"
#include "TRE_Json.mqh"

#define TRE_MANIFEST_SCHEMA_VERSION "tre.datamanifest.v1"
#define TRE_OUTPUT_ROOT             "TRE"

//+------------------------------------------------------------------+
//| Every input with its value and roadmap default. Non-default      |
//| inputs are listed explicitly so the Run Card shows exactly what  |
//| changed and everything else stays at the roadmap default.        |
//+------------------------------------------------------------------+
class CTRE_InputRecorder
  {
private:
   string            m_name[];
   string            m_value[];
   string            m_default[];

public:
   void              Clear(void)
     {
      ArrayResize(m_name, 0);
      ArrayResize(m_value, 0);
      ArrayResize(m_default, 0);
     }
   void              Add(const string name, const string value, const string roadmapDefault)
     {
      int n = ArraySize(m_name);
      ArrayResize(m_name, n + 1);
      ArrayResize(m_value, n + 1);
      ArrayResize(m_default, n + 1);
      m_name[n] = name;
      m_value[n] = value;
      m_default[n] = roadmapDefault;
     }
   void              AddBool(const string name, const bool value, const bool roadmapDefault)
     { Add(name, value ? "true" : "false", roadmapDefault ? "true" : "false"); }
   void              AddNum(const string name, const double value, const double roadmapDefault)
     { Add(name, TRE_NumStr(value), TRE_NumStr(roadmapDefault)); }
   void              AddInt(const string name, const long value, const long roadmapDefault)
     { Add(name, IntegerToString(value), IntegerToString(roadmapDefault)); }

   int               NonDefaultCount(void) const
     {
      int c = 0;
      for(int i = 0; i < ArraySize(m_name); i++)
         if(m_value[i] != m_default[i])
            c++;
      return c;
     }

   void              WriteJson(CTRE_Json &j) const
     {
      j.BeginObject();
      j.KArr("inputs");
      for(int i = 0; i < ArraySize(m_name); i++)
        {
         j.BeginObject();
         j.KStr("name", m_name[i]);
         j.KStr("value", m_value[i]);
         j.KStr("roadmap_default", m_default[i]);
         j.KBool("is_default", m_value[i] == m_default[i]);
         j.EndObject();
        }
      j.EndArray();
      j.KArr("non_default_inputs");
      for(int i = 0; i < ArraySize(m_name); i++)
         if(m_value[i] != m_default[i])
            j.Str(m_name[i]);
      j.EndArray();
      j.EndObject();
     }

   string            RunCardText(void) const
     {
      string s = "# Exact Inputs — every input; non-default values are marked with *\n";
      for(int i = 0; i < ArraySize(m_name); i++)
         s += (m_value[i] != m_default[i] ? "* " : "  ") + m_name[i] + " = " + m_value[i] +
              (m_value[i] != m_default[i] ? "    (roadmap default: " + m_default[i] + ")" : "") + "\n";
      return s;
     }
  };

//+------------------------------------------------------------------+
//| Output folder Common\Files\TRE\<ExperimentId>\ with a checksum   |
//| index of every written file.                                     |
//+------------------------------------------------------------------+
class CTRE_RunOutput
  {
private:
   string            m_dir;
   string            m_files[];
   string            m_sha[];
   int               m_failures;

public:
   void              Init(const string experimentId)
     {
      m_dir = TRE_OUTPUT_ROOT + "\\" + experimentId + "\\";
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
      for(int i = 0; i < ArraySize(m_files); i++)
         if(m_files[i] == fileName)
           {
            m_sha[i] = sha;
            return sha;
           }
      int n = ArraySize(m_files);
      ArrayResize(m_files, n + 1);
      ArrayResize(m_sha, n + 1);
      m_files[n] = fileName;
      m_sha[n] = sha;
      return sha;
     }

   //--- Indexes a file written directly (e.g. streamed ledgers) by hashing it from disk.
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
      for(int i = 0; i < ArraySize(m_files); i++)
         if(m_files[i] == fileName)
           {
            m_sha[i] = sha;
            return sha;
           }
      int n = ArraySize(m_files);
      ArrayResize(m_files, n + 1);
      ArrayResize(m_sha, n + 1);
      m_files[n] = fileName;
      m_sha[n] = sha;
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

//--- Experiment identifiers become folder names: letters, digits, '-', '_', '.'.
bool TRE_ValidateExperimentId(const string id, string &error)
  {
   error = "";
   int n = StringLen(id);
   if(n == 0 || n > 64)
     {
      error = "ExperimentId must be 1..64 characters";
      return false;
     }
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(id, i);
      bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
      if(!ok)
        {
         error = "ExperimentId may contain only letters, digits, '-', '_' and '.'";
         return false;
        }
     }
   return true;
  }

#endif // TRE_MANIFEST_MQH
//+------------------------------------------------------------------+
