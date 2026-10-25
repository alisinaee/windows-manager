import Foundation
import MachO
import ObjectiveC

// Looks inside the SkyLight image that is loaded in this process: its symbol table (including symbols
// that are not exported, so dlsym cannot see them) and the Objective-C classes it defines.
//
// Idea: yabai (MIT, https://github.com/asmvik/yabai, src/misc/macho.h `macho_find_symbol`) resolves the
// non-exported SLSPerformAsynchronousBridgedWindowManagementOperation by name from SkyLight's symbol
// table. The code below is our own. SkyLight lives in the dyld shared cache, where the whole symbol
// table (local symbols too) is mapped read-only inside the cache's __LINKEDIT segment, so a running
// process can read it directly. Everything here is read-only.

/// A defined symbol found in SkyLight's symbol table.
public struct SkyLightSymbol: Codable, Equatable {
    public var name: String
    /// Address in this process (symbol value plus the shared cache slide).
    public var address: UInt64
    /// Address before the slide; this is the number `dyld_info` prints for the symbol.
    public var unslidAddress: UInt64
    /// False for local (non-exported) symbols such as C++ `static` functions and Objective-C methods.
    public var isExported: Bool

    public init(name: String, address: UInt64, unslidAddress: UInt64, isExported: Bool) {
        self.name = name
        self.address = address
        self.unslidAddress = unslidAddress
        self.isExported = isExported
    }

    /// Objective-C method symbols are named "-[Class method]" or "+[Class method]".
    public var isObjCMethod: Bool { name.hasPrefix("-[") || name.hasPrefix("+[") }
}

/// Where SkyLight is loaded in this process.
public struct SkyLightImageInfo: Codable, Equatable {
    /// Path the dynamic linker reports for the image.
    public var path: String
    public var headerAddress: UInt64
    public var slide: Int64
    /// Number of entries in the image's symbol table (local + exported + undefined).
    public var symbolTableEntries: Int

    public init(path: String, headerAddress: UInt64, slide: Int64, symbolTableEntries: Int) {
        self.path = path
        self.headerAddress = headerAddress
        self.slide = slide
        self.symbolTableEntries = symbolTableEntries
    }
}

/// One Objective-C method of a class.
public struct ObjCMethodInfo: Codable, Equatable {
    public var name: String
    /// True for "+" (class) methods, false for "-" (instance) methods.
    public var isClassMethod: Bool
    public var typeEncoding: String
    /// Address of the implementation in this process.
    public var implementation: UInt64

    public init(name: String, isClassMethod: Bool, typeEncoding: String, implementation: UInt64) {
        self.name = name
        self.isClassMethod = isClassMethod
        self.typeEncoding = typeEncoding
        self.implementation = implementation
    }

    /// "-selector" or "+selector".
    public var signature: String { (isClassMethod ? "+" : "-") + name }
}

/// One class of the inheritance chain, with the methods it defines itself (not the inherited ones).
public struct ObjCClassInfo: Codable, Equatable {
    public var name: String
    public var superclass: String?
    public var instanceVariables: [String]
    public var methods: [ObjCMethodInfo]

    public init(name: String, superclass: String?, instanceVariables: [String], methods: [ObjCMethodInfo]) {
        self.name = name
        self.superclass = superclass
        self.instanceVariables = instanceVariables
        self.methods = methods
    }
}

public enum SkyLightImage {
    // MARK: Mach-O layout

    private struct Layout {
        var path: String
        var header: UInt
        var slide: Int
        /// Address of the first nlist_64 entry.
        var symbols: UInt
        var count: Int
        /// Address of the string table and its size in bytes.
        var strings: UInt
        var stringsSize: Int
    }

    private enum LayoutResult {
        case ok(Layout)
        case failed(String)
    }

    // Static lets are initialised lazily and exactly once.
    private static let layoutResult: LayoutResult = computeLayout()

    private static func computeLayout() -> LayoutResult {
        guard PrivateSymbols.isLoaded else {
            return .failed("SkyLight is not loaded" + (PrivateSymbols.loadError.map { ": \($0)" } ?? ""))
        }

        var index: UInt32?
        var path = ""
        for i in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(i) else { continue }
            let candidate = String(cString: raw)
            if candidate.contains("/SkyLight.framework/") && candidate.hasSuffix("/SkyLight") {
                index = i
                path = candidate
                break
            }
        }
        guard let index, let headerPointer = _dyld_get_image_header(index) else {
            return .failed("the SkyLight image is not among the loaded images")
        }
        let header = UnsafeRawPointer(headerPointer)
        guard header.load(as: UInt32.self) == MH_MAGIC_64 else {
            return .failed("the SkyLight header is not a 64-bit Mach-O header")
        }
        let slide = Int(_dyld_get_image_vmaddr_slide(index))

        var linkeditVM: UInt64 = 0, linkeditFileOffset: UInt64 = 0, linkeditSize: UInt64 = 0
        var symtab: symtab_command?
        let commandCount = Int(header.load(as: mach_header_64.self).ncmds)
        var cursor = header + MemoryLayout<mach_header_64>.size
        for _ in 0..<commandCount {
            let command = cursor.load(as: load_command.self)
            if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = cursor.load(as: segment_command_64.self)
                var nameBytes = segment.segname
                let name = withUnsafeBytes(of: &nameBytes) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if name == "__LINKEDIT" {
                    linkeditVM = segment.vmaddr
                    linkeditFileOffset = segment.fileoff
                    linkeditSize = segment.filesize
                }
            } else if command.cmd == UInt32(LC_SYMTAB) {
                symtab = cursor.load(as: symtab_command.self)
            }
            cursor += Int(command.cmdsize)
        }

        guard let symtab, linkeditVM != 0 else {
            return .failed("the SkyLight image has no symbol table or no __LINKEDIT segment")
        }
        let linkeditEnd = linkeditFileOffset + linkeditSize
        let symbolsEnd = UInt64(symtab.symoff) + UInt64(symtab.nsyms) * 16
        let stringsEnd = UInt64(symtab.stroff) + UInt64(symtab.strsize)
        guard UInt64(symtab.symoff) >= linkeditFileOffset, symbolsEnd <= linkeditEnd,
              UInt64(symtab.stroff) >= linkeditFileOffset, stringsEnd <= linkeditEnd else {
            return .failed("the symbol table lies outside the mapped __LINKEDIT segment")
        }

        // Offsets in LC_SYMTAB are file offsets; map them through __LINKEDIT (valid for cache images too).
        let linkeditBase = UInt(linkeditVM) &+ UInt(bitPattern: slide)
        let layout = Layout(
            path: path,
            header: UInt(bitPattern: headerPointer),
            slide: slide,
            symbols: linkeditBase &+ UInt(UInt64(symtab.symoff) - linkeditFileOffset),
            count: Int(symtab.nsyms),
            strings: linkeditBase &+ UInt(UInt64(symtab.stroff) - linkeditFileOffset),
            stringsSize: Int(symtab.strsize)
        )
        return .ok(layout)
    }

    // MARK: Image and symbols

    /// Where SkyLight is loaded, or nil when it is not (see `problem`).
    public static func info() -> SkyLightImageInfo? {
        guard case .ok(let layout) = layoutResult else { return nil }
        return SkyLightImageInfo(path: layout.path, headerAddress: UInt64(layout.header),
                                 slide: Int64(layout.slide), symbolTableEntries: layout.count)
    }

    /// Why the image or its symbol table could not be used; nil when everything is fine.
    public static var problem: String? {
        if case .failed(let reason) = layoutResult { return reason }
        return nil
    }

    /// Calls `body` for each defined symbol (type N_SECT, no debug entries) until it returns true.
    private static func forEachDefinedSymbol(
        _ layout: Layout,
        _ body: (_ name: UnsafePointer<CChar>, _ type: UInt8, _ value: UInt64) -> Bool
    ) {
        for i in 0..<layout.count {
            guard let entry = UnsafeRawPointer(bitPattern: layout.symbols &+ UInt(i * 16)) else { return }
            let stringIndex = Int(entry.loadUnaligned(as: UInt32.self))
            let type = entry.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            let value = entry.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            if stringIndex == 0 || stringIndex >= layout.stringsSize { continue }
            // Skip debug (stab) entries and anything that is not a defined symbol in a section.
            if type & 0xE0 != 0 || type & 0x0E != 0x0E { continue }
            guard let name = UnsafePointer<CChar>(bitPattern: layout.strings &+ UInt(stringIndex)) else { continue }
            if body(name, type, value) { return }
        }
    }

    private static func makeSymbol(_ layout: Layout, name: UnsafePointer<CChar>, type: UInt8, value: UInt64) -> SkyLightSymbol {
        SkyLightSymbol(name: String(cString: name),
                       address: value &+ UInt64(bitPattern: Int64(layout.slide)),
                       unslidAddress: value,
                       isExported: type & 0x01 != 0)
    }

    /// The defined symbol with exactly this name, exported or not. Mangled C++ names keep their leading
    /// underscore, for example `__ZL54SLSPerform...`; exported C names look like `_SLSMainConnectionID`.
    public static func symbol(named exact: String) -> SkyLightSymbol? {
        guard case .ok(let layout) = layoutResult else { return nil }
        var found: SkyLightSymbol?
        exact.withCString { target in
            forEachDefinedSymbol(layout) { name, type, value in
                guard strcmp(name, target) == 0 else { return false }
                found = makeSymbol(layout, name: name, type: type, value: value)
                return true
            }
        }
        return found
    }

    /// Defined symbols whose name contains any of `fragments` (case-insensitive), in symbol table order.
    /// `limit` stops the scan early; pass 0 for no limit.
    public static func symbols(containing fragments: [String], limit: Int = 0) -> [SkyLightSymbol] {
        guard case .ok(let layout) = layoutResult, !fragments.isEmpty else { return [] }
        var found: [SkyLightSymbol] = []
        // Keep the C strings alive for the whole scan.
        let needles = fragments.map { strdup($0) }
        defer { needles.forEach { free($0) } }
        forEachDefinedSymbol(layout) { name, type, value in
            for needle in needles {
                guard let needle, strcasestr(name, needle) != nil else { continue }
                found.append(makeSymbol(layout, name: name, type: type, value: value))
                break
            }
            return limit > 0 && found.count >= limit
        }
        return found
    }

    // MARK: Objective-C classes

    /// Names of all Objective-C classes the SkyLight image defines.
    public static func objcClassNames() -> [String] {
        guard let image = info() else { return [] }
        var count: UInt32 = 0
        guard let list = objc_copyClassNamesForImage(image.path, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: list)) }
        return (0..<Int(count)).map { String(cString: list[$0]) }
    }

    /// Class names containing any of `fragments` (case-sensitive), sorted.
    public static func objcClassNames(containing fragments: [String]) -> [String] {
        objcClassNames().filter { name in fragments.contains { name.contains($0) } }.sorted()
    }

    /// The class and its superclasses with the methods and instance variables each defines itself.
    /// Stops before NSObject / NSProxy so the output stays about SkyLight. Empty when the class is unknown.
    public static func objcClassChain(named name: String) -> [ObjCClassInfo] {
        // Loading SkyLight is what makes its classes known to the runtime.
        guard PrivateSymbols.isLoaded, var current: AnyClass = NSClassFromString(name) else { return [] }
        var chain: [ObjCClassInfo] = []
        while true {
            let className = String(cString: class_getName(current))
            if className == "NSObject" || className == "NSProxy" { break }
            let parent: AnyClass? = class_getSuperclass(current)

            var ivars: [String] = []
            var ivarCount: UInt32 = 0
            if let list = class_copyIvarList(current, &ivarCount) {
                for i in 0..<Int(ivarCount) {
                    let ivarName = ivar_getName(list[i]).map { String(cString: $0) } ?? "?"
                    let encoding = ivar_getTypeEncoding(list[i]).map { String(cString: $0) } ?? "?"
                    ivars.append("\(ivarName) \(encoding)")
                }
                free(list)
            }

            var methods = methodList(of: current, isClassMethod: false)
            if let meta = object_getClass(current) { methods += methodList(of: meta, isClassMethod: true) }

            chain.append(ObjCClassInfo(name: className,
                                       superclass: parent.map { String(cString: class_getName($0)) },
                                       instanceVariables: ivars, methods: methods))
            guard let parent else { break }
            current = parent
        }
        return chain
    }

    private static func methodList(of cls: AnyClass, isClassMethod: Bool) -> [ObjCMethodInfo] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { i in
            let method = list[i]
            return ObjCMethodInfo(
                name: String(cString: sel_getName(method_getName(method))),
                isClassMethod: isClassMethod,
                typeEncoding: method_getTypeEncoding(method).map { String(cString: $0) } ?? "",
                implementation: UInt64(unsafeBitCast(method_getImplementation(method), to: UInt.self))
            )
        }
    }
}
