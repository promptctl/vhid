import Testing
@testable import ScreenSpace

/// The point, the box, their spelling and the layout record, as values.
@Suite struct ScreenSpaceTests {
    @Test func aPairThatIsNotFiniteIsNotAPlace() {
        #expect(throws: NotAPlace.self) { try ScreenPoint(x: .nan, y: 0) }
        #expect(throws: NotAPlace.self) { try ScreenPoint(x: 0, y: .infinity) }
    }

    @Test func aBoxRefusesWhatNoArithmeticOnItHolds() {
        #expect(throws: NotABox.self) { try ScreenRect(x: .nan, y: 0, width: 1, height: 1) }
        #expect(throws: NotABox.self) { try ScreenRect(x: 0, y: 0, width: -1, height: 1) }
        // A far edge past what a Double holds, from two finite numbers.
        #expect(throws: NotABox.self) { try ScreenRect(x: 1.7e308, y: 0, width: 1.7e308, height: 1) }
    }

    @Test func anEmptyBoxIsABox() throws {
        #expect(try ScreenRect(x: 5, y: 5, width: 0, height: 10).isEmpty)
    }

    @Test func aUnionPastADoubleIsRefused() throws {
        let left = try ScreenRect(x: -1.7e308, y: 0, width: 1, height: 1)
        let right = try ScreenRect(x: 1.7e308, y: 0, width: 1, height: 1)
        #expect(throws: NotABox.self) { try left.union(right) }
    }

    @Test func boxesEdgeToEdgeShareNoArea() throws {
        let left = try ScreenRect(x: 0, y: 0, width: 10, height: 10)
        #expect(left.intersection(try ScreenRect(x: 10, y: 0, width: 10, height: 10)) == nil)
        #expect(left.intersection(try ScreenRect(x: 9, y: 0, width: 10, height: 10)) == (try ScreenRect(x: 9, y: 0, width: 1, height: 10)))
    }

    @Test func containmentIsHalfOpen() throws {
        let box = try ScreenRect(x: 0, y: 0, width: 10, height: 10)
        #expect(box.contains(try ScreenPoint(x: 0, y: 0)))
        #expect(!box.contains(try ScreenPoint(x: 10, y: 5)))
        #expect(!box.contains(x: .nan, y: 5))
    }

    /// Rounded outward, so a negative coordinate is not moved toward zero.
    @Test func theIntegralBoxRoundsOutward() throws {
        #expect(try ScreenRect(x: -0.6, y: 10.5, width: 99.6, height: 20).integral == (try ScreenRect(x: -1, y: 10, width: 100, height: 21)))
    }

    /// What is printed reads back as itself, fractions and all.
    @Test func eachSpellingReadsBackAsItself() throws {
        let point = try ScreenPoint(x: -12.25, y: 1e20)
        #expect(try ScreenPoint(spelled: point.description) == point)
        #expect(try ScreenPoint(x: 100, y: 200).description == "100,200")
        let box = try ScreenRect(x: 0.1, y: -3, width: 2e20, height: 7)
        #expect(try ScreenRect(spelled: box.description) == box)
        #expect(try ScreenRect(x: 1, y: 2, width: 3, height: 4).description == "1,2,3,4")
    }

    @Test func aSpellingOfTheWrongFormOrNumbersIsRefused() {
        #expect(throws: Misspelled.self) { try ScreenPoint(spelled: "1,2,3") }
        #expect(throws: Misspelled.self) { try ScreenPoint(spelled: "1,x") }
        #expect(throws: Misspelled.self) { try ScreenPoint(spelled: "inf,2") }
        #expect(throws: Misspelled.self) { try ScreenRect(spelled: "1,2,-3,4") }
    }

    @Test func theLayoutRecordReadsBackAsTheLayout() throws {
        let layout = try DisplayLayout([OnlineDisplay(id: 1, frame: ScreenRect(x: 0, y: 0, width: 1600, height: 900), active: true),
                                        OnlineDisplay(id: 7, frame: ScreenRect(x: -1000, y: -200, width: 1000, height: 800), active: false)])
        #expect(try DisplayLayout(record: layout.record) == layout)
    }

    @Test func aRecordThatIsNotALayoutIsRefusedByName() {
        #expect(throws: LayoutUnreadable.noDisplay) { try DisplayLayout(record: []) }
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout(record: [1, 0, 0, 10, 10]) }
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout(record: [1, 0, 0, -10, 10, 1]) }
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout(record: [1, 0, 0, 10, 10, 2]) }
    }
}
