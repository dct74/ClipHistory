import Testing
@testable import ClipHistory

@Suite("Version comparison")
struct UpdateCheckerTests {
    @Test("newer versions are detected")
    func newerIsDetected() {
        #expect(UpdateChecker.isNewer(remote: "1.7.5", current: "1.7.4"))
        #expect(UpdateChecker.isNewer(remote: "1.8.0", current: "1.7.9"))
        #expect(UpdateChecker.isNewer(remote: "2.0.0", current: "1.99.99"))
    }

    @Test("equal or older versions are not newer")
    func equalOrOlderIsNotNewer() {
        #expect(!UpdateChecker.isNewer(remote: "1.7.4", current: "1.7.4"))
        #expect(!UpdateChecker.isNewer(remote: "1.7.3", current: "1.7.4"))
        #expect(!UpdateChecker.isNewer(remote: "1.6.9", current: "1.7.0"))
    }

    @Test("missing components count as zero")
    func missingComponentsAreZero() {
        #expect(UpdateChecker.isNewer(remote: "1.8", current: "1.7.9"))
        #expect(!UpdateChecker.isNewer(remote: "1.7", current: "1.7.1"))
    }
}
