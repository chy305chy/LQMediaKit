//
//  LQVideoPlayer.swift
//  LQMediaKit
//
//  Created by cuilanqing on 2018/10/31.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import UIKit
import AVKit

class LQVideoPlayer: UIView {
    
    public var url: URL? {
        get {
            return _url
        }
        set {
            if _url?.absoluteString != newValue?.absoluteString {
                _url = newValue
                prepareToPlay()
            }
        }
    }
    
    private var _url: URL?
    private var _titleLabel: UILabel
    private var _player: AVPlayer?
    private var _playerLayer: AVPlayerLayer?
    private var _playerItem: AVPlayerItem?
    private var _playing: Bool = false
    
    override init(frame: CGRect) {
        _titleLabel = UILabel()
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(playDidFinished), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: nil)
    }
    
    convenience init() {
        self.init(frame: .zero)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        if _playerLayer != nil {
            _playerLayer?.frame = self.bounds
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        let playerItem = object as! AVPlayerItem?
        guard playerItem != nil else {
            return
        }
        
        if keyPath == #keyPath(AVPlayerItem.status) {
            let status: AVPlayerItem.Status
            
            // Get the status change from the change dictionary
            if let statusNumber = change?[.newKey] as? NSNumber {
                status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
            } else {
                status = .unknown
            }
            
            switch status {
            case .readyToPlay:
                //TODO: - 获取并设置视频时长
                let videoDuration = playerItem?.duration
                // 开始播放
                play()
                break
            case .failed:
                break
            case .unknown:
                break
            }
        } else if keyPath == #keyPath(AVPlayerItem.loadedTimeRanges) {
            let loadedTime = availableTimeRange()
            let totalTime = CMTimeGetSeconds(_playerItem!.duration)
            //TODO: 更新缓冲进度条
            
        }
    }
    
    private func prepareToPlay() {
        guard _url != nil else {
            return
        }
        let asset = AVURLAsset(url: _url!, options: nil)
        _playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [
            "playable",
            "hasProtectedContent"
            ])
        _player = AVPlayer(playerItem: _playerItem)
        _playerLayer = AVPlayerLayer(player: _player)
        _playerLayer?.frame = self.bounds
        self.layer.addSublayer(_playerLayer!)
        _playerItem?.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: nil)
        _playerItem?.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.loadedTimeRanges), options: [.old, .new], context: nil)
    }
    
    /// start to play
    private func play() {
        _playing = true
        _player?.play()
    }
    
    /// pause
    private func pause() {
        _playing = false
        _player?.pause()
    }
    
    /// get loaded range
    private func availableTimeRange() -> TimeInterval {
        let loadedTimeRanges = _playerItem?.loadedTimeRanges
        let timeRange = loadedTimeRanges?.first as! CMTimeRange
        let start = CMTimeGetSeconds(timeRange.start)
        let duration = CMTimeGetSeconds(timeRange.duration)
        let totalLoadedTime = start + duration
        return totalLoadedTime
    }
    
    @objc private func playDidFinished() {
        print("======finished=======")
    }
    
}

/// 播放器指示条
fileprivate class _VideoIndicatorBar: UIView {
    
    fileprivate var _progressBarTrackTintColor: UIColor?
    fileprivate var _progressBarLoadProgressTintColor: UIColor?
    fileprivate var _progressBarPlayProgressTintColor: UIColor?
    fileprivate var _indicatorDotColor: UIColor?
    
    private var _progressBarTrackLayer: CALayer
    private var _progressBarLoadLayer: CALayer
    private var _progressBarPlayLayer: CALayer
    private var _indicatorDot: CAShapeLayer
    
    private let _barHeight: CGFloat = 2
    private let _dotHeight: CGFloat = 16
    
    private override init(frame: CGRect) {
        _progressBarTrackLayer = CALayer()
        _progressBarLoadLayer = CALayer()
        _progressBarPlayLayer = CALayer()
        _indicatorDot = CAShapeLayer()
        super.init(frame: frame)

    }
    
    convenience init(withWidth width: CGFloat) {
        self.init(frame: CGRect(x: 0, y: 0, width: width, height: 10))
        
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        
    }
    
    private func setLayers() {
        _progressBarTrackLayer.frame = CGRect(x: 0, y: 0, width: self.frame.size.width, height: _barHeight)
        _progressBarLoadLayer.frame = CGRect(x: 0, y: 0, width: self.frame.size.width, height: _barHeight)
        _progressBarPlayLayer.frame = CGRect(x: 0, y: 0, width: self.frame.size.width, height: _barHeight)
        _indicatorDot.frame = CGRect(x: _dotHeight / 2, y: (self.frame.size.height - _dotHeight) / 2, width: _dotHeight, height: _dotHeight)
        _progressBarTrackLayer.position = self.center
        _progressBarLoadLayer.position = self.center
        _progressBarPlayLayer.position = self.center
        
        let path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: _dotHeight, height: _dotHeight))
        _indicatorDot.fillColor = (_indicatorDotColor ?? UIColor.white).cgColor
        _indicatorDot.path = path.cgPath
    }
    
}
