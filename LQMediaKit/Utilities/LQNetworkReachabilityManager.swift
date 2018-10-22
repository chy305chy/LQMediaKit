//
//  LQNetworkReachabilityManager.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/10/19.
//  Copyright © 2018 cuilanqing. All rights reserved.
//  网络状态监听

import Foundation
import SystemConfiguration

extension Notification.Name {
    public static let reachabilityChanged = Notification.Name(rawValue: "reachabilityChanged")
}

public enum NetworkStatus {
    case none
    case wifi
    case wwan
}

class LQNetworkReachabilityManager: NSObject {
    
    private var reachability: SCNetworkReachability?
    private var flags: SCNetworkReachabilityFlags {
        var flags = SCNetworkReachabilityFlags(rawValue: 0)
        
        if let reachability = reachability, withUnsafeMutablePointer(to: &flags, { SCNetworkReachabilityGetFlags(reachability, UnsafeMutablePointer($0)) }) == true {
            return flags
        }
        else {
            return []
        }
    }
    private var notifying = false
    
    public var networkStatus: NetworkStatus {
        
        if flags.contains(.reachable) {
            if flags.contains(.isWWAN) {
                return .wwan
            } else {
                return .wifi
            }
        } else {
            return .none
        }
    }
    
    static let sharedManager = { () -> LQNetworkReachabilityManager in
        let manager = LQNetworkReachabilityManager()
        var zeroAddress = sockaddr()
        zeroAddress.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        zeroAddress.sa_family = sa_family_t(AF_INET)
        let reachability = SCNetworkReachabilityCreateWithAddress(nil, &zeroAddress)
        manager.reachability = reachability
        return manager
    }()
    
    private override init() {
        super.init()
    }
    
    deinit {
        stopNotifier()
    }
}

//private extension LQNetworkReachabilityManager {
//
//    func setReachabilityFlags() throws {
//
//    }
//
//    func reachabilityChanged() {
//        DispatchQueue.main.async { [weak self] in
//
//        }
//    }
//
//}

extension LQNetworkReachabilityManager {
    
    public func startNotifier() -> Bool {
        guard !notifying else {
            return false
        }
        
        var context = SCNetworkReachabilityContext()
        context.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard let reachability = reachability, SCNetworkReachabilitySetCallback(reachability, { (target: SCNetworkReachability, flags: SCNetworkReachabilityFlags, info: UnsafeMutableRawPointer?) in
            if let currentInfo = info {
                let infoObject = Unmanaged<AnyObject>.fromOpaque(currentInfo).takeUnretainedValue()
                if infoObject is LQNetworkReachabilityManager {
                    let networkStatus = (infoObject as! LQNetworkReachabilityManager).networkStatus
                    NotificationCenter.default.post(name: Notification.Name.reachabilityChanged, object: networkStatus)
                }
            }
        }, &context) == true else { return false }
        
        notifying = true
        return notifying
    }
    
    public func stopNotifier() {
        if let reachability = reachability, notifying == true {
            SCNetworkReachabilityUnscheduleFromRunLoop(reachability, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode as! CFString)
            notifying = false
        }
    }
}
