import Foundation
import WMCore

enum ReportCommand {
    static let name = "report"
    static let help = "Summarise ./lab-results as markdown (--out FILE to write it to a file)"

    static func run(_ args: [String]) -> Int32 {
        var outPath: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--out":
                guard index + 1 < args.count else {
                    fputs("report: --out needs a file name\n", stderr)
                    return 2
                }
                outPath = args[index + 1]
                index += 2
            default:
                fputs("report: unknown option \(args[index]) (usage: spaceslab report [--out FILE])\n", stderr)
                return 2
            }
        }

        do {
            let markdown = try LabReport.markdown(from: LabResult.defaultFolder)
            if let outPath {
                try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
                print("Wrote \(outPath)")
            } else {
                print(markdown, terminator: "")
            }
            return 0
        } catch {
            fputs("report: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
