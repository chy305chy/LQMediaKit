//
//  LQImageCoder.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/9/27.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit
import MobileCoreServices

enum LQImageType {
    case Unknown
    case JPEG
    case JPEG2000
    case PNG
    case APNG
    case GIF
    case BMP
    case TIFF
    case ICO
    case ICNS
    case WebP
    case Other
}

class LQImageDecoder: NSObject {
    private(set) var imageType: LQImageType
    private(set) var scale: CGFloat = 0
    private(set) var framesCount: Int = 0
    private(set) var loopCount: Int = 0
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    var imageData: Data? {
        get {
            return _imageData
        }
    }
    
    private var frames: [_LQImageFrame]?
    private var _sem_lock: DispatchSemaphore
    private var _recursive_lock: UnsafeMutablePointer<pthread_mutex_t>
    private var _imageData: Data?
    private var _imageSource: CGImageSource?
    private var _finalized: Bool = false
    private var _imageTypeKnown: Bool = false

    override convenience init() {
        self.init(withScale: UIScreen.main.scale)
    }
    
    convenience init(withData data: Data, scale: CGFloat) {
        if data.count == 0 {
            fatalError("image data has no content, decoder init error")
        }
        self.init(withScale: scale)
        self.updateImageData(data: data, finalized: true)
    }
    
    init(withScale scale: CGFloat) {
        self.imageType = .Unknown
        self._sem_lock = DispatchSemaphore(value: 1)
        self._recursive_lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        let lock_attr = UnsafeMutablePointer<pthread_mutexattr_t>.allocate(capacity: 1)
        pthread_mutexattr_init(lock_attr)
        pthread_mutexattr_settype(lock_attr, PTHREAD_MUTEX_RECURSIVE)
        pthread_mutex_init(self._recursive_lock, lock_attr)
        super.init()
        
        if scale <= 0 {
            self.scale = 1
        } else {
            self.scale = scale
        }
    }
    
    public func imageAtIndex(_ index: Int, shouldDecode: Bool) -> UIImage? {
        var frame: _LQImageFrame?
        pthread_mutex_lock(_recursive_lock)
        frame = _frameAtIndex(index, shouldDecode: shouldDecode)
        pthread_mutex_unlock(_recursive_lock)
        if frame != nil {
            return frame!.image
        }
        return nil
    }
    
    public func imageDurationAtIndex(_ index: Int) -> TimeInterval {
        if frames == nil || index >= frames!.count {
            return 0
        }
        var frame: _LQImageFrame
        pthread_mutex_lock(_recursive_lock)
        frame = frames![index]
        pthread_mutex_unlock(_recursive_lock)
        return frame.duration
    }
    
    public func updateImageData(data: Data, finalized: Bool) {
        pthread_mutex_lock(_recursive_lock)
        _updateImageData(data: data, finalized: finalized)
        pthread_mutex_unlock(_recursive_lock)
    }
    
    //MARK: - 私有方法
    private func _frameAtIndex(_ index: Int, shouldDecode: Bool) -> _LQImageFrame? {
        if frames == nil {
            return nil
        }
        if index > frames!.count {
            return nil
        }
        
        let frame = _LQImageFrame()
        var decoded = false
        var imageRef = _imageRefAtIndex(index, decoded: &decoded)
        if imageRef == nil {
            return nil
        }
        if shouldDecode && !decoded {
            let decodedImageRef = CGImageCreateDecodedCopy(imageRef: imageRef!)
            if decodedImageRef != nil {
                imageRef = decodedImageRef
                decoded = true
            }
        }
        
        let image = UIImage(cgImage: imageRef!)
        image.isDecoded = decoded
        frame.image = image
        return frame
    }
    
    private func _imageRefAtIndex(_ index: Int, decoded: UnsafeMutablePointer<Bool>) -> CGImage? {
        if !_finalized && index > 0 {
            return nil
        }
        if frames == nil || frames!.count <= index {
            return nil
        }
        if _imageSource != nil {
            let dictKey = kCGImageSourceShouldCache
            let dictValue = true
            var imageRef = CGImageSourceCreateImageAtIndex(_imageSource!, index, [dictKey: dictValue] as CFDictionary)
            if imageRef != nil {
                let w = imageRef!.width
                let h = imageRef!.height
                if w == width && h == height {
                    let newImageRef = CGImageCreateDecodedCopy(imageRef: imageRef!)
                    imageRef = newImageRef
                    decoded.pointee = true
                } else {
                    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
                    if context != nil {
                        context!.draw(imageRef!, in: CGRect(x: 0, y: height - h, width: w, height: h))
                        let newImageRef = context!.makeImage()
                        if newImageRef != nil {
                            imageRef = newImageRef
                            decoded.pointee = true
                        }
                    }
                }
            }
            return imageRef
        }
        return nil
    }
    
    private func _updateImageData(data: Data, finalized: Bool) {
        if _finalized {
            return
        }
        if data.count == 0 {
            return
        }
        if _imageData != nil && data.count <= _imageData!.count {
            return
        }
        
        _finalized = finalized
        _imageData = data
        
        let type = _getImageType(data: data as CFData)
        if _imageTypeKnown {
            if type == .APNG && imageType == .PNG {
                imageType = type
            }
            if type != imageType {
                return
            } else {
                _updateImageSource()
            }
        } else {
            if imageData!.count > 16 {
                imageType = type
                _imageTypeKnown = true
                _updateImageSource()
            }
        }
    }
    
    /// 接收到新的imageData，更新imageSource
    private func _updateImageSource() {
        if _imageData == nil {
            return
        }
        
        if _imageSource == nil {
            if _finalized {
                _imageSource = CGImageSourceCreateWithData(_imageData! as CFData, nil)
            } else {
                _imageSource = CGImageSourceCreateIncremental(nil)
                if _imageSource != nil {
                    CGImageSourceUpdateData(_imageSource!, _imageData! as CFData, false)
                }
            }
        } else {
            CGImageSourceUpdateData(_imageSource!, _imageData! as CFData, _finalized)
        }
        if _imageSource == nil {
            return
        }
        
        framesCount = CGImageSourceGetCount(_imageSource!)
        if framesCount == 0 {
            return
        }
        
        if !_finalized {
            // 数据还未加载完毕
            framesCount = 1
        } else {
            if imageType == .GIF || imageType == .PNG {
                let properties = CGImageSourceCopyProperties(_imageSource!, nil) as NSDictionary?
                if properties != nil {
                    var propertyKey = kCGImagePropertyGIFDictionary
                    var property = kCGImagePropertyGIFLoopCount
                    
                    if imageType == .PNG {
                        propertyKey = kCGImagePropertyPNGDictionary
                        property = kCGImagePropertyAPNGLoopCount
                    }
                    
                    let dict = properties!.value(forKey: propertyKey as String) as! NSDictionary?
                    
                    if dict != nil {
                        let loop = dict!.value(forKey: property as String) as! CFNumber?
                        if loop != nil {
                            CFNumberGetValue(loop, CFNumberType.intType, &loopCount)
                        }
                    }
                }
            }
        }
        
        //TODO: - 针对动图，获取每帧的duration等信息
        var frames = [_LQImageFrame]()
        for i in 0 ..< framesCount {
            let frame = _LQImageFrame()
            frame.index = i
            frames.append(frame)

            let properties = CGImageSourceCopyPropertiesAtIndex(_imageSource!, i, nil) as NSDictionary?
            if properties != nil {
                var duration: TimeInterval = 0
                var width: Int = 0
                var height: Int = 0
                var value: CFTypeRef?

                var valueKey = kCGImagePropertyPixelWidth
                value = properties!.value(forKey: valueKey as String) as! CFNumber?
                if value != nil {
                    CFNumberGetValue((value as! CFNumber), CFNumberType.intType, &width)
                }
                valueKey = kCGImagePropertyPixelHeight
                value = properties!.value(forKey: valueKey as String) as! CFNumber?
                if value != nil {
                    CFNumberGetValue((value as! CFNumber), CFNumberType.intType, &height)
                }
                // 处理gif/apng格式动画图片
                if imageType == .GIF || imageType == .PNG {
                    var durationKey: CFString
                    if imageType == .GIF {
                        valueKey = kCGImagePropertyGIFDictionary
                        durationKey = kCGImagePropertyGIFDelayTime
                    } else {
                        valueKey = kCGImagePropertyPNGDictionary
                        durationKey = kCGImagePropertyAPNGDelayTime
                    }
                    let dict = properties!.value(forKey: valueKey as String) as! NSDictionary?
                    if dict != nil {
                        value = dict!.value(forKey: durationKey as String) as! CFNumber?
                        if value != nil {
                            CFNumberGetValue((value as! CFNumber), CFNumberType.doubleType, &duration)
                        }
                    }
                }

                frame.duration = duration
                frame.width = width
                frame.height = height
                
                if self.width + self.height == 0 {
                    self.width = width
                    self.height = height
                }
            }
        }

        _sem_lock.wait()
        self.frames = frames
        _sem_lock.signal()
    }
    
    /// 获取图片类型（from YYKit）
    private func _getImageType(data: CFData?) -> LQImageType {
        if data == nil {
            return .Unknown
        }
        
        let length = CFDataGetLength(data)
        if length < 16 {
            return .Unknown
        }
        
        let bytesPtr = CFDataGetBytePtr(data!)
        if bytesPtr == nil {
            return .Unknown
        }
        
        var first4Bytes: __uint32_t = 0
        bytesPtr!.withMemoryRebound(to: UInt32.self, capacity: 1) { ptr in
            first4Bytes = ptr.pointee
        }
        switch first4Bytes {
        case _4BytesMask(c1: 0x4d, c2: 0x4d, c3: 0x00, c4: 0x2a):
            return .TIFF
        case _4BytesMask(c1: 0x49, c2: 0x49, c3: 0x2a, c4: 0x00):
            return .TIFF
        case _4BytesMask(c1: 0x00, c2: 0x00, c3: 0x01, c4: 0x00):
            return .ICO
        case _4BytesMask(c1: 0x00, c2: 0x00, c3: 0x02, c4: 0x00):
            return .ICO
        case _4BytesMask(c1: 0x69, c2: 0x63, c3: 0x6e, c4: 0x73):
            return .ICNS
        case _4BytesMask(c1: 0x47, c2: 0x49, c3: 0x46, c4: 0x38):
            return .GIF
        case _4BytesMask(c1: 0x89, c2: 0x50, c3: 0x4e, c4: 0x47): do {
            if CFDataGetLength(data!) > 48 {
                // 继续判断是否APNG格式图片，
                // APNG格式的图片在普通PNG图片的IHDR头控制块后插入了一个动画控制块(acTL)用于告诉解析器这是一个动画，它位于第38~41字节，其内容为0x61, 0x63, 0x54, 0x4c
                var apngIdentifierBytes: __uint32_t = 0
                let alignedPtr = bytesPtr!.advanced(by: 37)
                alignedPtr.withMemoryRebound(to: UInt32.self, capacity: 1) { ptr in
                    apngIdentifierBytes = ptr.pointee
                }
                if apngIdentifierBytes == _4BytesMask(c1: 0x61, c2: 0x63, c3: 0x54, c4: 0x4c) {
                    return .APNG
                } else {
                    return .PNG
                }
            } else {
                return .PNG
            }
        }
//        case _4BytesMask(c1: 0x52, c2: 0x49, c3: 0x46, c4: 0x46):
//            var tmp: __uint32_t = 0
//            bytesPtr!.advanced(by: 8).withMemoryRebound(to: UInt32.self, capacity: 1, { ptr in
//                tmp = ptr.pointee
//            })
//            if tmp == _4BytesMask(c1: 0x57, c2: 0x45, c3: 0x42, c4: 0x50) {
//                return .WebP
//            }
        default: break
        }
        
        var first2Bytes: __uint16_t = 0
        bytesPtr!.withMemoryRebound(to: UInt16.self, capacity: 1) { ptr in
            first2Bytes = ptr.pointee
        }
        switch first2Bytes {
        case _2BytesMask(c1: 0x42, c2: 0x41):
            return .BMP
        case _2BytesMask(c1: 0x42, c2: 0x4d):
            return .BMP
        case _2BytesMask(c1: 0x49, c2: 0x43):
            return .BMP
        case _2BytesMask(c1: 0x50, c2: 0x49):
            return .BMP
        case _2BytesMask(c1: 0x43, c2: 0x49):
            return .BMP
        case _2BytesMask(c1: 0x43, c2: 0x50):
            return .BMP
        case _2BytesMask(c1: 0xff, c2: 0x4f):
            return .JPEG2000
        default: break
        }

        let ptr1 = UnsafeMutablePointer<UInt8>.allocate(capacity: 3)
        ptr1.initialize(to: 255)    // FF
        ptr1.advanced(by: 1).initialize(to: 216)    // D8
        ptr1.advanced(by: 2).initialize(to: 255)
        if memcmp(bytesPtr, ptr1, 3) == 0 {
            return .JPEG
        }
        
        let ptr2 = UnsafeMutablePointer<UInt8>.allocate(capacity: 5)
        ptr2.initialize(to: 106)
        ptr2.advanced(by: 1).initialize(to: 80)
        ptr2.advanced(by: 2).initialize(to: 32)
        ptr2.advanced(by: 3).initialize(to: 32)
        ptr2.advanced(by: 4).initialize(to: 13)
        if memcmp(bytesPtr!.advanced(by: 4), ptr2, 5) == 0 {
            return .JPEG2000
        }
        
        return .Unknown
    }
    
    private func _4BytesMask(c1: __uint32_t, c2: __uint32_t, c3: __uint32_t, c4: __uint32_t) -> __uint32_t {
        return c4 << 24 | c3 << 16 | c2 << 8 | c1
    }
    
    private func _2BytesMask(c1: __uint16_t, c2: __uint16_t) -> __uint16_t {
        return c2 << 8 | c1
    }

}

private class _LQImageFrame: NSObject {
    var index: Int = 0
    var duration: TimeInterval = 0.0
    var width: Int = 0  // width in pixel
    var height: Int = 0 // height in pixel
    var image: UIImage?
}

extension UIImage {
    
    struct RuntimeKey {
        static var image_is_decoded_key = "com.lqdiskcache.extended_data"
    }
    
    var isDecoded: Bool {
        get {
            if self.images != nil && self.images!.count > 1 {
                return true
            }
            
            let value = objc_getAssociatedObject(self, &RuntimeKey.image_is_decoded_key)
            if value == nil {
                return false
            }
            return value as! Bool
        }
        set {
            objc_setAssociatedObject(self, &RuntimeKey.image_is_decoded_key, newValue, .OBJC_ASSOCIATION_ASSIGN)
        }
    }
    
    func imageByDecoded() -> UIImage {
        if self.isDecoded {
            return self
        }
        if self.cgImage == nil {
            return self
        }
        
        let decodedImageRef = CGImageCreateDecodedCopy(imageRef: self.cgImage!)
        
        if decodedImageRef == nil {
            return self
        }
        
        let decodedImage = UIImage(cgImage: decodedImageRef!, scale: self.scale, orientation: self.imageOrientation)
        decodedImage.isDecoded = true
        
        return decodedImage
    }
}

/// 解码CGImage
private func CGImageCreateDecodedCopy(imageRef: CGImage) -> CGImage? {
    let size = CGSize(width: imageRef.width, height: imageRef.height)
    let rect = CGRect(origin: .zero, size: size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let alphaInfo = imageRef.alphaInfo
    
    var hasAlpha = false
    if alphaInfo == .first || alphaInfo == .last || alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast {
        hasAlpha = true
    }
    
    #if LITTLE_ENDIAN
    let bitmapInfo = CGBitmapInfo.byteOrder32Little
    #else
    let bitmapInfo = CGBitmapInfo.byteOrder32Big
    #endif
    
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo.rawValue | (hasAlpha ? CGImageAlphaInfo.premultipliedFirst.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue))
    if context == nil {
        return nil
    }
    context!.draw(imageRef, in: rect)
    
    return context!.makeImage()
}
