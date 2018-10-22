//
//  ViewController.swift
//  LQCacheKitDemo
//
//  Created by cuilanqing on 2018/9/13.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import UIKit

class ViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    private var tableView: UITableView = UITableView(frame: CGRect.zero, style: .plain)
    
    
    private var images = ["http://i1.hoopchina.com.cn/u/1203/07/152/15516152/c5b1adbb.gif",
                          "http://i.imgur.com/GP1m9.png",
                          "https://n.sinaimg.cn/photo/transform/700/w1000h500/20180926/_3Fr-hkmwytp2209491.jpg",
                          "http://c.hiphotos.baidu.com/zhidao/pic/item/7aec54e736d12f2e0bd5528c48c2d5628435680e.jpg",
                          "http://wallpaperswide.com/download/mount_rainier_over_edith_creek-wallpaper-320x480.jpg",
                          "http://imgsrc.baidu.com/imgad/pic/item/34fae6cd7b899e51fab3e9c048a7d933c8950d21.jpg",
                          "http://pic2.ooopic.com/11/76/10/88bOOOPIC83_1024.jpg",
                          "http://imgsrc.baidu.com/imgad/pic/item/21a4462309f79052df1c9eea06f3d7ca7acbd5e7.jpg",
                          "http://pic5.photophoto.cn/20071228/0034034901778224_b.jpg",
                          "http://pic21.photophoto.cn/20111106/0020032891433708_b.jpg",
                          "http://attach.bbs.miui.com/forum/201303/16/173716jzszx8vbbb0z9o4k.jpg",
                          "http://pic41.nipic.com/20140601/18681759_143805185000_2.jpg",
                          "http://imgsrc.baidu.com/imgad/pic/item/7e3e6709c93d70cf0b0e1ad9f2dcd100bba12b69.jpg",
                          "http://pic.58pic.com/58pic/15/12/67/47958PICCjE_1024.jpg",
                          "http://pic144.nipic.com/file/20171030/20261224_123622249000_2.jpg",
                          "http://file06.16sucai.com/2016/0518/8afcf55356494abfda0537fd5ccf8696.jpg",
                          "http://pic15.photophoto.cn/20100422/0033034114452912_b.jpg",
                          "http://imgsrc.baidu.com/imgad/pic/item/4afbfbedab64034f788a1cd2a5c379310b551d9a.jpg",
                          "http://pic.58pic.com/58pic/13/17/97/42Z58PICJEC_1024.jpg",
                          "http://pic.58pic.com/58pic/13/86/80/95h58PIC5jK_1024.jpg",
                          "http://pic29.photophoto.cn/20131021/0005018459075260_b.jpg",
                          "http://imgsrc.baidu.com/imgad/pic/item/0bd162d9f2d3572c25e340088013632763d0c3e5.jpg",
                          "http://pic5.photophoto.cn/20071217/0008020241208713_b.jpg"]
    
    
    
//     private var images = ["https://n.sinaimg.cn/photo/transform/700/w1000h500/20180926/_3Fr-hkmwytp2209491.jpg"]
// "http://wallpaperswide.com/download/mount_rainier_over_edith_creek-wallpaper-1920x1080.jpg",
// "http://img4.imgtn.bdimg.com/it/u=2943299147,2485325577&fm=26&gp=0.jpg",
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.backgroundColor = .white
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .singleLine
        tableView.register(TestCell.self, forCellReuseIdentifier: "com.lqmediakit.test.tablecell")
        
        self.view.addSubview(tableView)
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        tableView.frame = self.view.bounds
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return images.count
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 120
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: TestCell = tableView.dequeueReusableCell(withIdentifier: "com.lqmediakit.test.tablecell", for: indexPath) as! TestCell
        
        cell.imgView.setImage(withUrl: URL(string: images[indexPath.row]))
        
        return cell
    }
    
}

class TestCell: UITableViewCell {
    public var imgView = UIImageView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.separatorInset = .zero
        
        imgView.backgroundColor = .white
        imgView.contentMode = .scaleAspectFit
        self.contentView.addSubview(imgView)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        imgView.center = self.contentView.center
    }
    
}
