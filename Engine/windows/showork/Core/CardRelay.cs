using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// 工作卡片自動轉送秘書（Mac 版 Sources/ShoWorkCore/CardRelay.swift 的移植）。
// 任何 session 跑 showork card，看板就把卡片內容以【工作回報】送給現任秘書（走派工回報同一條 Peer 路）。
//   • 秘書自己的卡不轉（迴圈）；秘書不在線就不送、也不堆積（那段期間的卡記成已看過）
//   • 節流：同一 session 60 秒內只送一次（期間的新卡等時間到送最後一張）；內容沒變不重送
//   • 看板剛啟動時現有的卡當成已看過，不一次灌給秘書
//   • 設定 captain.relayCards（預設開；Windows 在 board\prefs.json）
// Mac 的狀態放在看板行程的記憶體裡；Windows 由 `showork tick` 每次跑一輪，狀態存在 board\relay-state.json（agent 啟動時 --fresh 重來）。

static class CardRelay
{
    public const string SettingKey = "captain.relayCards";
    public static readonly TimeSpan MinInterval = TimeSpan.FromSeconds(60);
    /// 太舊的卡不轉（看板重開、秘書剛回來時不翻舊帳）
    public static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(10);

    public sealed class State
    {
        public Dictionary<string, string> SentKey = new();     // sessionId → 上次送出（或看過）的內容
        public Dictionary<string, DateTime> SentAt = new();
        public bool Seeded;
        public Dictionary<string, string> SentAsk = new();     // sessionId → 上次送出（或看過）的問題與選項

        public JsonObject ToJson() => new()
        {
            ["seeded"] = Seeded,
            ["sentKey"] = new JsonObject(SentKey.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value))),
            ["sentAt"] = new JsonObject(SentAt.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)HookJson.Iso(kv.Value)))),
            ["sentAsk"] = new JsonObject(SentAsk.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value))),
        };

        public static State From(JsonNode? o)
        {
            var s = new State { Seeded = o.Bool("seeded") };
            if (o?["sentKey"] is JsonObject k) foreach (var kv in k) if (kv.Value.Str0() is { } v) s.SentKey[kv.Key] = v;
            if (o?["sentAt"] is JsonObject a) foreach (var kv in a) if (HookJson.ParseIso(kv.Value.Str0()) is { } d) s.SentAt[kv.Key] = d;
            if (o?["sentAsk"] is JsonObject q) foreach (var kv in q) if (kv.Value.Str0() is { } v) s.SentAsk[kv.Key] = v;
            return s;
        }

        public void Mark(string sid, CardReport r)
        {
            var k = Key(r);
            if (AskKey(r) is { } a) SentAsk[sid] = a; else if (SentKey.GetValueOrDefault(sid) != k) SentAsk.Remove(sid);
            SentKey[sid] = k;
        }
        /// 送過了：內容一樣，而且沒有新的問題（問題從無到有、文字或選項改了＝要再送）
        public bool Seen(string sid, CardReport r) =>
            SentKey.GetValueOrDefault(sid) == Key(r) && (AskKey(r) is not { } a || a == SentAsk.GetValueOrDefault(sid));
    }

    static string? Str0(this JsonNode? n) => n is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.String ? v.GetValue<string>() : null;

    public sealed record Outgoing(string SessionId, string Text);

    /// 同一張卡（11-24 Keng）：同 doing、同狀態、同摘要就算重複；問題另外比（AskKey）
    public static string Key(CardReport r) => string.Join("\u001F", r.Kind ?? "", r.Status, r.Doing ?? "", r.Summary ?? "");
    static string? AskKey(CardReport r) => r.Ask == null ? null : string.Join("\u001F", new[] { r.Ask }.Concat(r.Options ?? new()));

    /// 這張卡要不要推給秘書：要秘書動手的才推（同 Mac 預設）；開工卡一律只進收件匣
    public static bool NeedsCaptain(CardReport r) => !r.IsStart && (r.Status is "review" or "blocked" || r.Ask != null);

    /// 這次要送哪些。captain＝現任秘書 sessionId（null 或不在線 ⇒ 不送，全部記成看過）
    public static List<Outgoing> Plan(Dictionary<string, CardReport> reports, string? captain, bool captainLive, State state, DateTime now, Func<string, CardReport, string> text)
    {
        if (!state.Seeded)
        {
            foreach (var (sid, r) in reports) state.Mark(sid, r);
            state.Seeded = true;
            return new();
        }
        var out_ = new List<Outgoing>();
        foreach (var sid in reports.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            var r = reports[sid];
            if (state.Seen(sid, r)) continue;
            // 派工單的做完／要你決定／卡住已經有【派工回報】（TaskRouter），不重複送
            bool routed = r.Task != null && r.Status != "working";
            if (captain == null || !captainLive || sid == captain || routed || now - r.At >= MaxAge || !NeedsCaptain(r))
            {
                state.Mark(sid, r);                        // 不送也不堆積
                continue;
            }
            // 等時間到再送最後一張
            if (state.SentAt.TryGetValue(sid, out var t) && now - t < MinInterval) continue;
            state.Mark(sid, r);
            state.SentAt[sid] = now;
            out_.Add(new Outgoing(sid, text(sid, r)));
        }
        return out_;
    }

    static string Cut(string s, int n = 300) => SwiftText.Count(s) > n ? SwiftText.Prefix(s, n) + "⋯" : s;

    /// 【工作回報】全文
    public static string Text(string name, string? project, CardReport r)
    {
        var h = $"【工作回報】{name}";
        if (!string.IsNullOrEmpty(project)) h += $"（{project}）";
        if (r.Doing != null) h += $"：{r.Doing}";
        var ls = new List<string> { h };
        var st = $"狀態 {r.Status}";
        if (r.Progress is { } p) st += $"・完成度 {p}%";
        if (r.Confidence is { } c) st += $"・信心 {c}%";
        ls.Add(st);
        if (r.Summary is { Length: > 0 } sm) ls.Add($"摘要：{Cut(sm)}");
        ls.Add("方法與工具：" + (r.How != null ? Cut(r.How) : "（沒寫 --how）"));
        if (r.Ask != null)
            ls.Add($"問使用者：{Cut(r.Ask)}" + ((r.Options ?? new()).Count == 0 ? "" : $"（選項：{string.Join("／", r.Options!)}）"));
        if (r.Report != null) ls.Add($"報告：{r.Report}");
        if (r.Task != null) ls.Add($"派工單：{r.Task}");
        ls.Add("（看板自動轉送，對方不等你回覆；有疑慮再 SendMessage 給它）");
        return string.Join("\n", ls);
    }
}
