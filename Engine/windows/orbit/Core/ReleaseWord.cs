using System.Text.RegularExpressions;

namespace Orbit42.Hooks;

/// 放行的暗號（Mac ReleaseWord.swift 的移植，Keng 11-25）：整句開頭「放行！」（全形半形驚嘆號）才算
static class ReleaseWord
{
    public const string How = "沒放行，請打：放行！單號，或放行！部署（要有驚嘆號，後面只能是一個單號或種類；語音聽寫通常沒有驚嘆號）";
    static readonly char[] Ws = { ' ', '\t', '\n', '\r', '\u3000' };

    /// none／latest／id／kind／bad，和後面的字
    public static (string Kind, string Value) Parse(string raw)
    {
        if (raw.IndexOfAny(new[] { '\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029' }) >= 0) return ("none", "");      // 整句單行才算
        var t = raw.Trim(Ws);
        if (t.Length < 3 || t[0] != '放' || t[1] != '行' || (t[2] != '！' && t[2] != '!')) return ("none", "");
        if (Peer.QuotesPeer(t) || t.Contains("<pasted_content", StringComparison.Ordinal) || t.Contains("[Pasted text", StringComparison.Ordinal)) return ("none", "");
        // 白名單：空、一個單號、一個種類詞；多一個字都不算
        var rest = t[3..].TrimStart(Blank).TrimEnd(Tail);
        if (rest.Length == 0) return ("latest", "");
        if (Regex.IsMatch(rest, "\\A[Bb][A-HJ-NP-Za-hj-np-z2-9]{4}\\z", RegexOptions.CultureInvariant)) return ("id", rest.ToUpperInvariant());
        return RuleOf(rest) is { } k ? ("kind", k) : ("bad", "「放行！」後面只能是一個單號或一個種類，多一個字都不算");
    }
    static readonly char[] Blank = { ' ', '\t', '\u3000' };
    static readonly char[] Tail = { ' ', '\t', '\u3000', '。', '.', '！', '!', '，', ',', '、', '；', ';', '~', '～' };
    /// 種類的固定清單（Mac ReleaseWord.swift 同一份）
    public static readonly (string Rule, string[] Words)[] Words =
    {
        ("GitHub 公開發言", new[] { "開 PR", "開 issue", "發 PR", "發 issue", "PR 留言", "issue 留言", "GitHub 留言", "發布", "create PR", "create issue" }),
        ("LINE 對外傳訊", new[] { "傳 LINE", "發 LINE", "用 LINE 通知", "LINE 通知" }),
        ("firebase 部署", new[] { "部署", "上線", "deploy" }),
        ("App 上傳", new[] { "上傳", "送審", "上架", "TestFlight" }),
    };
    static string? RuleOf(string rest)
    {
        var r = rest.ToLowerInvariant();
        foreach (var (rule, ws) in Words)
            if (ws.Any(w => r == w.ToLowerInvariant() || r == w.ToLowerInvariant().Replace(" ", ""))) return rule;
        return null;
    }
    public static bool Grants(string raw, string rule) => Parse(raw) is ("kind", var k) && rule.StartsWith(k, StringComparison.Ordinal);
    public static bool NearMiss(string raw) => Parse(raw).Kind == "none" && raw.Trim(Ws).StartsWith("放行", StringComparison.Ordinal);
}
