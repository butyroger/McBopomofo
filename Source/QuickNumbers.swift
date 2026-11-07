// Copyright (c) 2026 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR

import ChineseNumbers
import Foundation

/// Formats of a number typed after the text template key, such as a date
/// (2023.09.07), a time (12:30), an amount (6548), or an arithmetic
/// expression (10*15/6).
@objc class QuickNumbers: NSObject {
    private static let digits = Array("〇一二三四五六七八九")
    private static let uppercaseDigits = Array("零壹貳參肆伍陸柒捌玖")
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    /// Whether the code looks like a number, so that it is not a text template.
    @objc static func isNumberCode(_ code: String) -> Bool {
        guard let first = code.first, first.isASCII, first.isNumber || first == "(" else {
            return false
        }
        return code.allSatisfy { $0.isASCII && ($0.isNumber || "./-:+*()".contains($0)) }
    }

    @objc static func candidates(for code: String) -> [String] {
        guard isNumberCode(code) else {
            return []
        }
        var results = date(code) + time(code)
        if code.allSatisfy({ $0.isNumber || $0 == "." }) {
            results += amount(code)
        } else if let value = Expression.evaluate(code) {
            results += arithmetic(code, value: value)
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }

    // MARK: - Date

    private static func date(_ code: String) -> [String] {
        let parts = code.split(whereSeparator: { "./-".contains($0) }).map(String.init)
        let separators = code.filter { "./-".contains($0) }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
            Set(separators).count == 1
        else {
            return []
        }
        var year: Int
        var hasYear = true
        let month: Int
        let day: Int
        switch parts.count {
        case 3:
            guard let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
                return []
            }
            // A year of the Republic of China, such as 112.9.7.
            year = parts[0].count <= 3 ? y + 1911 : y
            month = m
            day = d
        case 2 where separators == "/":
            // Like 9/7, which is also a division.
            guard let m = Int(parts[0]), let d = Int(parts[1]) else {
                return []
            }
            year = Calendar(identifier: .gregorian).component(.year, from: Date())
            hasYear = false
            month = m
            day = d
        default:
            return []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard (1...12).contains(month), (1...31).contains(day), (1...9999).contains(year),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.day, from: date) == day
        else {
            return []
        }
        let weekday = "（星期\(weekdays[calendar.component(.weekday, from: date) - 1])）"
        let monthDay = "\(month)月\(day)日"
        let chineseMonthDay = "\(chineseNumber(month))月\(chineseNumber(day))日"
        var results: [String] = []
        if hasYear {
            let chineseYear = String(String(year).map { digits[Int(String($0))!] })
            results += [
                "\(year)年\(monthDay)\(weekday)",
                "\(chineseYear)年\(chineseMonthDay)\(weekday)",
                "中華民國\(year - 1911)年\(monthDay)\(weekday)",
                "民國\(year - 1911)年\(monthDay)",
                "西元\(year)年\(monthDay)\(weekday)",
                String(format: "%04d/%02d/%02d", year, month, day),
                String(format: "%04d-%02d-%02d", year, month, day),
            ]
        }
        results += ["\(monthDay)\(weekday)", "\(chineseMonthDay)\(weekday)"]
        return results
    }

    // MARK: - Time

    private static func time(_ code: String) -> [String] {
        let parts = code.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
            parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else {
            return []
        }
        let period = hour < 12 ? "上午" : "下午"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        let chineseMinute = minute == 0 ? "" : (minute < 10 ? "零" : "") + chineseNumber(minute) + "分"
        let minuteText = minute == 0 ? "" : "\(minute)分"
        let hhmm = String(format: "%d:%02d", hour12, minute)
        return [
            "\(hour)時\(minute)分",
            "\(period)\(chineseNumber(hour12))點\(chineseMinute)",
            "\(period)\(hour12)點\(minuteText)",
            "\(hhmm) \(ampm)",
            "\(ampm) \(hhmm)",
            String(format: "%02d:%02d", hour, minute),
        ]
    }

    // MARK: - Amount

    private static func amount(_ code: String) -> [String] {
        let parts = code.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let intPart = parts.first, !intPart.isEmpty, intPart.count <= 16 else {
            return []
        }
        let decPart = parts.count == 2 ? parts[1] : ""
        let grouped = groupedNumber(intPart) + (decPart.isEmpty ? "" : ".\(decPart)")
        let lowercase = ChineseNumbers.generate(intPart: intPart, decPart: decPart, digitCase: .lowercase)
        let uppercase = ChineseNumbers.generate(intPart: intPart, decPart: decPart, digitCase: .uppercase)
        var results = [grouped]
        if decPart.isEmpty {
            results += [
                "\(uppercase)元整",
                lowercase,
                "\(grouped)元",
                "NT$\(grouped)",
                String(intPart.map { digits[Int(String($0))!] }),
                String(intPart.map { uppercaseDigits[Int(String($0))!] }),
            ]
        } else {
            results += [lowercase, uppercase, "\(grouped)元"]
        }
        return results
    }

    // MARK: - Arithmetic

    private static func arithmetic(_ code: String, value: Double) -> [String] {
        let result = formatted(value)
        let pretty = code.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")
        var results = [result, "\(code)=\(result)", "\(pretty)=\(result)"]
        if value >= 0, value == value.rounded(), value < 1e16 {
            let intPart = String(Int64(value))
            results += [
                "\(groupedNumber(intPart))元",
                "\(ChineseNumbers.generate(intPart: intPart, decPart: "", digitCase: .uppercase))元整",
                ChineseNumbers.generate(intPart: intPart, decPart: "", digitCase: .lowercase),
            ]
        }
        return results
    }

    // MARK: - Helpers

    /// 1 to 99 in Chinese, such as 十二 and 三十.
    private static func chineseNumber(_ number: Int) -> String {
        if number < 10 {
            return String(digits[number])
        }
        let tens = number / 10
        let ones = number % 10
        return (tens == 1 ? "" : String(digits[tens])) + "十" + (ones == 0 ? "" : String(digits[ones]))
    }

    private static func groupedNumber(_ intPart: String) -> String {
        var result = ""
        for (index, c) in intPart.reversed().enumerated() {
            if index > 0 && index % 3 == 0 {
                result.append(",")
            }
            result.append(c)
        }
        return String(result.reversed())
    }

    private static func formatted(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e16 {
            return String(Int64(value))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return text
    }
}

/// Evaluates +, -, *, / and parentheses.
private struct Expression {
    private let characters: [Character]
    private var index = 0

    static func evaluate(_ text: String) -> Double? {
        // At least one operator, or it is just a number.
        guard text.contains(where: { "+-*/".contains($0) }) else {
            return nil
        }
        var parser = Expression(characters: Array(text))
        guard let value = parser.expression(), parser.index == parser.characters.count,
            value.isFinite
        else {
            return nil
        }
        return value
    }

    private init(characters: [Character]) {
        self.characters = characters
    }

    private mutating func expression() -> Double? {
        guard var value = term() else {
            return nil
        }
        while index < characters.count, "+-".contains(characters[index]) {
            let op = characters[index]
            index += 1
            guard let rhs = term() else {
                return nil
            }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func term() -> Double? {
        guard var value = factor() else {
            return nil
        }
        while index < characters.count, "*/".contains(characters[index]) {
            let op = characters[index]
            index += 1
            guard let rhs = factor() else {
                return nil
            }
            if op == "/" && rhs == 0 {
                return nil
            }
            value = op == "*" ? value * rhs : value / rhs
        }
        return value
    }

    private mutating func factor() -> Double? {
        guard index < characters.count else {
            return nil
        }
        if characters[index] == "-" {
            index += 1
            return factor().map { -$0 }
        }
        if characters[index] == "(" {
            index += 1
            guard let value = expression(), index < characters.count, characters[index] == ")" else {
                return nil
            }
            index += 1
            return value
        }
        let start = index
        while index < characters.count, characters[index].isNumber || characters[index] == "." {
            index += 1
        }
        return Double(String(characters[start..<index]))
    }
}
