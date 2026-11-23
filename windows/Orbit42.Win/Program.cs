using System.Diagnostics;

namespace Orbit42;

/// Orbit42.exe：整個 ShoWork 引擎（光暈、pipe、戰情中心、球體）跑在這裡面，主視窗＝球體＋衛星終端機。
/// Orbit42 取代 ShoWorkAgent（兩個同時跑會播報兩次、pipe 打架）：開的時候先關掉 ShoWorkAgent，結束時再把它開回來（Mac AgentSwap）。
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        var test = OrbitApp.Test;
        var agents = test ? new List<string>() : StopAgents();
        var app = new OrbitApp();
        try { return test ? ShoWork.Program.RunEmbeddedTest(app.Launch) : ShoWork.Program.RunEmbedded(app.Launch); }
        finally
        {
            app.Shutdown();
            foreach (var exe in agents) try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true }); } catch { }
        }
    }

    /// 關掉正在跑的 ShoWorkAgent（記下路徑，結束時開回來）
    static List<string> StopAgents()
    {
        var paths = new List<string>();
        foreach (var p in Process.GetProcessesByName("ShoWorkAgent"))
            try
            {
                var exe = p.MainModule?.FileName;
                p.Kill(); p.WaitForExit(5000);
                if (exe != null && !paths.Contains(exe)) paths.Add(exe);
                OrbitApp.Log($"stopped ShoWorkAgent pid={p.Id} {exe}");
            }
            catch (Exception x) { OrbitApp.Log($"stop agent failed {x.Message}"); }
        return paths;
    }
}
