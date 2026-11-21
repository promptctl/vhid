import Testing
@testable import ScreenSpace

/// How a coordinate, a point and a refusal are written: what an agent reads and passes back.
@Suite struct SpellingTests {
    /// The shortest digits that read back, written out in places, with no `.0` on a whole
    /// number and no sign on zero.
    @Test func aCoordinateIsItsShortestDigitsInPlaces() {
        let spelled: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (12, "12"), (-1512, "-1512"), (0.5, "0.5"), (-2.25, "-2.25"),
            (1e-5, "0.00001"), (1.5e-7, "0.00000015"), (1e20, "100000000000000000000"),
            (-1.25e17, "-125000000000000000"), (9_007_199_254_740_992, "9007199254740992"),
            (.nan, "nan"), (.infinity, "inf"), (-.infinity, "-inf"),
        ]
        for (value, want) in spelled {
            #expect(Coordinate.spelled(value) == want, "\(value)")
        }
    }

    /// Every finite coordinate reads back as itself from how it is spelled.
    @Test func aSpelledCoordinateReadsBack() {
        for value in [0.1, 1e-5, 123.456, 1e20, 1.7976931348623157e308, 5e-324, -3.14159, 2.5e15] {
            #expect(Double(Coordinate.spelled(value)) == value, "\(value)")
        }
    }

    /// A point is two finite numbers; anything else is refused by the one refusal every door
    /// words a place that is none with.
    @Test func aPlaceIsTwoFiniteNumbers() throws {
        #expect(try ScreenPoint.at(-0.0, 3.5).description == "0,3.5")
        // A NaN equals nothing, itself included, so a refusal is told by what it says.
        #expect { try ScreenPoint.at(.nan, 1) } throws: { "\($0)" == "nan,1 is not a place on the screen" }
        #expect(throws: NotAPlace(x: 0, y: .infinity)) { try ScreenPoint.at(0, .infinity) }
        #expect(NotAPlace(x: .nan, y: 1e20).description == "nan,100000000000000000000 is not a place on the screen")
    }
}
