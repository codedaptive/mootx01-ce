import Foundation
import Testing
@testable import MootCommunityUI

// MARK: - Community engine identity label (MF-MOOT-LINEAGE-LANGUAGE)
//
// Human-language acceptance law applied to the Community Engine form (census
// com.engine.identity-token, R-C8): the estate identity token is a technical
// identifier, so it renders behind a label naming what it is — never bare.
// The token value itself stays verbatim, monospaced, and selectable; only the
// naming is asserted here.

@Suite("Community engine — estate identity token labeled (R-C8)")
struct CommunityEngineIdentityLabelTests {

    @Test("the estate identity token carries a human label")
    func tokenIsLabeled() {
        let label = CommunityEngineIdentityDisplay.tokenLabel
        #expect(!label.isEmpty, "the token must carry a label naming what it is")
        #expect(label.contains(" "), "the label must be a human phrase: \(label)")
    }
}
