using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using ShoWork;

namespace Orbit42;

/// Orbit42 Windows 版主體（Mac main.swift 的 Host＋LoginPanel＋OrbitWindow）：
/// 主視窗＝ShoWork 戰情中心的球體鋪滿（BoardForm Orbit 模式）；上面蓋登入畫面（WebView2），再上面是衛星終端機小視窗（SatWindow＋WebView2＋ConPTY）。
/// 測試（螢幕外，不碰使用者畫面）：ORBIT_OFFSCREEN=1、ORBIT_TEST_LOGIN_SHOT=<png>、ORBIT_TEST_TERM="<指令>@<輸出txt>"、ORBIT_TEST_QUIT=1
sealed class OrbitApp
{
    public const string HostName = "orbit.okle42.invalid";
    static readonly Dictionary<string, string?> Env = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
        .ToDictionary(e => (string)e.Key, e => (string?)e.Value, StringComparer.OrdinalIgnoreCase);
    public static bool Test => Env.ContainsKey("ORBIT_OFFSCREEN");

    Form form = null!;
    CoreWebView2Environment? webEnv;
    WebView2? login;
    readonly Dictionary<string, Satellite> sats = new();
    readonly List<string> order = new();
    readonly Dictionary<string, WebView2> views = new();
    readonly Dictionary<string, SatWindow> wins = new();
    readonly Dictionary<Brain, int> counter = new();
    readonly Dictionary<string, MemoryStream> pending = new();
    readonly object pendLock = new();
    readonly System.Windows.Forms.Timer flushTimer = new() { Interval = 16 }, tick = new() { Interval = 1000 }, askTimer = new() { Interval = 300 };
    List<Provider> providers = new();
    string theme = "dark";
    bool fullscreen;
    Rectangle normalBounds;
    float Scale => form.DeviceDpi / 96f;        // 網頁 CSS px → 視窗像素

    // MARK: 開機

    /// 引擎起來之後（ShoWork.Program.RunEmbedded 的 onLaunch）：開戰情中心 Orbit 模式當主視窗
    public void Launch()
    {
        OrbitEmbed.Active = true;
        OrbitEmbed.BoardReady = f => { form = f; _ = Attach(); };
        OrbitEmbed.NewSatellite = b => { if (b == "accounts") ShowLogin(); else NewSatellite(Brains.Parse(b)); };
        OrbitEmbed.Command = Command;
        OrbitEmbed.OpenSession = OpenSession;
        var size = new Size(int.TryParse(Env.GetValueOrDefault("ORBIT_TEST_W"), out var w) ? w : 1440, int.TryParse(Env.GetValueOrDefault("ORBIT_TEST_H"), out var h) ? h : 900);
        var f = new BoardForm(new BoardForm.Options(Orbit: true, Size: size));
        f.Text = "Orbit42";
        f.Size = size;
        f.FormClosed += (_, _) => { Shutdown(); Application.Exit(); };
        if (Test) { f.StartPosition = FormStartPosition.Manual; f.Location = new Point(-6000, -6000); f.ShowInTaskbar = false; }
        f.KeyPreview = true;
        f.KeyDown += (_, e) => { if (e.KeyCode == Keys.F11) { ToggleFullscreen(); e.Handled = true; } };
        f.Show();
    }

    /// 戰情中心建好了：登入畫面、衛星、計時器
    async Task Attach()
    {
        try
        {
            webEnv = await CoreWebView2Environment.CreateAsync(null, Path.Combine(OrbitPaths.Support, "WebView2"));
            login = await MakeView("login.html", OnLoginMessage);
            login.Dock = DockStyle.Fill;
            form.Controls.Add(login);
            login.BringToFront();
            CheckAccounts();
            var poll = new System.Windows.Forms.Timer { Interval = 3000 };          // 登入多半在瀏覽器完成：開著時每 3 秒重查
            poll.Tick += (_, _) => { if (login.Visible) CheckAccounts(); };
            poll.Start();
            flushTimer.Tick += (_, _) => Flush(); flushTimer.Start();
            tick.Tick += (_, _) => { PushSats(); QuitRequested(); }; tick.Start();
            askTimer.Tick += async (_, _) => await WatchAskCard(); askTimer.Start();
            form.Resize += (_, _) => { foreach (var x in wins.Values.Where(x => x.Visible)) x.Bounds = SatWindow.Fit(x.Bounds, form.ClientRectangle); };
            Log($"attach ok web={OrbitPaths.WebDir} test={Test}");
            TestHooks();
            if (!Test && ReadPref("desktop", true)) ToggleFullscreen();       // 11-23 Keng：像系統一樣佔滿整個畫面（預設開；切掉會記住）
        }
        catch (Exception x) { Log($"attach failed: {x}"); }
    }

    async Task<WebView2> MakeView(string page, Action<WebView2, JsonElement> onMessage, string query = "")
    {
        var v = new WebView2 { DefaultBackgroundColor = ViewBg };
        v.CreateControl();
        await v.EnsureCoreWebView2Async(webEnv);
        var core = v.CoreWebView2;
        core.Settings.AreDevToolsEnabled = Env.ContainsKey("ORBIT_DEVTOOLS");
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Profile.PreferredColorScheme = theme == "light" ? CoreWebView2PreferredColorScheme.Light : CoreWebView2PreferredColorScheme.Dark;
        if (OrbitPaths.WebDir is { } dir) core.SetVirtualHostNameToFolderMapping(HostName, dir, CoreWebView2HostResourceAccessKind.DenyCors);
        core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith($"https://{HostName}/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true; };
        core.NewWindowRequested += (_, e) => { e.Handled = true; try { Process.Start(new ProcessStartInfo(e.Uri) { UseShellExecute = true }); } catch { } };
        core.WebMessageReceived += (_, e) =>
        {
            try { using var d = JsonDocument.Parse(e.WebMessageAsJson); onMessage(v, d.RootElement.Clone()); }
            catch (Exception x) { Log($"bad message {x.Message}"); }
        };
        core.Navigate($"https://{HostName}/{page}{query}");
        return v;
    }

    Color ViewBg => theme == "light" ? Color.FromArgb(0xf6, 0xf6, 0xf4) : Color.FromArgb(0x16, 0x16, 0x18);

    static void Call(WebView2 v, string fn, params JsonNode?[] args)
    {
        if (v.CoreWebView2 == null) return;
        var a = string.Join(",", args.Select(x => x?.ToJsonString() ?? "null"));
        try { _ = v.CoreWebView2.ExecuteScriptAsync($"{fn} && {fn}({a})"); } catch { }
    }
    static string? Str(JsonElement m, string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    static int Int(JsonElement m, string k, int d) => m.TryGetProperty(k, out var v) && v.TryGetInt32(out var i) ? i : d;

    // MARK: 登入畫面

    void CheckAccounts()
    {
        Task.Run(Accounts.Check).ContinueWith(t =>
        {
            if (t.Result is not { } list) return;
            try
            {
                form.BeginInvoke(() =>
                {
                    providers = list;
                    if (login != null) Call(login, "window.orbitAccounts", new JsonArray(list.Select(p => (JsonNode?)p.Json()).ToArray()));
                });
            }
            catch { }
        });
    }

    void OnLoginMessage(WebView2 v, JsonElement m)
    {
        var p = Accounts.All().FirstOrDefault(x => x.Id == Str(m, "id"));
        var brain = Brains.Parse(p?.Id);
        switch (Str(m, "action"))
        {
            case "check": CheckAccounts(); break;
            case "login": if (p?.Login is { } l) RunCommand($"登入 {p.Name}", brain, l); break;
            case "install": if (p?.Install is { } i) RunCommand($"安裝 {p.Name}", brain, i); break;
            case "enter": Enter(); break;
        }
    }

    /// 進入：收起登入畫面，球體的「＋ 新衛星」只列登入過的大腦，上次的衛星開回來
    void Enter()
    {
        foreach (var w in wins.Values) Animate(w, false);
        _ = OrbitEmbed.Eval("window.karaIntro && window.karaIntro()");
        if (login != null) login.Visible = false;
        var ids = new JsonArray(providers.Where(p => p.SignedIn).Select(p => (JsonNode?)p.Id).ToArray());
        _ = OrbitEmbed.Eval($"window.orbitBrains && window.orbitBrains({ids.ToJsonString()})");
        After(1200, Restore);
        // 球體進場動畫（karaIntro）跑完、卡片排好之前問不到衛星空位 ⇒ 接回的衛星晚一點再排（Mac 是球體排版一變就送 arrangeSats）
        After(2600, AutoArrange); After(4500, AutoArrange);
    }

    void ShowLogin()
    {
        foreach (var w in wins.Values) Animate(w, false);
        _ = OrbitEmbed.Eval("window.karaOutro && window.karaOutro()");      // 球拉遠消失
        CheckAccounts();
        After(800, () =>                                                     // 等球拉遠快消失才讓登入卡進場
        {
            if (login == null) return;
            login.Visible = true; login.BringToFront();
            foreach (var w in wins.Values.Where(x => x.Visible)) w.BringToFront();
            Call(login, "window.loginShow");
        });
    }

    // MARK: 球體 → 這裡

    void Command(string cmd)
    {
        if (cmd == "fullscreen") ToggleFullscreen();
        else if (cmd.StartsWith("theme:")) ApplyTheme(cmd[6..]);
        else if (cmd.StartsWith("arrangeSats"))
        {
            var v = cmd.Split(':').Skip(1).FirstOrDefault()?.Split(',').Select(s => double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : double.NaN).ToArray() ?? Array.Empty<double>();
            ArrangeSats(v.Length == 4 && v.All(double.IsFinite) ? Web(v) : null);
        }
    }

    /// 點到球上的衛星：Orbit42 開的（終端機是我們的）就打開它的小視窗；其他回 false（照舊跳到那個視窗）
    bool OpenSession(OrbitEmbed.SessionRef r)
    {
        foreach (var s in sats.Values)
            if (s.Pty is { } p && (p.Pid == r.Pid || ProcTree.IsAncestor(p.Pid, r.Pid))) { ShowSat(s.Id); return true; }
        return false;
    }

    void NewSatellite(Brain b)
    {
        int n = counter.GetValueOrDefault(b) + 1; counter[b] = n;
        Add(new Satellite(NewId(), $"{b.Label()} {n}", b, OrbitPaths.Home, b.Command()));
    }

    /// 登入／安裝：開一個終端機小視窗跑那一家的官方指令（結束後登入畫面重查）
    public string RunCommand(string name, Brain b, string command)
    {
        var s = new Satellite("cmd-" + NewId()[..6], name, b, OrbitPaths.Home, command);
        Add(s); return s.Id;
    }
    static string NewId() => Guid.NewGuid().ToString("N")[..8];

    void Add(Satellite s) { sats[s.Id] = s; order.Add(s.Id); PushSats(); ShowSat(s.Id); }

    // MARK: 衛星終端機網頁 → 這裡

    void OnTermMessage(WebView2 v, JsonElement m)
    {
        var from = views.FirstOrDefault(kv => kv.Value == v).Key;
        var id = Str(m, "id") ?? from ?? "";
        int cols = Int(m, "cols", 100), rows = Int(m, "rows", 30);
        switch (Str(m, "action"))
        {
            case "ready":
                if (from == null) return;
                Call(v, "window.orbitSats", SatList());
                Call(v, "window.orbitOpened", from);
                break;
            case "hide": if (from != null && wins.TryGetValue(from, out var hw)) Animate(hw, false, AutoArrange); break;
            case "open":
                if (!sats.TryGetValue(id, out var s)) return;
                if (s.Pty == null || s.Exited != null) Start(s, cols, rows);
                else { Call(v, "window.orbitReplay", id, Convert.ToBase64String(s.Snapshot())); s.Pty.Resize(cols, rows); }
                break;
            case "input":
                if (Str(m, "data") is { } d && sats.TryGetValue(id, out var si))
                {
                    if (LogInput) Log($"input {id} {JsonSerializer.Serialize(d)} pty={si.Pty != null}");     // 除錯：%LOCALAPPDATA%\Orbit42\log-input 存在時記下每次送進終端機的字
                    si.Pty?.Write(Encoding.UTF8.GetBytes(d));
                }
                break;
            case "resize": if (sats.TryGetValue(id, out var sr)) sr.Pty?.Resize(cols, rows); break;
            case "remove": End(id); break;
            case "new": NewSatellite(Brains.Parse(Str(m, "brain"))); break;
        }
    }

    static bool LogInput => File.Exists(Path.Combine(OrbitPaths.Support, "log-input"));

    void Start(Satellite s, int cols, int rows)
    {
        s.Exited = null;
        var env = new Dictionary<string, string> { ["COLORFGBG"] = theme != "light" ? "15;0" : "0;15", ["TERM_PROGRAM"] = "Orbit42", ["COLORTERM"] = "truecolor" };
        var p = ConPty.Start(s.Command, s.Cwd, cols, rows, env);
        if (p == null)
        {
            if (views.TryGetValue(s.Id, out var v)) Call(v, "window.orbitData", s.Id, Convert.ToBase64String(Encoding.UTF8.GetBytes("\r\n[Orbit42] could not start a terminal\r\n")));
            return;
        }
        var id = s.Id;
        p.OnData = d =>
        {
            s.Append(d);
            lock (pendLock) { if (!pending.TryGetValue(id, out var ms)) pending[id] = ms = new MemoryStream(); ms.Write(d); }
        };
        p.OnExit = code =>
        {
            try
            {
                form.BeginInvoke(() =>
                {
                    if (!sats.TryGetValue(id, out var x)) return;
                    x.Exited = code; x.Pty = null;
                    Flush();
                    if (views.TryGetValue(id, out var v)) Call(v, "window.orbitExit", id, code);
                    PushSats();
                    if (login?.Visible == true) CheckAccounts();
                });
            }
            catch { }
        };
        s.Pty = p;
        Log($"start {id} pid={p.Pid} {s.Command}");
        PushSats();
    }

    void Flush()
    {
        Dictionary<string, MemoryStream> out_;
        lock (pendLock) { if (pending.Count == 0) return; out_ = new(pending); pending.Clear(); }
        foreach (var (id, d) in out_)
            if (d.Length > 0 && views.TryGetValue(id, out var v)) Call(v, "window.orbitData", id, Convert.ToBase64String(d.ToArray()));
    }

    JsonArray SatList() => new(order.Where(sats.ContainsKey).Select(i => (JsonNode?)sats[i].Json()).ToArray());

    void PushSats()
    {
        var list = SatList();
        foreach (var v in views.Values) Call(v, "window.orbitSats", list.DeepClone());
        foreach (var (id, s) in sats) if (wins.TryGetValue(id, out var w) && w.Visible) w.SetBreathing(s.Busy);
    }

    /// 紅燈：結束這顆衛星
    void End(string id)
    {
        if (sats.Remove(id, out var s)) s.Pty?.Hangup();
        order.Remove(id);
        if (views.Remove(id, out var v)) { try { v.Dispose(); } catch { } }
        if (wins.Remove(id, out var w)) Animate(w, false, () => { form.Controls.Remove(w); w.Dispose(); AutoArrange(); });
        PushSats();
    }

    /// 11-23 Keng「點左上角綠燈應該是完全關閉：按下去先跟我確認，確認後清掉整個內容再關掉」（Mac confirmEnd 的 Windows 版，系統原生對話框）
    bool confirming;
    void ConfirmEnd(string id)
    {
        if (confirming || !sats.TryGetValue(id, out var s)) { if (!sats.ContainsKey(id)) End(id); return; }
        confirming = true;
        try
        {
            var close = new TaskDialogButton("關閉");
            var page = new TaskDialogPage
            {
                Caption = "Orbit42", Heading = $"關閉「{s.Name}」？", Icon = TaskDialogIcon.Warning,
                Text = "會結束這顆衛星裡正在跑的程式，並清掉這個視窗的全部內容，無法還原。",
                Buttons = { close, TaskDialogButton.Cancel }, DefaultButton = TaskDialogButton.Cancel,
            };
            if (TaskDialog.ShowDialog(form, page) == close) End(id);
        }
        finally { confirming = false; }
    }

    // MARK: 衛星小視窗

    async void ShowSat(string id)
    {
        if (!sats.TryGetValue(id, out var s)) return;
        if (!wins.TryGetValue(id, out var w))
        {
            var v = await MakeView("index.html", OnTermMessage, $"?term=1&sat={id}&theme={theme}");
            views[id] = v;
            w = new SatWindow(v) { Title = Title(s), Dark = theme != "light", Visible = false };
            int n = wins.Values.Count(x => x.Visible);
            var f = w.RestoredFrame(form.ClientRectangle); f.Offset(n * 28, n * 28);
            w.Bounds = SatWindow.Fit(f, form.ClientRectangle);
            w.OnClose = () => ConfirmEnd(id);                  // 11-23 Keng：綠燈＝完全關閉（先確認 → 結束程式、清內容 → 關視窗），同 Mac
            w.OnMinimize = () => Animate(w, false, AutoArrange);
            w.OnDropPaths = paths => s.Pty?.Write(Encoding.UTF8.GetBytes(string.Join(" ", paths) + " "));
            w.OnResized = size => { foreach (var o in wins.Values) if (o != w && o.Visible) o.MatchSize(size); };
            w.Raise = Raise;
            form.Controls.Add(w);
            wins[id] = w;
        }
        Raise(w);
        if (!w.Visible || !w.WantShown) { Animate(w, true); AutoArrange(); } else w.Flash();
        w.Content.Focus();
    }

    string Title(Satellite s) => $"{s.Name} · {s.Brain.Label()}";

    void Raise(SatWindow w) { w.BringToFront(); }

    /// 打開：出現＋邊框閃一下；收起：藏起來（WinForms 子視窗沒有透明度動畫）
    void Animate(SatWindow w, bool on, Action? then = null)
    {
        w.WantShown = on; w.YieldingToAsk = false;
        if (on)
        {
            w.Bounds = SatWindow.Fit(w.Bounds, form.ClientRectangle);
            w.Grow(true); w.Flash();
            then?.Invoke();
        }
        else if (!w.Visible) then?.Invoke();
        else { w.SetBreathing(false); w.Grow(false, () => { if (w.WantShown) w.Visible = true; then?.Invoke(); }); }
    }

    /// 斜對角排開（球體量好的空位裡；最底下的在左上）。Mac arrangeSats 的移植
    void ArrangeSats(Rectangle? area_)
    {
        var ws = wins.Values.Where(x => x.Visible && x.WantShown).OrderBy(x => x.Seq).ToList();
        if (ws.Count == 0) return;
        var b = form.ClientRectangle;
        var area = area_ ?? new Rectangle(16, 52, b.Width - 32, b.Height - 92);
        var bs = SatWindow.Fit(ws[0].RestoredFrame(b), b);
        int n = ws.Count;
        int w = Math.Max(Math.Min(SatWindow.MinW, b.Width - 32), Math.Min(bs.Width, n > 1 ? (int)(area.Width * 0.62) : area.Width));
        int h = Math.Max(Math.Min(SatWindow.MinH, b.Height - 80), Math.Min(bs.Height, n > 1 ? (int)(area.Height * 0.78) : area.Height));
        double dx = n > 1 ? Math.Max(0, area.Width - w) / (double)(n - 1) : 0, dy = n > 1 ? Math.Max(0, area.Height - h) / (double)(n - 1) : 0;
        for (int i = 0; i < n; i++)
            ws[i].Place(n > 1 ? new Rectangle((int)Math.Round(area.X + i * dx), (int)Math.Round(area.Y + i * dy), w, h)
                                 : new Rectangle(area.X + (area.Width - w) / 2, area.Y, w, h));
    }

    /// 開／關／收起衛星後：球體的自動排版開著就重排
    void AutoArrange() => AutoArrange(0);
    async void AutoArrange(int tries)
    {
        var r = await OrbitEmbed.Eval("window.karaSatArea ? JSON.stringify(window.karaSatArea()) : 'null'");
        if (LogInput) Log($"arrange try={tries} area={r} wins={wins.Count(x => x.Value.Visible)}");
        if (Unwrap(r) is { } s && JsonNode.Parse(s) is JsonArray a && a.Count == 4) ArrangeSats(Web(a.Select(x => (double)x!).ToArray()));
        else if (tries < 3) After(1000, () => AutoArrange(tries + 1));     // 球體還沒好：1 秒後再問（最多 3 次；自動排版關掉時本來就回 null）
    }

    /// 球體的答案卡被衛星蓋到：那顆衛星先藏起來（Windows 子視窗蓋在網頁上，網頁的 z-index 管不到），答完恢復
    async Task WatchAskCard()
    {
        if (login?.Visible == true || wins.Count == 0) return;
        const string js = "(() => { const r = []; for (const id of ['askCard','askUndo','askDot']) { const e = document.getElementById(id); if (!e || !e.classList.contains('on')) continue; const b = e.getBoundingClientRect(); if (b.width && b.height) r.push([b.left,b.top,b.width,b.height]); } return JSON.stringify(r); })()";
        if (Unwrap(await OrbitEmbed.Eval(js)) is not { } s || JsonNode.Parse(s) is not JsonArray arr) return;
        var rects = arr.OfType<JsonArray>().Where(x => x.Count == 4).Select(x => { var r = Web(x.Select(y => (double)y!).ToArray()); r.Inflate(10, 10); return r; }).ToList();
        foreach (var w in wins.Values.Where(x => x.WantShown))
        {
            bool y = rects.Any(r => r.IntersectsWith(w.Bounds));
            if (y == w.YieldingToAsk) continue;
            w.YieldingToAsk = y; w.Visible = !y;
        }
    }

    /// ExecuteScriptAsync 回的是 JSON：字串會帶引號 ⇒ 拆一層
    static string? Unwrap(string? r)
    {
        if (string.IsNullOrEmpty(r) || r == "null") return null;
        try { return JsonNode.Parse(r) is JsonValue v && v.TryGetValue<string>(out var s) ? s : r; } catch { return null; }
    }
    Rectangle Web(double[] v) => new((int)(v[0] * Scale), (int)(v[1] * Scale), (int)(v[2] * Scale), (int)(v[3] * Scale));

    // MARK: 深淺、全螢幕

    void ApplyTheme(string name)
    {
        theme = name == "light" ? "light" : "dark";
        var scheme = theme == "light" ? CoreWebView2PreferredColorScheme.Light : CoreWebView2PreferredColorScheme.Dark;
        if (webEnv != null && login?.CoreWebView2 != null) login.CoreWebView2.Profile.PreferredColorScheme = scheme;
        foreach (var w in wins.Values) w.Dark = theme != "light";
        // 終端機網頁的底色是半透明（Mac 透出毛玻璃）⇒ Windows 透出的是 WebView2 的預設底色，換深淺要跟著換（不然淺色字疊在深灰上）
        foreach (var v in views.Values) { v.DefaultBackgroundColor = ViewBg; if (v.CoreWebView2 != null) v.CoreWebView2.Profile.PreferredColorScheme = scheme; Call(v, "window.orbitTheme", theme); }
        if (login != null) login.DefaultBackgroundColor = ViewBg;
    }

    /// 全螢幕桌面模式（F11 或球體的全螢幕鈕）：無邊框蓋滿整個螢幕（含工作列），像 Mac 的全螢幕
    void ToggleFullscreen()
    {
        fullscreen = !fullscreen;
        if (fullscreen)
        {
            normalBounds = form.Bounds;
            form.FormBorderStyle = FormBorderStyle.None;
            form.WindowState = FormWindowState.Normal;
            form.Bounds = Screen.FromControl(form).Bounds;
        }
        else
        {
            form.FormBorderStyle = FormBorderStyle.Sizable;
            form.Bounds = normalBounds.Width > 0 ? normalBounds : new Rectangle(100, 100, 1440, 900);
        }
        if (!Test) WritePref("desktop", fullscreen);
    }

    static string PrefPath(string k) => Path.Combine(OrbitPaths.Support, "pref." + k);
    static bool ReadPref(string k, bool d) { try { return File.ReadAllText(PrefPath(k)).Trim() == "1"; } catch { return d; } }
    static void WritePref(string k, bool v) { try { File.WriteAllText(PrefPath(k), v ? "1" : "0"); } catch { } }

    static bool HasTranscript(string sid)
    {
        var dir = Path.Combine(OrbitPaths.Home, ".claude", "projects");
        try { return Directory.Exists(dir) && Directory.EnumerateFiles(dir, sid + ".jsonl", SearchOption.AllDirectories).Any(); }
        catch { return true; }   // 查不到就照舊試著接回
    }
    // MARK: 重開後衛星回來（Claude 記 session id，重開用 --resume 接回同一段對話）

    static string RestorePath => Path.Combine(OrbitPaths.Support, Env.ContainsKey("ORBIT_TEST_RESTORE") ? "restore.test.json" : "restore.json");
    static bool RestoreBlocked => Test && !Env.ContainsKey("ORBIT_TEST_RESTORE");

    void SaveForRestore()
    {
        if (RestoreBlocked) return;
        var recs = SessionFile.All();
        var out_ = new JsonArray();
        foreach (var id in order)
        {
            if (!sats.TryGetValue(id, out var s) || id.StartsWith("cmd-") || s.Exited != null || s.Pty is not { } p) continue;
            var e = new JsonObject { ["brain"] = s.Brain.Id(), ["name"] = s.Name, ["cwd"] = s.Cwd };
            if (s.Brain == Brain.Claude && recs.FirstOrDefault(r => r.Pid == p.Pid || ProcTree.IsAncestor(p.Pid, r.Pid)) is { } r) { e["sid"] = r.SessionId; e["cwd"] = r.Cwd; }
            out_.Add(e);
        }
        try { File.WriteAllText(RestorePath, out_.ToJsonString()); } catch { }
    }

    void Restore()
    {
        if (RestoreBlocked) return;
        JsonArray? list;
        try { list = JsonNode.Parse(File.ReadAllText(RestorePath)) as JsonArray; } catch { return; }
        try { File.Delete(RestorePath); } catch { }
        if (list == null) return;
        foreach (var e in list.OfType<JsonObject>())
        {
            var b = Brains.Parse((string?)e["brain"]);
            var name = (string?)e["name"] ?? b.Label();
            if (int.TryParse(name.Split(' ').Last(), out var n) && n > counter.GetValueOrDefault(b)) counter[b] = n;
            // 11-24：衛星開了還沒講話就關掉，Claude Code 不會留對話紀錄，--resume 會「No conversation found」直接結束 ⇒ 有紀錄才接回，沒有就開新的
            var cmd = b == Brain.Claude && (string?)e["sid"] is { } sid && HasTranscript(sid) ? b.Command() + " --resume " + sid : b.Command();
            Add(new Satellite(NewId(), name, b, (string?)e["cwd"] ?? OrbitPaths.Home, cmd));
        }
    }

    /// 安裝新版（pack.ps1）／別的程式要 Orbit42 正常結束：寫 %LOCALAPPDATA%\Orbit42\quit.request。
    /// 從 ssh 之類別的工作階段送 WM_CLOSE 送不到 ⇒ 用檔案；正常結束才會記下衛星（重開接回）、把 ShoWorkAgent 開回來
    public static string QuitFile => Path.Combine(OrbitPaths.Support, "quit.request");
    void QuitRequested()
    {
        if (Test || !File.Exists(QuitFile)) return;
        try { File.Delete(QuitFile); } catch { }
        Log("quit requested");
        Quit();
    }

    bool shutDown;
    public void Shutdown()
    {
        if (shutDown) return;
        shutDown = true;
        SaveForRestore();
        Log($"shutdown sats={sats.Count}");
        foreach (var s in sats.Values) s.Pty?.Hangup();
    }

    // MARK: 測試（只在螢幕外）

    void TestHooks()
    {
        if (Env.GetValueOrDefault("ORBIT_TEST_LOGIN_SHOT") is { Length: > 0 } shot)
            After(8000, async () =>
            {
                if (login?.CoreWebView2 != null)
                {
                    using (var fs = File.Create(shot)) await login.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
                    Console.WriteLine($"login shot saved {shot}");
                }
                if (Env.ContainsKey("ORBIT_TEST_QUIT")) Quit();
            });
        // ORBIT_TEST_TERM="<指令>@<輸出 txt>"：進入 → 開一顆跑那個指令的衛星 → 12 秒後把終端機畫面文字倒出來（＋小視窗截圖 .png）
        if (Env.GetValueOrDefault("ORBIT_TEST_TERM") is { Length: > 0 } spec && spec.LastIndexOf('@') is var at and > 0)
        {
            var (cmd, outTxt) = (spec[..at], spec[(at + 1)..]);
            After(4000, () => { Enter(); RunCommand("測試", Brain.Claude, cmd); });
            After(Env.GetValueOrDefault("ORBIT_TEST_TERM_DELAY") is { } dl && int.TryParse(dl, out var ds) ? ds * 1000 : 16000, async () =>
            {
                var v = views.Values.FirstOrDefault();
                var txt = v?.CoreWebView2 == null ? null : Unwrap(await v.CoreWebView2.ExecuteScriptAsync("window.orbitTest && window.orbitTest.screen ? window.orbitTest.screen() : ''"));
                File.WriteAllText(outTxt, txt ?? "(沒有畫面)", Encoding.UTF8);
                // 原始 PTY 位元組（查 Claude Code 在 ConPTY 下實際送出的顏色碼／字元，例如娃娃替換對不上時）
                if (sats.Values.FirstOrDefault() is { } st0) File.WriteAllBytes(Path.ChangeExtension(outTxt, ".raw"), st0.Snapshot());
                if (wins.Values.FirstOrDefault() is { } w)
                {
                    using var bmp = new Bitmap(w.Width, w.Height);
                    w.DrawToBitmap(bmp, new Rectangle(0, 0, w.Width, w.Height));
                    bmp.Save(Path.ChangeExtension(outTxt, ".frame.png"));
                    if (v?.CoreWebView2 != null) { using var fs = File.Create(Path.ChangeExtension(outTxt, ".png")); await v.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs); }
                }
                Console.WriteLine($"term dump saved {outTxt} sats={sats.Count}");
                if (Env.ContainsKey("ORBIT_TEST_QUIT")) Quit();
            });
        }
        // ORBIT_TEST_SHOT=<png>：整個 Orbit42 視窗（球體＋衛星）螢幕外截圖
        if (Env.GetValueOrDefault("ORBIT_TEST_SHOT") is { Length: > 0 } whole)
            After(int.TryParse(Env.GetValueOrDefault("ORBIT_TEST_SHOT_DELAY"), out var sd) ? sd * 1000 : 20000, () =>
            {
                using var bmp = new Bitmap(form.ClientSize.Width, form.ClientSize.Height);
                using (var g = Graphics.FromImage(bmp)) { var hdc = g.GetHdc(); PrintWindow(form.Handle, hdc, 3); g.ReleaseHdc(hdc); }
                bmp.Save(whole);
                Console.WriteLine($"orbit shot saved {whole}");
                if (Env.ContainsKey("ORBIT_TEST_QUIT")) Quit();
            });
    }
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    void Quit() { Shutdown(); form.Close(); }

    void After(int ms, Action a)
    {
        var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, ms) };
        t.Tick += (_, _) => { t.Dispose(); try { a(); } catch (Exception x) { Log($"timer failed {x}"); } };
        t.Start();
    }

    public static void Log(string s) { try { File.AppendAllText(Path.Combine(OrbitPaths.Support, "orbit.log"), $"{DateTime.Now:MM-dd HH:mm:ss} {s}\r\n"); } catch { } }
}

/// 程序樹：衛星的 pty 程式（cmd.exe）是不是球上那個 session（claude.exe）的祖先
static class ProcTree
{
    public static bool IsAncestor(int ancestor, int pid)
    {
        var parents = Snapshot();
        for (int i = 0, p = pid; i < 8 && parents.TryGetValue(p, out var pp) && pp > 0; i++, p = pp)
            if (pp == ancestor) return true;
        return false;
    }

    static Dictionary<int, int> Snapshot()
    {
        var d = new Dictionary<int, int>();
        var h = CreateToolhelp32Snapshot(2 /*TH32CS_SNAPPROCESS*/, 0);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return d;
        try
        {
            var e = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32>() };
            for (bool ok = Process32FirstW(h, ref e); ok; ok = Process32NextW(h, ref e)) d[(int)e.th32ProcessID] = (int)e.th32ParentProcessID;
        }
        finally { CloseHandle(h); }
        return d;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
}
