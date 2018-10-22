//
//  LQWebImageManager.swift
//  LQMediaKit
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
    
    /// 发生错误后将该url加入黑名单，不再重试，默认不加入黑名单
    static let IgnoreFailedURL = LQWebImageOptions(rawValue: 1 << 2)
    
    /// 忽略LQImageCache, 使用NSURLCache
    static let UseURLCache = LQWebImageOptions(rawValue: 1 << 3)
    
    /// 缓存图片和从缓存中取图片时忽略disk cache
    static let IgnoreDiskCache = LQWebImageOptions(rawValue: 1 << 4)
    
    /// 刷新缓存
    static let RefreshImageCache = LQWebImageOptions(rawValue: 1 << 5)
    
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
    
    /// 非WiFi网络下动图只下载第一帧以节省流量（无论是否开启该选项想，WiFi网络下均默认加载动图的全部数据）
    static let OnlyDownloadFirstFrameWhenAnimationImage = LQWebImageOptions(rawValue: 1 << 11)
    
    /// 设置图片时使用fade动画，默认显示fade动画
    static let ShowFadeAnimationWhenSetImage = LQWebImageOptions(rawValue: 1 << 12)
}

enum LQWebImageLoadStatus {
    case progress
    case finished
    case cancelled
}

typealias LQWebImageProgress = (Int, Int) -> Void
typealias LQWebImageTransform = (URL, UIImage) -> UIImage?
typealias LQWebImageCompletion = (URL?, UIImage?, LQWebImageLoadStatus, NSError?) -> Void


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
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 3
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
