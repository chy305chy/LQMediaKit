//
//  LQProxy.swift
//  LQMediaKitDemo
//
//  Created by cuilanqing on 2018/9/29.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation

class LQWeakProxy: NSObject {
    
    private(set) weak var target: NSObjectProtocol?
    
    init(target: NSObjectProtocol) {
        self.target = target
        super.init()
    }
    
    override func responds(to aSelector: Selector!) -> Bool {
        return (target?.responds(to: aSelector) ?? false) || super.responds(to: aSelector)
    }
    
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        return target
    }
}
