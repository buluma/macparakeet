import AppKit
import Carbon
import XCTest
@testable import MacParakeetCore

@MainActor
final class AppGeneratedKeyboardEventsTests: XCTestCase {
    func testProductionPastePostsMarkedCommandLayoutPairAtSessionBoundary() throws {
        var posted: [(CGEvent, CGEventTapLocation)] = []
        let poster = CGClipboardEventPosting(
            isAccessibilityTrusted: { true },
            postEvent: { posted.append(($0, $1)) }
        )
        let data = Data([0]) as CFData
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .data(data) },
            translatedCharacterProvider: { _, code, modifiers, _ in
                // Deliberately not the US V key; the production poster must
                // resolve using its Command-modified layout.
                XCTAssertEqual(modifiers, UInt32(cmdKey >> 8))
                return code == 17 ? UniChar(118) : nil
            }
        )
        try poster.simulatePaste(using: resolver)

        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted.map { $0.0.type }, [.keyDown, .keyUp])
        for (event, location) in posted {
            XCTAssertEqual(location, .cgSessionEventTap)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 17)
            XCTAssertEqual(event.flags, .maskCommand)
            XCTAssertTrue(AppGeneratedEventMarker.isMarked(event))
            XCTAssertEqual(
                event.getIntegerValueField(.eventSourceStateID),
                Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        }
    }

    func testProductionPostPasteActionAlsoUsesMarkedSessionPair() throws {
        var posted: [(CGEvent, CGEventTapLocation)] = []
        let poster = CGClipboardEventPosting(
            isAccessibilityTrusted: { true }, postEvent: { posted.append(($0, $1)) })
        try poster.simulateKeystroke(36)
        XCTAssertEqual(posted.map { $0.0.type }, [.keyDown, .keyUp])
        for (event, location) in posted {
            XCTAssertEqual(location, .cgSessionEventTap)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 36)
            XCTAssertEqual(event.flags, [])
            XCTAssertTrue(AppGeneratedEventMarker.isMarked(event))
        }
    }

    func testPermissionFailureCannotPostPartOfAPair() {
        let poster = CGClipboardEventPosting(
            isAccessibilityTrusted: { false }, postEvent: { _, _ in XCTFail("must not post") })
        XCTAssertThrowsError(try poster.simulateKeystroke(36))
        XCTAssertThrowsError(try poster.simulatePaste(using: PasteShortcutKeyResolver()))
    }

    func testStreamingMarkerRemainsCompatibleAndUnmarkedEventsStayUnmarked() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        XCTAssertFalse(AppGeneratedEventMarker.isMarked(event))
        StreamingCursorEventMarker.mark(event)
        XCTAssertTrue(AppGeneratedEventMarker.isMarked(event))
        XCTAssertEqual(StreamingCursorEventMarker.userData, 0x4D50_5343)
        // Quartz retains the first source-user-data value on an event. Foreign
        // metadata belongs on a fresh event, as it does at the production boundary.
        let foreign = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        foreign.setIntegerValueField(.eventSourceUserData, value: 123)
        XCTAssertEqual(foreign.getIntegerValueField(.eventSourceUserData), 123)
        XCTAssertFalse(AppGeneratedEventMarker.isMarked(foreign))
    }
}
