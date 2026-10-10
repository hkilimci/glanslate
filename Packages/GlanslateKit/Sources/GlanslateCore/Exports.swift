// On Apple platforms `CGRect`'s geometry API (minX, insetBy, Equatable, …) comes
// from CoreGraphics; swift-corelibs-foundation provides it on other platforms.
#if canImport(CoreGraphics)
@_exported import CoreGraphics
#endif
