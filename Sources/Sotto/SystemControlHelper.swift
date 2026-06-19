import Foundation
import CoreAudio
import CoreGraphics

struct SystemControlHelper {
    
    // --- 1. COREAUDIO MASTER VOLUME ---
    
    private static func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(1),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        
        return status == noErr ? deviceID : nil
    }
    
    static func getVolume() -> Float {
        guard let deviceID = getDefaultOutputDevice() else { return 0 }
        
        var volume = Float(0.0)
        var size = UInt32(MemoryLayout.size(ofValue: volume))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &volume
        )
        
        if status != noErr {
            // Fallback to channel 1 if master is not available
            address.mElement = 1
            _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        }
        
        return volume * 100.0
    }
    
    @discardableResult
    static func setVolume(_ volume: Float) -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }
        
        var volumeVal = max(0.0, min(100.0, volume)) / 100.0
        let size = UInt32(MemoryLayout.size(ofValue: volumeVal))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &volumeVal
        )
        
        if status != noErr {
            // Fallback to channel 1 and 2
            address.mElement = 1
            status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volumeVal)
            address.mElement = 2
            _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volumeVal)
        }
        
        return status == noErr
    }
    
    static func isMuted() -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }
        
        var muteVal: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: muteVal))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &muteVal
        )
        
        if status != noErr {
            address.mElement = 1
            _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muteVal)
        }
        
        return muteVal != 0
    }
    
    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }
        
        var muteVal: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout.size(ofValue: muteVal))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &muteVal
        )
        
        if status != noErr {
            address.mElement = 1
            status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muteVal)
            address.mElement = 2
            _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muteVal)
        }
        
        return status == noErr
    }
    
    // --- 2. DYNAMIC DISPLAYSERVICES SCREEN BRIGHTNESS ---
    
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    
    private static var setBrightnessPtr: SetBrightnessFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            return nil
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            return unsafeBitCast(sym, to: SetBrightnessFunc.self)
        }
        return nil
    }()
    
    private static var getBrightnessPtr: GetBrightnessFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            return nil
        }
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            return unsafeBitCast(sym, to: GetBrightnessFunc.self)
        }
        return nil
    }()
    
    static func getBrightness() -> Float {
        var brightness: Float = 0.5
        if let getFunc = getBrightnessPtr {
            let status = getFunc(CGMainDisplayID(), &brightness)
            if status == 0 {
                return brightness
            }
        }
        return 0.5
    }
    
    @discardableResult
    static func setBrightness(_ value: Float) -> Bool {
        let cleanVal = max(0.0, min(1.0, value))
        if let setFunc = setBrightnessPtr {
            let status = setFunc(CGMainDisplayID(), cleanVal)
            return status == 0
        }
        return false
    }
}
