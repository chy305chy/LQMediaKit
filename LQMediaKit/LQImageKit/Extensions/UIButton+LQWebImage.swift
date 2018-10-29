//
//  UIButton+LQWebImage.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/10/19.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

extension UIButton {
    
    struct RuntimeKey {
        static var button_image_setter_key = "com.lqmediakit.image.imagesetter.button"
        static var button_background_image_setter_key = "com.lqmediakit.image.imagesetter.buttonbackground"
    }
    
    private func _extractStates(fromState state: UIControl.State) -> [UIControl.State] {
        var states = [UIControl.State]()
        
        if state.contains(.highlighted) {
            states.append(.highlighted)
        }
        if state.contains(.disabled) {
            states.append(.disabled)
        }
        if state.contains(.selected) {
            states.append(.selected)
        }
        if state.rawValue & 0xff == 0 {
            states.append(.normal)
        }
        
        return states
    }
    
    //MARK: - Noramal Image
    func imageUrl(forState state: UIControl.State) -> URL? {
        let setter = (objc_getAssociatedObject(self, &RuntimeKey.button_image_setter_key) as! _LQWebImageSetterContainerForUIButton?)?.setterForState(state: state)
        if setter != nil {
            return setter!.imageUrl
        }
        return nil
    }
    
    func setImage(withUrl url: URL?) {
        setImage(withUrl: url, forState: .normal, placeholder: nil, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, state: UIControl.State) {
        setImage(withUrl: url, forState: state, placeholder: nil, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, state: UIControl.State, options: [LQWebImageOptions]) {
        setImage(withUrl: url, forState: state, placeholder: nil, options: options, manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, state: UIControl.State, placeholder: UIImage?) {
        setImage(withUrl: url, forState: state, placeholder: placeholder, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions]) {
        setImage(withUrl: url, forState: state, placeholder: placeholder, options: options, manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?) {
        setImage(withUrl: url, forState: state, placeholder: placeholder, options: options, manager: manager, progress: nil, transform: nil, completion: nil)
    }
    
    func setImage(withUrl url: URL?, forState state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?, progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?) {
        for s in _extractStates(fromState: state) {
            _setImage(withUrl: url, forState: s, placeholder: placeholder, options: options, manager: manager, progress: progress, transform: transform, completion: completion)
        }
    }
    
    private func _setImage(withUrl url: URL?, forState state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?, progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?)  {
        let _manager = manager ?? LQWebImageManager.sharedManager
        
        var setterContainer = objc_getAssociatedObject(self, &RuntimeKey.button_image_setter_key) as! _LQWebImageSetterContainerForUIButton?
        if setterContainer == nil {
            setterContainer = _LQWebImageSetterContainerForUIButton()
            objc_setAssociatedObject(self, &RuntimeKey.button_image_setter_key, setterContainer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        let setter = setterContainer!.setterForState(state: state)
        
        let identifier = setter.cancelWithNewImageUrl(imageUrl: url)
        
        DispatchQueue.main.async {
            if url == nil {
                self.setImage(placeholder, for: state)
                return
            }
            
            var imageFromMemory: UIImage?
            if _manager.imageCache != nil && !options.contains(.UseURLCache) && !options.contains(.RefreshImageCache) {
                imageFromMemory = _manager.imageCache!.getImage(forKey: _manager.cacheKeyForUrl(url: url!), withType: [.Memory])
            }
            if imageFromMemory != nil {
                self.setImage(imageFromMemory, for: state)
                if completion != nil {
                    completion!(url, imageFromMemory, .finished, nil)
                }
                return
            }
            
            self.setImage(placeholder, for: state)
            
            _LQWebImageSetter.setterQueue.async { [weak self] in
                guard self != nil else { return }
                
                var newIdentifier: __int32_t = 0
                weak var weakSetter: _LQWebImageSetter?
                let newCompletion: LQWebImageCompletion = { (url, image, loadStatus, error) -> Void in
                    let readyToSetImage = (loadStatus == .finished || loadStatus == .progress) && image != nil
                    DispatchQueue.main.async {
                        let identifierChanged = weakSetter != nil && weakSetter!.identifier != newIdentifier
                        if readyToSetImage && !identifierChanged {
                            self!.setImage(image, for: state)
                        }
                        if completion != nil {
                            if newIdentifier != setter.identifier {
                                completion!(url, nil, .cancelled, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "cancelled."]))
                            } else {
                                completion!(url, image, loadStatus, error)
                            }
                        }
                    }
                }
                
                newIdentifier = setter.setOperation(withIdentifier: identifier, url: url!, options: options, manager: _manager, progress: progress, transform: transform, completion: newCompletion)
                weakSetter = setter
            }
        }
    }
    
    func cancelCurrentImageRequest(forState state: UIControl.State) {
        for s in _extractStates(fromState: state) {
            _cancelCurrentImageRequest(forState: s)
        }
    }
    
    private func _cancelCurrentImageRequest(forState state: UIControl.State) {
        let setter = (objc_getAssociatedObject(self, &RuntimeKey.button_image_setter_key) as! _LQWebImageSetterContainerForUIButton?)?.setterForState(state: state)
        if setter != nil {
            _ = setter!.cancel()
        }
    }
    
    //MARK: - Background Image
    func backgroundImageUrl(forState state: UIControl.State) -> URL? {
        let setter = (objc_getAssociatedObject(self, &RuntimeKey.button_background_image_setter_key) as! _LQWebImageSetterContainerForUIButton?)?.setterForState(state: state)
        if setter != nil {
            return setter!.imageUrl
        }
        return nil
    }
    
    func setBackgroundImage(withUrl url: URL?) {
        setImage(withUrl: url, forState: .normal, placeholder: nil, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setBackgroundImage(withUrl url: URL?, state: UIControl.State) {
        setImage(withUrl: url, forState: state, placeholder: nil, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setBackgroundImage(withUrl url: URL?, state: UIControl.State, options: [LQWebImageOptions]) {
        setImage(withUrl: url, forState: state, placeholder: nil, options: options, manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setBackgroundImage(withUrl url: URL?, state: UIControl.State, placeholder: UIImage?) {
        setImage(withUrl: url, forState: state, placeholder: placeholder, options: [.AllowInvalidSSLCertificate], manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setBackgroundImage(withUrl url: URL?, state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions]) {
        setImage(withUrl: url, forState: state, placeholder: placeholder, options: options, manager: nil, progress: nil, transform: nil, completion: nil)
    }
    
    func setBackgroundImage(withUrl url: URL?, state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?) {
        setImage(withUrl: url, forState: state, placeholder: placeholder, options: options, manager: manager, progress: nil, transform: nil, completion: nil)
    }
    
    func setBackgroundImage(withUrl url: URL?, forState state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?, progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?) {
        for s in _extractStates(fromState: state) {
            _setBackgroundImage(withUrl: url, forState: s, placeholder: placeholder, options: options, manager: manager, progress: progress, transform: transform, completion: completion)
        }
    }
    
    private func _setBackgroundImage(withUrl url: URL?, forState state: UIControl.State, placeholder: UIImage?, options: [LQWebImageOptions], manager: LQWebImageManager?, progress: LQWebImageProgress?, transform: LQWebImageTransform?, completion: LQWebImageCompletion?)  {
        let _manager = manager ?? LQWebImageManager.sharedManager
        
        var setterContainer = objc_getAssociatedObject(self, &RuntimeKey.button_background_image_setter_key) as! _LQWebImageSetterContainerForUIButton?
        if setterContainer == nil {
            setterContainer = _LQWebImageSetterContainerForUIButton()
            objc_setAssociatedObject(self, &RuntimeKey.button_background_image_setter_key, setterContainer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        let setter = setterContainer!.setterForState(state: state)
        
        let identifier = setter.cancelWithNewImageUrl(imageUrl: url)
        
        DispatchQueue.main.async {
            if url == nil {
                self.setBackgroundImage(placeholder, for: state)
                return
            }
            
            var imageFromMemory: UIImage?
            if _manager.imageCache != nil && !options.contains(.UseURLCache) && !options.contains(.RefreshImageCache) {
                imageFromMemory = _manager.imageCache!.getImage(forKey: _manager.cacheKeyForUrl(url: url!), withType: [.Memory])
            }
            if imageFromMemory != nil {
                self.setBackgroundImage(imageFromMemory, for: state)
                if completion != nil {
                    completion!(url, imageFromMemory, .finished, nil)
                }
                return
            }
            
            self.setBackgroundImage(placeholder, for: state)
            
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
                            self!.setBackgroundImage(image, for: state)
                        }
                        if completion != nil {
                            if newIdentifier != setter.identifier {
                                completion!(url, nil, .cancelled, NSError(domain: "com.lqmediakit.image", code: -1, userInfo: [NSLocalizedDescriptionKey: "cancelled."]))
                            } else {
                                completion!(url, image, loadStatus, error)
                            }
                        }
                    }
                }
                
                newIdentifier = setter.setOperation(withIdentifier: identifier, url: url!, options: options, manager: _manager, progress: progress, transform: transform, completion: newCompletion)
                weakSetter = setter
            }
        }
    }
    
    func cancelCurrentBackgroundImageRequest(forState state: UIControl.State) {
        for s in _extractStates(fromState: state) {
            _cancelCurrentBackgroundImageRequest(forState: s)
        }
    }
    
    private func _cancelCurrentBackgroundImageRequest(forState state: UIControl.State) {
        let setter = (objc_getAssociatedObject(self, &RuntimeKey.button_background_image_setter_key) as! _LQWebImageSetterContainerForUIButton?)?.setterForState(state: state)
        if setter != nil {
            _ = setter!.cancel()
        }
    }
    
}

private class _LQWebImageSetterContainerForUIButton: NSObject {
    
    private var _dict = Dictionary<NSNumber, _LQWebImageSetter>()
    private let _lock = DispatchSemaphore(value: 1)
    
    public func setterForState(state: UIControl.State) -> _LQWebImageSetter {
        _lock.wait()
        var setter = _dict[NSNumber(value: state.rawValue)]
        if setter == nil {
            setter = _LQWebImageSetter()
            _dict[NSNumber(value: state.rawValue)] = setter
        }
        _lock.signal()
        return setter!
    }
    
}
