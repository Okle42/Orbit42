using System.Text.Json;
using System.Text.Json.Nodes;

namespace Orbit42;

static class OrbitPaths
{
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    /// %LOCALAPPDATA%\Orbit42（log、重開後衛星回來的紀錄、WebView2 資料）
    public static string Support
    {
        get { var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Orbit42"); Directory.CreateDirectory(d); return d; }
    }
    /// 登入畫面、衛星終端機網頁（Orbit42 的 Web\，跟 Mac Resources/OrbitWeb 同一份）
    public static string? WebDir
    {
        get
        {
            foreach (var d in new[] { Path.Combine(AppContext.BaseDirectory, "OrbitWeb"), Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "Web")) })
                if (File.Exists(Path.Combine(d, "index.html"))) return d;
            return null;
        }
    }
}

/// 衛星裡跑哪一家的 AI（各家官方 CLI，登入、工具、更新都是它們自己的）。Mac Satellites.swift 的 Brain
enum Brain { Claude, Codex, Gemini }

static class Brains
{
    public static string Id(this Brain b) => b switch { Brain.Codex => "codex", Brain.Gemini => "gemini", _ => "claude" };
    public static string Label(this Brain b) => b switch { Brain.Codex => "ChatGPT", Brain.Gemini => "Gemini", _ => "Claude" };
    public static Brain Parse(string? s) => s switch { "codex" => Brain.Codex, "gemini" => Brain.Gemini, _ => Brain.Claude };

    /// 11-23 Keng：所有 AI 都用最高權限開（跟 ccc 一樣）；Claude 衛星關掉 flightdeck 面板（球體已經有額度／溫度）
    public static string Command(this Brain b) => b switch
    {
        Brain.Gemini => "agy --dangerously-skip-permissions",
        Brain.Codex => "codex --dangerously-bypass-approvals-and-sandbox",
        _ => $"claude --dangerously-skip-permissions --settings \"{SatSettings()}\"",
    };

    /// Windows 的 cmd 不認單引號：Claude 衛星的 --settings 改成一個 JSON 檔（Mac 是直接帶 JSON 字串）
    static string SatSettings()
    {
        var f = Path.Combine(OrbitPaths.Support, "satellite-settings.json");
        try { File.WriteAllText(f, "{\"enabledPlugins\":{\"flightdeck@claude-flightdeck\":false}}"); } catch { }
        return f;
    }
}

/// 一顆衛星＝一個真終端機（ConPTY）＋裡面在跑的東西
sealed class Satellite
{
    public string Id { get; }
    public string Name { get; set; }
    public Brain Brain { get; }
    public string Cwd { get; }
    public string Command { get; }
    public ConPty? Pty { get; set; }
    public int? Exited { get; set; }
    public DateTime LastOutput { get; private set; } = DateTime.MinValue;
    readonly object gate = new();
    byte[] scrollback = Array.Empty<byte>();       // 小視窗重新打開時重播
    readonly MemoryStream buf = new();

    public Satellite(string id, string name, Brain brain, string cwd, string command)
    { Id = id; Name = name; Brain = brain; Cwd = cwd; Command = command; }

    public void Append(byte[] d)
    {
        lock (gate)
        {
            buf.Write(d);
            const int cap = 2 * 1024 * 1024;
            if (buf.Length > cap * 2)
            {
                var all = buf.ToArray();
                buf.SetLength(0); buf.Write(all, all.Length - cap, cap);
            }
            LastOutput = DateTime.UtcNow;
        }
    }
    public byte[] Snapshot()
    {
        lock (gate)
        {
            var all = buf.ToArray();
            return all.Length > 2 * 1024 * 1024 ? all[^(2 * 1024 * 1024)..] : all;
        }
    }

    public bool Busy => Exited == null && Pty != null && DateTime.UtcNow - LastOutput < TimeSpan.FromSeconds(2.5);

    public JsonObject Json()
    {
        var state = Exited != null ? "exited" : Pty == null ? "idle" : DateTime.UtcNow - LastOutput < TimeSpan.FromSeconds(3) ? "busy" : "open";
        var o = new JsonObject { ["id"] = Id, ["name"] = Name, ["brain"] = Brain.Id(), ["brainLabel"] = Brain.Label(), ["cwd"] = Cwd, ["state"] = state };
        if (Exited is { } e) o["exit"] = e;
        return o;
    }
}

/// ~/.claude/sessions/<pid>.json（重開後用 --resume 接回同一段對話）
sealed record SessionFile(int Pid, string SessionId, string Cwd)
{
    public static List<SessionFile> All()
    {
        var dir = Path.Combine(OrbitPaths.Home, ".claude", "sessions");
        var list = new List<SessionFile>();
        if (!Directory.Exists(dir)) return list;
        foreach (var f in Directory.GetFiles(dir, "*.json"))
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(f));
                var r = doc.RootElement;
                if (r.TryGetProperty("pid", out var p) && r.TryGetProperty("sessionId", out var s))
                    list.Add(new SessionFile(p.GetInt32(), s.GetString() ?? "", r.TryGetProperty("cwd", out var c) ? c.GetString() ?? "" : ""));
            }
            catch { }
        return list;
    }
}
