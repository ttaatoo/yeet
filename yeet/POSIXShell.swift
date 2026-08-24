//
//  POSIXShell.swift
//  kero
//

import Foundation

/// POSIX single-quote escaping for values interpolated into a `/bin/sh -c`
/// script. Each argument is quoted independently so the shell never reparses
/// or expands caller-supplied text.
enum POSIXShell {
    nonisolated static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
