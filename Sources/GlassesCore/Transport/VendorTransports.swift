import Foundation

/// Registry through which a vendor transport that lives OUTSIDE GlassesCore
/// joins `TransportChoice.auto` resolution.
///
/// The Swift mirror of Android's `VendorTransports`, and it exists for the same
/// reason: a vendor whose SDK cannot ship inside the main package needs a seam
/// to register itself through. On Android that is `:glasses-xr` and
/// `:glasses-htc`; on iOS the first case is HTC VIVE Eagle, whose frameworks
/// have no licence permitting redistribution and therefore ship as a separate
/// SwiftPM package (`swift-glasses-htc`).
///
/// Every transport that CAN live in this module still does — Meta, Brilliant,
/// the browser sim and the vendorless audio baseline are all resolved directly
/// by `Extentos.swift`. This is not a generalised plugin system; it is the one
/// door for the case where the vendor's own licensing makes in-module
/// impossible.
///
/// iOS has no `androidx.startup`, so registration is explicit: the host app
/// calls the vendor package's one-liner (`ExtentosHtc.register()`) at launch.
/// That is a real platform difference rather than a port gap — there is no iOS
/// mechanism that runs a library's code before the app's.
public enum VendorTransports {

    /// A vendor package's entry point into `auto` resolution.
    public protocol Factory: AnyObject, Sendable {
        /// Canonical vendor wire token (e.g. `"htc"`).
        var vendorId: String { get }

        /// The `TransportChosen` value reported when this factory claims.
        var chosen: TransportChosen { get }

        /// Resolution order when more than one vendor is eligible — lower first.
        ///
        /// Defaults to ``priorityPreview`` so a new vendor package cannot
        /// quietly outrank a production one by forgetting to declare anything.
        /// A vendor whose transport has run on real hardware overrides to
        /// ``priorityProduction``.
        var priority: Int { get }

        /// Return a transport when this vendor's device is present and
        /// eligible — must be a fast, non-blocking check — or `nil` to let
        /// resolution continue down the chain.
        func createIfEligible(config: ExtentosConfig) -> (any GlassesTransport)?
    }

    /// Hardware-verified, shipping vendors.
    public static let priorityProduction = 0

    /// Built but unproven on hardware. Ranks behind production by default.
    public static let priorityPreview = 100

    private static let lock = NSLock()
    nonisolated(unsafe) private static var factories: [any Factory] = []

    /// Register a vendor factory. Idempotent per instance.
    public static func register(_ factory: any Factory) {
        lock.lock(); defer { lock.unlock() }
        guard !factories.contains(where: { $0 === factory }) else { return }
        factories.append(factory)
    }

    /// Remove a previously registered factory (tests / teardown).
    public static func unregister(_ factory: any Factory) {
        lock.lock(); defer { lock.unlock() }
        factories.removeAll { $0 === factory }
    }

    /// Drop all registrations (test isolation).
    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        factories.removeAll()
    }

    /// Which vendors THIS BUILD can reach on real hardware — the registered
    /// factories' wire ids, sorted, or empty when no vendor package is present.
    ///
    /// "Can reach", not "is connected": a vendor appears here because its
    /// package is linked, whether or not a device is paired.
    ///
    /// Exists because the simulator makes a missing vendor package invisible.
    /// `BrowserSimTransport` serves camera and display from the Rust core, so a
    /// build with no vendor package simulates a pair of glasses perfectly and
    /// then reaches nothing on real hardware — the one direction of
    /// sim/hardware divergence that manufactures confidence instead of
    /// destroying it.
    public static func reachableVendorIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(factories.map(\.vendorId))).sorted()
    }

    /// First factory that claims, in a DETERMINISTIC order.
    ///
    /// Registration order would be incidental — it depends on the order the host
    /// app happens to call each vendor's `register()` — so the order is declared
    /// instead:
    ///
    ///  1. `priority`, lower first. On a phone that could satisfy two vendors,
    ///     the right default is the transport that has actually run on hardware.
    ///  2. `vendorId` alphabetically, purely to make ties stable.
    ///
    /// Deliberately NOT a way for an app to express a preference. An app that
    /// wants a specific vendor says so with an explicit `TransportChoice`.
    static func resolveFirstEligible(config: ExtentosConfig) -> ((any GlassesTransport), TransportChosen)? {
        lock.lock()
        let ordered = factories.sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.vendorId < $1.vendorId
        }
        lock.unlock()
        for factory in ordered {
            if let transport = factory.createIfEligible(config: config) {
                return (transport, factory.chosen)
            }
        }
        return nil
    }
}

public extension VendorTransports.Factory {
    var priority: Int { VendorTransports.priorityPreview }
}
