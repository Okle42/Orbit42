using System.Text;
using System.Text.RegularExpressions;

namespace Orbit42.Hooks;

/// 擋單比對：把包裝裡面真正會跑的指令也切出來（Mac Unwrap.swift 的移植，防冒充方案 A）。只會多切出，原本的段不變。
/// Windows 沒做：呼叫者程序鏈、秘書登記要同意、orbit guard 開關
static class Unwrap
{
    public const string Opaque = "‹解不開的包裝›";
    public static readonly HashSet<string> Shells = new() { "sh", "bash", "zsh", "dash", "ksh" };
    static readonly Dictionary<string, string[]> Carriers = new()
    {
        ["sudo"] = new[] { "-u", "-g", "-h", "-p", "-C" }, ["env"] = new[] { "-u", "-S", "-C", "-P" }, ["command"] = new string[0], ["builtin"] = new string[0], ["nohup"] = new string[0], ["time"] = new[] { "-o", "-f" }, ["exec"] = new[] { "-a" },
        ["nice"] = new[] { "-n" }, ["ionice"] = new[] { "-c", "-n" }, ["caffeinate"] = new[] { "-t", "-w" }, ["timeout"] = new[] { "-s", "-k" }, ["gtimeout"] = new[] { "-s", "-k" }, ["stdbuf"] = new[] { "-i", "-o", "-e" }, ["setsid"] = new string[0],
        ["arch"] = new string[0], ["xcrun"] = new[] { "--sdk", "-sdk" }, ["doas"] = new[] { "-u" }, ["xargs"] = new[] { "-I", "-J", "-L", "-n", "-P", "-s", "-R", "-E", "-a", "-d" },
    };
    static bool M(string s, string p) => Regex.IsMatch(s, p, RegexOptions.CultureInvariant);

    public static List<string> Inner(string seg, int depth = 0)
    {
        if (depth >= 5) return new() { Opaque };
        var o = Substitutions(seg).SelectMany(x => All(x, depth + 1)).ToList();
        var tok = Tokens(seg);
        if (tok.Count == 0) return o;
        o.AddRange(Run(tok, depth, !seg.StartsWith(tok[0], StringComparison.Ordinal) || tok[0].Contains('/')));
        return o;
    }
    static List<string> All(string script, int depth) =>
        CaptainLink.RawSegments(script).SelectMany(s => new[] { CaptainLink.BlankQuotes(s) }.Concat(Inner(s, depth))).ToList();

    static List<string> Run(List<string> t0, int depth, bool changed)
    {
        var t = new List<string>(t0); bool piped = false;
        for (int hops = 0; t.Count > 0 && hops < 8; hops++)
        {
            if (M(t[0], "^[A-Za-z_][A-Za-z0-9_]*=")) { t.RemoveAt(0); changed = true; continue; }
            var c = Base(t[0]);
            if (!Carriers.TryGetValue(c, out var skip)) break;
            piped |= c == "xargs"; t.RemoveAt(0); changed = true;
            while (t.Count > 0 && t[0].StartsWith('-'))
            {
                var x = t[0]; t.RemoveAt(0);
                if (x == "--") break;
                if (skip.Contains(x) && t.Count > 0) { var v = t[0]; t.RemoveAt(0); if (c == "env" && x == "-S") return All(v, depth + 1); }
            }
            if (c is "timeout" or "gtimeout" && t.Count > 0) t.RemoveAt(0);
            if (c == "command" && (t0.Contains("-v") || t0.Contains("-V"))) return new();
        }
        if (t.Count == 0) return new();
        var n = Base(t[0]); var args = t.Skip(1).ToList();
        if (Shells.Contains(n))
        {
            for (int i = 0; i < args.Count && (args[i].StartsWith('-') || args[i].StartsWith('+'));)
            {
                if (M(args[i], @"^-[a-zA-Z]*c[a-zA-Z]*\z")) return args.Skip(i + 1).FirstOrDefault(x => !x.StartsWith('-')) is { } s ? Script(s, depth) : new() { Opaque };
                i += args[i] is "-o" or "+o" ? 2 : 1;
            }
            return new();
        }
        if (n == "eval") return args.Count == 0 ? new() : Script(string.Join(" ", args), depth);
        if (n == "find") return Find(args, depth);
        if (M(n, @"^(python|python3(\.\d+)?|node|perl|ruby)\z"))
        {
            var k = args.FindIndex(x => x is "-c" or "-e" or "-E" or "--eval" or "-Ic" or "-ne" or "-pe");
            if (k >= 0 && k + 1 < args.Count) return Deletes(args[k + 1]) ? new() { "rm " + n + "‹程式刪檔›" } : new();
        }
        if (!changed) return new();
        var a = args.Select(x => x.Length == 0 ? "Q" : Regex.Replace(x, @"\s", "_")).Prepend(n);
        if (piped && n == "rm") a = a.Append("‹管線給的檔名›");
        return new() { string.Join(" ", a) };
    }
    static List<string> Script(string s, int depth) =>
        M(s.Trim(), @"^[""']?\$(\{?[A-Za-z_@*#0-9]+[^}\s]*\}?)[""']?\z") ? new() { Opaque } : All(s.Trim(), depth + 1);
    static List<string> Find(List<string> a, int depth)
    {
        var roots = string.Join(" ", a.TakeWhile(x => !x.StartsWith('-') && x != "(" && x != "!"));
        var o = new List<string>();
        for (int i = 0; i < a.Count; i++)
        {
            if (a[i] == "-delete") o.Add("rm " + (roots.Length == 0 ? "." : roots));
            if (a[i] is "-exec" or "-execdir" or "-ok" or "-okdir")
            {
                var body = a.Skip(i + 1).TakeWhile(x => x != ";" && x != "+").Select(x => x == "{}" ? (roots.Length == 0 ? "." : roots + "/x") : x).ToList();
                o.AddRange(Run(body, depth + 1, true)); i += body.Count;
            }
        }
        return o;
    }
    static bool Deletes(string code) => M(code, @"\bos\.(remove|unlink|rmdir|removedirs)\b|\bshutil\.rmtree\b|\.(unlink|rmdir)\s*\(|\b(rmSync|unlinkSync|rmdirSync)\b|\bfs(\.promises)?\.(rm|unlink|rmdir)\b|\bunlink\s*[\s(]|\brmtree\b|\bFileUtils\.rm|\bFile\.delete\b");
    public static List<string> InSubstitutions(string s) => Substitutions(s).SelectMany(x => All(x, 1)).ToList();
    /// 開頭是變數的指令（同 Mac Unwrap.variable）
    public static List<string> Variable(string seg, string cmd)
    {
        var alt = Regex.Match(seg, @"^\$\{\w+:[+=-]([^}]*)\}\s*", RegexOptions.CultureInvariant);
        if (alt.Success) { var r = seg[alt.Length..]; return new[] { r, alt.Groups[1].Value + " " + r }.Where(x => x.Trim().Length > 0).ToList(); }
        var m = Regex.Match(seg, @"^""?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?([^\s""]*)""?(?=\s|\z)", RegexOptions.CultureInvariant);
        if (!m.Success || M(seg, @"^\$\{?\w+\}?\s*[-+*/%<>=]\s*[$0-9]")) return new();
        string name = m.Groups[1].Value, tail = m.Groups[2].Value, rest = seg[m.Length..];
        string? Literal(string v) { var b = Base(v); return v.Contains('/') && !v.EndsWith('/') && !b.Contains('$') && !b.Contains('`') && !b.Contains(')') && !b.Contains(' ') ? b : null; }
        if (Literal(tail) is { } t) return new() { t + rest };
        var vs = Values(name, cmd);
        if (vs.Count == 0) return rest.Trim().Length == 0 && tail.Length == 0 && !seg.StartsWith('"') ? new() : new() { Opaque };
        string? One(string raw)
        {
            var v = string.Join(" ", Tokens(raw)) + tail;
            var w = Regex.Match(v, @"^\$\((?:command -v|which)\s+([\w.-]+)", RegexOptions.CultureInvariant);
            if (w.Success) return w.Groups[1].Value + rest;
            if (v.Contains("$(", StringComparison.Ordinal) || v.Contains('`')) return v.EndsWith(')') ? null : Literal(v) is { } l ? l + rest : null;
            if (seg.StartsWith('"')) { var b = Base(v); if (v.Contains('/') && b.Length > 0 && !b.Contains('$')) return b + rest; }
            else if (v.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() is { } f && Literal(f) is { } l2) return l2 + v[f.Length..] + rest;
            return v.Length == 0 || v.StartsWith('$') ? null : v + rest;
        }
        var o = vs.Select(One).OfType<string>().ToList();
        return o.Count == 0 ? new() { Opaque } : o;
    }
    static List<string> Values(string name, string cmd)
    {
        var o = new List<string>();
        foreach (Match m in Regex.Matches(cmd, @"(?:^|[;&|\n(\s])" + name + "=", RegexOptions.CultureInvariant))
        {
            var b = new StringBuilder(); char? q = null; int depth = 0; char prev = ' ';
            foreach (var c in cmd[(m.Index + m.Length)..])
            {
                if (q is { } k) { b.Append(c); if (c == k) q = null; prev = c; continue; }
                if (c is '"' or '\'') { q = c; b.Append(c); prev = c; continue; }
                if (c == '(' && (prev == '$' || depth > 0)) depth++;
                else if (c == ')') { if (depth == 0) break; depth--; }
                else if (depth == 0 && (char.IsWhiteSpace(c) || c is ';' or '&' or '|') && prev != '\\') break;
                b.Append(c); prev = c;
            }
            if (b.Length > 0) o.Add(b.ToString());
        }
        return o;
    }
    public static bool HeredocDeletes(string cmd) =>
        Regex.Matches(cmd, @"\b(?:python[0-9.]*|node|perl|ruby)\b[^\n|;]*<<-?\s*['""]?(\w+)['""]?[^\n]*\n(.*?)\n\s*\1\b", RegexOptions.Singleline | RegexOptions.CultureInvariant).Any(m => Deletes(m.Groups[2].Value));
    public static string Base(string s) => s.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? s;

    static List<string> Substitutions(string c)
    {
        var o = new List<string>(); bool single = false, dbl = false;
        for (int i = 0; i < c.Length; i++)
        {
            if (c[i] == '\\' && !single) { i++; continue; }
            if (c[i] == '\'' && !dbl) single = !single;
            else if (c[i] == '"' && !single) dbl = !dbl;
            else if (dbl && c[i] == '$' && i + 2 < c.Length && c[i + 1] == '(' && c[i + 2] != '(')
            {
                int d = 1, j = i + 2; for (; j < c.Length && d > 0; j++) { if (c[j] == '(') d++; else if (c[j] == ')') d--; }
                var e = Math.Max(i + 2, d == 0 ? j - 1 : j);
                o.Add(c[(i + 2)..e]); i = j - 1;
            }
            else if (dbl && c[i] == '`' && c.IndexOf('`', i + 1) is var e2 && e2 > 0) { o.Add(c[(i + 1)..e2]); i = e2; }
        }
        return o;
    }
    public static List<string> Tokens(string s)
    {
        var o = new List<string>(); var cur = new StringBuilder(); bool has = false, esc = false; char? q = null;
        foreach (var ch in s)
        {
            if (esc) { if (ch != '\n') { cur.Append(ch); has = true; } esc = false; continue; }
            if (ch == '\\' && q != '\'') { esc = true; continue; }
            if (q is { } k) { if (ch == k) q = null; else cur.Append(ch); continue; }
            if (ch is '\'' or '"') { q = ch; has = true; continue; }
            if (char.IsWhiteSpace(ch)) { if (has) { o.Add(cur.ToString()); cur.Clear(); has = false; } continue; }
            cur.Append(ch); has = true;
        }
        if (has) o.Add(cur.ToString());
        return o;
    }
}
