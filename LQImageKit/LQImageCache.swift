//
//  LQImageCache.swift
//  LQMediaKitDemo
//
//  Created by cuilanqing on 2018/9/20.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

typealias GetImageCompletionBlock = (_ image: UIImage?, _ cacheType: LQImageCacheType) -> Void

struct LQImageCacheType: OptionSet {
    let rawValue: UInt
    
    static let None = LQImageCacheType(rawValue: 1 << 0)
    static let Memory = LQImageCacheType(rawValue: 1 << 1)
    static let Disk = LQImageCacheType(rawValue: 1 << 2)
    static let All = [LQImageCacheType.Memory, LQImageCacheType.Disk]
}

class LQImageCache: NSObject {
    var name: String?
    private(set) var memoryCache: LQMemoryCache?
    private(set) var diskCache: LQDiskCache?
    static let sharedCache = { () -> LQImageCache in
        let cacheUrl = URL(string: NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!)?.appendingPathComponent("com.lq.mediakit").appendingPathComponent("cache").appendingPathComponent("image")
        if cacheUrl == nil {
            fatalError("init error, path is null.")
        }
        return LQImageCache(path: cacheUrl!.path)
    }()
    
    @available(*, unavailable)
    override init() {
        fatalError("init error, use init(path) / sharedCache() instead.")
    }
    
    init(path: String) {
        super.init()
        
        if path.count == 0 {
            fatalError("init error, path is empty.")
        }
        
        memoryCache = LQMemoryCache()
        diskCache = LQDiskCache(witPath: path)
        
        if memoryCache == nil || diskCache == nil {
            fatalError("init error, can't creat cache.")
        }
        
        memoryCache?.shouldClearCacheOnMemoryWarning = true
        memoryCache?.shouldClearCacheWhenEnterBackground = true
    }
    
    public func setImage(image: UIImage, forKey key: String) {
        setImage(image: image, imageData: nil, forKey: key, cacheType: LQImageCacheType.All)
    }
    
    public func setImage(image: UIImage?, imageData: Data?, forKey key: String, cacheType: [LQImageCacheType]) {
        if key.count == 0 || (image == nil && (imageData == nil || imageData?.count == 0)) {
            return
        }
        
        if cacheType.contains(.Memory) {
            if image != nil {
                if image!.isDecoded {
                    memoryCache!.setObject(forKey: key, object: image)
                } else {
                    DispatchQueue.global(qos: .background).async {
                        self.memoryCache!.setObject(forKey: key, object: image!.imageByDecoded())
                    }
                }
            } else if (imageData != nil) {
                let newImage = UIImage(data: imageData!)
                if newImage!.isDecoded {
                    memoryCache!.setObject(forKey: key, object: newImage)
                } else {
                    DispatchQueue.global(qos: .background).async {
                        self.memoryCache!.setObject(forKey: key, object: newImage!.imageByDecoded())
                    }
                }
            }
        }
        
        if cacheType.contains(.Disk) {
            if image != nil {
                diskCache!.setObject(forKey: key, object: image)
            } else if imageData != nil {
                let newImage = UIImage(data: imageData!)
                diskCache!.setObject(forKey: key, object: newImage)
            }
        }
    }
    
    public func removeImage(forKey key: String) {
        removeImage(forKey: key, withType: LQImageCacheType.All)
    }
    
    public func removeImage(forKey key: String, withType type: [LQImageCacheType]) {
        if type.contains(.Memory) {
            memoryCache?.removeObject(forKey: key)
        }
        if type.contains(.Disk) {
            _ = diskCache?.removeObject(forKey: key)
        }
    }
    
    public func containsImage(forKey key: String) -> Bool {
        return containsImage(forKey: key, withType: LQImageCacheType.All)
    }
    
    public func containsImage(forKey key: String, withType type: [LQImageCacheType]) -> Bool {
        if type.contains(.Memory) {
            if memoryCache == nil {
                return false
            }
            if memoryCache!.containsObject(key: key) {
                return true
            }
        }
        if type.contains(.Disk) {
            if diskCache == nil {
                return false
            }
            if diskCache!.containsObject(forKey: key) {
                return true
            }
        }
        return false
    }
    
    public func getImage(forKey key: String) -> UIImage? {
        return getImage(forKey: key, withType: LQImageCacheType.All)
    }
    
    public func getImage(forKey key: String, withType type: [LQImageCacheType]) -> UIImage? {
        if type.contains(.Memory) {
            let image = memoryCache?.getObject(key: key) as? UIImage
            if image != nil {
                return image
            }
        }
        if type.contains(.Disk) {
            let image = diskCache?.getObject(forKey: key) as? UIImage
            if image != nil {
                if type.contains(.Memory) {
                    memoryCache?.setObject(forKey: key, object: image)
                }
                return image
            }
        }
        return nil
    }
    
    public func getImage(forKey key: String, withType type: LQImageCacheType, completion: GetImageCompletionBlock?) {
        if completion == nil {
            return
        }
        DispatchQueue.global(qos: .background).async {
            var image: UIImage?
            
            if type.contains(.Memory) {
                image = self.memoryCache?.getObject(key: key) as? UIImage
                if image != nil {
                    DispatchQueue.main.async {
                        completion!(image, .Memory)
                    }
                    return
                }
            }
            
            if type.contains(.Disk) {
                image = self.diskCache?.getObject(forKey: key) as? UIImage
                if image != nil {
                    DispatchQueue.main.async {
                        completion!(image, .Disk)
                    }
                    return
                }
            }
            
            DispatchQueue.main.async {
                completion!(nil, .None)
            }
        }
    }
    
}
