using System.Text.RegularExpressions;

namespace ShoWork.Hooks;

/// 放行的暗號（Mac ReleaseWord.swift 的移植，Keng 11-25）：整句開頭「放行！」（全形半形驚嘆號）才算
static class ReleaseWord
{
    public const string How = "要放行請用打的：放行！單號（要有驚嘆號；語音聽寫通常沒有）";
    static readonly char[] Ws = { ' ', '\t', '\n', '\r', '\u3000' };

    /// none／latest／id／kinds／bad，和後面的字
    public static (string Kind, string Value) Parse(string raw)
    {
        var t = raw.Trim(Ws);
        if (t.Length < 3 || t[0] != '放' || t[1] != '行' || (t[2] != '！' && t[2] != '!')) return ("none", "");
        if (Peer.QuotesPeer(t) || t.Contains("<pasted_content", StringComparison.Ordinal) || t.Contains("[Pasted text", StringComparison.Ordinal)) return ("none", "");
        var rest = t[3..].Trim(Ws);
        if (rest.Length == 0) return ("latest", "");
        if (CaptainInbox.IsQuestion(rest)) return ("bad", "這是問句");
        if (CaptainInbox.IsNegated(rest)) return ("bad", "句子裡有否定或延後的字");
        if (rest.IndexOfAny(new[] { '\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029' }) >= 0) return ("bad", "只能一行");
        return Regex.IsMatch(rest, "^[Bb][A-Za-z2-9]{4}\\z", RegexOptions.CultureInvariant) ? ("id", rest.ToUpperInvariant()) : ("kinds", rest);
    }
    public static bool Grants(string raw, string rule) => Parse(raw) is ("kinds", var t) && CaptainInbox.Authorizes(t, rule);
    public static bool NearMiss(string raw) => Parse(raw).Kind == "none" && raw.Trim(Ws).StartsWith("放行", StringComparison.Ordinal);
}
