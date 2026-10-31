import Foundation
import Testing
@testable import PikoKit

@Suite struct SensitiveContentTests {
    @Test func classificationTable() {
        let cases: [(String, String, SensitiveContent.Verdict)] = [
            ("my/id", "2345-6789-0123", .blocked(.governmentID)),
            ("my/pan", "abcde1234f", .blocked(.governmentID)),
            ("usual", "Abcde1234F", .blocked(.governmentID)),
            ("my/phone-passcode", "482193", .blocked(.password)),
            ("my/upi-mpin", "4821", .blocked(.authCode)),
            ("my/2fa", "482193", .blocked(.authCode)),
            ("my/otps", "482193", .blocked(.authCode)),
            ("note", "TOTP 482193", .blocked(.authCode)),
            ("note", "passcode 482193", .blocked(.password)),
            ("my/passwords", "hunter2", .blocked(.password)),
            ("my/wifi-pass", "hunter2", .blocked(.password)),
            ("wifi_password", "hunter2", .blocked(.password)),
            ("wifiPassword", "hunter2", .blocked(.password)),
            ("my/tpin", "4821", .blocked(.authCode)),
            ("my/pins", "4821", .blocked(.authCode)),
            ("my/codes", "4821", .blocked(.authCode)),
            ("card", "4111  1111  1111  1111", .blocked(.payment)),
            ("card", "4111.1111.1111.1111", .blocked(.payment)),
            ("password", "bluebird", .blocked(.password)),
            ("passphrase", "bluebird", .blocked(.password)),
            ("pwd", "bluebird", .blocked(.password)),
            ("secret", "bluebird", .blocked(.password)),
            ("hint", "my password is bluebird", .blocked(.password)),
            ("hint", "passphrase: bluebird", .blocked(.password)),
            ("hint", "passwd bluebird", .blocked(.password)),
            ("hint", "secret key bluebird", .blocked(.password)),
            ("card", "4111 1111 1111 1111", .blocked(.payment)),
            ("preference", "4111-1111-1111-1111", .blocked(.payment)),
            ("preference", "4111111111111111", .blocked(.payment)),
            ("credit card", "tea", .blocked(.payment)),
            ("debit card", "tea", .blocked(.payment)),
            ("hint", "CVV 123", .blocked(.payment)),
            ("payment", "expiry 12/28", .blocked(.payment)),
            ("bank account", "tea", .blocked(.payment)),
            ("passport", "AB123", .blocked(.governmentID)),
            ("driver licence", "AB123", .blocked(.governmentID)),
            ("driving license", "AB123", .blocked(.governmentID)),
            ("aadhaar", "1234 5678 9012", .blocked(.governmentID)),
            ("hint", "1234 5678 9012", .blocked(.governmentID)),
            ("hint", "ABCDE1234F", .blocked(.governmentID)),
            ("hint", "123-45-6789", .blocked(.governmentID)),
            ("social security", "tea", .blocked(.governmentID)),
            ("otp", "123456", .blocked(.authCode)),
            ("verification code", "123456", .blocked(.authCode)),
            ("pin", "1234", .blocked(.authCode)),
            ("auth code", "1234", .blocked(.authCode)),
            ("hint", "OTP 987654", .blocked(.authCode)),
            ("hint", "verification 4321", .blocked(.authCode)),
            ("hint", "code 12345678", .blocked(.authCode)),
            ("hint", "PIN 0000", .blocked(.authCode)),
            ("usual", "flat white", .safe),
            ("plan", "gym every Monday at 7 am", .safe),
            ("phone", "+91 98450 12345", .safe),
            ("day", "Fridays", .safe),
            ("person", "Riya", .safe),
            ("home", "Pune", .safe),
            ("plan", "meet at 9", .safe),
            ("plan", "at 1234", .safe),
            ("preference", "4111111111111112", .safe),
            ("date", "12/28", .safe),
            ("note", "normal words", .safe),
            ("time", "9:30", .safe),
            ("note", String(repeating: "a", count: 257), .blocked(.password)),
            ("note", "hello\nworld", .blocked(.password)),
            ("note", "hello\u{0000}world", .blocked(.password)),
        ]
        #expect(cases.count >= 40)
        for (label, value, expected) in cases {
            #expect(SensitiveContent.verdict(label: label, value: value) == expected)
        }
    }

    private func verhoeffDigit(_ prefix: String) -> Int {
        let d = [
            [0,1,2,3,4,5,6,7,8,9], [1,2,3,4,0,6,7,8,9,5],
            [2,3,4,0,1,7,8,9,5,6], [3,4,0,1,2,8,9,5,6,7],
            [4,0,1,2,3,9,5,6,7,8], [5,9,8,7,6,0,4,3,2,1],
            [6,5,9,8,7,1,0,4,3,2], [7,6,5,9,8,2,1,0,4,3],
            [8,7,6,5,9,3,2,1,0,4], [9,8,7,6,5,4,3,2,1,0],
        ]
        let p = [
            [0,1,2,3,4,5,6,7,8,9], [1,5,7,6,2,8,3,0,9,4],
            [5,8,0,3,7,9,6,1,4,2], [8,9,1,6,0,4,3,5,2,7],
            [9,4,5,3,1,2,6,8,7,0], [4,2,8,6,5,7,3,9,0,1],
            [2,7,9,3,8,0,6,4,1,5], [7,0,4,6,9,1,3,2,5,8],
        ]
        let inverse = [0,4,3,2,1,5,6,7,8,9]
        var checksum = 0
        for (index, digit) in prefix.reversed().enumerated() {
            checksum = d[checksum][p[(index + 1) % 8][digit.wholeNumberValue!]]
        }
        return inverse[checksum]
    }

    @Test func separatorAndSuffixVariants() {
        let prefix = "23456789012"
        let aadhaar = prefix + String(verhoeffDigit(prefix))
        let separators = [" ", "  ", "-", " - ", ".", "/", "_", "\u{00a0}",
                          ",", "–", "—", "‐", "−", "•", "·"]
        let fixtures: [(String, [String], SensitiveContent.Category)] = [
            ("4111111111111111", ["4111", "1111", "1111", "1111"], .payment),
            (aadhaar, [String(aadhaar.prefix(4)), String(aadhaar.dropFirst(4).prefix(4)),
                       String(aadhaar.suffix(4))], .governmentID),
            ("ABCDE1234F", ["ABCDE", "1234", "F"], .governmentID),
            ("123456789", ["123", "45", "6789"], .governmentID),
        ]
        for (plain, groups, category) in fixtures {
            #expect(SensitiveContent.verdict(label: "usual", value: plain) == .blocked(category))
            for separator in separators {
                let variant = groups.joined(separator: separator)
                #expect(SensitiveContent.verdict(label: "usual", value: variant) == .blocked(category),
                        "separator: \(separator.debugDescription), value: \(variant)")
                if category == .payment {
                    for cvv in ["123", "1234"] {
                        #expect(SensitiveContent.verdict(label: "usual", value: variant + separator + cvv)
                                == .blocked(.payment))
                    }
                }
            }
        }
        #expect(SensitiveContent.verdict(label: "usual", value: "٤١١١/١١١١/١١١١/١١١١") == .blocked(.payment))
        #expect(SensitiveContent.verdict(label: "usual", value: "4111111111111111 123") == .blocked(.payment))
    }

    @Test func verifierReproducersAndBenignValues() {
        let leaks: [(String, String, SensitiveContent.Category)] = [
            ("usual", "4111 1111 1111 1111 123", .payment),
            ("usual", "4111111111111111 123", .payment),
            ("usual", "4111 - 1111 - 1111 - 1111", .payment),
            ("usual", "4111/1111/1111/1111", .payment),
            ("my/id", "2345.6789.0123", .governmentID),
            ("usual", "2345  6789  0123", .governmentID),
            ("usual", "2345 - 6789 - 0123", .governmentID),
            ("usual", "ABCDE 1234 F", .governmentID),
            ("usual", "abcde-1234-f", .governmentID),
            ("my/card-exp", "08/29", .payment),
            ("my/o-t-p", "482193", .authCode),
        ]
        for (label, value, category) in leaks {
            #expect(SensitiveContent.verdict(label: label, value: value) == .blocked(category))
        }
        let newLeaks: [(String, SensitiveContent.Category)] = [
            ("4111,1111,1111,1111", .payment),
            ("4111–1111–1111–1111", .payment),
            ("2345,6789,0124", .governmentID),
            ("234,567,890,124", .governmentID),
            ("2345–6789–0124", .governmentID),
            ("2345•6789•0124", .governmentID),
            ("ABCDE–1234–F", .governmentID),
            ("123–45–6789", .governmentID),
            ("123,45,6789", .governmentID),
        ]
        for (value, category) in newLeaks {
            #expect(SensitiveContent.verdict(label: "usual", value: value) == .blocked(category))
        }
        let benignTimes = ["9:00–10:00", "31/10/2026 at 10:30", "12.11.2026"]
        for value in benignTimes {
            #expect(SensitiveContent.verdict(label: "usual", value: value) == .safe)
        }
        let benign = ["meet at 9", "flat white", "Riya", "Fridays", "gym every Monday at 7 am",
                      "+91 98450 12345", "98450 12345", "080-4123-4567",
                      "standup 9.30 to 10.15 daily", "12 March 1990", "AI 2021 on 12 Nov",
                      "LIB 2024 0091", "Pan-fried noodles", "Dr Mehta", "oat milk latte"]
        for value in benign {
            #expect(SensitiveContent.verdict(label: "usual", value: value) == .safe)
        }
    }


    @Test func countryCodePhonesRemainSafe() {
        #expect(SensitiveContent.verdict(label: "usual", value: "+91 80 4123 4567") == .safe)
        #expect(SensitiveContent.verdict(label: "usual", value: "91 80 4123 4567") == .safe)
        for index in 0..<50 {
            let number = "9845" + String(index % 10) + "1" + String(format: "%04d", index)
            let local = String(number.prefix(5)) + " " + String(number.suffix(5))
            for value in ["+91 " + local, "91 " + local] {
                #expect(SensitiveContent.verdict(label: "usual", value: value) == .safe)
            }
        }
    }

}
