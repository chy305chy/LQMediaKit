//
//  LQWebImageManager.swift
//  LQMediaKitDemo
//
//  Created by cuilanqing on 2018/9/20.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

struct LQWebImageOptions : OptionSet {
    let rawValue: UInt
    
    /// 在statusBar上显示网络状态
    static let ShowNetworkActivity = LQWebImageOptions(rawValue: 1 << 0)
    
    /// 渐进式加载
    static let Progressive = LQWebImageOptions(rawValue: 1 << 1)
    
    /// 失败后重试
    static let RetryFailed = LQWebImageOptions(rawValue: 1 << 2)
    
    /// 优先级 - 高
    static let HighPriority = LQWebImageOptions(rawValue: 1 << 3)
    
    /// 优先级 - 低
    static let LowPriority = LQWebImageOptions(rawValue: 1 << 4)
    
    /// 仅缓存到Memory中
    static let CacheMemoryOnly = LQWebImageOptions(rawValue: 1 << 5)
    
    /// handle cookies
    static let HandleCookies = LQWebImageOptions(rawValue: 1 << 6)
    
    /// 当App进入后台时继续
    static let ContinueInBackground = LQWebImageOptions(rawValue: 1 << 7)
    
    /// 允许invalid SSL证书
    static let AllowInvalidSSLCertificate = LQWebImageOptions(rawValue: 1 << 8)
    
    /// 忽略图片的预解码（默认状态下，图片下载后即解码）
    static let IgnoreImagePreDecode = LQWebImageOptions(rawValue: 1 << 9)
    
    /// 忽略动图
    static let IgnoreAnimationImage = LQWebImageOptions(rawValue: 1 << 10)
    
    /// 刷新缓存
    static let RefreshImageCache = LQWebImageOptions(rawValue: 1 << 11)
    
    /// 缓存原始image数据（默认情况下，缓存解码后的数据，但是空间占用较大）
    static let CacheOriginalImageData = LQWebImageOptions(rawValue: 1 << 12)
    
    /// 忽略LQImageCache, 使用NSURLCache
    static let UseURLCache = LQWebImageOptions(rawValue: 1 << 13)
    
    /// 忽略disk cache
    static let IgnoreDiskCache = LQWebImageOptions(rawValue: 1 << 14)
    
    /// 忽略发生请求错误的URL
    static let IgnoreFailedURL = LQWebImageOptions(rawValue: 1 << 15)
}

enum LQWebImageStatus {
    case Progress
    case Finished
    case Cancelled
}

typealias LQWebImageProgress = (Int, Int) -> Void
typealias LQWebImageTransform = (URL, UIImage) -> UIImage?
typealias LQWebImageCompletion = (URL?, UIImage?, NSError?) -> Void


class LQWebImageManager: NSObject {
    
    var timeout: TimeInterval = 15
    var imageCache: LQImageCache?
    var queue: OperationQueue?
    var username: String?
    var password: String?
    var httpHeaders: [String: String]?
    
    static let sharedManager = { () -> LQWebImageManager in
        let cache = LQImageCache.sharedCache
        let queue = OperationQueue()
        queue.qualityOfService = .background
        queue.maxConcurrentOperationCount = 2
        let manager = LQWebImageManager(cache: cache, queue: queue)
        return manager
    }()
    
    @available(*, unavailable)
    override init() {}
    
    init(cache: LQImageCache?, queue: OperationQueue?) {
        super.init()
        self.imageCache = cache
        self.queue = queue
        self.httpHeaders = ["Accept": "image/*;q=0.8"]
    }
    
    public func requestImage(withUrl url: URL, options: [LQWebImageOptions], progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?) -> LQWebImageOperation? {
        
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = options.contains(.HandleCookies)
        request.allHTTPHeaderFields = httpHeaders
        request.httpShouldUsePipelining = true
        request.cachePolicy = options.contains(.UseURLCache) ? .useProtocolCachePolicy : .reloadIgnoringLocalCacheData
        
        let operation = LQWebImageOperation(request: request, options: options, cache: imageCache, cacheKey: cacheKeyForUrl(url: url), progress: progress, transform: transform, completion: completion)
        
        if username != nil && password != nil {
            operation.credential = URLCredential(user: username!, password: password!, persistence: .forSession)
        }
        
        if queue != nil {
            queue!.addOperation(operation)
        } else {
            operation.start()
        }
        
        return operation
    }
    
    public func cacheKeyForUrl(url: URL) -> String {
        if url.absoluteString.count == 0 {
            return ""
        }
        return url.absoluteString
    }
    
}
