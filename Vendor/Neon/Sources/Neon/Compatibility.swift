import Foundation

/// Carries AppKit delegate values into a closure that is synchronously checked
/// to run on the main queue.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

func assumeMainActor<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
#if swift(>=5.9)
	if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
		return try MainActor.assumeIsolated(body)
	}
#endif

	dispatchPrecondition(condition: .onQueue(.main))
	return try withoutActuallyEscaping(body) { fn in
		try unsafeBitCast(fn, to: (() throws -> T).self)()
	}
}
