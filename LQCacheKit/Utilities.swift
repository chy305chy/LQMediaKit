//
//  Utilities.swift
//  LQCacheKitDemo
//
//  Created by cuilanqing on 2018/9/17.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation

extension Int {
    /// 重载运算符
    static prefix func ++(num: inout Int) -> Int {
        num += 1
        return num
    }
    
    static postfix func ++(num: inout Int) -> Int {
        let tmp = num
        num += 1
        return tmp
    }
    
    static prefix func --(num: inout Int) -> Int {
        num -= 1
        return num
    }
    
    static postfix func --(num: inout Int) -> Int {
        let tmp = num
        num -= 1
        return tmp
    }
}
