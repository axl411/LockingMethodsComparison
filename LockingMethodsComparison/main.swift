//
//  main.swift
//  LockingMethodsComparison
//
//  Created by Gu Chao on 2018/10/13.
//  Copyright © 2018 Gu Chao. All rights reserved.
//

import Foundation

protocol Locking {
    func lock()
    func unlock()
}

public final class UnfairLock: Locking {
    private var unfairLock = os_unfair_lock()
    public func lock() { os_unfair_lock_lock(&unfairLock) }
    public func unlock() { os_unfair_lock_unlock(&unfairLock) }
}

public final class Lock: Locking {
    private let nsLock = NSLock()
    public func lock() { nsLock.lock() }
    public func unlock() { nsLock.unlock() }
}

public final class RecrusiveLock: Locking {
    private let nsLock = NSRecursiveLock()
    public func lock() { nsLock.lock() }
    public func unlock() { nsLock.unlock() }
}

public final class MutexLock: Locking {
    private var mutexLock: pthread_mutex_t = {
        var mutex = pthread_mutex_t()
        pthread_mutex_init(&mutex, nil)
        return mutex
    }()
    public func lock() { pthread_mutex_lock(&mutexLock) }
    public func unlock() { pthread_mutex_unlock(&mutexLock) }
}

public final class ObjcSyncLock: Locking {
    private let obj = NSObject()
    public func lock() { objc_sync_enter(obj) }
    public func unlock() { objc_sync_exit(obj) }
}

public final class SemaphoreLock: Locking {
    private let sem = DispatchSemaphore(value: 1)
    public func lock() { sem.wait() }
    public func unlock() { sem.signal() }
}

class LockedPropertyWrapper<T> {
    lazy var value: T = undefined()
    func setValue(_ setter: (_ oldValue: T) -> T) {}
    func mutateValue(_ mutator: (_ wrappedValue: inout T) -> Void) {}
}

func undefined<T>() -> T {
    fatalError()
}

class WrapperUsingLockable<T>: LockedPropertyWrapper<T> {
    private var wrapped: T
    private var lock: Locking

    init(wrapped: T, lock: Locking) {
        self.wrapped = wrapped
        self.lock = lock
    }

    // TODO: ❌ there're 2 steps: get the value and set the value, so `value += 1` is slower, this is like objc's atomic attribute, although the get and set are all atomic, this is not thread safe
    override var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return wrapped
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            wrapped = newValue
        }
    }

    override func setValue(_ setter: (_ oldValue: T) -> T) {
        lock.lock()
        defer { lock.unlock() }
        wrapped = setter(wrapped)
    }

    override func mutateValue(_ mutator: (_ wrappedValue: inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutator(&wrapped)
    }
}

class WrapperUsingSyncQueue<T>: LockedPropertyWrapper<T> {
    private var wrapped: T
    private let queue = DispatchQueue(label: "queue")

    init (wrapped: T) {
        self.wrapped = wrapped
    }

    override var value: T {
        get {
            var v: T?
            queue.sync {
                v = wrapped
            }
            return v!
        }
        set {
            queue.sync {
                wrapped = newValue
            }
        }
    }

    override func setValue(_ setter: (T) -> T) {
        queue.sync {
            wrapped = setter(wrapped)
        }
    }

    override func mutateValue(_ mutator: (inout T) -> Void) {
        queue.sync {
            mutator(&wrapped)
        }
    }
}

class MyTester: NSObject {
    static let queue1 = DispatchQueue(label: "queue1")
    static let queue2 = DispatchQueue(label: "queue2")
    static let queue3 = DispatchQueue(label: "queue3")

    enum WayOfLock {
        case usingLock(Locking)
        case usingSyncQueue
    }

    enum WayOfWork: String, CaseIterable {
        case setValue
        case mutateValue
    }

    public static func test() {
        test(wayOfLock: .usingLock(UnfairLock()))
        test(wayOfLock: .usingLock(ObjcSyncLock()))
        test(wayOfLock: .usingLock(MutexLock()))
        test(wayOfLock: .usingLock(Lock()))
        test(wayOfLock: .usingLock(RecrusiveLock()))

        test(wayOfLock: .usingLock(SemaphoreLock()))
        test(wayOfLock: .usingSyncQueue)
    }

    static func test(wayOfLock: WayOfLock) {
        let title: String
        switch wayOfLock {
        case let .usingLock(lock): title = String(describing: type(of: lock))
        case .usingSyncQueue: title = "SyncQueue"
        }
        print("+++++ \(title) +++++")

        for wayOfWork in WayOfWork.allCases {
            guard wayOfWork == .setValue else { break }
//            print("    --\(wayOfWork)")

            let counterWrapper: LockedPropertyWrapper<UInt>
            switch wayOfLock {
            case let .usingLock(lock):
                counterWrapper = WrapperUsingLockable(wrapped: 0, lock: lock)
            case .usingSyncQueue:
                counterWrapper = WrapperUsingSyncQueue(wrapped: 0)
            }

            let semaphore = DispatchSemaphore(value: 0)
            let loopCount = 300000
            let work = {
                switch wayOfWork {
                case .setValue: counterWrapper.setValue { $0 + 1 }
                case .mutateValue: counterWrapper.mutateValue { $0 = $0 + 1}
                }
            }


            let beginTime = Date()

            queue1.async {
                for _ in 0..<loopCount {
                    work()
                }
                semaphore.signal()
            }

            queue2.async {
                for _ in 0..<loopCount {
                    work()
                }
                semaphore.signal()
            }

            queue3.async {
                for _ in 0..<loopCount {
                    work()
                }
                semaphore.signal()
            }


            semaphore.wait()
            semaphore.wait()
            semaphore.wait()

            let expectedCounterValue = loopCount * 3
            let result = counterWrapper.value == expectedCounterValue ? "✅" : "❌"
            print("    \(result) elapsed time: \(Date().timeIntervalSince(beginTime))")
            //            print("counter value: \(counterWrapper.value)")
            //            print("expected counter value: \(expectedCounterValue)")
            print("")
        }
    }
}

// TODO: For NSLock, NSRecursiveLock and MutexLock, why the mutating version is faster than the set version?

MyTester.test()
