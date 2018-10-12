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
    
    private var _imageSetter: _LQWebImageSetter? {
        get {
            return objc_getAssociatedObject(self, &RuntimeKey.image_setter_key) as! _LQWebImageSetter?
        }
        set {
            objc_setAssociatedObject(self, &RuntimeKey.image_setter_key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
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
        setImage(withUrl: url, placeholder: placeholder, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
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
        
        if _imageSetter == nil {
            _imageSetter = _LQWebImageSetter()
        }
        if _imageSetter == nil {
            return
        }
        
        let identifier = _imageSetter!.cancelWithNewImageUrl(imageUrl: url)
        
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
                    completion!(url, imageFromMemory, nil)
                }
                return
            }
            
            // 设置placeholder
            if placeholder != nil {
                self.setImage(image: placeholder!)
            }
            
            _LQWebImageSetter.setterQueue.async { [weak self] in
                if self == nil {
                    return
                }
                var newIdentifier: __int32_t = 0
                let newCompletion: LQWebImageCompletion = { (url, image, error) -> Void in
                    DispatchQueue.main.async {
                        if image != nil {
                            self!.setImage(image: image!)
                        }
                        if completion != nil {
                            if newIdentifier != self!._imageSetter!.identifier {
                                completion!(url, nil, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "cancelled."]))
                            } else {
                                completion!(url, image, error)
                            }
                        }
                    }
                }

                newIdentifier = self!._imageSetter!.setOperation(withIdentifier: identifier, url: url!, options: options, manager: _manager, progress: progress, transform: transform, completion: newCompletion)
            }
        }
    }
    
    func cancelCurrentImageRequest() {
        if _imageSetter != nil {
            _ = _imageSetter!.cancel()
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
