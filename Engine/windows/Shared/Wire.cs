namespace Orbit42;

/// Shared by orbit.exe (sender) and Orbit42Agent.exe (receiver): one line of JSON over a named pipe.
///   {"v":1,"event":"working","agent":"claude","pid":1234,"t":134035392000000000}\n
/// The pid is the AI process (claude.exe). It plays the role of the Mac version's tty: one AI session,
/// one entry; the agent maps it to a window. t = when the AI started the hook (FILETIME, 0 = unknown).
static class Wire
{
    public static readonly string[] Events = { "working", "done", "input", "clear" };

    /// \.\pipe\Orbit42-<user SID>. ORBIT_PIPE overrides the name (tests run a private agent).
    public static string PipeName(string sid) =>
        Environment.GetEnvironmentVariable("ORBIT_PIPE") is { Length: > 0 } p ? p : "Orbit42-" + sid;

    /// %LOCALAPPDATA%Orbit42 (state, log, install snapshot). ORBIT_HOME overrides it for tests.
    public static string SupportDir =>
        Environment.GetEnvironmentVariable("ORBIT_HOME") is { Length: > 0 } h ? h
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Orbit42");

    /// Agent names go into JSON and logs verbatim, so keep them boring.
    public static bool ValidAgent(string s) =>
        s.Length is > 0 and <= 32 && s.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');
}
