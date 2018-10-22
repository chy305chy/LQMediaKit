//
//  LQDiskCache.swift
//  LQCacheKit
//
//  Created by cuilanqing on 2018/9/14.
//  Copyright © 2018 cuilanqing. All rights reserved.
//

import Foundation
import CommonCrypto
import SQLite3

enum LQDiskCacheType {
    // only cache to file
    case file
    // only cache to sqlite
    case sqlite
    // default, cache to file & sqlite
    case mixed
}

/// 失败后重试次数
let kMaxRetryCountWhenFailed = 5
/// 重试间隔
let kRetryTimeInterval: TimeInterval = 2
let kMaxPathLength = PATH_MAX - 64
let kSQLiteFileName = "manifest.sqlite"
let kSQLiteShmFileName = "manifest.sqlite-shm"
let kSQLiteWalFileName = "manifest.sqlite-wal"
let kDataDirectoryName = "data"

/// 根据key获取文件命（使用MD5计算方法）
///
/// - Parameter key: 缓存的key
/// - Returns: 文件名
fileprivate func getFilename(withKey key: String) -> String? {
    if key.count == 0 {
        return nil
    }
    
    let result = UnsafeMutablePointer<CUnsignedChar>.allocate(capacity: Int(CC_MD5_DIGEST_LENGTH))
    CC_MD5(key.cString(using: .utf8), CC_LONG(exactly: key.lengthOfBytes(using: .utf8))!, result)
    return String(format: "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", [result.pointee, result.advanced(by: 1).pointee, result.advanced(by: 2).pointee, result.advanced(by: 3).pointee, result.advanced(by: 4).pointee, result.advanced(by: 5).pointee, result.advanced(by: 6).pointee, result.advanced(by: 7).pointee, result.advanced(by: 8).pointee, result.advanced(by: 9).pointee, result.advanced(by: 10).pointee, result.advanced(by: 11).pointee, result.advanced(by: 12).pointee, result.advanced(by: 13).pointee, result.advanced(by: 14).pointee, result.advanced(by: 15).pointee])
}

/// DiskCache数据模型
private class _LQDiskCacheEntity: NSObject {
    fileprivate var key: String = ""
    fileprivate var value: Data?
    fileprivate var size: Int = 0
    fileprivate var filename: String?
    fileprivate var modifiedTime: TimeInterval = 0
    fileprivate var lastAccessTime: TimeInterval = 0
    fileprivate var lifeTime: TimeInterval = 0
    fileprivate var extendedData: Data?
}

private class _LQDiskCacheManager: NSObject {
    private(set) var cachePath: String = ""
    private(set) var cacheType: LQDiskCacheType = .mixed
    private(set) var mixCriticalValue = 0
    private var _dbPath: String = ""
    private var _fileDataPath: String = ""
    private var _db: OpaquePointer?
    private var _stmtCache: [String: OpaquePointer?] = [String: OpaquePointer?]()
    private var _dbLastOpenErrorTimestamp: TimeInterval = 0
    private var _dbOpenErrorCount = 0
    private var _trimPort: NSMachPort?
    private var _trimRunLoop: RunLoop?
    var autoTrimTimeInterval = 30
    private lazy var _timer = Timer(timeInterval: TimeInterval(exactly: autoTrimTimeInterval)!, target: self, selector: #selector(_timerHandler), userInfo: nil, repeats: true)
    private lazy var _trimThread = Thread(target: self, selector: #selector(_trimThreadEntryPoint), object: nil)
   
    //MARK: - 子线程相关
    private func _startTrimThread(withName: String) {
        _trimThread.name = withName
        if !_trimThread.isExecuting {
            _trimThread.qualityOfService = .background
            _trimThread.start()
        }
    }
    
    @objc private func _trimThreadEntryPoint(obj: AnyObject?) {
        let runLoop = RunLoop.current
        let port = NSMachPort()
        runLoop.add(port, forMode: .default)
        runLoop.add(_timer, forMode: .default)
        runLoop.run()
        _timer.fire()
        _trimPort = port
        _trimRunLoop = runLoop
    }
    
    @objc private func _timerHandler() {
        self._removeExpirationItems()
    }
    
    private func _removeExpirationItems() {
        if !_checkDB() {
            return
        }
        
        // 找出文件名存储在sqlite中，但是数据存储在文件中的item
        let sql1 = "select filename from manifest where strftime('%s', 'now') - modification_time >= life_time and inline_data is null;"
        // 删除sqlite中超时的项目
        let sql2 = "delete from manifest where strftime('%s', 'now') - modification_time >= life_time"
        
        let stmt = _dbPrepareStmt(sql: sql1)
        var result = 0
        if stmt == nil {
            return
        }
        while true {
            result = Int(sqlite3_step(stmt))
            if result == SQLITE_ROW {
                let filename = sqlite3_column_text(stmt, 0)
                if filename != nil {
                    _ = filename?.withMemoryRebound(to: CChar.self, capacity: 1, { ptr in
                        _fileDelete(withName: String(utf8String: ptr)!)
                    })
                }
            } else {
                break
            }
        }
        
        // 执行sql2
        sqlite3_exec(_db, sql2.cString(using: .utf8), nil, nil, nil)
    }
    
    //MARK: - 数据库操作相关私有方法
    private func _dbOpen() -> Bool {
        if _db != nil {
            return true
        }
        
        var result: Int32 = 0
        _dbPath.withCString { ptr in
            // 开启fullmutex保证多线程安全
            result = sqlite3_open_v2(ptr, &_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_WAL, nil)
        }

        if result == SQLITE_OK {
            _dbLastOpenErrorTimestamp = TimeInterval(exactly: 0)!
            _dbOpenErrorCount = 0
            return true
        } else {
            // 打开数据库失败
            _db = nil
            if _stmtCache.count > 0 {
                _stmtCache.removeAll()
            }
            _dbLastOpenErrorTimestamp = CFAbsoluteTimeGetCurrent()
            _dbOpenErrorCount = _dbOpenErrorCount.advanced(by: 1)
            return false
        }
    }
    
    private func _dbClose() -> Bool {
        if _db == nil {
            return true
        }
        if _stmtCache.count > 0 {
            _stmtCache.removeAll()
        }
        
        var result: Int32 = 0
        var retry = true
        var stmtFinalized = false
        
        while retry {
            result = sqlite3_close(_db)
            if result == SQLITE_OK {
                retry = false
            } else if (result == SQLITE_BUSY || result == SQLITE_LOCKED) {
                if !stmtFinalized {
                    stmtFinalized = true
                    var stmt = sqlite3_next_stmt(_db, nil)
                    let nullPointer = OpaquePointer.init(UnsafePointer<Any>(bitPattern: 0))
                    while stmt != nullPointer  {
                        sqlite3_finalize(stmt)
                        stmt = sqlite3_next_stmt(_db, nil)
                    }
                }
            }
        }
        
        _db = nil
        return true
    }
    
    private func _dbInitialize() -> Bool {
        let sql = "pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, life_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);"
        if !_checkDB() {
            return false
        }
        
        let result = sqlite3_exec(_db!, sql.cString(using: .utf8), nil, nil, nil)
        sqlite3_wal_autocheckpoint(_db!, 500)
        return result == SQLITE_OK
    }
    
    private func _checkDB() -> Bool {
        if _db == nil {
            if (_dbOpenErrorCount < kMaxRetryCountWhenFailed && CFAbsoluteTimeGetCurrent() - _dbLastOpenErrorTimestamp > kRetryTimeInterval) {
                return _dbOpen() && _dbInitialize()
            } else {
                return false
            }
        }
        return true
    }
    
    private func _dbCheckpoint() {
        if !_checkDB() {
            return
        }
        sqlite3_wal_checkpoint(_db, nil)
    }
    
    private func _dbPrepareStmt(sql: String) -> OpaquePointer? {
        if (sql.count == 0 || !_checkDB()) {
            return nil
        }
        
        var stmt = _stmtCache[sql]
        if stmt == nil {
            let stmtPtr = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
            let result = sqlite3_prepare_v2(_db, sql.cString(using: .utf8), -1, stmtPtr, nil)
            if result != SQLITE_OK {
                return nil
            }
            _stmtCache[sql] = stmtPtr.pointee
            stmt = stmtPtr.pointee
        } else {
            sqlite3_reset(stmt!)
        }
        return stmt!
    }
    
    private func _dbJoinedKeys(keys: Array<String>) -> String {
        let keysCount = keys.count
        var joinedString = String()
        for i in 0 ..< keysCount {
            joinedString = (joinedString as NSString).appending("?")
            if i < keysCount - 1 {
                joinedString = (joinedString as NSString).appending(",")
            }
        }
        return joinedString
    }
    
    private func _dbBindJoinedKeys(keys: Array<String>, stmt: OpaquePointer?, fromIndex: Int) {
        if stmt == nil {
            return
        }
        for i in 0 ..< keys.count {
            let key = keys[i]
            sqlite3_bind_text(stmt!, Int32(fromIndex.advanced(by: i)), key.cString(using: .utf8), -1, nil)
        }
    }
    
    private func _dbInsert(key: String, value: Data?, filename: String?, extendedData: Data?) -> Bool {
        return _dbInsert(key: key, value: value, filename: filename, lifeTime: TimeInterval(Int.max), extendedData: extendedData)
    }
    
    private func _dbInsert(key: String, value: Data?, filename: String?, lifeTime: TimeInterval, extendedData: Data?) -> Bool {
        let sql = "insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, life_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);"
        
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return false
        }
        
        let timestamp = CFAbsoluteTimeGetCurrent()
        sqlite3_bind_text(stmt!, 1, key.cString(using: .utf8), -1, nil)
        sqlite3_bind_text(stmt!, 2, filename?.cString(using: .utf8), -1, nil)
        if value == nil {
            sqlite3_bind_int(stmt!, 3, 0)
        } else {
            sqlite3_bind_int(stmt!, 3, Int32(value!.count))
        }
        if filename == nil || filename?.count == 0 {
            // 如果不传filename，说明只把value保存在sqlite中
            _ = value!.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt!, 4, ptr, Int32(value!.count), nil)
            }
        } else {
            sqlite3_bind_blob(stmt!, 4, nil, 0, nil)
        }
        sqlite3_bind_double(stmt!, 5, timestamp)
        sqlite3_bind_double(stmt!, 6, timestamp)
        sqlite3_bind_double(stmt!, 7, lifeTime)

        if extendedData == nil {
            sqlite3_bind_blob(stmt!, 8, nil, 0, nil)
        } else {
            let count = Int32(extendedData!.count)
            _ = extendedData!.withUnsafeBytes({ ptr in
                sqlite3_bind_blob(stmt!, 8, ptr, count, nil)
            })
        }
        let result = sqlite3_step(stmt!)
        return result == SQLITE_DONE
    }
    
//    private func _dbBatchInsert(keys: [String], values: [Data?], filenames: [String?]?, lifeTimes: [TimeInterval]?, extendedDatas: [Data?]) -> Bool {
//        if keys.count - values.count + filenames.count - lifeTimes.count + extendedDatas.count != extendedDatas.count {
//            return false
//        }
//        let beginTransaction = "begin transaction;"
//        let commitTransaction = "commit transaction;"
//        sqlite3_exec(_db, beginTransaction.cString(using: .utf8), nil, nil, nil)
//        for i in 0 ..< keys.count {
//            if !_dbInsert(key: keys[i], value: values[i], filename: filenames[i], lifeTime: lifeTimes[i], extendedData: extendedDatas[i]) {
//                sqlite3_exec(_db, commitTransaction.cString(using: .utf8), nil, nil, nil)
//                return false
//            }
//        }
//        sqlite3_exec(_db, commitTransaction.cString(using: .utf8), nil, nil, nil)
//        return true
//    }
    
    private func _dbDeleteItem(forKey key: String) -> Bool {
        let sql = "delete from manifest where key = ?1;"
        let stmt = _dbPrepareStmt(sql: sql)
        
        if stmt == nil {
            return false
        }
        sqlite3_bind_text(stmt!, 1, key.cString(using: .utf8), -1, nil)
        return sqlite3_step(stmt!) == SQLITE_DONE
    }
    
    private func _dbDeleteItems(forKeys keys: Array<String>) -> Bool {
        if !_checkDB() {
            return false
        }
        
        let sql = String(format: "delete from manifest where key in (%@);", [_dbJoinedKeys(keys: keys)])
        let stmtPtr = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        var result = sqlite3_prepare_v2(_db!, sql.cString(using: .utf8), -1, stmtPtr, nil)
        if result != SQLITE_OK {
            return false
        }
        _dbBindJoinedKeys(keys: keys, stmt: stmtPtr.pointee, fromIndex: 1)
        result = sqlite3_step(stmtPtr.pointee)
        sqlite3_finalize(stmtPtr.pointee)
        
        return result == SQLITE_DONE
    }
    
    private func _dbupdateAccessTime(forKey key: String) -> Bool {
        let sql = "update manifest set last_access_time = ?1 where key = ?2"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return false
        }
        let timestamp = CFAbsoluteTimeGetCurrent()
        sqlite3_bind_double(stmt!, 1, timestamp)
        sqlite3_bind_text(stmt!, 2, key.cString(using: .utf8), -1
            , nil)
        let result = sqlite3_step(stmt!)
        return result == SQLITE_DONE
    }
    
    private func _dbUpdateAccessTime(keys: Array<String>) -> Bool {
        if !_checkDB() {
            return false
        }
        
        let sql = String(format: "update manifest set last_access_time = %d where key in (%@);", arguments: [CFAbsoluteTimeGetCurrent(), _dbJoinedKeys(keys: keys)])
        let stmtPtr = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        var result = sqlite3_prepare_v2(_db!, sql.cString(using: .utf8), -1, stmtPtr, nil)
        if result != SQLITE_OK {
            return false
        }
        _dbBindJoinedKeys(keys: keys, stmt: stmtPtr.pointee, fromIndex: 1)
        result = sqlite3_step(stmtPtr.pointee)
        sqlite3_finalize(stmtPtr.pointee)

        return result == SQLITE_DONE
    }
    
    private func _dbGetValue(forKey key: String) -> Data? {
        let sql = "select inline_data from manifest where key = ?1"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return nil
        }
        sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            let inline_data = sqlite3_column_blob(stmt, 0)
            let inline_data_bytes = sqlite3_column_bytes(stmt, 0)
            if inline_data == nil || inline_data_bytes <= 0 {
                return nil
            }
            return Data(bytes: inline_data!, count: Int(inline_data_bytes))
        } else {
            return nil
        }
    }
    
    private func _dbGetLifeTime(forKey key: String) -> TimeInterval {
        let sql = "select life_time from manifest where key = ?1"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return 0
        }
        sqlite3_bind_text(stmt!, 1, key.cString(using: .utf8), -1, nil)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            return sqlite3_column_double(stmt!, 0)
        } else {
            return 0
        }
    }
    
    private func _dbGetFilename(forKey key: String) -> String? {
        let sql = "select filename from manifest where key = ?1"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return nil
        }
        sqlite3_bind_text(stmt!, 1, key.cString(using: .utf8), -1, nil)
        let result = sqlite3_step(stmt!)
        if result == SQLITE_ROW {
            let filename: UnsafePointer<CUnsignedChar>? = sqlite3_column_text(stmt!, 0)
            if filename != nil {
                // sqlite3_column_text返回UInt8类型指针，这里需要把它转换成Int8类型指针
                let filenameStr = filename?.withMemoryRebound(to: CChar.self, capacity: 1, { ptr in
                    return String(utf8String: ptr)
                })
                return filenameStr
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    private func _dbGetFilenames(forKeys keys: Array<String>) -> Array<String>? {
        if !_checkDB() {
            return nil
        }
        
        let sql = String(format: "select filename from manifest where key in (%@)", _dbJoinedKeys(keys: keys))
        let stmtPtr = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        var result = sqlite3_prepare_v2(_db!, sql.cString(using: .utf8), -1, stmtPtr, nil)
        if result != SQLITE_OK {
            return nil
        }
        _dbBindJoinedKeys(keys: keys, stmt: stmtPtr.pointee, fromIndex: 1)
        var filenames = [String]()
        
        while true {
            result = sqlite3_step(stmtPtr.pointee)
            if result == SQLITE_ROW {
                let filename = sqlite3_column_text(stmtPtr.pointee, 0)
                if filename != nil {
                    filename?.withMemoryRebound(to: CChar.self, capacity: 1, { ptr in
                        filenames.append(String(utf8String: ptr)!)
                    })
                }
            } else if (result == SQLITE_DONE) {
                break
            } else {
                return nil
            }
        }
        sqlite3_finalize(stmtPtr.pointee)
        
        return filenames
    }
    
    private func _dbGetItem(withStmt stmt: OpaquePointer!, includeInlineData: Bool) -> _LQDiskCacheEntity {
        var index = 0
        let key = sqlite3_column_text(stmt, Int32(index++))
        let filename = sqlite3_column_text(stmt, Int32(index++))
        let size = sqlite3_column_int(stmt, Int32(index++))
        let inline_data = includeInlineData ? sqlite3_column_blob(stmt, Int32(index)) : nil
        let inline_data_bytes = includeInlineData ? sqlite3_column_bytes(stmt, Int32(index++)) : 0
        let modified_time = sqlite3_column_double(stmt, Int32(index++))
        let last_access_time = sqlite3_column_double(stmt, Int32(index++))
        let life_time = sqlite3_column_double(stmt, Int32(index++))
        let extended_data = sqlite3_column_blob(stmt, Int32(index))
        let extended_data_bytes = sqlite3_column_bytes(stmt, Int32(index++))
        
        let cacheItem = _LQDiskCacheEntity()
        if key != nil {
            cacheItem.key = String(cString: key!)
        }
        if filename != nil {
            cacheItem.filename = String(cString: filename!)
        }
        cacheItem.size = Int(size)
        if inline_data != nil && inline_data_bytes > 0 {
            cacheItem.value = Data(bytes: inline_data!, count: Int(inline_data_bytes))
        }
        cacheItem.modifiedTime = TimeInterval(modified_time)
        cacheItem.lastAccessTime = TimeInterval(last_access_time)
        cacheItem.lifeTime = TimeInterval(life_time)
        if extended_data != nil && extended_data_bytes > 0 {
            cacheItem.extendedData = Data(bytes: extended_data!, count: Int(extended_data_bytes))
        }
        
        return cacheItem
    }
    
    private func _dbGetItem(forKey key: String, includeInlineData: Bool) -> _LQDiskCacheEntity? {
        let sql = includeInlineData ? "select key, filename, size, inline_data, modification_time, last_access_time, life_time, extended_data from manifest where key = ?1;" : "select key, filename, size, modification_time, last_access_time, life_time, extended_data from manifest where key = ?1;"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return nil
        }
        sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            return _dbGetItem(withStmt: stmt!, includeInlineData: includeInlineData)
        } else {
            return nil
        }
    }
    
    private func _dbGetItems(forKeys keys: Array<String>, includeInlineData: Bool) -> [_LQDiskCacheEntity]? {
        if keys.count == 0 {
            return nil
        }
        if !_checkDB() {
            return nil
        }
        let sql = includeInlineData ? String(format: "select key, filename, size, inline_data, modification_time, last_access_time, life_time, extended_data from manifest where key in (%@)", _dbJoinedKeys(keys: keys)) : String(format: "select key, filename, size, modification_time, last_access_time, life_time, extended_data from manifest where key in (%@)", _dbJoinedKeys(keys: keys))
        let stmtPtr = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        var result = sqlite3_prepare_v2(_db, sql.cString(using: .utf8), -1, stmtPtr, nil)
        if result != SQLITE_OK {
            return nil
        }
        _dbBindJoinedKeys(keys: keys, stmt: stmtPtr.pointee, fromIndex: 1)
        var items = [_LQDiskCacheEntity]()
        while true {
            result = sqlite3_step(stmtPtr.pointee)
            if result == SQLITE_ROW {
                items.append(_dbGetItem(withStmt: stmtPtr.pointee!, includeInlineData: includeInlineData))
            } else if result == SQLITE_DONE {
                break
            } else {
                return nil
            }
        }
        sqlite3_finalize(stmtPtr.pointee)
        return items
    }
    
    private func _dbGetItemsByAccessTimeAscending(withLimitCount limitCount: Int) -> [_LQDiskCacheEntity]? {
        let sql = "select key, filename, size from manifest order by last_access_time asc limit ?1;"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return nil
        }
        sqlite3_bind_int(stmt, 1, Int32(limitCount))
        var items = [_LQDiskCacheEntity]()
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                let key = sqlite3_column_text(stmt, 0)
                let filename = sqlite3_column_text(stmt, 1)
                let size = sqlite3_column_int(stmt, 2)
                var keyStr: String?
                var filenameStr: String?
                if key == nil {
                    keyStr = nil
                } else {
                    _ = key?.withMemoryRebound(to: CChar.self, capacity: 1, { ptr in
                        keyStr = String(utf8String: ptr)
                    })
                }
                if filename == nil {
                    filenameStr = nil
                } else {
                    _ = filename?.withMemoryRebound(to: CChar.self, capacity: 1, { ptr in
                        filenameStr = String(utf8String: ptr)
                    })
                }
                if keyStr != nil {
                    let item = _LQDiskCacheEntity()
                    item.key = keyStr!
                    item.filename = filenameStr
                    item.size = Int(size)
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                items.removeAll()
                break;
            }
        }
        return items
    }
    
    private func _dbGetTotalItemCount() -> Int {
        let sql = "select count(*) from manifest;"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return -1
        }
        if sqlite3_step(stmt) != SQLITE_ROW {
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    private func _dbGetTotalItemSize() -> Int {
        let sql = "select sum(size) from manifest;"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return -1
        }
        if sqlite3_step(stmt) != SQLITE_ROW {
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    private func _dbGetItemCount(forKey key: String) -> Int {
        let sql = "select count(key) from maniest where key = ?1;"
        let stmt = _dbPrepareStmt(sql: sql)
        if stmt == nil {
            return -1
        }
        sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
        if sqlite3_step(stmt) != SQLITE_ROW {
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    //MARK: - 文件操作相关私有方法
    private func _fileWrite(withName filename: String, fileData data: Data?) -> Bool {
        if data == nil {
            return false
        }
        do {
            let filePath = _fileDataPath + "/\(filename)"
            try data!.write(to: URL(fileURLWithPath: filePath, isDirectory: false), options: .atomic)
            return true
        } catch  {
            return false
        }
    }
    
    private func _fileDelete(withName filename: String) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: _fileDataPath + "/\(filename)")
        } catch  {
            return false
        }
        return true
    }
    
    private func _fileDeleteAll() -> Bool {
        do {
            try FileManager.default.removeItem(atPath: _fileDataPath)
            try FileManager.default.createDirectory(atPath: _fileDataPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return false
        }
        return true
    }
    
    private func _fileRead(withName filename: String) -> Data? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: _fileDataPath + "/\(filename)"), options: .uncached)
            return data
        } catch  {
            return nil
        }
    }
    
    private func _reset() {
        try? FileManager.default.removeItem(atPath: (cachePath as NSString).appendingPathComponent(kSQLiteFileName))
        try? FileManager.default.removeItem(atPath: (cachePath as NSString).appendingPathComponent(kSQLiteShmFileName))
        try? FileManager.default.removeItem(atPath: (cachePath as NSString).appendingPathComponent(kSQLiteWalFileName))
        _ = _fileDeleteAll()
    }
    
    //MARK: - 公共方法
    @available(*, unavailable)
    override init() {
        fatalError("use init(path: String?, type: LQDiskCacheType?) instead.")
    }
    
    init(path: String?, type: LQDiskCacheType?) {
        super.init()
        
        if path == nil || path!.count == 0 {
            fatalError("disk cache path must not be nil!")
        }
        if type != nil {
            cacheType = type!
        } else {
            cacheType = .mixed
        }
        mixCriticalValue = 30 * 1024
        cachePath = path!
        _dbPath = (cachePath as NSString).appendingPathComponent(kSQLiteFileName) as String
        _fileDataPath = (cachePath as NSString).appendingPathComponent(kDataDirectoryName) as String
        
        do {
            try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            fatalError("failed to create directory at specified path.")
        }
        
        do {
            try FileManager.default.createDirectory(atPath: _fileDataPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            fatalError("failed to create files at specified path.")
        }
        
        if !FileManager.default.fileExists(atPath: _dbPath) {
            FileManager.default.createFile(atPath: _dbPath, contents: nil, attributes: nil)
        }
        
        if !_dbOpen() || !_dbInitialize() {
            _ = _dbClose()
            _reset()
            if !_dbOpen() || !_dbInitialize() {
                _ = _dbClose()
                fatalError("LQDiskCache init error: failed to open db file.")
            }
        }
        
        _startTrimThread(withName: String(format: "com.lqcache.disk.autotrimthread.%@", [(cachePath as NSString).lastPathComponent]))
    }
    
    deinit {
        _timer.invalidate()
        if _trimRunLoop != nil {
            _trimRunLoop!.remove(_trimPort!, forMode: .default)
            _trimRunLoop!.cancelPerformSelectors(withTarget: self)
        }
        _trimThread.cancel()
    }
    
    fileprivate func saveItem(withItem item: _LQDiskCacheEntity) -> Bool {
        return self.saveItem(withKey: item.key, value: item.value, filename: item.filename, lifeTime: item.lifeTime, extendedData: item.extendedData)
    }
    
    fileprivate func saveItem(withKey key: String, value: Data?, filename: String?, extendedData: Data?) -> Bool {
        return self.saveItem(withKey: key, value: value, filename: filename, lifeTime: TimeInterval(Int.max), extendedData: extendedData)
    }
    
    fileprivate func saveItem(withKey key: String, value: Data?, filename: String?, lifeTime: TimeInterval, extendedData: Data?) -> Bool {
        if key.count == 0 || value == nil || value!.count == 0 {
            return false
        }
        if cacheType == .file && (filename == nil || filename?.count == 0) {
            return false
        }
        if filename != nil && (filename?.count)! > 0 {
            if cacheType == .file {
                return _fileWrite(withName: filename!, fileData: value)
            } else {
                // mix mode
                if value!.count <= mixCriticalValue {
                    // only save to db
                    return _dbInsert(key: key, value: value, filename: nil, lifeTime: lifeTime, extendedData: extendedData)
                } else {
                    // save filename to db, save value to file
                    return _dbInsert(key: key, value: nil, filename: filename!, lifeTime: lifeTime, extendedData: extendedData) && _fileWrite(withName: filename!, fileData: value)
                }
            }
        } else {
            if cacheType != .sqlite {
                // mix mode
                if value!.count <= mixCriticalValue {
                    // only save to db
                    return _dbInsert(key: key, value: value, filename: nil, extendedData: extendedData)
                } else {
                    // save filename to db, save value to file
                    let md5_filename = getFilename(withKey: key)
                    if md5_filename == nil {
                        return false
                    }
                    return _dbInsert(key: key, value: nil, filename: md5_filename, extendedData: extendedData) && _fileWrite(withName: md5_filename!, fileData: value);
                }
            } else {
                return _dbInsert(key: key, value: value, filename: nil, extendedData: extendedData)
            }
        }
    }
    
    /// 删除一条缓存
    ///
    /// - Parameter key: 缓存的key
    /// - Returns: true: 删除成功，false: 删除失败
    fileprivate func removeItem(forKey key: String) -> Bool {
        if key.count == 0 {
            return false
        }
        switch cacheType {
        case .file:
            let filename = getFilename(withKey: key)
            if filename == nil {
                return false
            } else {
                return _fileDelete(withName:filename!)
            }
        case .sqlite:
            return _dbDeleteItem(forKey: key)
        case .mixed:
            let filename = _dbGetFilename(forKey: key)
            let value = _dbGetValue(forKey: key)
            if filename == nil {
                return _dbDeleteItem(forKey: key)
            } else {
                if value == nil {
                    return _dbDeleteItem(forKey: key) && _fileDelete(withName: filename!)
                } else {
                    return _dbDeleteItem(forKey: key)
                }
            }
        }
    }
    
    /// 根据keys批量删除缓存
    ///
    /// - Parameter keys: keys
    /// - Returns: true: success, false: fail
    fileprivate func removeItems(forKeys keys: [String]) -> Bool {
        if keys.count == 0 {
            return false
        }
        switch cacheType {
        case .file:
            for key in keys {
                if (!_fileDelete(withName: getFilename(withKey: key)!)) {
                    return false
                }
            }
            return true
        case .sqlite:
            return _dbDeleteItems(forKeys: keys)
        case .mixed:
            let filenames = _dbGetFilenames(forKeys: keys)
            if filenames == nil || filenames?.count == 0 {
                return false
            }
            for filename in filenames! {
                if !_fileDelete(withName: filename) {
                    return false
                }
            }
            if (!_dbDeleteItems(forKeys: keys)) {
                return false
            }
            return true
        }
    }
    
    /// 删除所有缓存
    ///
    /// - Returns: true: success, false: fail
    fileprivate func removeAllItems() -> Bool {
        if !_dbClose() {
            return false
        }
        _reset()
        if !_dbOpen() {
            return false
        }
        if !_dbInitialize() {
            return false
        }
        return true
    }
    
    /// 删除所有缓存，带progress和finish回调
    ///
    /// - Parameters:
    ///   - progress: 进度回调，arg1: 已删除数量, arg2: 全部数量
    ///   - finish: 完成回调, arg: true/false
    fileprivate func removeAllItems(withProgress progress: LQCacheClearProgress?, finish: LQCacheClearFinish?) {
        let totalCount = _dbGetTotalItemCount()
        if totalCount <= 0 {
            if finish != nil {
                finish!(totalCount < 0)
            }
        } else {
            var itemLeftCount = totalCount
            let removeItemsCountPerTime = 32
            var items: [_LQDiskCacheEntity]? = [_LQDiskCacheEntity]()
            var success = false
            repeat {
                items = _dbGetItemsByAccessTimeAscending(withLimitCount: removeItemsCountPerTime)
                if items == nil {
                    break
                }
                for item: _LQDiskCacheEntity in items! {
                    if itemLeftCount > 0 {
                        if item.filename != nil {
                             _ = _fileDelete(withName: item.filename!)
                        }
                        success = _dbDeleteItem(forKey: item.key)
                        itemLeftCount = itemLeftCount.advanced(by: -1)
                    } else {
                        break
                    }
                    if !success {
                        break
                    }
                }
                if progress != nil {
                    progress!(totalCount - itemLeftCount, totalCount)
                }
            } while success && itemLeftCount > 0 && items!.count > 0
            
            if success {
                _dbCheckpoint()
            }
            if finish != nil {
                finish!(success)
            }
        }
    }
    
    /// 根据key获取缓存
    ///
    /// - Parameter key: 缓存的key
    /// - Returns: 缓存item
    fileprivate func getItem(forKey key: String) -> _LQDiskCacheEntity? {
        if key.count == 0 {
            return nil
        }
        
        var item = _dbGetItem(forKey: key, includeInlineData: true)
        if item != nil {
            _ = _dbupdateAccessTime(forKey: key)
            if item!.filename != nil {
                item?.value = _fileRead(withName: item!.filename!)
                if item?.value == nil {
                    _ = _dbDeleteItem(forKey: key)
                    item = nil
                }
            }
        }
        return item
    }
    
    /// 根据keys批量获取缓存
    ///
    /// - Parameter keys: keys
    /// - Returns: 缓存数组
    fileprivate func getItems(forKeys keys: [String]) -> [_LQDiskCacheEntity]? {
        if keys.count == 0 {
            return nil
        }
        
        var items = _dbGetItems(forKeys: keys, includeInlineData: true)
        if items == nil {
            return nil
        }
        if cacheType != .sqlite {
            var count = items!.count
            for var i in 0 ..< count {
                let item = items![i]
                if item.filename != nil {
                    // 缓存的value存储在file中
                    item.value = _fileRead(withName: item.filename!)
                    if item.value == nil {
                        // file中没有对应的缓存value，删除数据库中对应的条目
                        _ = _dbDeleteItem(forKey: item.key)
                        _ = items!.remove(at: i)
                        i = i.advanced(by: -1)
                        count = count.advanced(by: -1)
                    }
                }
            }
        }
        if items!.count > 0 {
            _ = _dbUpdateAccessTime(keys: keys)
        }
        return items!.count > 0 ? items : nil
    }
    
    /// 根据key获取缓存信息，不包含data
    ///
    /// - Parameter key: 缓存key
    /// - Returns: 缓存item
    fileprivate func getItemInfo(forKey key: String) -> _LQDiskCacheEntity? {
        if key.count == 0 {
            return nil
        }
        return _dbGetItem(forKey: key, includeInlineData: false)
    }
    
    /// 根据keys批量获取缓存信息，不包含data
    ///
    /// - Parameter keys: 缓存keys
    /// - Returns: 缓存items
    fileprivate func getItemsInfo(forKeys keys: [String]) -> [_LQDiskCacheEntity]? {
        if keys.count == 0 {
            return nil
        }
        return _dbGetItems(forKeys: keys, includeInlineData: false)
    }
    
    /// 根据key获取缓存的data
    ///
    /// - Parameter key: 缓存key
    /// - Returns: 缓存data
    fileprivate func getItemValue(forKey key: String) -> Data? {
        if key.count == 0 {
            return nil
        }
        var value: Data?
        switch cacheType {
        case .file:
            let filename = getFilename(withKey: key)
            if filename != nil {
                value = _fileRead(withName: filename!)
            }
        case .sqlite:
            value = _dbGetValue(forKey: key)
        case.mixed:
            value = _dbGetValue(forKey: key)
            if value == nil {
                let filename = _dbGetFilename(forKey: key)
                if filename != nil {
                    value = _fileRead(withName: filename!)
                    if value == nil {
                        _ = _dbDeleteItem(forKey: key)
                    }
                }
            }
        }
        if value != nil {
            _ = _dbupdateAccessTime(forKey: key)
        }
        return value
    }
    
    /// 根据key批量获取缓存的data
    ///
    /// - Parameter keys: 缓存keys
    /// - Returns: 缓存datas
    fileprivate func getItemsValue(forKeys keys: [String]) -> [String: Data]? {
        if keys.count == 0 {
            return nil
        }
        
        let items = getItems(forKeys: keys)
        var dict = [String: Data]()
        if items == nil {
            return nil
        }
        for item: _LQDiskCacheEntity in items! {
            if item.value != nil {
                dict[item.key] = item.value!
            }
        }
        return dict.count > 0 ? dict : nil
    }
    
    /// 是否包含对应key的缓存
    ///
    /// - Parameter key: key
    /// - Returns: true/false
    fileprivate func containsItem(forKey key: String) -> Bool {
        if key.count == 0 {
            return false
        }
        return _dbGetItemCount(forKey: key) > 0
    }
    
    /// 获取全部缓存的数量
    ///
    /// - Returns: count
    fileprivate func totalItemsCount() -> Int {
        return _dbGetTotalItemCount();
    }
    
    /// 根据key获取缓存的最大存活时间
    ///
    /// - Parameter key: 缓存的key
    /// - Returns: 缓存最大存活时间
    fileprivate func getItemLifeTime(forKey key: String) -> TimeInterval {
        if key.count == 0 {
            return 0
        }
        return _dbGetLifeTime(forKey: key)
    }
}

//MARK: - LOCK相关
fileprivate let sem_lock = { () -> DispatchSemaphore in
    let lock = DispatchSemaphore.init(value: 1)
    return lock
}()

fileprivate func lock(handler: () -> Void) {
    sem_lock.wait()
    handler()
    sem_lock.signal()
}

// MARK: - DiskCache公有类
class LQDiskCache: NSObject {
    private(set) var path: String = ""
    
    private var _diskCacheManager: _LQDiskCacheManager?
    
    @available(*, unavailable)
    override init() {
        fatalError("init error, use 'init(withPath path: String)' or 'init(withPath path:String, inlineThreshold: Int)' instead.")
    }
    
    convenience init(witPath path: String) {
        self.init(withPath: path, type: .mixed)
    }
    
    init(withPath path:String, type: LQDiskCacheType?) {
        super.init()
        
        _diskCacheManager = _LQDiskCacheManager(path: path, type: type)
        if _diskCacheManager == nil {
            fatalError("init error, check path and retry.")
        }
        self.path = path
    }
    
    deinit {
        _diskCacheManager = nil
    }
    
    //MARK: - 加入缓存相关方法，Object必须遵循NSCoding协议
    public func setObject<T: AnyObject>(forKey key: String, object: T?) where T: NSCoding {
        setObject(forKey: key, object: object, lifeTime: TimeInterval(Int.max))
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?, lifeTime: TimeInterval) where T: NSCoding {
        if key.count == 0 {
            return
        }
        if object == nil {
            _ = removeObject(forKey: key)
            return
        }
        
        let extendedData = getExtendedData(forObject: object)
        var value: Data?
        do {
            try value = NSKeyedArchiver.archivedData(withRootObject: object!, requiringSecureCoding: false)
        } catch {
            return
        }
        
        if value == nil {
            return
        }
        let filename = getFilename(withKey: key)
        lock {
            _ = _diskCacheManager!.saveItem(withKey: key, value: value, filename: filename, lifeTime: lifeTime, extendedData: extendedData)
        }
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?, finish: @escaping (Bool) -> Void) where T: NSCoding {
        setObject(forKey: key, object: object, lifeTime: TimeInterval(Int.max), finish: finish)
    }
    
    public func setObject<T: AnyObject>(forKey key: String, object: T?, lifeTime: TimeInterval, finish: @escaping (Bool) -> Void) where T: NSCoding {
        if key.count == 0 {
            return
        }
        if object == nil {
            _ = removeObject(forKey: key)
            return
        }
        let extendedData = getExtendedData(forObject: object)
        var value: Data?
        do {
            try value = NSKeyedArchiver.archivedData(withRootObject: object!, requiringSecureCoding: false)
        } catch  {
            return
        }
        
        if value == nil {
            return
        }
        
        let filename = getFilename(withKey: key)
        lock {
            DispatchQueue.global(qos: .default).async {
                let result = self._diskCacheManager!.saveItem(withKey: key, value: value, filename: filename, lifeTime: lifeTime, extendedData: extendedData)
                finish(result)
            }
        }
    }
    
    //MARK: - 删除缓存相关方法
    public func removeObject(forKey key: String) -> Bool {
        if key.count == 0 {
            return false
        }
        var success = false
        lock {
            success = _diskCacheManager!.removeItem(forKey: key)
        }
        return success
    }
    
    public func removeObject(forKey key: String, result: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .default).async {
            let rs = self.removeObject(forKey: key)
            result(rs)
        }
    }
    
    public func removeAllObects() -> Bool {
        var result = false
        lock {
            result = _diskCacheManager!.removeAllItems()
        }
        return result
    }
    
    public func removeAllObjects(withResult result: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .default).async {
            let rs = self.removeAllObects()
            result(rs)
        }
    }
    
    public func removeAllObjects(withProgress progress: @escaping LQCacheClearProgress, finish: @escaping LQCacheClearFinish) {
        DispatchQueue.global(qos: .default).async {
            lock {
                self._diskCacheManager!.removeAllItems(withProgress: progress, finish: finish)
            }
        }
    }
    
    //MARK: - 缓存查找相关方法
    public func containsObject(forKey key: String) -> Bool {
        if key.count == 0 {
            return false
        }
        var contains = false
        lock {
            contains = _diskCacheManager!.containsItem(forKey: key)
        }
        return contains
    }
    
    public func getObject(forKey key: String) -> AnyObject? {
        if key.count == 0 {
            return nil
        }
        var item: _LQDiskCacheEntity?
        lock {
            item = _diskCacheManager!.getItem(forKey: key)
        }
        if item == nil {
            return nil
        }
        if item?.value == nil {
            return nil
        }
        let object: AnyObject? = NSKeyedUnarchiver.unarchiveObject(with: item!.value!) as AnyObject
//        do {
//            try object = NSKeyedUnarchiver.unarchiveObject(with: item!.value)//unarchiveTopLevelObjectWithData(item!.value!) as AnyObject
//        } catch  {
//            return nil
//        }
        if object != nil && item?.extendedData != nil {
            setExtendedData(forObject: object, data: item?.extendedData)
        }
        return object
    }
    
    public func getObject(forKey key: String, result: @escaping (String, AnyObject?) -> Void) {
        DispatchQueue.global(qos: .default).async {
            let object = self.getObject(forKey: key)
            result(key, object)
        }
    }
    
    public func getObjects(forKeys keys: [String]) -> [AnyObject]? {
        if keys.count == 0 {
            return nil
        }
        var objects = [AnyObject]()
        for key: String in keys {
            let obj = getObject(forKey: key)
            if obj != nil {
                objects.append(obj!)
            }
        }
        return objects
    }
    
    public func getObjectLifeTime(forKey key: String) -> TimeInterval {
        return _diskCacheManager!.getItemLifeTime(forKey: key)
    }
    
    public func totalObjectsCount() -> Int {
        var count = 0
        lock {
            count = _diskCacheManager!.totalItemsCount()
        }
        return count
    }
}

private var extended_data_key = "com.lqdiskcache.extended_data"
extension LQDiskCache {

    public func getExtendedData(forObject object: Any?) -> Data? {
        if object == nil {
            return nil
        }
        return objc_getAssociatedObject(object!, &extended_data_key) as? Data
    }
    
    public func setExtendedData(forObject object: Any?, data: Data?) {
        if object == nil {
            return
        }
        objc_setAssociatedObject(object!, &extended_data_key, data, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
