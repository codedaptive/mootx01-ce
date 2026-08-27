import Testing
@testable import NeuronKit

@Suite("QueryDateWindow — absolute date-expression parsing (golden pins)")
struct QueryDateWindowTests {

    // Golden pins: literal twins of query_date_window.rs tests.
    @Test("day-month-year forms pin to one-day windows")
    func dayMonthYearPins() {
        #expect(parseQueryDateExpression("What happened on 8 May 2023 at the fair?")
                == .anchored([QueryDateWindow(
                    start: "2023-05-08T00:00:00Z",
                    end: "2023-05-08T23:59:59Z",
                    matchedText: "8 may 2023")]))
        #expect(parseQueryDateExpression("On May 8, 2023 she left.")
                == .anchored([QueryDateWindow(
                    start: "2023-05-08T00:00:00Z",
                    end: "2023-05-08T23:59:59Z",
                    matchedText: "may 8 2023")]))
        #expect(parseQueryDateExpression("The 2023-05-08 entry")
                == .anchored([QueryDateWindow(
                    start: "2023-05-08T00:00:00Z",
                    end: "2023-05-08T23:59:59Z",
                    matchedText: "2023-05-08")]))
    }

    @Test("month-year pins to a month window with correct end day")
    func monthYearPins() {
        #expect(parseQueryDateExpression("back in February 2024")
                == .anchored([QueryDateWindow(
                    start: "2024-02-01T00:00:00Z",
                    end: "2024-02-29T23:59:59Z",   // 2024 is a leap year
                    matchedText: "february 2024")]))
    }

    @Test("month-only returns the month for estate-span expansion")
    func monthOnlyPin() {
        #expect(parseQueryDateExpression("When did Melanie go camping in July?")
                == .monthOnly(month: 7, matchedText: "july"))
        #expect(expandMonthOnly(month: 7, matchedText: "july", years: 2022...2023)
                == [QueryDateWindow(start: "2022-07-01T00:00:00Z",
                                    end: "2022-07-31T23:59:59Z", matchedText: "july"),
                    QueryDateWindow(start: "2023-07-01T00:00:00Z",
                                    end: "2023-07-31T23:59:59Z", matchedText: "july")])
    }

    @Test("year-only pins to a year window")
    func yearOnlyPin() {
        #expect(parseQueryDateExpression("everything from 2023")
                == .anchored([QueryDateWindow(
                    start: "2023-01-01T00:00:00Z",
                    end: "2023-12-31T23:59:59Z",
                    matchedText: "2023")]))
    }

    @Test("no date expression yields none")
    func noneCases() {
        #expect(parseQueryDateExpression("What is Melanie's favorite song?") == .none)
        #expect(parseQueryDateExpression("mayonnaise recipes and marching bands") == .none)
    }

    @Test("day without a year reads as month-only, never a guessed day")
    func dayWithoutYear() {
        #expect(parseQueryDateExpression("they met on 8 May at the market")
                == .monthOnly(month: 5, matchedText: "may"))
    }

    @Test("window containment is inclusive and lexicographic")
    func containment() {
        let w = QueryDateWindow(start: "2023-07-01T00:00:00Z",
                                end: "2023-07-31T23:59:59Z", matchedText: "july")
        #expect(windowContains(w, eventTime: "2023-07-17T14:31:00Z"))
        #expect(windowContains(w, eventTime: "2023-07-01T00:00:00Z"))
        #expect(!windowContains(w, eventTime: "2023-08-01T00:00:00Z"))
    }

    @Test("paddedWindow widens both bounds across month and year edges")
    func paddedWindowPins() {
        let w = QueryDateWindow(start: "2023-10-03T00:00:00Z",
                                end: "2023-10-03T23:59:59Z", matchedText: "x")
        let p1 = paddedWindow(w, days: 1)
        #expect(p1.start == "2023-10-02T00:00:00Z")
        #expect(p1.end == "2023-10-04T23:59:59Z")
        // Month edge and leap-year edge.
        let feb = QueryDateWindow(start: "2024-03-01T00:00:00Z",
                                  end: "2024-03-01T23:59:59Z", matchedText: "x")
        let p2 = paddedWindow(feb, days: 1)
        #expect(p2.start == "2024-02-29T00:00:00Z")
        #expect(p2.end == "2024-03-02T23:59:59Z")
        // Year edge, 10-day cap shape.
        let jan = QueryDateWindow(start: "2023-01-05T00:00:00Z",
                                  end: "2023-01-05T23:59:59Z", matchedText: "x")
        let p3 = paddedWindow(jan, days: 10)
        #expect(p3.start == "2022-12-26T00:00:00Z")
        #expect(p3.end == "2023-01-15T23:59:59Z")
        #expect(paddedWindow(w, days: 0) == w)
    }

    @Test("date-seeking intent pins")
    func dateSeekingPins() {
        #expect(isDateSeekingQuery("When did Melanie go camping?"))
        #expect(isDateSeekingQuery("What date was the gala in Boston?"))
        #expect(isDateSeekingQuery("how long ago did they meet"))
        #expect(!isDateSeekingQuery("Which city was Calvin at on October 3, 2023?"))
        #expect(!isDateSeekingQuery("What is Melanie's favorite song?"))
    }
}
