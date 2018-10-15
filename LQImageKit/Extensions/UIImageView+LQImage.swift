//
//  UIImageView+LQImageView.swift
//  LQMediaKitDemo
//
//  Created by cuilanqing on 2018/10/10.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

extension UIImageView {
    
    struct RuntimeKey {
        static var image_setter_key = "com.lqmediakit.image.imagesetter"
    }
    
    var imageUrl: URL? {
        get {
            let setter = objc_getAssociatedObject(self, &RuntimeKey.image_setter_key) as! _LQWebImageSetter?
            if setter != nil {
                return setter!.imageUrl
            }
            return nil
        }
    }
    
    func setImage(withUrl url: URL?) {
        setImage(withUrl: url, placeholder: nil, options: [.AllowInvalidSSLCertificate, .Progressive], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, placeholder: UIImage?) {
        setImage(withUrl: url, placeholder: placeholder, options: [.AllowInvalidSSLCertificate, .Progressive], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, options: [LQWebImageOptions]) {
        setImage(withUrl: url, placeholder: nil, options: options, manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, placeholder: UIImage?, options: [LQWebImageOptions], completion: LQWebImageCompletion?) {
        setImage(withUrl: url, placeholder: placeholder, options: options, manager: nil, progress: nil, transform: nil, completion: completion)
    }
    
    func setImage(withUrl url: URL?, placeholder: UIImage?, options: [LQWebImageOptions], progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?) {
        setImage(withUrl: url, placeholder: placeholder, options: options, manager: nil, progress: progress, transform: transform, completion: completion)
    }
    
    func setImage(withUrl url: URL?, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?, progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?) {
        let _manager = manager ?? LQWebImageManager.sharedManager
        var setter = objc_getAssociatedObject(self, &RuntimeKey.image_setter_key) as! _LQWebImageSetter?
        if setter == nil {
            setter = _LQWebImageSetter()
            objc_setAssociatedObject(self, &RuntimeKey.image_setter_key, setter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if setter == nil {
            return
        }
        
        let identifier = setter!.cancelWithNewImageUrl(imageUrl: url)
        
        DispatchQueue.main.async {
            if url == nil {
                if placeholder != nil {
                    self.setImage(image: placeholder!)
                }
                return
            }
            
            var imageFromMemory: UIImage?
            if _manager.imageCache != nil && !options.contains(.UseURLCache) && !options.contains(.RefreshImageCache) {
                imageFromMemory = _manager.imageCache!.getImage(forKey: _manager.cacheKeyForUrl(url: url!), withType: [.Memory])
            }
            if imageFromMemory != nil {
                self.setImage(image: imageFromMemory!)
                if completion != nil {
                    completion!(url, imageFromMemory, .finished, nil)
                }
                return
            }
            
            // 设置placeholder
            self.image = placeholder
            
            _LQWebImageSetter.setterQueue.async { [weak self] in
                if self == nil {
                    return
                }
                var newIdentifier: __int32_t = 0
                weak var weakSetter: _LQWebImageSetter?
                let newCompletion: LQWebImageCompletion = { (url, image, loadStatus, error) -> Void in
                    let readyToSetImage = (loadStatus == .finished || loadStatus == .progress) && image != nil
                    DispatchQueue.main.async {
                        let identifierChanged = weakSetter != nil && weakSetter!.identifier != newIdentifier
                        if readyToSetImage && !identifierChanged {
                            self!.setImage(image: image!)
                        }
                        if completion != nil {
                            if newIdentifier != setter!.identifier {
                                completion!(url, nil, .cancelled, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "cancelled."]))
                            } else {
                                completion!(url, image, loadStatus, error)
                            }
                        }
                    }
                }

                newIdentifier = setter!.setOperation(withIdentifier: identifier, url: url!, options: options, manager: _manager, progress: progress, transform: transform, completion: newCompletion)
                weakSetter = setter
            }
        }
    }
    
    func cancelCurrentImageRequest() {
        let setter = objc_getAssociatedObject(self, &RuntimeKey.image_setter_key) as! _LQWebImageSetter?
        if setter != nil {
            _ = setter!.cancel()
        }
    }
    
}

//MARK: - Animated Image View
extension UIImageView {
    
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        _didMoved()
    }
    
    open override func didMoveToSuperview() {
        super.didMoveToSuperview()
        _didMoved()
    }
    
    func setImage(image: UIImage) {
        if image != self.image {
            self.image = image
            _imageDidChanged()
        }
    }
    
    private func _didMoved() {
        if self.animationImages != nil && self.animationImages!.count > 1 {
            if self.superview != nil && self.window != nil {
                self.startAnimating()
            } else {
                self.stopAnimating()
            }
        }
    }
    
    private func _imageDidChanged() {
        if self.image == nil {
            return
        }
        
        if self.image!.images == nil {
            self.setNeedsDisplay()
        } else {
            if self.image!.images!.count > 1 {
                self.animationImages = self.image!.images
                self.animationRepeatCount = Int.max
                self.animationDuration = self.image!.duration
                self.startAnimating()
            } else {
                self.setNeedsDisplay()
            }
        }
    }
}
