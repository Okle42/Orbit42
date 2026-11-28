using Orbit42.Hooks;
using Xunit;

namespace Orbit42.Engine.Tests;

/// 11-28 待修⑥：Windows 答案卡打進終端機要留記號（同 Mac TypedMark），hook 才不會當成鍵盤、當場放行
[Collection("env")]
public class TypedMarkTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "orbit-typed-" + Guid.NewGuid().ToString("N"));
    public TypedMarkTests() => Environment.SetEnvironmentVariable("ORBIT_TYPED_MARKS", dir);
    public void Dispose() { Environment.SetEnvironmentVariable("ORBIT_TYPED_MARKS", null); try { Directory.Delete(dir, true); } catch { } }

    [Fact]
    public void MarkIsOneShotBoundToSessionAndText()
    {
        var t = new DateTime(2026, 11, 28, 1, 0, 0, DateTimeKind.Utc);
        Assert.True(TypedMark.Put("S1", "放行！ 部署", t));
        Assert.False(TypedMark.Take("S2", "放行！部署", t));                 // 別的 session 不算
        Assert.False(TypedMark.Take("S1", "放行！別的", t));                 // 內容對不上不算（鍵盤打的照舊放行）
        Assert.True(TypedMark.Take("S1", "放行！部署\n", t.AddSeconds(3)));  // 卡片打的：空白不同也認
        Assert.False(TypedMark.Take("S1", "放行！部署", t.AddSeconds(4)));   // 用一次就沒了
    }

    [Fact]
    public void ExpiresAndDoesNotOverwriteUnusedMark()
    {
        var t = new DateTime(2026, 11, 28, 1, 0, 0, DateTimeKind.Utc);
        Assert.True(TypedMark.Put("S1", "好", t));
        Assert.False(TypedMark.Put("S1", "不要", t.AddSeconds(1)));          // 前一句還沒用掉、內容不同：不蓋（這句不打字）
        Assert.False(TypedMark.Take("S1", "好", t.Add(TypedMark.Ttl)));      // 過期
        Assert.True(TypedMark.Put("S1", "不要", t.Add(TypedMark.Ttl)));
        Assert.False(TypedMark.Put("../x", "好", t));                        // 路徑字元不收
    }
}
