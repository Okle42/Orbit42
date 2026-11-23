using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Orbit42;

/// 這台電腦登入了哪幾家 AI。Orbit42 不經手密碼或金鑰：只問各家 CLI（或讀 CLI 自己的「誰登入了」檔案），
/// 登入時在終端機跑那一家的官方登入。Mac Accounts.swift 的 Windows 版。
sealed class Provider
{
    public required string Id, Name, Company, Cli;
    public string? Login, Install;
    public bool Available = true, Installed, SignedIn;
    public string? Account, Plan;

    public JsonObject Json()
    {
        var o = new JsonObject { ["id"] = Id, ["name"] = Name, ["company"] = Company, ["installed"] = Installed, ["signedIn"] = SignedIn, ["available"] = Available };
        if (Account != null) o["account"] = Account;
        if (Plan != null) o["plan"] = Plan;
        if (Login != null) o["login"] = Login;
        if (Install != null) o["install"] = Install;
        return o;
    }
}

static class Accounts
{
    public static List<Provider> All() => new()
    {
        new() { Id = "claude", Name = "Claude", Company = "Anthropic", Cli = "claude", Login = "claude auth login",
                Install = "powershell -NoProfile -ExecutionPolicy Bypass -Command \"irm https://claude.ai/install.ps1 | iex\"" },
        new() { Id = "codex", Name = "ChatGPT", Company = "OpenAI", Cli = "codex", Login = "codex login", Install = "npm install -g @openai/codex" },
        // Antigravity CLI（2026-05 取代 Gemini CLI）沒有獨立的登入指令：第一次開就用 Google 登入
        new() { Id = "gemini", Name = "Gemini", Company = "Google", Cli = "agy", Login = "agy" },
        new() { Id = "grok", Name = "Grok", Company = "xAI", Cli = "grok", Available = false },
    };

    /// 背景跑：幾個查詢，什麼都不改
    public static List<Provider> Check()
    {
        var home = OrbitPaths.Home;
        var list = All();
        foreach (var p in list)
        {
            if (!p.Available) continue;
            p.Installed = Run($"where {p.Cli}").Length > 0;
            if (!p.Installed) continue;
            switch (p.Id)
            {
                case "claude":
                    try
                    {
                        using var d = JsonDocument.Parse(Run("claude auth status --json"));
                        var j = d.RootElement;
                        p.SignedIn = j.TryGetProperty("loggedIn", out var l) && l.ValueKind == JsonValueKind.True;
                        if (j.TryGetProperty("email", out var e)) p.Account = e.GetString();
                        if (j.TryGetProperty("subscriptionType", out var s) && s.GetString() is { Length: > 0 } st) p.Plan = char.ToUpperInvariant(st[0]) + st[1..];
                    }
                    catch { }
                    break;
                case "gemini":
                    try
                    {
                        using var d = JsonDocument.Parse(File.ReadAllText(Path.Combine(home, ".gemini", "google_accounts.json")));
                        if (d.RootElement.TryGetProperty("active", out var a) && a.GetString() is { Length: > 0 } acc) { p.SignedIn = true; p.Account = acc; }
                    }
                    catch { }
                    break;
                case "codex":
                    p.SignedIn = File.Exists(Path.Combine(home, ".codex", "auth.json"));
                    break;
            }
        }
        return list;
    }

    /// cmd /c（PATH 跟一般終端機一樣：npm 全域、%USERPROFILE%\.local\bin）
    static string Run(string cmd)
    {
        try
        {
            var psi = new ProcessStartInfo(Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe", $"/d /s /c \"{cmd}\"")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
              StandardOutputEncoding = System.Text.Encoding.UTF8 };
            foreach (var k in psi.Environment.Keys.Where(k => k == "CLAUDECODE" || k.StartsWith("CLAUDE_CODE_") && k != "CLAUDE_CODE_GIT_BASH_PATH").ToList()) psi.Environment.Remove(k);
            using var p = Process.Start(psi)!;
            var o = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(15000)) { try { p.Kill(true); } catch { } return ""; }
            return p.ExitCode == 0 ? o.Result.Trim() : "";
        }
        catch { return ""; }
    }
}
