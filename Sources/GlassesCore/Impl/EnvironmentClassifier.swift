import Foundation

// Layer 2 SDK pre-flight (iOS side).
// Mirror of android-library/.../EnvironmentClassifier.kt.
// Spec: docs/TELEMETRY_PRODUCT_PLAN.md § Layer 2: SDK-side cheap pre-flight.
//
// At Extentos.create(config:) we classify the runtime environment from
// signals available in the binary — DEBUG flag, simulator targetEnvironment,
// App Store receipt URL, embedded.mobileprovision presence — and reconcile
// against ExtentosConfig.environment. Mismatches downgrade silently with
// a console warning, so a developer who hardcodes .production but ships
// a debug build doesn't pollute the production analytics stack.
//
// `EnvironmentClassification`, `EnvironmentReconciliation` and the pure
// `reconcileEnvironment` decision logic were migrated to the Rust core
// (extentos-core) — see core/extentos-core/src/{types/environment.rs,logic/mod.rs}
// and MigratedCoreTypes.swift. The platform-specific `classify()` below — which
// reads Bundle / build signals — stays native.

enum EnvironmentClassifier {
    /// Classify from build-time + runtime signals. No I/O beyond Bundle reads.
    static func classify() -> EnvironmentClassification {
        #if DEBUG
        return .looksDevelopment
        #else

        #if targetEnvironment(simulator)
        return .looksDevelopment
        #else

        // Receipt URL: "sandboxReceipt" → TestFlight / StoreKit sandbox
        //              "receipt"        → App Store / Ad Hoc (the App Store
        //                                 path is the same — we use the
        //                                 mobileprovision check below to
        //                                 disambiguate).
        let receiptName = Bundle.main.appStoreReceiptURL?.lastPathComponent
        let hasMobileProvision = Bundle.main.path(
            forResource: "embedded",
            ofType: "mobileprovision"
        ) != nil

        if receiptName == "sandboxReceipt" {
            return .looksBeta
        }
        if receiptName == "receipt" {
            // App Store strips embedded.mobileprovision from the IPA.
            // Its presence indicates Ad Hoc / Enterprise / dev / TestFlight
            // (which technically uses sandboxReceipt — caught above — but
            // some custom-distribution paths still look like this).
            return hasMobileProvision ? .looksBeta : .looksProduction
        }
        // No receipt at all is unusual. Treat as unknown so the developer's
        // declared environment wins.
        return .unknown

        #endif
        #endif
    }
}
