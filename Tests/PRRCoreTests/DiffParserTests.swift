import XCTest
@testable import PRRCore

final class DiffParserTests: XCTestCase {
    func testHunkStartParsing() {
        XCTAssertEqual(DiffParser.parseHunkStarts("@@ -10,6 +12,7 @@ func x()").old, 10)
        XCTAssertEqual(DiffParser.parseHunkStarts("@@ -10,6 +12,7 @@").new, 12)
        XCTAssertEqual(DiffParser.parseHunkStarts("@@ -0,0 +1,5 @@").new, 1)
    }

    func testNewFileAdditionsOnly() {
        let diff = """
        diff --git a/foo.txt b/foo.txt
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/foo.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let rows = DiffParser.parse(diff)
        XCTAssertEqual(rows.first?.kind, .fileHeader)
        XCTAssertEqual(rows.first?.header, "foo.txt")
        let lineRows = rows.filter { $0.kind == .line }
        XCTAssertEqual(lineRows.count, 2)
        XCTAssertTrue(lineRows.allSatisfy { $0.isChange && $0.left == nil && $0.right != nil })
        XCTAssertEqual(lineRows[0].right?.number, 1)
        XCTAssertEqual(lineRows[0].right?.text, "hello")
        XCTAssertEqual(lineRows[1].right?.number, 2)
    }

    func testModificationPairsDelAndAdd() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        """
        let rows = DiffParser.parse(diff).filter { $0.kind == .line }
        // context, paired change, context
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows[0].isChange)
        XCTAssertEqual(rows[0].left?.text, "let a = 1")
        XCTAssertEqual(rows[0].right?.text, "let a = 1")

        XCTAssertTrue(rows[1].isChange)
        XCTAssertEqual(rows[1].left?.text, "let b = 2")
        XCTAssertEqual(rows[1].right?.text, "let b = 3")
        XCTAssertEqual(rows[1].left?.number, 2)
        XCTAssertEqual(rows[1].right?.number, 2)

        XCTAssertFalse(rows[2].isChange)
        XCTAssertEqual(rows[2].left?.number, 3)
    }

    func testUnbalancedChangesGetOneSidedRows() {
        let diff = """
        diff --git a/a b/a
        @@ -1,3 +1,2 @@
         keep
        -remove1
        -remove2
        +addonly
        """
        let rows = DiffParser.parse(diff).filter { $0.kind == .line }
        // keep(context) + max(2 del, 1 add)=2 change rows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].left?.text, "remove1")
        XCTAssertEqual(rows[1].right?.text, "addonly")
        XCTAssertEqual(rows[2].left?.text, "remove2")
        XCTAssertNil(rows[2].right)
    }
}
