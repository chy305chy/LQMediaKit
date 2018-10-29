//
//  CALayer+LQWebImage.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/10/29.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

extension CALayer {
    
    struct RuntimeKey {
        static var layer_image_setter_key = "com.lqmediakit.image.imagesetter.layer"
    }
    
    var imageUrl: URL? {
        get {
            let setter = objc_getAssociatedObject(self, &RuntimeKey.layer_image_setter_key) as! _LQWebImageSetter?
            if setter != nil {
                return setter!.imageUrl
            }
            return nil
        }
    }
    
    func setImage(withUrl url: URL?) {
        setImage(withUrl: url, placeholder: nil, options: [.AllowInvalidSSLCertificate, .ShowNetworkActivity, .ShowFadeAnimationWhenSetImage], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, placeholder: UIImage?) {
        setImage(withUrl: url, placeholder: placeholder, options: [.AllowInvalidSSLCertificate, .ShowNetworkActivity, .ShowFadeAnimationWhenSetImage], manager: nil, progress: nil, transform: nil, completion: nil)
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
        var setter = objc_getAssociatedObject(self, &RuntimeKey.layer_image_setter_key) as! _LQWebImageSetter?
        if setter == nil {
            setter = _LQWebImageSetter()
            objc_setAssociatedObject(self, &RuntimeKey.layer_image_setter_key, setter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if setter == nil {
            return
        }
        
        let identifier = setter!.cancelWithNewImageUrl(imageUrl: url)
        
        DispatchQueue.main.async {
            if options.contains(.ShowFadeAnimationWhenSetImage) {
                self.removeAnimation(forKey: _LQWebImageFadeAnimationKey)
            }
            
            if url == nil {
                self.contents = placeholder?.cgImage
                return
            }
            
            var imageFromMemory: UIImage?
            if _manager.imageCache != nil && !options.contains(.UseURLCache) && !options.contains(.RefreshImageCache) {
                imageFromMemory = _manager.imageCache!.getImage(forKey: _manager.cacheKeyForUrl(url: url!), withType: [.Memory])
            }
            if imageFromMemory != nil {
                self.contents = imageFromMemory!.cgImage
                if completion != nil {
                    completion!(url, imageFromMemory, .finished, nil)
                }
                return
            }
            
            // 设置placeholder
            self.contents = placeholder?.cgImage
            
            _LQWebImageSetter.setterQueue.async { [weak self] in
                guard self != nil else { return }
                
                var newIdentifier: __int32_t = 0
                weak var weakSetter: _LQWebImageSetter?
                let newCompletion: LQWebImageCompletion = { (url, image, loadStatus, error) -> Void in
                    let readyToSetImage = (loadStatus == .finished || loadStatus == .progress) && image != nil
                    DispatchQueue.main.async {
                        let identifierChanged = weakSetter != nil && weakSetter!.identifier != newIdentifier
                        if readyToSetImage && !identifierChanged {
                            if options.contains(.ShowFadeAnimationWhenSetImage) {
                                let animation = CATransition()
                                animation.duration = 0.2
                                animation.type = .fade
                                animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                                self!.add(animation, forKey: _LQWebImageFadeAnimationKey)
                            }
                            self!.contents = image?.cgImage
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
        let setter = objc_getAssociatedObject(self, &RuntimeKey.layer_image_setter_key) as! _LQWebImageSetter?
        if setter != nil {
            _ = setter!.cancel()
        }
    }
}
