import Foundation
import StoreKit

// Apple's signed answer to "how was this copy of the app obtained".
//
// Layer 2 (EnvironmentClassifier) infers store-ness from the receipt URL's
// filename and whether embedded.mobileprovision survived packaging. Those are
// unsigned inferences about the container, readable and forgeable on a
// jailbroken device, and they cannot cleanly separate App Store from Ad Hoc.
//
// StoreKit's AppTransaction is the real thing: a JWS signed by Apple carrying
// `environment` (.production / .sandbox / .xcode) plus the bundle id and
// version. We send the JWS untouched and let the BACKEND verify the signature
// against Apple's root and read the environment from the verified payload —
// a client-side read of `environment` is a hint, never evidence, because the
// client is the thing we are trying to check.
//
// AppTransaction is iOS 16+; the package floor is iOS 17, so no availability
// guard is needed. `AppTransaction.shared` is async and may hit the network on
// a cold install, which is why this is read at attestation time (already async)
// rather than in the synchronous create() pre-flight.
enum StoreProof {

    /// What Apple says, for logging only. The backend decides the bucket.
    enum Hint: String {
        case production, sandbox, xcode, unknown
    }

    struct Result {
        /// Raw JWS to hand to the backend verbatim. nil when unavailable.
        let jws: String?
        let hint: Hint
    }

    static func fetch() async -> Result {
        do {
            let verification = try await AppTransaction.shared
            // Deliberately NOT switching on `verification` being .verified:
            // local verification uses the device's own trust store. The backend
            // re-verifies against Apple's root regardless, so we forward the
            // JWS either way and let the server be the judge.
            let jws = verification.jwsRepresentation
            let tx: AppTransaction
            switch verification {
            case .verified(let t): tx = t
            case .unverified(let t, _): tx = t
            }
            let hint: Hint
            switch tx.environment {
            case .production: hint = .production
            case .sandbox: hint = .sandbox
            case .xcode: hint = .xcode
            default: hint = .unknown
            }
            return Result(jws: jws, hint: hint)
        } catch {
            // No AppTransaction is available in some legitimate states (a
            // freshly sideloaded build, no network on first launch). Absence
            // is not evidence of anything, so it degrades to "unknown" and the
            // backend falls back to the App Attest AAGUID as before.
            return Result(jws: nil, hint: .unknown)
        }
    }
}
