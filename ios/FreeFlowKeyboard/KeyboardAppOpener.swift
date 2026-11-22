import UIKit

/// Opens the containing app from the keyboard extension.
///
/// Keyboards get no supported way to do this: `extensionContext.open` only
/// works for Today and iMessage extensions, and the old `openURL:` selector
/// stopped working in iOS 18. The extension process still has a
/// UIApplication at the end of its responder chain, and its
/// `openURL:options:completionHandler:` works, but it is marked unavailable
/// to extensions, so it is called through the Objective-C runtime. This is an
/// unsupported technique that a future iOS release could stop honoring.
///
/// The technique matches ContainingAppOpener.swift in anomalyco/hex
/// (https://github.com/anomalyco/hex, ios/HEXKeyboard/ContainingAppOpener.swift),
/// MIT License, Copyright (c) 2026 Christopher Langton.
@MainActor
enum KeyboardAppOpener {
    private typealias Completion = @convention(block) (Bool) -> Void
    private typealias OpenURLFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Completion?) -> Void

    /// Returns false when no UIApplication answering the selector was found.
    /// Otherwise iOS later calls `completion` on the main queue with whether
    /// the app opened; treat a missing call as success.
    static func open(_ url: URL, from responder: UIResponder, completion: @escaping (Bool) -> Void) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var current: UIResponder? = responder
        while let candidate = current {
            if candidate.isKind(of: UIApplication.self), candidate.responds(to: selector) {
                let implementation = candidate.method(for: selector)
                let openURL = unsafeBitCast(implementation, to: OpenURLFunction.self)
                let reportResult: Completion = { opened in
                    completion(opened)
                }
                openURL(candidate, selector, url as NSURL, NSDictionary(), reportResult)
                return true
            }
            current = candidate.next
        }
        return false
    }
}

/// Delete-key repeat timing from `KeyboardDeleteRepeat`: one deletion on
/// press, repeats after the initial delay, and words once held long enough.
@MainActor
final class KeyboardDeleteRepeater {
    /// Performs one deletion of the given unit.
    var deleteOnce: @MainActor (KeyboardDeleteRepeat.Unit) -> Void = { _ in }

    private var repeatTask: Task<Void, Never>?

    func begin() {
        stop()
        let startedAt = Date()
        deleteOnce(.character)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: KeyboardDeleteRepeater.nanoseconds(KeyboardDeleteRepeat.initialDelay))
            while !Task.isCancelled {
                guard let self else { return }
                self.deleteOnce(KeyboardDeleteRepeat.unit(afterHolding: Date().timeIntervalSince(startedAt)))
                try? await Task.sleep(nanoseconds: KeyboardDeleteRepeater.nanoseconds(KeyboardDeleteRepeat.repeatInterval))
            }
        }
    }

    func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}
