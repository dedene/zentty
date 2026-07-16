import XCTest
@testable import Zentty

final class CleanCopyURLHelpersTests: XCTestCase {

    // MARK: - URL Tracking Parameters

    func test_stripURLTrackingParameters_unknownHostKeepsFunctionalParamAndRemovesUTMParam() {
        XCTAssertEqual(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://example.com/reset?token=abc123&utm_source=mail",
                enabled: true
            ),
            "https://example.com/reset?token=abc123"
        )
    }

    func test_stripURLTrackingParameters_unknownHostWithOnlyFunctionalParamsIsUnchanged() {
        XCTAssertNil(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://example.com/search?q=zentty",
                enabled: true
            )
        )
    }

    func test_stripURLTrackingParameters_unknownHostRemovesKnownClickIdAndKeepsFunctionalParam() {
        XCTAssertEqual(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://example.com/search?q=zentty&fbclid=abc",
                enabled: true
            ),
            "https://example.com/search?q=zentty"
        )
    }

    func test_stripURLTrackingParameters_trackingParamMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://example.com/reset?token=abc123&UTM_Source=mail",
                enabled: true
            ),
            "https://example.com/reset?token=abc123"
        )
    }

    func test_stripURLTrackingParameters_youtubeStripsKnownShareParamsAndGlobalTrackingParams() {
        XCTAssertEqual(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://youtube.com/watch?v=abc&t=12s&feature=share&si=xyz&utm_source=mail",
                enabled: true
            ),
            "https://youtube.com/watch?v=abc&t=12s"
        )
    }

    func test_stripURLTrackingParameters_knownHostRuleMatchesSubdomain() {
        XCTAssertEqual(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://www.youtube.com/watch?v=abc&t=12s&feature=share",
                enabled: true
            ),
            "https://www.youtube.com/watch?v=abc&t=12s"
        )
    }

    func test_stripURLTrackingParameters_githubSearchFunctionalParamsAreUnchanged() {
        XCTAssertNil(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://github.com/search?q=zentty&type=repositories",
                enabled: true
            )
        )
    }

    func test_stripURLTrackingParameters_youtuBeStripsKnownShareParams() {
        XCTAssertEqual(
            CleanCopyPipeline.stripURLTrackingParameters(
                "https://youtu.be/abc?t=12s&si=xyz&feature=share",
                enabled: true
            ),
            "https://youtu.be/abc?t=12s"
        )
    }

    // MARK: - Wrapped URL Repair

    func test_repairWrappedURL_rejoinsURLWrappedAcrossTwoLines() {
        XCTAssertEqual(
            CleanCopyPipeline.repairWrappedURL(
                "https://example.com/very/long/path/segment/that\n/continues/here?query=value"
            ),
            "https://example.com/very/long/path/segment/that/continues/here?query=value"
        )
    }

    func test_repairWrappedURL_rejoinsURLWrappedAcrossThreeLines() {
        XCTAssertEqual(
            CleanCopyPipeline.repairWrappedURL(
                "https://example.com/very/long/path/segment/that\n/continues/across/multiple\n/lines/of/wrapping"
            ),
            "https://example.com/very/long/path/segment/that/continues/across/multiple/lines/of/wrapping"
        )
    }

    func test_repairWrappedURL_doesNotFuseTrailingProseIntoURL() {
        XCTAssertNil(
            CleanCopyPipeline.repairWrappedURL(
                "https://example.com/docs/setup\nOpen this in your browser, then continue."
            )
        )
    }

    func test_clean_urlFollowedByProseSentenceKeepsProseSpacesIntact() {
        let input = "https://example.com/docs/setup\nOpen this in your browser, then continue."
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, input)
    }

    // MARK: - Path Quoting

    func test_quotePathWithSpaces_quotesAbsolutePath() {
        XCTAssertEqual(
            CleanCopyPipeline.quotePathWithSpaces("/Users/peter/My Documents/file.txt"),
            "\"/Users/peter/My Documents/file.txt\""
        )
    }

    func test_quotePathWithSpaces_doesNotQuoteTCPIPProse() {
        XCTAssertNil(CleanCopyPipeline.quotePathWithSpaces("TCP/IP is a protocol"))
    }

    func test_quotePathWithSpaces_doesNotQuoteIOProse() {
        XCTAssertNil(CleanCopyPipeline.quotePathWithSpaces("I/O throughput is fine"))
    }

    func test_quotePathWithSpaces_doesNotQuoteRelativePathWithOnlyOneSlashInFirstToken() {
        XCTAssertNil(CleanCopyPipeline.quotePathWithSpaces("scripts/agent bench/run"))
    }

    func test_quotePathWithSpaces_quotesExplicitRelativePath() {
        XCTAssertEqual(
            CleanCopyPipeline.quotePathWithSpaces("./My Folder/file"),
            "\"./My Folder/file\""
        )
    }

    func test_quotePathWithSpaces_doesNotQuoteSentenceStartingWithAbsolutePath() {
        XCTAssertNil(CleanCopyPipeline.quotePathWithSpaces("/etc/hosts is the file you want"))
    }

    func test_quotePathWithSpaces_quotesAbsolutePathWithSpacesInTwoSegments() {
        XCTAssertEqual(
            CleanCopyPipeline.quotePathWithSpaces("/Users/peter/My Documents/report final.pdf"),
            "\"/Users/peter/My Documents/report final.pdf\""
        )
    }

    func test_quotePathWithSpaces_quotesTildePathWithSpaces() {
        XCTAssertEqual(
            CleanCopyPipeline.quotePathWithSpaces("~/Library/Application Support/Zentty"),
            "\"~/Library/Application Support/Zentty\""
        )
    }

    func test_quotePathWithSpaces_doesNotQuoteProseStartingWithRelativeCommand() {
        XCTAssertNil(CleanCopyPipeline.quotePathWithSpaces("./configure then run make again"))
    }
}
