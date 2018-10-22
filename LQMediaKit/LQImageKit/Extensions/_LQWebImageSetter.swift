//
//  _LQWebImageSetter.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/10/10.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation

let _LQWebImageFadeAnimationKey = "com.lqmediakit.image.fadeanimation"

class _LQWebImageSetter: NSObject {
    private(set) var imageUrl: URL?
    var identifier: __int32_t = 0
    
    private let _sem_lock: DispatchSemaphore = DispatchSemaphore(value: 1)
    private var _operation: Operation?
    private var _unfair_lock = os_unfair_lock()
    
    static let setterQueue = { () -> DispatchQueue in
        let queue = DispatchQueue(label: "com.lqmediakit.image.setterqueue")
        return queue
    }()
    
    override init() {
        super.init()
        
    }
    
    deinit {
        if #available(iOS 10.0, *) {
            os_unfair_lock_lock(&_unfair_lock)
            identifier = identifier.advanced(by: 1)
            os_unfair_lock_unlock(&_unfair_lock)
        } else {
            OSAtomicIncrement32(&identifier)
        }
        _operation?.cancel()
    }
    
    func setOperation(withIdentifier identifier: __int32_t,
                      url imageUrl: URL,
                      options:[LQWebImageOptions],
                      manager: LQWebImageManager,
                      progress: LQWebImageProgress?,
                      transform: LQWebImageTransform?,
                      completion: LQWebImageCompletion?) -> __int32_t {
        if identifier != self.identifier {
            if completion != nil {
                completion!(imageUrl, nil, .cancelled, nil)
            }
            return self.identifier
        }
        
        let operation = manager.requestImage(withUrl: imageUrl, options: options, progress: progress, transform: transform, completion: completion)
        
        if operation == nil && completion != nil {
            completion!(imageUrl, nil, .finished, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "failed to create operation."]))
        }
        
        _lock {
            if identifier == self.identifier {
                if _operation != nil {
                    _operation!.cancel()
                }
                _operation = operation
            } else {
                operation?.cancel()
            }
        }
        return identifier
    }
    
    func cancel() -> __int32_t {
        return cancelWithNewImageUrl(imageUrl: nil)
    }
    
    func cancelWithNewImageUrl(imageUrl: URL?) -> __int32_t {
        var _identifier: __int32_t = 0;
        _lock {
            if _operation != nil {
                _operation?.cancel()
                _operation = nil
            }
            self.imageUrl = imageUrl
            if #available(iOS 10.0, *) {
                os_unfair_lock_lock(&_unfair_lock)
                identifier = identifier.advanced(by: 1)
                _identifier = identifier
                os_unfair_lock_unlock(&_unfair_lock)
            } else {
                _identifier = OSAtomicIncrement32(&identifier)
            }
        }
        return _identifier
    }
    
    private func _lock(block: () -> Void) {
        _sem_lock.wait()
        block()
        _sem_lock.signal()
    }
}
