import Foundation
import OSLog

public enum GlanslateLog {
    public static let subsystem = "com.glanslate.app"

    public static let app        = Logger(subsystem: subsystem, category: "app")
    public static let invocation = Logger(subsystem: subsystem, category: "invocation")
    public static let regionSelect = Logger(subsystem: subsystem, category: "regionSelect")
    public static let capture    = Logger(subsystem: subsystem, category: "capture")
    public static let textDetect = Logger(subsystem: subsystem, category: "textDetect")
    public static let translate  = Logger(subsystem: subsystem, category: "translate")
    public static let overlay    = Logger(subsystem: subsystem, category: "overlay")
    public static let platform   = Logger(subsystem: subsystem, category: "platform")
    public static let history    = Logger(subsystem: subsystem, category: "history")
    public static let settings   = Logger(subsystem: subsystem, category: "settings")

    public static let signpost = OSSignposter(subsystem: subsystem, category: "signpost")
}
