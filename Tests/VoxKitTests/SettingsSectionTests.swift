import XCTest

@testable import VoxKit

final class SettingsSectionTests: XCTestCase {
    func testEverySectionBelongsToExactlyOneGroupInSidebarOrder() {
        let flattened = SettingsSection.Group.allCases.flatMap(\.sections)
        XCTAssertEqual(flattened, SettingsSection.allCases)
        XCTAssertEqual(Set(flattened).count, SettingsSection.allCases.count)
    }

    func testNoGroupIsEmpty() {
        for group in SettingsSection.Group.allCases {
            XCTAssertFalse(group.sections.isEmpty, "\(group) has no sections")
        }
    }

    func testTitlesAndSymbolsAreUniqueAndNonEmpty() {
        let titles = SettingsSection.allCases.map(\.title)
        let symbols = SettingsSection.allCases.map(\.systemImage)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        XCTAssertFalse(SettingsSection.Group.allCases.map(\.title).contains(where: \.isEmpty))
    }

    func testRawValuesRoundTripAndResolveFallsBack() {
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsSection.resolve(section.rawValue), section)
        }
        XCTAssertEqual(SettingsSection.resolve(nil), .initial)
        XCTAssertEqual(SettingsSection.resolve("does-not-exist"), .initial)
    }

    func testGeneralOpensFirst() {
        XCTAssertEqual(SettingsSection.initial, .general)
        XCTAssertEqual(SettingsSection.allCases.first, .general)
    }
}
