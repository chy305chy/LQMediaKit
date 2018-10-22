//
//  LQNetworkActivityIndicatorManager.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/10/19.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

class LQNetworkActivityIndicatorManager: NSObject {
    private let _sem_lock = DispatchSemaphore(value: 1)
    private let _invisibleActivityIndicatorDelay = 0.17
    private var _activityIndicatorVisibilityTimer: Timer?
    private var _activityCount: Int = 0
    
    public var activityCount: Int {
        get {
            return _activityCount
        }
        set {
            _activityCount = newValue
            
            DispatchQueue.main.async {
                self._updateNetworkActivityIndicatorStatusDelay()
            }
        }
    }
    public var enabled: Bool = false
    
    static let sharedManager = { () -> LQNetworkActivityIndicatorManager in
        let manager = LQNetworkActivityIndicatorManager()
        return manager
    }()
    
    private override init() {
        super.init()
    }
    
    deinit {
        if _activityIndicatorVisibilityTimer != nil {
            _activityIndicatorVisibilityTimer!.invalidate()
            _activityIndicatorVisibilityTimer = nil
        }
    }
    
    @objc private func _updateNetworkActivityIndicatorStatus() {
        UIApplication.shared.isNetworkActivityIndicatorVisible = self._isNetworkIndicatorVisable()
    }
    
    private func _isNetworkIndicatorVisable() -> Bool {
        return _activityCount > 0
    }
    
    private func _updateNetworkActivityIndicatorStatusDelay() {
        if enabled {
            if !_isNetworkIndicatorVisable() {
                if _activityIndicatorVisibilityTimer != nil {
                    _activityIndicatorVisibilityTimer!.invalidate()
                    _activityIndicatorVisibilityTimer = nil
                }
                _activityIndicatorVisibilityTimer = Timer(timeInterval: _invisibleActivityIndicatorDelay, target:LQWeakProxy(target: self) , selector: #selector(_updateNetworkActivityIndicatorStatus), userInfo: nil, repeats: false)
                RunLoop.main.add(_activityIndicatorVisibilityTimer!, forMode: .common)
            } else {
                self.performSelector(onMainThread: #selector(_updateNetworkActivityIndicatorStatus), with: nil, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
            }
        }
    }
    
    public func incrementActivityCount() {
        self.willChangeValue(forKey: "LQNetworkActivityIndicatorManager.activityCount")
        _sem_lock.wait()
        activityCount = activityCount.advanced(by: 1)
        _sem_lock.signal()
        self.didChangeValue(forKey: "LQNetworkActivityIndicatorManager.activityCount")
    }
    
    public func decrementActivityCount() {
        self.willChangeValue(forKey: "LQNetworkActivityIndicatorManager.activityCount")
        _sem_lock.wait()
        activityCount = activityCount.advanced(by: -1)
        _sem_lock.signal()
        self.didChangeValue(forKey: "LQNetworkActivityIndicatorManager.activityCount")
    }
    
}
