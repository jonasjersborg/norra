//
//  ChargingDetail.swift
//  Norra
//
//  The finer-grained charging fields, kept in the shape the UI already reads.
//
//  On Polestar these came from a separate gRPC battery service because the
//  GraphQL API didn't carry them. Volvo returns them in the same Energy v2
//  response as the battery level, so the service is gone — but the struct
//  stays, because the menu rows, the widget and the notifications all read
//  charging detail from here, and renaming it would have been a rename for
//  its own sake.
//

import Foundation

/// The extra battery fields the gRPC service knows about. All optional —
/// every consumer must degrade gracefully when the service is unreachable.
struct GrpcBatteryExtras {
    /// "CONNECTED", "DISCONNECTED" or "FAULT" (UNSPECIFIED is dropped).
    let chargerConnectionStatus: String?
    let chargingPowerWatts: Int?
    let chargingCurrentAmps: Int?
    let chargingVoltageVolts: Int?
    /// "AC", "DC" or "WIRELESS". NONE and UNSPECIFIED both map to nil — the
    /// car reports NONE whenever it isn't charging, which is not worth a row.
    let chargingType: String?
}
