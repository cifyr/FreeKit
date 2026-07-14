import Foundation
import CIMobileDevice
import FreeSpeechCore

// iPhone/iPad/Apple Watch battery via libimobiledevice's lockdownd + companion_proxy
// services, feeding into Stats' device battery section alongside the Bluetooth-accessory
// scan (StatsSampler.bluetoothAccessoryBatteries). Only works against a device already
// trust-paired over USB or WiFi sync — there is no way to read this battery level without
// that relationship. Silent no-op (empty result, not an error) for anything not paired:
// this mirrors the module's existing quiet-failure style for the IOKit Bluetooth scan.
enum IDeviceBatteryReader {
    static func read() -> [DeviceBattery] {
        var results: [DeviceBattery] = []

        var deviceList: UnsafeMutablePointer<idevice_info_t?>?
        var count: Int32 = 0
        guard idevice_get_device_list_extended(&deviceList, &count) == IDEVICE_E_SUCCESS,
              let deviceList else {
            return []
        }
        defer { idevice_device_list_extended_free(deviceList) }

        for i in 0..<Int(count) {
            guard let info = deviceList[i] else { continue }
            guard let udidCString = info.pointee.udid else { continue }
            let udid = String(cString: udidCString)
            let options: idevice_options = info.pointee.conn_type == CONNECTION_NETWORK
                ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX

            var device: idevice_t?
            guard idevice_new_with_options(&device, udidCString, options) == IDEVICE_E_SUCCESS,
                  let device else {
                Log.info("stats: idevice_new_with_options failed for \(udid), skipping")
                continue
            }
            defer { idevice_free(device) }

            var lockdown: lockdownd_client_t?
            guard lockdownd_client_new_with_handshake(device, &lockdown, "FreeKit") == LOCKDOWN_E_SUCCESS,
                  let lockdown else {
                // Not trust-paired (or paired to a different Mac) — expected, not an error.
                Log.info("stats: lockdownd handshake failed for \(udid), not trust-paired")
                continue
            }
            defer { lockdownd_client_free(lockdown) }

            guard let level = batteryLevel(lockdown) else {
                Log.info("stats: no battery info for \(udid)")
                continue
            }
            let name = deviceName(lockdown) ?? "iPhone or iPad"
            results.append(DeviceBattery(name: name, percent: level))
            Log.info("stats: read \(name) (\(udid)) battery \(level)%")

            if let watch = watchBattery(device: device) {
                results.append(watch)
            }
        }

        return results
    }

    private static func deviceName(_ lockdown: lockdownd_client_t) -> String? {
        var value: plist_t?
        guard lockdownd_get_value(lockdown, nil, "DeviceName", &value) == LOCKDOWN_E_SUCCESS else { return nil }
        defer { plist_free(value) }
        return plistString(value)
    }

    private static func batteryLevel(_ lockdown: lockdownd_client_t) -> Int? {
        var value: plist_t?
        guard lockdownd_get_value(lockdown, "com.apple.mobile.battery", "BatteryCurrentCapacity", &value)
                == LOCKDOWN_E_SUCCESS else { return nil }
        defer { plist_free(value) }
        return plistUInt(value).map(Int.init)
    }

    private static func watchBattery(device: idevice_t) -> DeviceBattery? {
        var client: companion_proxy_client_t?
        guard companion_proxy_client_start_service(device, &client, "FreeKit") == COMPANION_PROXY_E_SUCCESS,
              let client else {
            return nil
        }
        defer { companion_proxy_client_free(client) }

        var registry: plist_t?
        guard companion_proxy_get_device_registry(client, &registry) == COMPANION_PROXY_E_SUCCESS,
              let registry else {
            return nil
        }
        defer { plist_free(registry) }

        guard plist_array_get_size(registry) > 0,
              let firstEntry = plist_array_get_item(registry, 0),
              let watchUDID = plistString(firstEntry) else {
            return nil
        }

        var levelValue: plist_t?
        guard companion_proxy_get_value_from_registry(client, watchUDID, "BatteryCurrentCapacity", &levelValue)
                == COMPANION_PROXY_E_SUCCESS, let level = plistUInt(levelValue) else {
            return nil
        }
        defer { plist_free(levelValue) }

        var nameValue: plist_t?
        var name = "Apple Watch"
        if companion_proxy_get_value_from_registry(client, watchUDID, "Name", &nameValue) == COMPANION_PROXY_E_SUCCESS,
           let resolved = plistString(nameValue) {
            name = resolved
        }
        defer { plist_free(nameValue) }

        Log.info("stats: read \(name) (\(watchUDID)) companion battery \(level)%")
        return DeviceBattery(name: name, percent: Int(level))
    }

    private static func plistString(_ node: plist_t?) -> String? {
        guard let node else { return nil }
        var cString: UnsafeMutablePointer<CChar>?
        plist_get_string_val(node, &cString)
        guard let cString else { return nil }
        defer { free(cString) }
        return String(cString: cString)
    }

    private static func plistUInt(_ node: plist_t?) -> UInt64? {
        guard let node else { return nil }
        var value: UInt64 = 0
        plist_get_uint_val(node, &value)
        return value
    }
}
