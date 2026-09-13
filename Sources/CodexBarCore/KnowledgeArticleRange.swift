import Foundation

public enum KnowledgeArticleRange: String, CaseIterable, Sendable {
    case today
    case yesterday
    case lastSevenDays

    public var title: String {
        switch self {
        case .today: "今天"
        case .yesterday: "昨天"
        case .lastSevenDays: "近七天"
        }
    }

    public var heading: String {
        switch self {
        case .today: "今日新增"
        case .yesterday: "昨日新增"
        case .lastSevenDays: "近七天新增"
        }
    }

    public func interval(relativeTo date: Date) -> DateInterval {
        let calendar = KnowledgeArticle.collectionCalendar
        let today = calendar.startOfDay(for: date)
        let startOffset = self == .yesterday ? -1 : (self == .lastSevenDays ? -6 : 0)
        return DateInterval(
            start: calendar.date(byAdding: .day, value: startOffset, to: today)!,
            end: calendar.date(byAdding: .day, value: self == .yesterday ? 0 : 1, to: today)!
        )
    }
}
