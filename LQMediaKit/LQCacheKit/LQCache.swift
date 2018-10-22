//
//  LQCache.swift
//  LQCacheKit
//
//  Created by cuilanqing on 2018/9/18.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation

typealias LQCacheClearProgress = (Int, Int) -> Void
typealias LQCacheClearFinish = (Bool) -> Void

class LQCache : NSObject {
    private(set) var memoryCache: LQMemoryCache?
    private(set) var diskCache: LQDiskCache?
    var name: String = ""
    
    @available(*, unavailable)
    override init() {
        fatalError("init error, use init(withPath path: String) / init(withName name: String) instead.")
    }
    
    convenience init(withName name: String) {
        if name.count == 0 {
            fatalError("name should not be empty")
        }
        
        let path = (NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first! as NSString).appendingPathComponent(name)
        self.init(withPath: path)
    }
    
    init(withPath path: String) {
        super.init()
        
        if path.count == 0 {
            fatalError("path should not be empty, please retry.")
        }
        
        memoryCache = LQMemoryCache()
        diskCache = LQDiskCache(witPath: path)
        if memoryCache == nil || diskCache == nil {
            fatalError("init error, please retry")
        }
        
        let tmpName = (path as NSString).lastPathComponent
        memoryCache!.name = tmpName
        self.name = tmpName
    }
    
    static func cacheWithName(name: String) -> LQCache? {
        return LQCache(withName: name)
    }
    
    static func cacheWithPath(path: String) -> LQCache? {
        return LQCache(withPath: path)
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?) where T: NSCoding {
        memoryCache!.setObject(forKey: key, object: object)
        diskCache!.setObject(forKey: key, object: object)
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?, lifeTime: TimeInterval) where T: NSCoding {
        memoryCache!.setObject(forKey: key, object: object, lifeTime: lifeTime)
        diskCache!.setObject(forKey: key, object: object, lifeTime: lifeTime)
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?, result: @escaping (Bool) -> Void) where T: NSCoding {
        memoryCache!.setObject(forKey: key, object: object)
        diskCache!.setObject(forKey: key, object: object, finish: result)
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?, lifeTime: TimeInterval, result: @escaping (Bool) -> Void) where T: NSCoding {
        memoryCache!.setObject(forKey: key, object: object, lifeTime: lifeTime)
        diskCache!.setObject(forKey: key, object: object, lifeTime: lifeTime, finish: result)
    }
    
    public func getObject(forKey key: String) -> AnyObject? {
        // 先从内存中查找
        var object = memoryCache!.getObject(key: key)
        if object == nil {
            // 内存中未找到，从磁盘缓存中z查找，找到后缓存到内存中
            object = diskCache!.getObject(forKey: key)
            if object != nil {
                memoryCache?.setObject(forKey: key, object: object, lifeTime: diskCache!.getObjectLifeTime(forKey: key))
            }
        }
        return object
    }
    
    public func getObject(forKey key: String, result: @escaping (String, AnyObject?) -> Void) {
        let object = memoryCache!.getObject(key: key)
        if object != nil {
            DispatchQueue.global().async {
                result(key, object)
            }
        } else {
            diskCache!.getObject(forKey: key) { (key, obj) in
                if obj != nil {
                    self.memoryCache!.setObject(forKey: key, object: obj, lifeTime: self.diskCache!.getObjectLifeTime(forKey: key))
                }
                result(key, obj)
            }
        }
    }
    
    public func removeObject(forKey key: String) -> Bool {
        memoryCache!.removeObject(forKey: key)
        return diskCache!.removeObject(forKey: key)
    }
    
    public func removeObject(forKey key: String, result: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .default).async {
            let rs = self.removeObject(forKey: key)
            result(key, rs)
        }
    }
    
    public func removeAllObjects() -> Bool {
        memoryCache?.clearCache()
        return diskCache!.removeAllObects()
    }
    
    public func removeAllObjects(withResult result: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .default).async {
            let rs = self.removeAllObjects()
            result(rs)
        }
    }
    
    public func removeAllObjects(withProgress progress:@escaping LQCacheClearProgress, finish:@escaping LQCacheClearFinish) {
        memoryCache?.clearCache()
        diskCache?.removeAllObjects(withProgress: progress, finish: finish)
    }
    
    deinit {
        memoryCache = nil
        diskCache = nil
    }
}
