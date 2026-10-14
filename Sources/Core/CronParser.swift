import Foundation

/// 标准 5 段 cron：分 时 日 月 周
/// 支持 `*`、`a`、`a-b`、`a-b/n`、`*/n`、`a,b,c`
struct CronParser {

    private var minutes: [Int] = []
    private var hours: [Int] = []
    private var days: [Int] = []
    private var months: [Int] = []
    private var weekdays: [Int] = []
    private let restrictedDay: Bool
    private let restrictedWeekday: Bool

    private static let bounds: [(Int, Int)] = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 6)]

    init?(_ expression: String) {
        let parts = expression
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count == 5 else { return nil }

        var fields: [[Int]] = []
        for (idx, raw) in parts.enumerated() {
            let (lo, hi) = CronParser.bounds[idx]
            guard let values = CronParser.parse(raw, lo: lo, hi: hi) else { return nil }
            fields.append(values)
        }
        minutes = fields[0]
        hours = fields[1]
        days = fields[2]
        months = fields[3]
        weekdays = fields[4].map { $0 == 7 ? 0 : $0 }

        restrictedDay = parts[2] != "*"
        restrictedWeekday = parts[4] != "*"
    }

    private static func parse(_ field: String, lo: Int, hi: Int) -> [Int]? {
        var result = Set<Int>()
        for token in field.split(separator: ",") {
            var body = String(token)
            var step = 1
            if let slash = body.firstIndex(of: "/") {
                let stepStr = String(body[body.index(after: slash)...])
                guard let s = Int(stepStr), s > 0 else { return nil }
                step = s
                body = String(body[..<slash])
            }

            var start = lo
            var end = hi
            if body == "*" || body.isEmpty {
                // 全范围
            } else if let dash = body.firstIndex(of: "-") {
                guard let a = Int(body[..<dash]),
                      let b = Int(body[body.index(after: dash)...]) else { return nil }
                start = a; end = b
            } else {
                guard let a = Int(body) else { return nil }
                start = a; end = a
            }

            guard start >= lo, end <= hi, start <= end else { return nil }
            var v = start
            while v <= end {
                result.insert(v)
                v += step
            }
        }
        return result.sorted()
    }

    /// 返回给定时间之后的下一次触发时间
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let minute = comps.minute, let hour = comps.hour else { return nil }
        comps.second = 0

        // 从下一分钟开始找，最多找 366 天
        var cursor = calendar.date(from: comps) ?? date
        cursor = calendar.date(byAdding: .minute, value: 1, to: cursor) ?? cursor

        for _ in 0..<(366 * 24 * 60) {
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: cursor)
            guard let m = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let wd = c.weekday else { return nil }

            if months.contains(m) {
                // 星期：Calendar 中 1=周日，cron 中 0=周日
                let cronWeekday = wd - 1
                let dayOk = days.contains(d)
                let weekOk = weekdays.contains(cronWeekday)

                var dateMatch: Bool
                if restrictedDay && restrictedWeekday {
                    dateMatch = dayOk || weekOk     // 与标准 vixie-cron 一致：任一匹配即触发
                } else if restrictedDay {
                    dateMatch = dayOk
                } else if restrictedWeekday {
                    dateMatch = weekOk
                } else {
                    dateMatch = true
                }

                if dateMatch && hours.contains(h) && minutes.contains(mi) {
                    return cursor
                }
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        _ = minute; _ = hour
        return nil
    }

    var isValid: Bool { true }

    /// 人类可读的粗略描述，用于列表展示
    static func describe(_ expression: String) -> String {
        let e = expression.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return "手动触发" }
        let p = e.split(separator: " ").map(String.init)
        guard p.count == 5 else { return e }
        let min = p[0], hour = p[1], day = p[2], month = p[3], week = p[4]

        if min.hasPrefix("*/"), hour == "*", day == "*", month == "*", week == "*" {
            return "每 \(min.dropFirst(2)) 分钟"
        }
        if hour.hasPrefix("*/"), min == "0", day == "*", month == "*", week == "*" {
            return "每 \(hour.dropFirst(2)) 小时"
        }
        if min.contains(","), hour == "*" {
            return "每小时的第 \(min) 分钟"
        }
        if week == "0", min != "*", hour != "*" {
            return "每周日 \(hour):\(String(format: "%02d", Int(min) ?? 0))"
        }
        return e
    }
}
