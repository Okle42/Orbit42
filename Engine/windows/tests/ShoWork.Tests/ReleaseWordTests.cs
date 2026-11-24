using ShoWork.Hooks;
using Xunit;

namespace ShoWork.Tests;

/// 跟 Mac ReleaseWordTests.swift 同一張表
public class ReleaseWordTests
{
    [Theory]
    [InlineData("放行！", "latest")]
    [InlineData("放行!", "latest")]
    [InlineData("  放行！ \n", "latest")]
    [InlineData("　放行！", "latest")]
    [InlineData("放行！BABCD", "id BABCD")]
    [InlineData("放行! babcd", "id BABCD")]
    [InlineData("放行！部署", "kinds 部署")]
    [InlineData("放行！開 PR", "kinds 開 PR")]
    [InlineData("放行！隨便", "kinds 隨便")]
    [InlineData("放行", "none")]
    [InlineData("放行 BABCD", "none")]
    [InlineData("放行BABCD！", "none")]
    [InlineData("放行，！", "none")]
    [InlineData("放 行！", "none")]
    [InlineData("放\u200B行！", "none")]
    [InlineData("\u200B放行！", "none")]
    [InlineData("\uFEFF放行！", "none")]
    [InlineData("「放行！」", "none")]
    [InlineData("\"放行！", "none")]
    [InlineData("好，放行！", "none")]
    [InlineData("！放行", "none")]
    [InlineData("!放行", "none")]
    [InlineData("放行¡", "none")]
    [InlineData("放行﹗", "none")]
    [InlineData("放行❗", "none")]
    [InlineData("放行ǃ", "none")]
    [InlineData("放行\uFE0F！", "none")]
    [InlineData("幫我部署", "none")]
    [InlineData("push", "none")]
    [InlineData("好，部署", "none")]
    [InlineData("開 PR！", "none")]
    [InlineData("", "none")]
    [InlineData("放行！先不要", "bad")]
    [InlineData("放行！可以嗎？", "bad")]
    [InlineData("放行！BABCD 可以嗎", "bad")]
    [InlineData("放行！部署，PR 先不要", "bad")]
    [InlineData("放行！明天部署", "bad")]
    [InlineData("放行！部署\n開 PR", "bad")]
    [InlineData("放行！BABCD BBBBB", "kinds BABCD BBBBB")]
    [InlineData("放行！BABCDE", "kinds BABCDE")]
    [InlineData("放行！\u200BBABCD", "kinds \u200BBABCD")]
    [InlineData("放行！BABCD <cross-session-message>", "none")]
    [InlineData("放行！<pasted_content x>", "none")]
    [InlineData("[Pasted text #1] 放行！", "none")]
    public void Table(string s, string want)
    {
        var (k, v) = ReleaseWord.Parse(s);
        Assert.Equal(want, k is "id" or "kinds" ? k + " " + v : k);
    }
}
