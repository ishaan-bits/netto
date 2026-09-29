import Foundation
import Testing
@testable import Netto

// MARK: Pure normalization policy

struct ContactNormalizationTests {
    // MARK: Phones

    @Test func strictPhoneKeyIgnoresFormattingAndLeadingPlus() {
        #expect(ContactNormalization.phone("+1 (555) 010-1234") == "s:15550101234")
        #expect(ContactNormalization.phone("+1 555 010 1234") == "s:15550101234")
        #expect(ContactNormalization.phone("15550101234") == "s:15550101234")
        #expect(ContactNormalization.phone("1555-010-1234") == "s:15550101234")
        #expect(
            ContactNormalization.phone("(555) 010.1234")
                == ContactNormalization.phone("5550101234")
        )
    }

    @Test func nationalToleranceKeyOnlyForBare10DigitAndLongInternationalForms() {
        // Bare 10-digit number → national key is the full digits.
        let bare = ContactNormalization.phoneMatchKeys("(555) 010-7777")
        #expect(bare.contains("s:5550107777"))
        #expect(bare.contains("n:5550107777"))

        // >10 digits with `+` → national key is the last 10 digits.
        let international = ContactNormalization.phoneMatchKeys("+15550107777")
        #expect(international.contains("s:15550107777"))
        #expect(international.contains("n:5550107777"))

        // The two forms therefore share a match key…
        #expect(!bare.isDisjoint(with: international))

        // …but a short or non-`+` international form never gets one.
        #expect(ContactNormalization.phoneMatchKeys("919876543210") == ["s:919876543210"])
        #expect(ContactNormalization.phoneMatchKeys("+15550101") == ["s:15550101"])
    }

    @Test func trunkZeroAndCountryVariantsAreNeverRewrittenToMatch() {
        // Deliberately not equivalent: no country guessing, no trunk-zero stripping.
        #expect(ContactNormalization.phone("09876543210") == "s:09876543210")
        let trunk = ContactNormalization.phoneMatchKeys("09876543210")
        let international = ContactNormalization.phoneMatchKeys("+919876543210")
        #expect(trunk.isDisjoint(with: international))
    }

    @Test func unusablePhonesNormalizeToNilOrNoKeys() {
        #expect(ContactNormalization.phone("") == nil)
        #expect(ContactNormalization.phone("123") == nil)
        #expect(ContactNormalization.phone("12 3") == nil)
        #expect(ContactNormalization.phone("call me") == nil)
        #expect(ContactNormalization.phone("+1+5550101234") == nil)
        #expect(ContactNormalization.phone("5550101234+") == nil)
        #expect(ContactNormalization.phoneMatchKeys("123").isEmpty)
    }

    @Test func unicodeDigitVariantsArePolicyBound() {
        // Indic digits fold to ASCII; fullwidth digits are outside the documented policy and reject.
        #expect(ContactNormalization.phone("५५५०१०१२३४") == "s:5550101234")
        #expect(ContactNormalization.phone("５５５０１０１２３４") == nil)
    }

    // MARK: Emails

    @Test func emailsAreTrimmedAndLowercasedOnly() {
        #expect(ContactNormalization.email("  Mara.Voss@Example.COM ") == "mara.voss@example.com")
        // Plus-tags keep their delivery identity — never stripped.
        #expect(ContactNormalization.email("a+b@example.com") == "a+b@example.com")
    }

    @Test func malformedEmailsAreUnusable() {
        #expect(ContactNormalization.email("") == nil)
        #expect(ContactNormalization.email("   ") == nil)
        #expect(ContactNormalization.email("no-at-sign") == nil)
        #expect(ContactNormalization.email("@example.com") == nil)
        #expect(ContactNormalization.email("mara@") == nil)
        #expect(ContactNormalization.email("a@b@c.com") == nil)
    }

    // MARK: Names and organization

    @Test func namesAreCollapsedAndLowercasedButDiacriticsAreKept() {
        #expect(ContactNormalization.name("  Mara   ", " Voss ") == "mara voss")
        #expect(ContactNormalization.name("José", "") == "josé")
        #expect(ContactNormalization.name("Jose", "") != ContactNormalization.name("José", ""))
    }

    @Test func emptyNamesAndOrganizationsAreNeverIndexedAsEmptyStrings() {
        #expect(ContactNormalization.name("", "") == nil)
        #expect(ContactNormalization.name("   ", "\n") == nil)
        #expect(ContactNormalization.organization("") == nil)
        #expect(ContactNormalization.organization("  ") == nil)
        #expect(ContactNormalization.organization("Brightlabs") == "brightlabs")
    }
}
