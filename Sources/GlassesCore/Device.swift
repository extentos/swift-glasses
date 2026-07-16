import Foundation

public typealias DeviceId = String

// `DeviceInfo` + `DeviceType` → migrated to extentos-core in Phase 2.0 (the
// generated bindings compile into GlassesCore, so `import`s are unchanged).
// `DeviceInfo.id` is a plain `String` on the core type; `DeviceId` stays a
// shell-side alias so existing `connect(deviceId: DeviceId?)` signatures hold.
// Two documented iOS deltas on the core `DeviceInfo`: `firmwareVersion` is a
// non-optional `String` (canonicalised to Android's shape), and `DeviceType`
// gains `metaOrion` / `mentraG1` (the union of both platforms' cases).
