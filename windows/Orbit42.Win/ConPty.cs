using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Orbit42;

/// Mac Pty.swift 的 Windows 版：Windows 10 1809 起內建的虛擬主控台（ConPTY）。
/// 衛星裡跑的是真的 claude／agy／codex，輸出（VT 序列）原封不動送進 xterm.js，跟 Mac 一樣。
sealed class ConPty : IDisposable
{
    public int Pid { get; }
    public Action<byte[]>? OnData;
    public Action<int>? OnExit;

    IntPtr hpc;
    readonly SafeFileHandle inWrite, outRead;
    readonly IntPtr process, thread;
    readonly FileStream input;
    bool disposed;

    ConPty(IntPtr hpc, SafeFileHandle inWrite, SafeFileHandle outRead, PROCESS_INFORMATION pi)
    {
        this.hpc = hpc; this.inWrite = inWrite; this.outRead = outRead;
        process = pi.hProcess; thread = pi.hThread; Pid = pi.dwProcessId;
        input = new FileStream(inWrite, FileAccess.Write, 1, false);
    }

    /// 用 cmd.exe /d /s /c 跑一行指令（claude.cmd、agy.cmd 這類 npm 包裝都要經過 cmd 才找得到）
    public static ConPty? Start(string commandLine, string cwd, int cols, int rows, IDictionary<string, string>? env = null)
    {
        if (!CreatePipe(out var inRead, out var inWrite, IntPtr.Zero, 0)) return null;
        if (!CreatePipe(out var outRead, out var outWrite, IntPtr.Zero, 0)) return null;
        int hr = CreatePseudoConsole(new COORD((short)Math.Max(2, cols), (short)Math.Max(2, rows)), inRead, outWrite, 0, out var hpc);
        inRead.Dispose(); outWrite.Dispose();                       // ConPTY 自己複製了一份
        if (hr != 0) { inWrite.Dispose(); outRead.Dispose(); return null; }

        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
        // 父程式的 stdout 被導向時（測試、從別的程式開），子程式會沿用父的標準控制代碼、輸出不進 ConPTY ⇒
        // 指定「用標準控制代碼」但全給空的，子程式才會接到虛擬主控台（microsoft/terminal #4061）
        si.StartupInfo.dwFlags = 0x00000100;   // STARTF_USESTDHANDLES
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        si.lpAttributeList = Marshal.AllocHGlobal(size);
        try
        {
            if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref size)) throw new Win32Exception();
            if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception();
            var block = EnvBlock(env);
            var cmd = $"{Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe"} /d /s /c \"{commandLine}\"";
            var dir = Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!CreateProcessW(null, cmd, IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                                block, dir, ref si, out var pi))
            {
                Marshal.FreeHGlobal(block);
                throw new Win32Exception();
            }
            Marshal.FreeHGlobal(block);
            var p = new ConPty(hpc, inWrite, outRead, pi);
            p.Pump();
            return p;
        }
        catch (Exception x)
        {
            Log($"start failed: {x.Message}");
            ClosePseudoConsole(hpc); inWrite.Dispose(); outRead.Dispose();
            return null;
        }
        finally
        {
            DeleteProcThreadAttributeList(si.lpAttributeList);
            Marshal.FreeHGlobal(si.lpAttributeList);
        }
    }

    /// 讀輸出（背景執行緒）＋等程式結束
    void Pump()
    {
        var reader = new Thread(() =>
        {
            using var s = new FileStream(outRead, FileAccess.Read, 1, false);
            var buf = new byte[16384];
            try
            {
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) OnData?.Invoke(buf.AsSpan(0, n).ToArray());
            }
            catch { }
        }) { IsBackground = true, Name = "orbit-pty-read" };
        reader.Start();
        new Thread(() =>
        {
            WaitForSingleObject(process, INFINITE);
            GetExitCodeProcess(process, out var code);
            // ConPTY 要關掉，讀的那條管子才會收到結束（不然最後一段輸出會卡住）
            ClosePc();
            reader.Join(2000);
            OnExit?.Invoke((int)code);
        }) { IsBackground = true, Name = "orbit-pty-wait" }.Start();
    }

    public void Write(byte[] data)
    {
        if (disposed) return;
        try { input.Write(data, 0, data.Length); input.Flush(); } catch { }
    }

    public void Resize(int cols, int rows)
    {
        if (hpc == IntPtr.Zero) return;
        ResizePseudoConsole(hpc, new COORD((short)Math.Max(2, cols), (short)Math.Max(2, rows)));
    }

    /// 紅燈：結束（像關掉終端機視窗）。整棵程序樹一起收（cmd → claude → node）
    public void Hangup()
    {
        try { using var p = System.Diagnostics.Process.GetProcessById(Pid); p.Kill(entireProcessTree: true); } catch { }
        ClosePc();
    }

    void ClosePc()
    {
        var h = Interlocked.Exchange(ref hpc, IntPtr.Zero);
        if (h != IntPtr.Zero) ClosePseudoConsole(h);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Hangup();
        try { input.Dispose(); } catch { }
        CloseHandle(thread); CloseHandle(process);
    }

    /// 目前的環境變數＋額外的（排序、雙 null 結尾的 UTF-16 區塊）
    static IntPtr EnvBlock(IDictionary<string, string>? extra)
    {
        var d = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) d[(string)e.Key] = (string?)e.Value ?? "";
        // 在 Claude Code 裡開 Orbit42（測試）時，衛星的 claude 不要以為自己是子程序
        foreach (var k in d.Keys.Where(k => k == "CLAUDECODE" || k.StartsWith("CLAUDE_CODE_", StringComparison.Ordinal) && k != "CLAUDE_CODE_GIT_BASH_PATH").ToList()) d.Remove(k);
        if (extra != null) foreach (var (k, v) in extra) d[k] = v;
        var s = string.Concat(d.Select(kv => kv.Key + "=" + kv.Value + "\0")) + "\0";
        return Marshal.StringToHGlobalUni(s);
    }

    internal static void Log(string s) { try { File.AppendAllText(Path.Combine(OrbitPaths.Support, "orbit.log"), $"{DateTime.Now:MM-dd HH:mm:ss} PTY {s}\r\n"); } catch { } }

    // MARK: Win32

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000, CREATE_UNICODE_ENVIRONMENT = 0x00000400, INFINITE = 0xFFFFFFFF;
    const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; public COORD(short x, short y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr hpc);
    [DllImport("kernel32.dll")] static extern int ResizePseudoConsole(IntPtr hpc, COORD size);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hpc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string? app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
}
