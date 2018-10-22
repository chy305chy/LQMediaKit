//
//  LQMemoryCache.swift
//  LQCacheKit
//
//  Created by cuilanqing on 2018/9/13.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation

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

fileprivate func tryLock(lockSuccess: () -> Void, lockFail: () -> Void) {
    if pthread_mutex_trylock(recursive_lock) == 0 {
        lockSuccess()
        pthread_mutex_unlock(recursive_lock)
    } else {
        lockFail()
    }
}

private class _LQQueueNode: NSObject {
    weak var _prev: _LQQueueNode?
    weak var _next: _LQQueueNode?
    var _key: String = ""
    var _value: AnyObject?
    // 进入缓存的时间
    var _cachedTime: TimeInterval = 0.0
    // 生存时间
    var _lifeTime: TimeInterval = 0.0
}

/// LRU队列（双向链表，从尾部进入，头部移出，最新的条目始终在队列的尾部）
private class _LQLRUQueue: NSObject {
    fileprivate var _totalItemCount = 0
    fileprivate var _itemCountLimit = Int.max
    fileprivate var _dict: [String: _LQQueueNode] = [String: _LQQueueNode]()
    fileprivate var _releaseOnMainThread: Bool = false
    fileprivate var _releaseAsynchronously: Bool = false
    fileprivate weak var _head: _LQQueueNode?
    fileprivate weak var _tail: _LQQueueNode?
    
    // 最新的缓存进入队列尾部
    public func insertNodeAtTail(withNode: _LQQueueNode?) {
        if withNode == nil {
            return
        }
        
        if _totalItemCount >= _itemCountLimit {
            // 队列已满，先移出头部的s元素
            let headNode = removeHeadNode()
            if headNode != nil {
                if _releaseAsynchronously {
                    let queue: DispatchQueue = _releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
                    queue.async {
                        _ = headNode?.classForCoder
                    }
                } else if (_releaseOnMainThread && pthread_main_np() == 0) {
                    DispatchQueue.main.async {
                        _ = headNode?.classForCoder
                    }
                }
            }
        }
        
        _dict[withNode!._key] = withNode
        _totalItemCount = _totalItemCount.advanced(by: 1)
        
        if (_tail != nil) {
            _tail!._next = withNode
            withNode!._prev = _tail
            _tail = withNode
        } else {
            _tail = withNode
            _head = withNode
        }
    }
    
    public func bringNodeToTail(withNode: _LQQueueNode?) {
        if withNode == nil {
            return
        }
        if _tail == nil || _head == nil {
            // 队列此时为空
            insertNodeAtTail(withNode: withNode)
            return
        }
        if _tail!.isEqual(withNode) {
            return
        }
        if _head!.isEqual(withNode) {
            _head = withNode!._next
            _head!._prev = nil
        } else {
            withNode!._next?._prev = withNode!._prev
            withNode!._prev?._next = withNode!._next
        }
        _tail!._next = withNode
        withNode!._prev = _tail
        _tail = withNode
        withNode!._next = nil
    }
    
    public func removeNode(node: _LQQueueNode?) -> _LQQueueNode? {
        if node == nil || _head == nil || _tail == nil {
            return nil
        }
        _dict.removeValue(forKey: node!._key)
        _totalItemCount = _totalItemCount.advanced(by: -1)
        if node!._next != nil {
            node!._next!._prev = node!._prev
        }
        if node!._prev != nil {
            node!._prev!._next = node!._next
        }
        if _tail!.isEqual(node) {
            _tail = node!._prev
        }
        if _head!.isEqual(node) {
            _head = node!._next
        }
        return node
    }
    
    public func removeHeadNode() -> _LQQueueNode? {
        if _head == nil {
            return nil
        }
        
        let head = _head
        _dict.removeValue(forKey: _head!._key)
        _totalItemCount = _totalItemCount.advanced(by: -1)
        if _tail == _head {
            _tail = nil
            _head = nil
        } else {
            _head = _head!._next
            _head!._prev = nil
        }
        return head
    }
    
    public func removeAllNodes() {
        _totalItemCount = 0
        _tail = nil
        _head = nil
        
        if _dict.count > 0 {
            if _releaseAsynchronously {
                DispatchQueue.global(qos: .default).async {
                    self._dict.removeAll()
                }
            } else if _releaseOnMainThread && pthread_main_np() == 0 {
                DispatchQueue.main.async {
                    self._dict.removeAll()
                }
            }
        }
    }
}

class LQMemoryCache : NSObject {
    var name: String = ""
    var _autoTrimTimeInterval = 30
    private let _lruQueue = _LQLRUQueue()
    private lazy var _timer = Timer(timeInterval: TimeInterval(exactly: _autoTrimTimeInterval)!, target: self, selector: #selector(_timerHandler), userInfo: nil, repeats: true)
    private var _trimPort: NSMachPort?
    private var _trimRunLoop: RunLoop?
    private lazy var _trimThread = Thread(target: self, selector: #selector(_trimThreadEntryPoint), object: nil)
    
    var releaseOnMainThread: Bool {
        get {
            var b = false
            lock {
                b = _lruQueue._releaseOnMainThread
            }
            return b
        }
        set {
            lock {
                _lruQueue._releaseOnMainThread = newValue
            }
        }
    }
    
    var releaseAsynchronously: Bool {
        get {
            var b = false
            lock {
                b = _lruQueue._releaseAsynchronously
            }
            return b
        }
        set {
            lock {
                _lruQueue._releaseAsynchronously = newValue
            }
        }
    }
    
    var shouldClearCacheOnMemoryWarning = true
    var shouldClearCacheWhenEnterBackground = false
    var countLimit: Int = Int.max {
        didSet {
            _lruQueue._itemCountLimit = countLimit
        }
    }
    var totalCount: Int {
        get {
            var b = 0
            lock {
                b = _lruQueue._totalItemCount
            }
            return b
        }
    }
    
    private func _startTrimThread(withName: String) {
        _trimThread.name = withName
        if !_trimThread.isExecuting {
            _trimThread.qualityOfService = .background
            _trimThread.start()
        }
    }
    
    @objc private func _timerHandler() {
        self._removeExpirationItems()
    }
    
    @objc private func _trimThreadEntryPoint(obj: AnyObject?) {
        let runLoop = RunLoop.current
        let port = NSMachPort()
        runLoop.add(port, forMode: .default)
        runLoop.add(_timer, forMode: .default)
        runLoop.run()
        _timer.fire()
        _trimRunLoop = runLoop
        _trimPort = port
    }
    
    /// 移出过期项目
    private func _removeExpirationItems() {
        var finished = false
        var ptrNode = _lruQueue._head
        var holder = Array<_LQQueueNode>()
        // mach_absolute_time()受系统时钟影响，设备重启后被重置，可以用在内存缓存中
        let now = Double(mach_absolute_time() / NSEC_PER_SEC)
        
        if ptrNode == nil {
            finished = true
        }
        
        while !finished {
            tryLock(lockSuccess: {
                if (ptrNode != nil && now.advanced(by: -ptrNode!._cachedTime) > ptrNode!._lifeTime) {
                    // node超出其存活时间，删除
                    let removedNode = _lruQueue.removeNode(node: ptrNode)
                    if removedNode != nil {
                        holder.append(removedNode!)
                    }
                    ptrNode = ptrNode?._next
                } else if ptrNode != nil {
                    // node未超出其存活时间，寻找下一个
                    ptrNode = ptrNode?._next
                } else {
                    finished = true
                }
            }, lockFail: {
                usleep(10 * 1000)
            })
        }
        if holder.count > 0 {
            let queue = self.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
            queue.async {
                _ = holder.count
            }
        }
    }
    
    private func _trimToCount(count: Int) {
        DispatchQueue.global(qos: .default).async {
            while(self._lruQueue._totalItemCount > count) {
                var node: _LQQueueNode?
                tryLock(lockSuccess: {
                    node = self._lruQueue.removeHeadNode()
                }, lockFail: {
                    usleep(10*1000)
                })
                if node != nil {
                    let queue = self.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
                    queue.async {
                        _ = node?.classForCoder
                    }
                }
            }
        }
    }
    
    @objc private func _memoryWarningHandler() {
        if shouldClearCacheOnMemoryWarning {
            self.clearCache()
        } else {
            self._trimToCount(count: Int(Double(self.totalCount)*0.625))
        }
    }
    
    @objc private func _enterBackgroundHandler() {
        if shouldClearCacheWhenEnterBackground {
            self.clearCache()
        }
    }
    
    public func containsObject(key: String) -> Bool {
        if key.count == 0 {
            return false
        }
        var contains = false
        lock {
            contains = _lruQueue._dict.contains(where: { (dictKey: String, _: AnyObject) -> Bool in
                dictKey == key
            })
        }
        return contains
    }
    
    public func getObject(key: String) -> AnyObject? {
        if key.count == 0 {
            return nil
        }
        var object: AnyObject?
        lock {
            if _lruQueue._dict.contains(where: { (dictKey: String, _: AnyObject) -> Bool in
                dictKey == key
            }) {
                let node = _lruQueue._dict[key]
                _lruQueue.bringNodeToTail(withNode: node)
                object = node!._value
            } else {
                object = nil
            }
        }
        return object;
    }

    public func setObject(forKey key: String, object: AnyObject?) {
        self.setObject(forKey: key, object: object, lifeTime: TimeInterval(Int.max))
    }

    public func setObject(forKey key: String, object: AnyObject?, lifeTime: TimeInterval) {
        if object == nil {
            self.removeObject(forKey: key)
            return
        }
        
        lock {
            if _lruQueue._dict.contains(where: { (dictKey: String, _: AnyObject) -> Bool in
                dictKey == key
            }) {
                let node = _lruQueue._dict[key]
                _lruQueue.bringNodeToTail(withNode: node)
            } else {
                let node = _LQQueueNode()
                node._key = key
                node._value = object
                node._lifeTime = lifeTime
                node._cachedTime = Double(mach_absolute_time() / NSEC_PER_SEC)
                _lruQueue.insertNodeAtTail(withNode: node)
            }
        }
    }

    public func removeObject(forKey key: String) {
        if _lruQueue._dict.contains(where: { (dictKey: String, _: AnyObject) -> Bool in
            dictKey == key
        }) {
            lock {
                let node = _lruQueue._dict[key]
                _ = _lruQueue.removeNode(node: node)
                if self.releaseAsynchronously {
                    let queue = self.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
                    queue.async {
                        _ = node?.classForCoder
                    }
                } else if (self.releaseOnMainThread && pthread_main_np() == 0) {
                    DispatchQueue.main.async {
                        _ = node?.classForCoder
                    }
                }
            }
        }
        return
    }

    public func clearCache() {
        lock {
            _lruQueue.removeAllNodes()
        }
    }

    override init() {
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(_memoryWarningHandler), name: Notification.Name("didReceiveMemoryWarningNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_enterBackgroundHandler), name: Notification.Name("didEnterBackgroundNotification"), object: nil)
        _startTrimThread(withName: "com.lqcache.memory.autotrimthread")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: Notification.Name("didReceiveMemoryWarningNotification"), object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name("didEnterBackgroundNotification"), object: nil)
        _timer.invalidate()
        pthread_mutex_destroy(recursive_lock)
        if _trimRunLoop != nil {
            _trimRunLoop!.remove(_trimPort!, forMode: .default)
            _trimRunLoop!.cancelPerformSelectors(withTarget: self)
        }
        _trimThread.cancel()
    }
}
