import Testing
@testable import Termy

/// The gate for the "Show Image" affordance. SwiftTerm renders the actual
/// pixels (same path the iTerm2/kitty protocols use); this policy just decides
/// which local files are safe to hand it.
struct InlineImagePolicyTests {
    @Test func acceptsCommonImageFormatsWithinSizeCap() {
        #expect(InlineImagePolicy.isRenderable(ext: "png", byteCount: 1024))
        #expect(InlineImagePolicy.isRenderable(ext: "JPG", byteCount: 5_000_000))   // case-insensitive
        #expect(InlineImagePolicy.isRenderable(ext: "gif", byteCount: 200_000))
        #expect(InlineImagePolicy.isRenderable(ext: "webp", byteCount: 10))
    }

    @Test func rejectsNonImagesAndBadSizes() {
        #expect(!InlineImagePolicy.isRenderable(ext: "txt", byteCount: 1024))
        #expect(!InlineImagePolicy.isRenderable(ext: "pdf", byteCount: 1024))
        #expect(!InlineImagePolicy.isRenderable(ext: "png", byteCount: 0))           // empty
        #expect(!InlineImagePolicy.isRenderable(ext: "png", byteCount: InlineImagePolicy.maxBytes + 1)) // too big
        #expect(!InlineImagePolicy.isRenderable(ext: "", byteCount: 1024))
    }

    @Test func sizeCapIsAtTheBoundary() {
        #expect(InlineImagePolicy.isRenderable(ext: "png", byteCount: InlineImagePolicy.maxBytes))
    }
}
