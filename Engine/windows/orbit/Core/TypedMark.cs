using System.Text.Json;
using System.Text.RegularExpressions;

namespace Orbit42.Hooks;

/// 答案卡打進終端機的記號（同 Mac TypedMark.swift；11-28 待修⑥：Windows 打字路徑以前沒有這個，答案卡打進去會被 hook 當成鍵盤、當場放行）。
/// 看板打字之前寫，UserPromptSubmit 的 hook 看到就知道這句是卡片打的、不是鍵盤打的 ⇒ 不在 hook 判放行。
/// 綁 session 與內容、用一次就刪、10 分鐘過期。有記號只會「少做」放行；別的程序偽造它，頂多讓那一句不能放行。
public static class TypedMark
{
    public static readonly TimeSpan Ttl = TimeSpan.FromMinutes(10);
    public static string Dir => HookPaths.Env("ORBIT_TYPED_MARKS") ?? Path.Combine(HookPaths.Board, "captain", "typed");
    static string FileOf(string sid) => Path.Combine(Dir, sid + ".json");
    /// 比對用：拿掉所有空白（同 Mac TermAnswer.squash 的用意：換行、多空白不影響）
    public static string Squash(string? s) => Regex.Replace(s ?? "", @"\s+", "");
    static bool BadSid(string sid) => sid.Length == 0 || sid.Contains('/') || sid.Contains('\\') || sid.Contains("..");

    /// 寫好才能打字（寫不進去＝不打）。前一句的記號還沒用掉、內容不同：不蓋掉，這句不打
    public static bool Put(string sid, string text, DateTime? now = null)
    {
        if (BadSid(sid)) return false;
        var t = now ?? DateTime.UtcNow;
        try
        {
            Directory.CreateDirectory(Dir);
            var f = FileOf(sid);
            if (File.Exists(f))
            {
                if (Read(f) is { } m && t - m.At < Ttl && m.Text != Squash(text)) return false;
                File.Delete(f);
            }
            var json = JsonSerializer.Serialize(new Dictionary<string, string> { ["sid"] = sid, ["text"] = Squash(text), ["at"] = HookJson.Iso(t) });
            using var fs = new FileStream(f, FileMode.CreateNew, FileAccess.Write);
            using var w = new StreamWriter(fs);
            w.Write(json);
            return true;
        }
        catch { return false; }
    }

    /// 這句是不是卡片打的；是就把記號用掉。收成 [Pasted text] 的、前後多了字的也算（寧可嚴）
    public static bool Take(string sid, string? prompt, DateTime? now = null)
    {
        if (BadSid(sid)) return false;
        var f = FileOf(sid);
        if (!File.Exists(f) || Read(f) is not { } m || m.Sid != sid) return false;
        var t = now ?? DateTime.UtcNow;
        if (t - m.At >= Ttl) { TryDelete(f); return false; }
        var p = Squash(prompt);
        if (m.Text.Length == 0 || !(p.Contains(m.Text, StringComparison.Ordinal) || p.Contains("[Pastedtext#", StringComparison.Ordinal))) return false;
        TryDelete(f);
        return true;
    }

    record Mark(string Sid, string Text, DateTime At);
    static Mark? Read(string f)
    {
        try
        {
            var d = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(f));
            if (d == null || !d.TryGetValue("sid", out var s) || !d.TryGetValue("text", out var x) || !d.TryGetValue("at", out var a) || HookJson.ParseIso(a) is not { } at) return null;
            return new Mark(s, x, at);
        }
        catch { return null; }
    }
    static void TryDelete(string f) { try { File.Delete(f); } catch { } }
}
