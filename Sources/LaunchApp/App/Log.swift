// App/Log.swift
// Unified logging (Console.app → subsystem "com.vuhpquang.launchapp"); DEBUG builds also print.

import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.vuhpquang.launchapp", category: "launchapp")

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        #if DEBUG
        print("[LaunchApp] \(text)")
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        #if DEBUG
        print("[LaunchApp] ERROR \(text)")
        #endif
    }
}
