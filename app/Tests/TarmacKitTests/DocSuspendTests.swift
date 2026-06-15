import CoreGraphics
import XCTest
@testable import TarmacKit

/// P5.5: the pure helpers behind doc-webview suspension.
final class DocSuspendTests: XCTestCase {
    func testHonorsDidFinishOnlyWhenNotSuspended() {
        // The real template load (not suspended) is honored…
        XCTAssertTrue(DocSuspend.shouldHonorDidFinish(suspended: false))
        // …the about:blank load issued during suspend is dropped.
        XCTAssertFalse(DocSuspend.shouldHonorDidFinish(suspended: true))
    }

    func testScrollRestoreJSEmitsOffset() {
        XCTAssertEqual(
            DocSuspend.scrollRestoreJS(scrollTop: 0),
            "var s=document.scrollingElement||document.documentElement; if(s){s.scrollTop=0.0;}"
        )
        XCTAssertEqual(
            DocSuspend.scrollRestoreJS(scrollTop: 128.5),
            "var s=document.scrollingElement||document.documentElement; if(s){s.scrollTop=128.5;}"
        )
    }

    func testScrollRestoreJSIsWellFormedForLargeOffset() {
        let js = DocSuspend.scrollRestoreJS(scrollTop: 99999)
        // Single statement guarded on the scrolling element, ending with a brace.
        XCTAssertTrue(js.contains("scrollTop="))
        XCTAssertTrue(js.hasSuffix(";}"))
        XCTAssertTrue(js.contains("document.scrollingElement||document.documentElement"))
    }
}
