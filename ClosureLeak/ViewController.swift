import UIKit

public protocol ObserverType {
    associatedtype Element
}

class ObserverBase<Element> : ObserverType {
}

public typealias RxTime = Date
public typealias RxTimeInterval = DispatchTimeInterval

public protocol SchedulerType {
    var now : RxTime {
        get
    }
}

public protocol Cancelable {
    /// Was resource disposed.
    var isDisposed: Bool { get }
}

public struct Disposables {
    private init() {}
}

extension Disposables {
    static public func create() -> Void {
        return
    }
}

final private class ObserveOnSerialDispatchQueueSink<Observer: ObserverType>: ObserverBase<Observer.Element> {
    let scheduler: DummyScheduler
    let observer: Observer
    
    let cancel: Cancelable
    
    var cachedScheduleLambda: (((sink: ObserveOnSerialDispatchQueueSink<Observer>, event: Int)) -> Void)!
    
    init(scheduler: DummyScheduler, observer: Observer, cancel: Cancelable) {
        self.scheduler = scheduler
        self.observer = observer
        self.cancel = cancel
        super.init()
        
        self.cachedScheduleLambda = { pair in
            guard !cancel.isDisposed else { return Disposables.create() }
            
            return Disposables.create()
        }
    }
}

class DummyObserver : ObserverType {
    typealias Element = Int
}

class DummyCancelable : Cancelable {
    var isDisposed: Bool = false
}

class DummyScheduler : SchedulerType {
    var now: RxTime = Date()
}

class ViewController: UIViewController {
    
    private var sink: ObserveOnSerialDispatchQueueSink<DummyObserver>!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let scheduler = DummyScheduler()
        self.sink = ObserveOnSerialDispatchQueueSink<DummyObserver>(scheduler: scheduler,
                                                                    observer: DummyObserver(),
                                                                    cancel: DummyCancelable())
    }


}

