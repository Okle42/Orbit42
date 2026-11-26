import XCTest
@testable import Orbit42

/// AI 操作衛星網頁：哪些按鈕要先問 Keng（寄信、刪除、付款類）
final class WebDangerTests: XCTestCase {
    func testAsksForSendDeletePay() {
        for label in ["傳送 (⌘Enter)", "寄出", "Send", "送出訂單", "刪除", "永久刪除", "移至垃圾桶", "Delete forever", "Move to Trash",
                      "付款", "前往結帳", "Buy now", "Place order", "Checkout", "Pay NT$490", "立即購買", "訂閱 Premium", "Discard draft"] {
            XCTAssertNotNil(WebDanger.hit(label), "應該要問：\(label)")
        }
    }

    func testLeavesOrdinaryButtonsAlone() {
        for label in ["封存", "收件匣", "搜尋信件", "下一頁", "Archive", "Search", "Repost guidelines", "Payload settings", "buyer guide", "Sender info", "Open", "Reply"] {
            XCTAssertNil(WebDanger.hit(label), "不用問：\(label)")
        }
    }

    func testEnterOnlyFreeInSearchBoxes() {
        XCTAssertFalse(WebDanger.enterNeedsAsk(search: true))
        XCTAssertTrue(WebDanger.enterNeedsAsk(search: false))
    }
}
