import Foundation

/// Loads the private SkyLight framework once and looks up its C symbols by name.
/// Every private call in the project is built on top of this.
public enum PrivateSymbols {
    public static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    // Static lets are initialised lazily and exactly once.
    private static let handle: UnsafeMutableRawPointer? = dlopen(skyLightPath, RTLD_LAZY)
    private static let openError: String? = {
        handle == nil ? dlerror().map { String(cString: $0) } : nil
    }()

    /// True when SkyLight could be loaded (this also makes its ObjC classes available).
    public static var isLoaded: Bool { handle != nil }

    /// The dlopen error text when loading failed, otherwise nil.
    public static var loadError: String? { openError }

    /// Finds a symbol and casts it to `T`, normally an `@convention(c)` function type.
    /// Returns nil when SkyLight is not loaded, the symbol is missing, or `T` is not pointer sized.
    public static func lookup<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, MemoryLayout<T>.size == MemoryLayout<UnsafeRawPointer>.size else { return nil }
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// True when SkyLight exports a symbol with this name.
    public static func exists(_ name: String) -> Bool {
        guard let handle else { return false }
        return dlsym(handle, name) != nil
    }
}
