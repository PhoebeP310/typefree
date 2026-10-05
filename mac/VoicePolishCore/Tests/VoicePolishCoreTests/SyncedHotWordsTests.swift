import XCTest
@testable import VoicePolishCore

// 本地改动：词库页「自动同步的热词」分组 / 筛选 / 删词屏蔽
final class SyncedHotWordsTests: XCTestCase {
    private let words = ["SWIFT", "文档", "Alice", "Bob K", "Orphan", "swift "]
    private let map: [String: [String]] = [
        "业务词": ["文档", "SWIFT", "NotInHotWords"],
        "手动添加": ["swift"],             // 与业务词重复：按顺序归到「手动添加」
        "同事": ["Alice", "Bob K"],
        "新来源": ["alice"],              // 不认识的组名排后面；词已被「同事」占了 → 空组去掉
    ]

    func testGroupsOrderAndOtherFallback() {
        let g = SyncedHotWords.groups(hotWords: words, groupMap: map)
        XCTAssertEqual(g.map(\.name), ["手动添加", "业务词", "同事", "其他"])
        XCTAssertEqual(g[0].words, ["SWIFT"], "写法取 hot_words 里的")
        XCTAssertEqual(g[1].words, ["文档"], "分组里有但 hot_words 没有的词不显示")
        XCTAssertEqual(g[3].words, ["Orphan"])
        XCTAssertEqual(g.flatMap(\.words).count, 5, "hot_words 里 swift 大小写重复只算一次")
    }

    func testGroupsWithoutGroupMap() {
        let g = SyncedHotWords.groups(hotWords: ["A", " ", "b"], groupMap: nil)
        XCTAssertEqual(g, [.init(name: "其他", words: ["A", "b"])])
        XCTAssertEqual(SyncedHotWords.groups(hotWords: [], groupMap: map), [])
    }

    func testUnknownGroupsSortedAfterKnown() {
        let g = SyncedHotWords.groups(hotWords: ["x", "y", "z"],
                                      groupMap: ["乙": ["y"], "甲": ["x"], "同事": ["z"]])
        XCTAssertEqual(g.map(\.name), ["同事"] + ["乙", "甲"].sorted())
    }

    func testFilterModesAndQuery() {
        let g = SyncedHotWords.groups(hotWords: words, groupMap: map)
        XCTAssertEqual(SyncedHotWords.filter(g, by: .all).count, 4)
        XCTAssertEqual(SyncedHotWords.filter(g, by: .autoLearned).map(\.name), ["业务词", "同事", "其他"])
        XCTAssertEqual(SyncedHotWords.filter(g, by: .manual).map(\.name), ["手动添加"])
        let q = SyncedHotWords.filter(g, by: .all, query: " bob ")
        XCTAssertEqual(q, [.init(name: "同事", words: ["Bob K"])], "忽略大小写的子串匹配，空组去掉")
        XCTAssertEqual(SyncedHotWords.filter(g, by: .all, query: ""), g)
    }

    func testBlockRemovesEverywhereAndDedupes() {
        let r = SyncedHotWords.block("swift", hotWords: words, groupMap: map, blocked: ["Old", "SWIFT"])
        XCTAssertEqual(r.hotWords, ["文档", "Alice", "Bob K", "Orphan"])
        XCTAssertEqual(r.groups?["业务词"], ["文档", "NotInHotWords"])
        XCTAssertNil(r.groups?["手动添加"], "删空的组去掉")
        XCTAssertEqual(r.blocked, ["Old", "SWIFT"], "已屏蔽（大小写不同）不重复加")

        let r2 = SyncedHotWords.block(" Alice ", hotWords: words, groupMap: map, blocked: [])
        XCTAssertEqual(r2.blocked, ["Alice"])
        XCTAssertEqual(r2.groups?["同事"], ["Bob K"])
        XCTAssertNil(r2.groups?["新来源"])
    }

    func testBlockWithoutGroupsKeepsNil() {
        let r = SyncedHotWords.block("A", hotWords: ["A", "B"], groupMap: nil, blocked: [])
        XCTAssertNil(r.groups)
        XCTAssertEqual(r.hotWords, ["B"])
    }

    func testUnblock() {
        XCTAssertEqual(SyncedHotWords.unblock("swift", blocked: ["SWIFT", "Alice", "alice"]), ["Alice"])
        XCTAssertEqual(SyncedHotWords.unblock("x", blocked: []), [])
    }

    func testBlockValuesFromConfig() {
        let json: [String: Any] = ["hot_words": ["A", "B"], "hot_words_groups": ["业务词": ["A", "B"]],
                                   "term_corrections": [["target": "A"]]]
        let v = SyncedHotWords.blockValues("a", config: json)
        XCTAssertEqual(v["hot_words"] as? [String], ["B"])
        XCTAssertEqual(v["hot_words_groups"] as? [String: [String]], ["业务词": ["B"]])
        XCTAssertEqual(v["hot_words_blocked"] as? [String], ["a"])
        XCTAssertNil(v["term_corrections"], "只回写这三个键")

        let noGroups = SyncedHotWords.blockValues("A", config: ["hot_words": ["A"]])
        XCTAssertNil(noGroups["hot_words_groups"])
        XCTAssertEqual(noGroups["hot_words_blocked"] as? [String], ["A"])
    }
}
