import Foundation

// `ExtentosResult` is the generic success/failure type. uniffi has no generics,
// so it stays a hand-written shell type, mirroring the Kotlin `ExtentosResult`
// one-for-one so call sites stay aligned across platforms.
//
// Its concrete payload errors — `ConnectError`, `CaptureError`, `AudioError`,
// `TransportError`, and the `ExtentosError` umbrella — migrated to extentos-core
// (`ConnectError` in Phase 0, the rest in Phase 2.0). See MigratedCoreTypes.swift
// for the shell-side § 3b conversions (`platformError` / `transportFailure`)
// that turn a caught native `Error` into the core types' structured
// `code` + `message`, and Conformances.swift for the restored
// `Error` / `Sendable` conformances.

public enum ExtentosResult<Success: Sendable, Failure: Error & Sendable>: Sendable {
    case success(Success)
    case failure(Failure)

    public func map<T: Sendable>(_ transform: (Success) -> T) -> ExtentosResult<T, Failure> {
        switch self {
        case .success(let v): return .success(transform(v))
        case .failure(let e): return .failure(e)
        }
    }

    public func flatMap<T: Sendable>(_ transform: (Success) -> ExtentosResult<T, Failure>) -> ExtentosResult<T, Failure> {
        switch self {
        case .success(let v): return transform(v)
        case .failure(let e): return .failure(e)
        }
    }

    public var success: Success? {
        if case let .success(v) = self { return v } else { return nil }
    }

    public var failure: Failure? {
        if case let .failure(e) = self { return e } else { return nil }
    }
}
