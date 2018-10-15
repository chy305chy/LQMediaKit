//
//  LQWebImageOperation.swift
//  LQMediaKitDemo
//
//  Created by cuilanqing on 2018/9/20.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit
import ImageIO

//MARK: - Lock相关
fileprivate let recursive_lock = { () -> UnsafeMutablePointer<pthread_mutex_t> in
    let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    let lock_attr = UnsafeMutablePointer<pthread_mutexattr_t>.allocate(capacity: 1)
    pthread_mutexattr_init(lock_attr)
    pthread_mutexattr_settype(lock_attr, PTHREAD_MUTEX_RECURSIVE)
    pthread_mutex_init(lock, lock_attr)
    
    return lock
}()

fileprivate func lock(handler: () -> Void) {
    pthread_mutex_lock(recursive_lock)
    handler()
    pthread_mutex_unlock(recursive_lock)
}

struct SessionError: Error {
    var code: Int
    var localizedDescription: String?
    var domain: NSErrorDomain
    var userInfo: [NSError.UserInfoKey: Any]?
}

class LQWebImageOperation: Operation, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    private(set) var request: URLRequest?
    private(set) var response: URLResponse?
    private(set) var cache: LQImageCache?
    private(set) var cacheKey: String?
    var credential: URLCredential?
    
    static let _networkThread = { () -> Thread in
        let thread = Thread(target: LQWebImageOperation.self, selector: #selector(_networkThreadEntryPoint), object: nil)
        thread.name = "com.clq.lqmediakit.webimage.request"
        thread.qualityOfService = .background
        thread.start()
        return thread
    }()
    
    static let _imageProcessQueue = { () -> DispatchQueue in
        var queues = [DispatchQueue]()
        var queueCount = ProcessInfo.processInfo.activeProcessorCount
        var counter = 0
        queueCount = queueCount < 1 ? 1 : queueCount > 16 ? 16 : queueCount
        for i in 0 ..< queueCount {
            let queue = DispatchQueue(label: "com.mediakit.image.imageprocess")
            queues.append(queue)
        }
        counter = counter.advanced(by: 1)
        var i: Int = counter
        if i < 0 {
            i = i.unsafeMultiplied(by: -1)
        }
        return queues[i % queueCount]
    }()
    
    private var expectedSize: Int = 0
    private var imageData: Data?
    private var options: [LQWebImageOptions]
    private var decoder: LQImageDecoder?
    private var lastProgressiveDecodeTimestamp: TimeInterval = 0
    private var progress: LQWebImageProgress?
    private var transform: LQWebImageTransform?
    private var completion: LQWebImageCompletion?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier?
    private var _sessionConfig: URLSessionConfiguration?
    private var _session: URLSession?
    private var _sessionQueue: OperationQueue?
    private var _imageSource: CGImageSource?
    private var _firstAnimatedImage: UIImage?
    private let _MIN_PROGRESSIVE_TIME_INTERVAL: TimeInterval = 0.5

    // 重写start方法后，要保证这些key pathes支持KVO
    private var _executing: Bool = false
    override var isExecuting: Bool {
        get {
            var b: Bool = false
            lock {
                b = _executing
            }
            return b
        }
        set {
            lock {
                self.willChangeValue(forKey: "isExecuting")
                _executing = newValue
                self.didChangeValue(forKey: "isExecuting")
            }
        }
    }

    private var _finished: Bool = false
    override var isFinished: Bool {
        get {
            var b: Bool = false
            lock {
                b = _finished
            }
            return b
        }
        set {
            lock {
                self.willChangeValue(forKey: "isFinished")
                _finished = newValue
                self.didChangeValue(forKey: "isFinished")
            }
        }
    }

    private var _canceled: Bool = false
    override var isCancelled: Bool {
        get {
            var b: Bool = false
            lock {
                b = _canceled
            }
            return b
        }
        set {
            self.willChangeValue(forKey: "isCancelled")
            _canceled = newValue
            self.didChangeValue(forKey: "isCancelled")
        }
    }

    override var isAsynchronous: Bool {
        get {
            return true
        }
    }

    override var description: String {
        get {
            var string = String(format: "<%@: %p ", type(of: self) as! CVarArg, self)
            string = string.appendingFormat(" executing:%@", self.isExecuting ? "true" : "false")
            string = string.appendingFormat(" finished:%@", self.isFinished ? "true" : "false")
            string = string.appendingFormat(" cancelled:%@", self.isCancelled ? "true" : "false")
            string.append(">")
            return string
        }
    }
    
    @available(*, unavailable)
    override init() {
        fatalError("init error, request must not be nil, use custom init method instead.")
    }
    
    init(request: URLRequest,  options: [LQWebImageOptions], cache: LQImageCache?, cacheKey: String?, progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?) {
        self.options = options
        super.init()
        self.request = request
        self.cache = cache
        self.cacheKey = cacheKey
        self.progress = progress
        self.transform = transform
        self.completion = completion
        _sessionConfig = URLSessionConfiguration.default
        _sessionQueue = OperationQueue()
    }
    
    deinit {
        lock {
            if backgroundTaskIdentifier != nil && backgroundTaskIdentifier != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier!)
                backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
            }
            if self.isExecuting {
                self.isCancelled = true
                self.isFinished = true
                if _session != nil {
                    _session?.invalidateAndCancel()
                }
                if completion != nil {
                    autoreleasepool {
                        completion!(request?.url, nil, .cancelled, nil)
                    }
                }
            }
        }
    }
    
    //MARK: - URLSession Delegate
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        var disposition = URLSession.AuthChallengeDisposition.performDefaultHandling
        var credential: URLCredential?
        
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // 忽略验证，直接信任
            if !options.contains(.AllowInvalidSSLCertificate) {
                disposition = .cancelAuthenticationChallenge
            } else {
                disposition = .useCredential
                credential = URLCredential(trust: challenge.protectionSpace.serverTrust!)
                if self.credential == nil {
                    self.credential = credential
                } else {
                    credential = self.credential
                }
            }
        } else {
            disposition = .performDefaultHandling
        }
        
        completionHandler(disposition, credential)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) {
        // 如果重写了该方法，必须调用completionHandler
        if options.contains(.UseURLCache) {
            completionHandler(proposedResponse)
        } else {
            completionHandler(nil)
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        autoreleasepool {
            var error: SessionError?
            if response.isKind(of: HTTPURLResponse.self) {
                let statusCode = (response as! HTTPURLResponse).statusCode
                if statusCode >= 400 || statusCode == 304 {
                    error = SessionError(code: statusCode, localizedDescription: nil, domain: NSURLErrorDomain as NSErrorDomain, userInfo: nil)
                }
            }
            if error != nil {
                // 请求出现错误
                dataTask.cancel()
                urlSession(session, task: dataTask, didCompleteWithError: error)
            } else {
                if response.expectedContentLength >= 0 {
                    expectedSize = Int(response.expectedContentLength)
                } else {
                    expectedSize = -1
                }
                imageData = Data(capacity: expectedSize > 0 ? expectedSize : 0)
                if progress != nil {
                    if !self.isCancelled {
                        progress!(0, expectedSize)
                    }
                }
                // allow后才会继续从服务器下载数据
                completionHandler(.allow)
            }
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        autoreleasepool {
            if self.isCancelled || imageData == nil {
                return
            }
            if data.count > 0 {
                imageData!.append(data)
            }
            if imageData == nil {
                return
            }
            if progress != nil {
                lock {
                    if !self.isCancelled {
                        progress!(imageData!.count, expectedSize)
                    }
                }
            }
            
            let progressive = options.contains(LQWebImageOptions.Progressive)
            let ignorePreDecode = options.contains(LQWebImageOptions.IgnoreImagePreDecode)
            let now = CACurrentMediaTime()
            if now - lastProgressiveDecodeTimestamp < _MIN_PROGRESSIVE_TIME_INTERVAL {
                return
            }
            
            if decoder == nil {
                decoder = LQImageDecoder()
            }
            decoder!.updateImageData(data: imageData!, finalized: false)
            
            if progressive {
                let image = decoder!.imageAtIndex(0, shouldDecode: !ignorePreDecode)
                if image != nil {
                    lock {
                        if !self.isCancelled {
                            if completion != nil {
                                completion!(request!.url, image, .progress, nil)
                                lastProgressiveDecodeTimestamp = now
                            }
                        }
                    }
                }
                return
            } else {
                if decoder?.imageType == .GIF || decoder?.imageType == .PNG {
                    if _firstAnimatedImage == nil {
                        let image = decoder!.imageAtIndex(0, shouldDecode: !ignorePreDecode)
                        if image == nil {
                            return
                        }
                        _firstAnimatedImage = image
                        lock {
                            if !self.isCancelled {
                                if completion != nil {
                                    completion!(request!.url, _firstAnimatedImage, .progress, nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil {
            autoreleasepool {
                lock {
                    if !self.isCancelled {
                        LQWebImageOperation._imageProcessQueue.async { [weak self] in
                            if self == nil || self!.imageData == nil {
                                return
                            }
                            if self!.decoder == nil {
                                self!.decoder = LQImageDecoder()
                            }
                            
                            let shouldDecode = !self!.options.contains(LQWebImageOptions.IgnoreImagePreDecode)
                            let allowAnimation = !self!.options.contains(LQWebImageOptions.IgnoreAnimationImage)
                            var image: UIImage?
                            
                            self!.decoder!.updateImageData(data: self!.imageData!, finalized: true)
                            if allowAnimation {
                                image = UIImage.animatedImage(withData: self!.imageData!, scale: self!.decoder!.scale)
                                if shouldDecode {
                                    image = image?.imageByDecoded()
                                }
                            } else {
                                image = self!.decoder!.imageAtIndex(0, shouldDecode: shouldDecode)
                            }
                            
                            if self!.isCancelled {
                                return
                            }
                            
                            if image != nil && self!.transform != nil {
                                let newImage = self!.transform!(self!.request!.url!, image!)
                                image = newImage
                                if self!.isCancelled {
                                    return
                                }
                            }
                            
                            self!.perform(#selector(self!._didReceiveImageFromWeb), on: LQWebImageOperation._networkThread, with: image, waitUntilDone: false)
                        }
                    }
                }
            }
        } else {
            // error occurred
            autoreleasepool {
                lock {
                    if self.isCancelled {
                        if completion != nil {
                            completion!(request!.url, nil, .finished, error as NSError?)
                        }
                        task.cancel()
                        imageData = nil
                        self._finish()
                        
                        //TODO: - 处理blacklist url事件
                        
                    }
                }
            }
        }
        _session = nil
    }
    
    override func start() {
        autoreleasepool {
            lock {
                if self.isCancelled {
                    self.perform(#selector(_cancelOperation), on: LQWebImageOperation._networkThread, with: nil, waitUntilDone: false)
                    self.isFinished = true
                } else if self.isReady && !self.isExecuting && !self.isFinished {
                    if request == nil {
                        self.isFinished = true
                        if completion != nil {
                            completion!(nil, nil, .finished, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "request is nil."]))
                        }
                    } else {
                        self.isExecuting = true
                        self.perform(#selector(_startOperation), on: LQWebImageOperation._networkThread, with: nil, waitUntilDone: false)
                        if options.contains(.ContinueInBackground) {
                            if backgroundTaskIdentifier == UIBackgroundTaskIdentifier.invalid {
                                backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(expirationHandler: {
                                    self.cancel()
                                    self.isFinished = true
                                })
                            }
                        }
                    }
                }
            }
        }
    }
    
    override func cancel() {
        lock {
            if !self.isCancelled {
                super.cancel()
                self.isCancelled = true
                if self.isExecuting {
                    self.isExecuting = false
                    self.perform(#selector(_cancelOperation), on: LQWebImageOperation._networkThread, with: nil, waitUntilDone: false)
                    self.isFinished = true
                }
            }
        }
    }
    
    //MARK: - 私有方法
    private func _endBackgroundTask() {
        if backgroundTaskIdentifier == nil {
            return
        }
        lock {
            if backgroundTaskIdentifier! != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier!)
                backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
            }
        }
    }
    
    private func _finish() {
        lock {
            self.isExecuting = false
            self.isFinished = true
            _endBackgroundTask()
        }
    }
    
    @objc private func _startOperation() {
        if self.isCancelled {
            return
        }
        
        // 从cache中查找
        autoreleasepool {
            if cache != nil && cacheKey != nil && !options.contains(.UseURLCache) && !options.contains(.RefreshImageCache) {
                let image = cache!.getImage(forKey: cacheKey!, withType: [.Memory])
                if image != nil {
                    lock {
                        if !self.isCancelled {
                            if completion != nil {
                                completion!(request?.url, image!, .finished, nil)
                            }
                        }
                        _finish()
                    }
                    return
                }
                if !options.contains(.IgnoreDiskCache) {
                    LQWebImageOperation._imageProcessQueue.async { [weak self] in
                        if self == nil || self!.isCancelled {
                            return
                        }
                        let image = self!.cache!.getImage(forKey : self!.cacheKey!, withType: [.Disk])
                        if image != nil {
                            self!.cache?.setImage(image: image, imageData: nil, forKey: self!.cacheKey!, cacheType: [.Memory])
                            self!.perform(#selector(self!._didReceiveImageFromDiskCache), on: LQWebImageOperation._networkThread, with: image, waitUntilDone: false)
                        } else {
                            self!.perform(#selector(self!._startRequest), on: LQWebImageOperation._networkThread, with: nil, waitUntilDone: false)
                        }
                    }
                    return
                }
            }
            
            // cache中没有，发起网络请求
            self.perform(#selector(_startRequest), on: LQWebImageOperation._networkThread, with: nil, waitUntilDone: false)
        }
    }
    
    @objc private func _cancelOperation() {
        if _session != nil {
            _session!.invalidateAndCancel()
            _session = nil
            if completion != nil {
                completion!(nil, nil, .cancelled, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "user cancelled."]))
            }
            _endBackgroundTask()
        }
    }
    
    @objc private func _didReceiveImageFromDiskCache(image: UIImage?) {
        autoreleasepool {
            lock {
                if !self.isCancelled {
                    if cache != nil {
                        if image != nil {
                            if completion != nil {
                                completion!(request?.url, image, .finished, nil)
                            }
                            _finish()
                        } else {
                            _startRequest()
                        }
                    }
                }
            }
        }
    }
    
    @objc private func _didReceiveImageFromWeb(image: UIImage?) {
        autoreleasepool {
            lock {
                if !self.isCancelled {
                    //MARK: - 缓存image
                    if cache != nil {
                        if image != nil || options.contains(.RefreshImageCache) {
                            let data = imageData
                            LQWebImageOperation._imageProcessQueue.async { [weak self] in
                                if self == nil {
                                    return
                                }
                                let type = self!.options.contains(LQWebImageOptions.IgnoreDiskCache) ? [LQImageCacheType.Memory] : LQImageCacheType.All
                                self!.cache!.setImage(image: image, imageData: data, forKey: self!.cacheKey!, cacheType: type)
                            }
                        }
                    }
                    
                    imageData = nil
                    var error: NSError?
                    if image == nil {
                        error = NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "Web image decode fail."])
                        if options.contains(.IgnoreFailedURL) {
                            //TODO: - black url list 处理
                            
                        }
                    }
                    
                    if completion != nil {
                        completion!(request!.url, image, .finished, error)
                    }
                    self._finish()
                }
            }
        }
    }
    
    @objc private func _startRequest() {
        lock {
            if !self.isCancelled {
                _session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
                if _session == nil {
                    if completion != nil {
                        completion!(request!.url, nil, .finished, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "cannot create session."]))
                    }
                }
                let imageTask = _session!.dataTask(with: request!)
                imageTask.resume()
                _session?.finishTasksAndInvalidate()
            }
        }
        
    }
    
    //MARK: - 子线程和子队列（全局）相关方法
    @objc private static func _networkThreadEntryPoint(obj: Any) {
        let runLoop = RunLoop.current
        runLoop.add(NSMachPort(), forMode: .default)
        runLoop.run()
    }
}
