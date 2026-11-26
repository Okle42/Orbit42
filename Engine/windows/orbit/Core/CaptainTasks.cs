using System.Globalization;
using System.Text.Json.Nodes;

namespace Orbit42.Hooks;

// 秘書派工（Mac 版 Sources/Orbit42Core/Captain.swift 的 CaptainTask／Roster／Captain，以及 CaptainLink.swift 的合併預告、巡檢）。
//   board\captain.json        誰是秘書
//   board\roster.json         名冊快照（Windows：Orbit42.Engine.Win 的 HandoverClear 迴圈每 3 秒寫；orbit roster 讀）
//   board\tasks\<id>.json     派工單（orbit task add 建；對方 orbit card --task 回報時更新）

/// 一張派工單
sealed class CaptainTask
{
    public static readonly string[] States = { "sent", "working", "review", "done", "blocked", "cancelled" };

    public string Id = "";
    public string From = "";             // 秘書的 sessionId
    public string To = "";               // 對方的 session 名（SendMessage 的地址）
    public string? ToSession;            // 派出當下對方的 sessionId
    public string? Project;
    public string Text = "";
    public string State = "sent";
    public string? Summary;              // 對方最後一次回報的一句話
    public string? Ask;
    public DateTime CreatedAt;
    public DateTime UpdatedAt;
    public string? ThenTo;               // 做完（done）後自動交給誰（接力）
    public string? ThenText;             // 交給下一棒的任務
    public string? FollowUp;             // 已經開出的下一棒單號
    public string? After;                // 這張是哪張單的下一棒
    public string? Notified;             // 已經通知秘書到哪個狀態（同一個狀態只通知一次）
    public string? SendError;            // 直送失敗的原因

    public static string Title(string state) => state switch
    {
        "sent" => "已派出", "working" => "做事中", "review" => "要你看", "done" => "完成", "blocked" => "卡住", "cancelled" => "已取消", var s => s,
    };
    /// 還沒結束（秘書要繼續追）
    public bool IsOpen => State is "sent" or "working" or "blocked";

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["from"] = From, ["to"] = To };
        o.Put("toSession", ToSession); o.Put("project", Project);
        o["text"] = Text; o["state"] = State;
        o.Put("summary", Summary); o.Put("ask", Ask);
        o["createdAt"] = HookJson.Iso(CreatedAt); o["updatedAt"] = HookJson.Iso(UpdatedAt);
        o.Put("thenTo", ThenTo); o.Put("thenText", ThenText); o.Put("followUp", FollowUp); o.Put("after", After);
        o.Put("notified", Notified); o.Put("sendError", SendError);
        return o;
    }

    public static CaptainTask? Parse(JsonNode? o)
    {
        if (o.Str("id") is not { } id || o.Str("from") is not { } from || o.Str("to") is not { } to || o.Str("text") is not { } text
            || o.Str("state") is not { } st || !States.Contains(st) || o.Date("createdAt") is not { } c || o.Date("updatedAt") is not { } u) return null;
        return new CaptainTask
        {
            Id = id, From = from, To = to, ToSession = o.Str("toSession"), Project = o.Str("project"), Text = text, State = st, Summary = o.Str("summary"),
            Ask = o.Str("ask"), CreatedAt = c, UpdatedAt = u, ThenTo = o.Str("thenTo"), ThenText = o.Str("thenText"), FollowUp = o.Str("followUp"),
            After = o.Str("after"), Notified = o.Str("notified") is { } n && States.Contains(n) ? n : null, SendError = o.Str("sendError"),
        };
    }
}

/// 名冊的一列
sealed class RosterEntry
{
    public string Name = "";             // SendMessage 用的地址
    public string SessionId = "";
    public int Pid;
    public string? Kind;
    public string Project = "";
    public string? Root;                 // 專案資料夾（git 根目錄）
    public string Column = "todo";       // todo／active／review／done／stuck
    public string Reason = "";
    public string Title = "";
    public string? Summary;
    public int? Ctx;
    public int? CtxTokens;               // 交接門檻看這個
    public DateTime? LastActivity;
    public bool Captain;
    public List<string> SameProject = new();   // 同專案的其他 session 名（重工警告）
    public string? Handover;             // 「已收尾待 /clear」⋯

    public static string ColumnTitle(string c) => c switch
    {
        "todo" => "待辦", "active" => "進行中", "review" => "待審", "done" => "完成", "stuck" => "卡住", var s => s,
    };

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["name"] = Name, ["sessionId"] = SessionId, ["pid"] = Pid };
        o.Put("kind", Kind);
        o["project"] = Project;
        o.Put("root", Root);
        o["column"] = Column; o["reason"] = Reason; o["title"] = Title;
        o.Put("summary", Summary); o.Put("ctx", Ctx); o.Put("ctxTokens", CtxTokens); o.Put("lastActivity", LastActivity);
        o["captain"] = Captain;
        o["sameProject"] = HookJson.Arr(SameProject);
        o.Put("handover", Handover);
        return o;
    }

    public static RosterEntry? From(JsonNode? o)
    {
        if (o.Str("name") is not { } n || o.Str("sessionId") is not { } sid || o.Str("project") is not { } p || o.Str("column") is not { } col) return null;
        return new RosterEntry
        {
            Name = n, SessionId = sid, Pid = o.Int("pid") ?? 0, Kind = o.Str("kind"), Project = p, Root = o.Str("root"), Column = col,
            Reason = o.Str("reason") ?? "", Title = o.Str("title") ?? "", Summary = o.Str("summary"), Ctx = o.Int("ctx"), CtxTokens = o.Int("ctxTokens"),
            LastActivity = o.Date("lastActivity"), Captain = o.Bool("captain"), SameProject = o.Strs("sameProject"), Handover = o.Str("handover"),
        };
    }
}

sealed class Roster
{
    public DateTime At;
    public string? Captain;              // 秘書的 sessionId
    public List<RosterEntry> Entries = new();

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["at"] = HookJson.Iso(At) };
        o.Put("captain", Captain);
        o["entries"] = new JsonArray(Entries.Select(e => (JsonNode?)e.ToJson()).ToArray());
        return o;
    }

    public static Roster? From(JsonNode? o) => o.Date("at") is { } at && o?["entries"] is JsonArray es
        ? new Roster { At = at, Captain = o.Str("captain"), Entries = es.Select(RosterEntry.From).OfType<RosterEntry>().ToList() } : null;
}

/// 派工的規則（Mac 的 enum Captain；Windows 看板那邊已經有一個 Orbit42.Captain，這裡叫 Dispatch 免得撞名）
static class Dispatch
{
    /// 派工單號：T 加上月日時分秒（同一秒派兩張就再加一碼）
    public static string NewId(DateTime now, ISet<string> existing)
    {
        var b = "T" + now.ToLocalTime().ToString("MMddHHmmss", CultureInfo.InvariantCulture);
        if (!existing.Contains(b)) return b;
        for (int i = 2; ; i++) if (!existing.Contains($"{b}-{i}")) return $"{b}-{i}";
    }

    /// 秘書要用 SendMessage 送給對方的全文（附上回報方式）
    public static string Message(CaptainTask t, string orbit)
    {
        var lines = t.Text.Trim().Split('\n');
        var rest = string.Join("\n", lines.Skip(1));
        return $"【秘書派工 {t.Id}】{lines.FirstOrDefault() ?? ""}\n"
            + (rest.Length == 0 ? "" : rest + "\n")
            + $"\n回報方式：這件事每一輪的 orbit card 都加上 --task {t.Id}（例如 \"{orbit}\" card --task {t.Id} --status done --progress 100 --confidence 80 --summary \"…\"）。要使用者決定的用 --ask；卡住用 --status blocked 並說原因。同一個 repo 的規則（不准 push、客戶案要審）照舊遵守。";
    }

    /// 秘書要知道的狀態：做完、要使用者決定、卡住（做事中不吵）
    public static bool ShouldNotify(CaptainTask t) => t.State is "done" or "review" or "blocked" && t.Notified != t.State;

    static string OneLine(string s, int n) => SwiftText.Prefix(s.Replace("\n", " "), n);

    /// 傳給秘書的回報
    public static string ReportText(CaptainTask t, CaptainTask? followUp = null)
    {
        var s = $"【派工回報 {t.Id}】{t.To}：{CaptainTask.Title(t.State)}" + (t.Summary != null ? $"——{t.Summary}" : "");
        if (t.Ask != null) s += $"\n要使用者決定：{t.Ask}";
        s += $"\n原任務：{OneLine(t.Text, 120)}";
        if (followUp != null) s += $"\n已自動接力：{followUp.Id} 交給 {followUp.To}";
        return s;
    }

    /// 接力：A 做完 ⇒ 開給 B 的單（附上 A 的回報）
    public static CaptainTask? NextLeg(CaptainTask t, string id, DateTime now)
    {
        if (t.State != "done" || t.FollowUp != null || t.ThenTo is not { } to || t.ThenText is not { } text) return null;
        var full = text + $"\n（前一棒 {t.To} 已完成「{OneLine(t.Text, 80)}」，回報：{t.Summary ?? "沒有摘要"}）";
        return new CaptainTask { Id = id, From = t.From, To = to, Text = full, CreatedAt = now, UpdatedAt = now, After = t.Id };
    }

    /// 建單＋直送；送不出去時單子照樣留著（sendError），讓呼叫端改走 SendMessage
    public static (CaptainTask Task, string? Error) Send(CaptainTask t, string orbit, string fromName = "Orbit42")
    {
        var target = Peer.Find(t.ToSession ?? t.To) ?? Peer.Find(t.To);
        if (target != null) { t.ToSession = target.SessionId; t.To = target.Name ?? t.To; }
        var replyTo = Peer.Find(t.From)?.MessagingSocketPath;
        string? err = target == null ? $"找不到開著的 session「{t.To}」" : Peer.Send(target, Message(t, orbit), fromName, replyTo).Error;
        t.SendError = err;
        CaptainStore.Save(t);
        return (t, err);
    }
}

static partial class CaptainStore
{
    public static List<CaptainTask> Tasks() =>
        HookJson.Files(TasksDir, "*.json").Select(f => CaptainTask.Parse(HookJson.ReadObject(f))).OfType<CaptainTask>().OrderBy(t => t.CreatedAt).ToList();

    public static CaptainTask? Task(string id) => CaptainTask.Parse(HookJson.ReadObject(Path.Combine(TasksDir, id + ".json")));

    public static bool Save(CaptainTask t) => HookJson.WriteAtomic(Path.Combine(TasksDir, t.Id + ".json"), HookJson.Text(t.ToJson()));

    public static Roster? Roster() => Hooks.Roster.From(HookJson.ReadObject(RosterFile));

    public static void SaveRoster(Roster r) => HookJson.WriteAtomic(RosterFile, HookJson.Text(r.ToJson()));
}

/// 合併預告、巡檢（Mac CaptainLink.swift 的 noticeText／dueNotices／alarm）
static partial class CaptainLink
{
    /// 要不要立刻推給秘書：只有擋下等放行的；開工卡和不擋的預告只寫收件匣（11-24 Keng）
    public static bool PushNow(InboxItem i) => i.Kind == "block" && !i.Delivered;

    // ③ 秘書鬧鐘
    public const string AlarmKey = "captain.alarmMinutes";
    public static readonly TimeSpan IdleAfter = TimeSpan.FromMinutes(30);

    /// 名冊一行摘要＋指紋（沒變化就只送一行）
    public static (string Text, string Sig) Alarm(Roster r, int pending, DateTime now)
    {
        var crew = r.Entries.Where(e => !e.Captain).OrderBy(e => e.Name, StringComparer.Ordinal).ToList();
        var idle = crew.Where(e => e.LastActivity is not { } t || now - t > IdleAfter).Select(e => e.Name).ToList();
        var ctx = crew.Select(e => $"{e.Name} {(e.Ctx is { } c ? $"{c}%" : "–")}").ToList();
        // Swift 的整數除法往 0 取整：(-10)/10 = -1
        var b = string.Join(",", crew.Select(e => $"{e.Name}:{(e.Ctx ?? -10) / 10}")) + "|" + string.Join(",", idle) + $"|{pending}";
        var wrapped = crew.Where(e => e.Handover != null).Select(e => $"{e.Name}（{e.Handover}）").ToList();
        var sig = b + "|" + string.Join(",", wrapped);
        var t = $"【巡檢時間】在線 {crew.Count} 人（不含秘書）";
        if (ctx.Count > 0) t += "；ctx：" + string.Join("、", ctx);
        t += "；閒置超過 30 分鐘：" + (idle.Count == 0 ? "沒有" : string.Join("、", idle));
        if (wrapped.Count > 0) t += "；已收尾、還沒 /clear：" + string.Join("、", wrapped);
        if (pending > 0) t += $"；收件匣未處理 {pending} 則（orbit captain 看）";
        t += "\n（看 orbit roster、orbit tasks、orbit b1 read）";
        return (t, sig);
    }

    /// 要秘書處理的事（每項一句）＋指紋；空的＝不用推。開工卡、不擋的預告不算
    public static (List<string> Reasons, string Sig) AlarmActions(Roster r, ISet<string> openTaskSessions, List<InboxItem> inbox, int ctxLimit, DateTime now)
    {
        var crew = r.Entries.Where(e => !e.Captain).OrderBy(e => e.Name, StringComparer.Ordinal).ToList();
        var stuck = crew.Where(e => e.Column == "stuck").Select(e => e.Name).ToList();
        var review = crew.Where(e => e.Column == "review").Select(e => e.Name).ToList();
        var full = crew.Where(e => e.Handover == null && (e.CtxTokens ?? 0) >= ctxLimit).ToList();
        var idle = crew.Where(e => openTaskSessions.Contains(e.SessionId) && (e.LastActivity is not { } t || now - t > IdleAfter)).Select(e => e.Name).ToList();
        var open = inbox.Where(i => i.Kind == "block" && i.Acked == null && i.Released == null && now - i.At < TimeSpan.FromDays(1)).Select(i => i.Id).ToList();
        var out_ = new List<string>();
        if (stuck.Count > 0) out_.Add("卡住：" + string.Join("、", stuck));
        if (review.Count > 0) out_.Add("待審／等回答：" + string.Join("、", review));
        if (full.Count > 0) out_.Add($"ctx 到門檻 {ctxLimit / 1000}k：" + string.Join("、", full.Select(e => $"{e.Name} {(e.CtxTokens ?? 0) / 1000}k")));
        if (idle.Count > 0) out_.Add("有派工單卻閒置超過 30 分鐘：" + string.Join("、", idle));
        if (open.Count > 0) out_.Add($"擋下等放行 {open.Count} 則：" + string.Join("、", open));
        var sig = string.Join("|", string.Join(",", stuck), string.Join(",", review), string.Join(",", full.Select(e => e.Name)),
                              string.Join(",", idle), string.Join(",", open.OrderBy(x => x, StringComparer.Ordinal)));
        return (out_, out_.Count == 0 ? "" : sig);
    }
    /// 有要處理的事、而且跟上次推的不一樣才推
    public static bool AlarmShouldPush(List<string> reasons, string sig, string? last) => reasons.Count > 0 && sig != last;
    public static string AlarmQuietText(List<string> reasons, string full) => "【巡檢時間】要處理：" + string.Join("；", reasons) + "\n" + full.Replace("【巡檢時間】", "");
}
