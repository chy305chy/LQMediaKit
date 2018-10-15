//
//  UIImage+Animated.swift
//  LQMediaKitDemo
//
//  Created by cuilanqing on 2018/10/11.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit

/// UIImage动图扩展
extension UIImage {
    
    convenience init?(imageData: Data, scale: CGFloat) {
        if imageData.count == 0 {
            fatalError("image data is empty.")
        }
        let decoder = LQImageDecoder(withData: imageData, scale: scale <= 0 ? UIScreen.main.scale : scale)
        let image = decoder.imageAtIndex(0, shouldDecode: true)
        if image == nil {
            fatalError("cannot create image.")
        }
        self.init(cgImage: image!.cgImage!, scale: scale, orientation: image!.imageOrientation)
        
//        if decoder.framesCount > 1 {
//
//        } else {
//
//        }
        
        self.isDecoded = true
    }
    
    class func animatedImage(withData data: Data, scale: CGFloat) -> UIImage? {
        if data.count == 0 {
            return nil
        }
        
        var animatedImage: UIImage?
        let _scale = scale <= 0 ? UIScreen.main.scale : scale
        let decoder = LQImageDecoder(withData: data, scale: _scale)
        if decoder.framesCount > 1 {
            var animatedImages = [UIImage]()
            let frameCount = decoder.framesCount
            var duration: TimeInterval = 0
            for i in 0 ..< frameCount {
                duration = duration + decoder.imageDurationAtIndex(i)
                let imageFrame = decoder.imageAtIndex(i, shouldDecode: true)
                if imageFrame != nil {
                    animatedImages.append(imageFrame!)
                }
            }
            if duration == 0 {
                /// 设置一个默认的duration值
                duration = 0.1 * Double(decoder.framesCount)
            }
            animatedImage = UIImage.animatedImage(with: animatedImages, duration: duration)
        } else {
            animatedImage = UIImage(data: data, scale: _scale)
        }
        return animatedImage
    }
}
