import Foundation
import Testing
@testable import Orbit42Core

@Suite("CardOrder")
struct CardOrderTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func live(_ s: String...) -> [(sid: String, prev: [String])] { s.map { x in let p = x.split(separator: "<").map(String.init); return (p[0], Array(p.dropFirst())) } }

    @Test func defaultUntilDragged() {
        var o = CardOrder()
        #expect(o.reconcile(live("a", "b", "a", "c"), now: t0) == ["a", "b", "c"] && !o.manual)
        o.apply(["c", "a", "b"], live: live("a", "b", "c"), now: t0)
        #expect(o.manual && o.reconcile(live("a", "b", "c"), now: t0) == ["c", "a", "b"])
    }

    @Test func arrangeNeverLosesOrDuplicates() {
        #expect(CardOrder.arrange(["a", "b", "c", "d"], wanted: ["d", "a"]) == ["d", "b", "c", "a"])      // 只動佔的格子
        #expect(CardOrder.arrange(["a", "b", "c"], wanted: ["c", "c", "x", "a", "c"]) == ["c", "b", "a"])
        #expect(CardOrder.arrange(["a", "b"], wanted: []) == ["a", "b"])
        var g = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let all = (0..<Int.random(in: 0...12, using: &g)).map { "s\($0)" }
            let w = (0..<Int.random(in: 0...20, using: &g)).map { _ in "s\(Int.random(in: 0...15, using: &g))" }
            #expect(CardOrder.arrange(all, wanted: w).sorted() == all.sorted())
        }
    }

    @Test func offlineComesBackToItsPlaceForSevenDays() {
        var o = CardOrder(); o.apply(["c", "a", "b"], live: live("a", "b", "c"), now: t0)
        #expect(o.reconcile(live("b", "c"), now: t0 + 60) == ["c", "b"])
        #expect(o.reconcile(live("b", "c", "n"), now: t0 + 90) == ["c", "b", "n"])                       // 新來的放最後
        #expect(o.reconcile(live("a", "b", "c", "n"), now: t0 + 6 * 86400) == ["c", "a", "b", "n"])
        _ = o.reconcile(live("b", "c", "n"), now: t0 + 13.5 * 86400)      // 平常一直在更新：6 天那次之後過了 7 天就忘掉
        #expect(o.reconcile(live("a", "b", "c", "n"), now: t0 + 14 * 86400) == ["c", "b", "n", "a"])     // 7 天沒來就當新的
    }

    @Test func clearAndHandoverKeepPlace() {
        var o = CardOrder(); o.apply(["c", "a", "b"], live: live("a", "b", "c"), now: t0)
        #expect(o.reconcile(live("a2<a", "b", "c"), now: t0 + 5) == ["c", "a2", "b"])
        #expect(o.reconcile(live("a3<a<a2", "b", "c"), now: t0 + 6) == ["c", "a3", "b"])
        // 看板先看到新 id、晚一拍才知道它是誰：先當新人放最後，知道了就回原位，不會有兩格
        #expect(o.reconcile(live("b", "c2", "a3"), now: t0 + 7) == ["a3", "b", "c2"])
        #expect(o.reconcile(live("b", "c2<c", "a3"), now: t0 + 8) == ["c2", "a3", "b"])
        #expect(Set(o.entries.map(\.key)).count == o.entries.count)
        // 舊對話還開著（/resume 回去）⇒ 各算各的
        #expect(o.reconcile(live("b", "c2", "a3", "z<b"), now: t0 + 9) == ["c2", "a3", "b", "z"])
    }

    @Test func twoSidesLastWins() {
        let l = live("a", "b", "c", "d")
        var o = CardOrder()
        o.apply(["b", "a", "c", "d"], live: l, now: t0)          // Mac
        o.apply(["a", "b", "d", "c"], live: l, now: t0 + 1)      // 手機後放開
        #expect(o.reconcile(l, now: t0 + 2) == ["a", "b", "d", "c"] && o.entries.count == 4)
        // 手機手上是 /clear 前的 id、少一個新人
        o.apply(["c", "d", "b", "a"], live: live("a2<a", "b", "c", "d", "n"), now: t0 + 3)
        #expect(o.reconcile(live("a2<a", "b", "c", "d", "n"), now: t0 + 4) == ["c", "d", "b", "a2", "n"])
        // 全是不認得的：什麼都不變
        let was = o; o.apply(["x", "y"], live: live("a2<a", "b", "c", "d", "n"), now: t0 + 5); #expect(o == was)
    }

    @Test func partialFromSatelliteList() {
        var o = CardOrder(); o.apply(["a", "b", "c", "d"], live: live("a", "b", "c", "d"), now: t0)
        o.apply(["d", "b"], live: live("a", "b", "c", "d"), now: t0)
        #expect(o.reconcile(live("a", "b", "c", "d"), now: t0) == ["a", "d", "c", "b"])
    }

    @Test func limitDropsOldestOfflineOnly() {
        var o = CardOrder(); o.apply(["a", "b"], live: live("a", "b"), now: t0)
        for i in 0..<CardOrder.limit { o.entries.append(.init(key: "o\(i)", seen: t0 + Double(i))) }
        #expect(o.reconcile(live("a", "b"), now: t0 + 1000) == ["a", "b"] && o.entries.count == CardOrder.limit && !o.entries.contains { $0.key == "o0" })
    }

    @Test func roundTrip() throws {
        var o = CardOrder(); o.apply(["b", "a"], live: live("a", "b"), now: t0)
        #expect(try BoardJSON.decoder.decode(CardOrder.self, from: BoardJSON.encoder.encode(o)) == o)
    }

    @Test func endpointOnlyTakesOrder() {
        func p(_ s: String) -> WebRouter.OrderRequest? { WebRouter.parseOrder(Data(s.utf8)) }
        #expect(p(#"{"ids":["ab-1","c"]}"#) == .set(["ab-1", "c"]) && p(#"{"reset":true}"#) == .reset)
        for bad in ["", "[]", "{}", #"{"ids":[]}"#, #"{"ids":["../x"]}"#, #"{"ids":["a"],"text":"x"}"#, #"{"ids":["a"],"reset":true}"#, #"{"reset":1}"#, #"{"reset":false}"#, #"{"ids":"a"}"#, #"{"ids":[1]}"#] { #expect(p(bad) == nil, "\(bad)") }
        #expect(p("{\"ids\":[" + Array(repeating: "\"a\"", count: 201).joined(separator: ",") + "]}") == nil)
        let tok = WebToken.generate()
        var lim = WebRateLimiter(perMinute: 60, minGap: 0.2), got: [WebRouter.OrderRequest] = []
        var clock = t0
        func run(_ method: String = "POST", token: String? = nil, peer: String = "100.70.1.2", type: String = "application/json", body: String = #"{"ids":["a"]}"#) -> Int {
            clock += 1
            var h = ["content-type": type]; h["x-orbit-token"] = token ?? tok
            return WebRouter.handleOrder(WebRequest(method: method, path: "/api/order", query: [:], headers: h, body: Data(body.utf8)), peer: peer, localIP: "100.70.1.1", token: tok, now: clock, limiter: &lim, order: { got.append($0); return true }).status
        }
        #expect(run() == 200 && got == [.set(["a"])])
        #expect(run(token: "bad") == 403 && run(peer: "192.168.1.2") == 403 && run(peer: "100.70.1.1") == 403 && run("GET") == 405 && run(type: "text/plain") == 415 && run(body: #"{"ids":["a"],"x":1}"#) == 400)
        #expect(got.count == 1)
    }
}
