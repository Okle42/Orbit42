using System.Drawing.Drawing2D;

namespace Orbit42;

/// 衛星終端機小視窗（Mac TermWindow.swift 的 Windows 版）：裝在 Orbit42 主視窗裡的子控制項，
/// 標題列可以拖、雙擊放大／還原，左上三顆燈（深色：綠＝結束、灰＝收起、白＝放大；淺色：紅／灰／白），
/// 右下角拉大小，圓角，打開時邊框閃一下（深色護眼綠、淺色紅），工作中邊框呼吸。位置大小會記住。
/// Windows 子視窗疊在另一個 WebView2（球體）上沒辦法半透明 ⇒ 終端機底色是實色（跟 Mac 毛玻璃差在這裡）。
sealed class SatWindow : Control
{
    public Control Content { get; }
    public string Title { get => title; set { title = value; Invalidate(); } }
    public Action? OnClose, OnMinimize;
    public Action<Size>? OnResized;
    public Action<string[]>? OnDropPaths;
    static int seqN;
    public int Seq { get; } = ++seqN;                // 打開的先後（斜對角排的順序）
    public bool WantShown;                           // 收起動畫跑到一半又被打開時用
    public bool YieldingToAsk;                       // 答案卡被蓋到 ⇒ 藏起來讓答案卡在上面
    public bool Dark { get => dark; set { dark = value; Invalidate(); } }

    public const int BarHeight = 34, MinW = 420, MinH = 260, Radius = 12;
    string title = "";
    bool dark = true;
    Rectangle? zoomedFrom;
    Point? dragMouse; Point dragOrigin;
    Point? gripMouse; Size gripSize;
    int hoverLight = -1, tipOn = -1;
    readonly ToolTip tips = new() { InitialDelay = 500 };
    static readonly string[] LightTips = { "關閉（先確認；結束裡面的程式、清掉內容）", "收起（衛星繼續跑）", "放大／還原（也可以雙擊標題列）" };

    // 邊框動畫：閃一下（0.9 秒）、工作中呼吸（1.4 秒來回）
    readonly System.Windows.Forms.Timer anim = new() { Interval = 16 };
    DateTime flashAt = DateTime.MinValue;
    bool breathing;
    DateTime breathAt;

    public SatWindow(Control content)
    {
        Content = content;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Controls.Add(content);
        AllowDrop = true;
        anim.Tick += (_, _) => { Invalidate(new Rectangle(0, 0, Width, BarHeight + 3)); InvalidateEdges(); if (!Animating) anim.Stop(); };
        DragEnter += (_, e) => { if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true) { e.Effect = DragDropEffects.Copy; dropHover = true; Invalidate(); } };
        DragLeave += (_, _) => { dropHover = false; Invalidate(); };
        DragDrop += (_, e) => { dropHover = false; Invalidate(); if (e.Data?.GetData(DataFormats.FileDrop) is string[] f) OnDropPaths?.Invoke(f.Select(Quote).ToArray()); };
    }
    bool dropHover;

    /// 路徑有空白就加引號（Claude Code 在 Windows 認雙引號路徑，拖圖片進來會當附件）
    public static string Quote(string p) => p.Contains(' ') ? $"\"{p}\"" : p;

    bool Animating => breathing || DateTime.UtcNow - flashAt < TimeSpan.FromSeconds(0.9);
    void InvalidateEdges() { Invalidate(new Rectangle(0, 0, 3, Height)); Invalidate(new Rectangle(Width - 3, 0, 3, Height)); Invalidate(new Rectangle(0, Height - 3, Width, 3)); }

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        Content.Bounds = new Rectangle(2, BarHeight, Math.Max(0, Width - 4), Math.Max(0, Height - BarHeight - 2));
        using var path = Round(new Rectangle(0, 0, Width, Height), Radius);
        Region = new Region(path);
    }

    static GraphicsPath Round(Rectangle r, int rad)
    {
        var p = new GraphicsPath(); int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }

    /// 強調色＝跟三顆燈一致：深色護眼綠、淺色紅
    public Color Accent => dark ? Color.FromArgb(0x4f, 0xc3, 0x6a) : Color.FromArgb(0xd7, 0x26, 0x1b);
    Color BaseBorder => dark ? Color.FromArgb(40, 255, 255, 255) : Color.FromArgb(46, 0, 0, 0);

    (Color c, float w) Border()
    {
        if (dropHover) return (Accent, 2.5f);
        var t = (DateTime.UtcNow - flashAt).TotalSeconds;
        if (t < 0.9)
        {
            // 0～0.35 秒全亮，之後 0.55 秒淡回原本的邊框
            var k = t < 0.35 ? 1 : 1 - (t - 0.35) / 0.55;
            return (Mix(BaseBorder, Accent, k), (float)(1 + 1.5 * k));
        }
        if (breathing)
        {
            var ph = (Math.Sin((DateTime.UtcNow - breathAt).TotalSeconds / 1.4 * Math.PI - Math.PI / 2) + 1) / 2;
            var from = dark ? Color.FromArgb(46, 255, 255, 255) : Color.FromArgb(64, 77, 77, 77);
            var to = dark ? Color.FromArgb(217, 255, 255, 255) : Color.FromArgb(230, 51, 51, 51);
            return (Mix(from, to, ph), (float)(1 + 0.6 * ph));
        }
        return (BaseBorder, 1);
    }
    static Color Mix(Color a, Color b, double k)
    {
        k = Math.Clamp(k, 0, 1);
        int L(int x, int y) => (int)Math.Round(x + (y - x) * k);
        return Color.FromArgb(L(a.A, b.A), L(a.R, b.R), L(a.G, b.G), L(a.B, b.B));
    }

    public void Flash() { flashAt = DateTime.UtcNow; anim.Start(); }

    /// 打開／收起的過場（Mac：0.26 秒從 94% 放大淡入；收起 0.2 秒縮小淡出）。WinForms 子視窗沒有透明度 ⇒ 只做縮放
    System.Windows.Forms.Timer? grow;
    Rectangle growFull;
    /// 放到這個位置；過場跑到一半就改過場的終點（自動排版不會被過場蓋回去）
    public void Place(Rectangle r) { if (grow != null) growFull = r; else Bounds = r; }
    public void Grow(bool on, Action? done = null)
    {
        grow?.Dispose();
        growFull = Bounds;
        var start = DateTime.UtcNow;
        double dur = on ? 0.26 : 0.2;
        Rectangle At(double k)      // k：0＝94%、1＝原尺寸（以中心縮放）
        {
            double sc = 0.94 + 0.06 * k;
            var f = growFull;
            int w = (int)Math.Round(f.Width * sc), h = (int)Math.Round(f.Height * sc);
            return new Rectangle(f.X + (f.Width - w) / 2, f.Y + (f.Height - h) / 2, w, h);
        }
        if (on) { Bounds = At(0); Visible = true; BringToFront(); }
        grow = new System.Windows.Forms.Timer { Interval = 15 };
        grow.Tick += (_, _) =>
        {
            double t = Math.Min(1, (DateTime.UtcNow - start).TotalSeconds / dur);
            double e = on ? 1 - Math.Pow(1 - t, 3) : t * t;          // 打開 ease-out、收起 ease-in
            Bounds = At(on ? e : 1 - e);
            if (t < 1) return;
            grow!.Dispose(); grow = null;
            Bounds = growFull;
            if (!on) Visible = false;
            done?.Invoke();
        };
        grow.Start();
    }
    public void SetBreathing(bool on)
    {
        if (on == breathing) return;
        breathing = on; breathAt = DateTime.UtcNow;
        if (on) anim.Start(); else Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var bg = dark ? Color.FromArgb(0x16, 0x16, 0x18) : Color.FromArgb(0xf6, 0xf6, 0xf4);
        g.Clear(bg);
        // 標題列
        using (var b = new SolidBrush(dark ? Color.FromArgb(0x1c, 0x1c, 0x1f) : Color.FromArgb(0xee, 0xee, 0xec))) g.FillRectangle(b, 0, 0, Width, BarHeight);
        for (int i = 0; i < 3; i++) PaintLight(g, i);
        using (var f = new Font("Segoe UI Semibold", 9f))
        {
            var r = new Rectangle(80, 0, Math.Max(0, Width - 160), BarHeight);
            TextRenderer.DrawText(g, title, f, r, dark ? Color.FromArgb(237, 237, 237) : Color.FromArgb(20, 20, 20),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
        // 右下角拉大小的小斜線
        using (var p = new Pen(dark ? Color.FromArgb(90, 255, 255, 255) : Color.FromArgb(90, 0, 0, 0)))
            for (int k = 4; k <= 12; k += 4) g.DrawLine(p, Width - 3 - k, Height - 3, Width - 3, Height - 3 - k);
        var (bc, bw) = Border();
        using var pen = new Pen(bc, bw);
        using var path = Round(new Rectangle(0, 0, Width - 1, Height - 1), Radius);
        g.DrawPath(pen, path);
    }

    Rectangle LightRect(int i) => new(14 + i * 20, 11, 12, 12);

    void PaintLight(Graphics g, int i)
    {
        // 跟 Mac 一樣：深色 綠 #4fc36a／灰 #8a8a8f／白 #ededed；淺色 紅 #d7261b／灰 #8c8c8c／白
        Color fill = i switch
        {
            0 => dark ? Color.FromArgb(0x4f, 0xc3, 0x6a) : Color.FromArgb(0xd7, 0x26, 0x1b),
            1 => dark ? Color.FromArgb(0x8a, 0x8a, 0x8f) : Color.FromArgb(0x8c, 0x8c, 0x8c),
            _ => dark ? Color.FromArgb(0xed, 0xed, 0xed) : Color.White,
        };
        var r = LightRect(i);
        using (var b = new SolidBrush(fill)) g.FillEllipse(b, r);
        using (var p = new Pen(i == 2 && !dark ? Color.FromArgb(90, 0, 0, 0) : Color.FromArgb(dark ? 115 : 46, 0, 0, 0))) g.DrawEllipse(p, r);
        if (hoverLight >= 0)
        {
            using var p = new Pen(i == 0 ? (dark ? Color.FromArgb(217, 5, 56, 18) : Color.FromArgb(217, 89, 5, 0)) : Color.FromArgb(191, 26, 26, 26), 1.4f);
            var c = new PointF(r.X + 6, r.Y + 6);
            if (i == 0) { g.DrawLine(p, c.X - 2.5f, c.Y - 2.5f, c.X + 2.5f, c.Y + 2.5f); g.DrawLine(p, c.X + 2.5f, c.Y - 2.5f, c.X - 2.5f, c.Y + 2.5f); }
            else if (i == 1) g.DrawLine(p, c.X - 3, c.Y, c.X + 3, c.Y);
            else { g.DrawLine(p, c.X - 3, c.Y, c.X + 3, c.Y); g.DrawLine(p, c.X, c.Y - 3, c.X, c.Y + 3); }
        }
    }

    // MARK: 滑鼠：拖標題列、點燈、拉右下角

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        int hv = e.Y < BarHeight && e.X < 80 ? 0 : -1;
        if (hv != hoverLight) { hoverLight = hv; Invalidate(new Rectangle(0, 0, 80, BarHeight)); }
        // 三顆燈的說明（同 Mac toolTip）
        int on = -1; for (int i = 0; i < 3; i++) if (Rectangle.Inflate(LightRect(i), 3, 3).Contains(e.Location)) on = i;
        if (on != tipOn) { tipOn = on; tips.SetToolTip(this, on < 0 ? null : LightTips[on]); }
        Cursor = InGrip(e.Location) || gripMouse != null ? Cursors.SizeNWSE : Cursors.Default;
        if (dragMouse is { } d && Parent is { } sup)
        {
            var m = Cursor.Position;
            var o = new Point(dragOrigin.X + m.X - d.X, dragOrigin.Y + m.Y - d.Y);
            o.X = Math.Min(Math.Max(o.X, -Width + 120), sup.ClientSize.Width - 120);       // 標題列一定拿得到
            o.Y = Math.Min(Math.Max(o.Y, 0), sup.ClientSize.Height - BarHeight);
            Location = o; zoomedFrom = null;
        }
        else if (gripMouse is { } gm)
        {
            var m = Cursor.Position;
            Size = new Size(Math.Max(MinW, gripSize.Width + m.X - gm.X), Math.Max(MinH, gripSize.Height + m.Y - gm.Y));
            zoomedFrom = null;
            OnResized?.Invoke(Size);
        }
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hoverLight != -1) { hoverLight = -1; Invalidate(); } }
    bool InGrip(Point p) => p.X > Width - 18 && p.Y > Height - 18;

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Raise?.Invoke(this);
        if (InGrip(e.Location)) { gripMouse = Cursor.Position; gripSize = Size; Capture = true; return; }
        if (e.Y >= BarHeight) return;
        for (int i = 0; i < 3; i++)
            if (Rectangle.Inflate(LightRect(i), 3, 3).Contains(e.Location))
            {
                if (i == 0) OnClose?.Invoke(); else if (i == 1) OnMinimize?.Invoke(); else ToggleZoom();
                return;
            }
        if (e.Clicks == 2) { ToggleZoom(); return; }        // 雙擊標題列＝放大／還原，跟 macOS 一樣
        dragMouse = Cursor.Position; dragOrigin = Location; Capture = true;
    }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (dragMouse != null || gripMouse != null) { dragMouse = null; gripMouse = null; Capture = false; Save(); }
    }

    /// 點到就疊到最上面（OrbitApp 接）
    public Action<SatWindow>? Raise;

    public void MatchSize(Size s)
    {
        if (Parent is not { } sup || Size == s) return;
        Bounds = Fit(new Rectangle(Location, s), sup.ClientRectangle); zoomedFrom = null;
    }

    public void ToggleZoom()
    {
        if (Parent is not { } sup) return;
        if (zoomedFrom is { } back) { Bounds = back; zoomedFrom = null; }
        else { zoomedFrom = Bounds; var r = sup.ClientRectangle; r.Inflate(-16, -16); r.Y += 8; r.Height -= 8; Bounds = r; }
        Save();
    }

    static string Key => Path.Combine(OrbitPaths.Support, "satwindow.txt");
    /// 記住的位置大小（沒有就放右半邊）
    public Rectangle RestoredFrame(Rectangle b)
    {
        Rectangle f;
        try
        {
            var v = File.ReadAllText(Key).Split(',').Select(int.Parse).ToArray();
            f = v.Length == 4 && v[2] >= MinW && v[3] >= MinH ? new Rectangle(v[0], v[1], v[2], v[3]) : throw new FormatException();
        }
        catch { int w = Math.Max(560, b.Width / 2); f = new Rectangle(b.Width - w - 28, 80, w, b.Height - 120); }
        return Fit(f, b);
    }
    /// 比 Orbit42 視窗還大就縮進來、整個留在視窗裡（上面留球體工具列的空間）
    public static Rectangle Fit(Rectangle r, Rectangle b)
    {
        var f = r;
        f.Width = Math.Min(f.Width, Math.Max(MinW, b.Width - 32));
        f.Height = Math.Min(f.Height, Math.Max(MinH, b.Height - 72));
        f.X = Math.Min(Math.Max(f.X, 16), Math.Max(16, b.Width - f.Width - 16));
        f.Y = Math.Min(Math.Max(f.Y, 44), Math.Max(44, b.Height - f.Height - 16));
        return f;
    }
    public void Save() { if (zoomedFrom == null) try { File.WriteAllText(Key, $"{Left},{Top},{Width},{Height}"); } catch { } }

    protected override void Dispose(bool disposing) { if (disposing) { anim.Dispose(); tips.Dispose(); grow?.Dispose(); } base.Dispose(disposing); }
}
