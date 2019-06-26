import UIKit

public enum Event<Element> {
    /// Next element is produced.
    case next(Element)
    
    /// Sequence terminated with an error.
    case error(Swift.Error)
    
    /// Sequence completed successfully.
    case completed
}
extension Event {
    /// Is `completed` or `error` event.
    public var isStopEvent: Bool {
        switch self {
        case .next: return false
        case .error, .completed: return true
        }
    }
    
    /// If `next` event, returns element value.
    public var element: Element? {
        if case .next(let value) = self {
            return value
        }
        return nil
    }
    
    /// If `error` event, returns error.
    public var error: Swift.Error? {
        if case .error(let error) = self {
            return error
        }
        return nil
    }
    
    /// If `completed` event, returns `true`.
    public var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

public protocol Disposable {
    /// Dispose resource.
    func dispose()
}

public protocol ObserverType {
    /// The type of elements in sequence that observer can observe.
    associatedtype Element
    
    @available(*, deprecated, message: "Use `Element` instead.")
    typealias E = Element
    
    /// Notify observer about sequence event.
    ///
    /// - parameter event: Event that occurred.
    func on(_ event: Event<Element>)
}

final class AtomicInt: NSLock {
    fileprivate var value: Int32
    public init(_ value: Int32 = 0) {
        self.value = value
    }
}

@discardableResult
@inline(__always)
func fetchOr(_ this: AtomicInt, _ mask: Int32) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.value |= mask
    this.unlock()
    return oldValue
}

@inline(__always)
func load(_ this: AtomicInt) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.unlock()
    return oldValue
}

@inline(__always)
func isFlagSet(_ this: AtomicInt, _ mask: Int32) -> Bool {
    return (load(this) & mask) != 0
}


func rxFatalError(_ lastMessage: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) -> Swift.Never  {
    fatalError(lastMessage(), file: file, line: line)
}

func rxAbstractMethod(file: StaticString = #file, line: UInt = #line) -> Swift.Never {
    rxFatalError("Abstract method", file: file, line: line)
}

class ObserverBase<Element> : Disposable, ObserverType {
    private let _isStopped = AtomicInt(0)
    
    func on(_ event: Event<Element>) {
        switch event {
        case .next:
            if load(self._isStopped) == 0 {
                self.onCore(event)
            }
        case .error, .completed:
            if fetchOr(self._isStopped, 1) == 0 {
                self.onCore(event)
            }
        }
    }
    
    func onCore(_ event: Event<Element>) {
        rxAbstractMethod()
    }
    
    func dispose() {
        fetchOr(self._isStopped, 1)
    }
}

public protocol ImmediateSchedulerType {
    /**
     Schedules an action to be executed immediately.
     
     - parameter state: State passed to the action to be executed.
     - parameter action: Action to be executed.
     - returns: The disposable object used to cancel the scheduled action (best effort).
     */
    func schedule<StateType>(_ state: StateType, action: @escaping (StateType) -> Disposable) -> Disposable
}
public typealias RxTime = Date
public typealias RxTimeInterval = DispatchTimeInterval

public protocol SchedulerType: ImmediateSchedulerType {
    
    /// - returns: Current time.
    var now : RxTime {
        get
    }
    
    /**
     Schedules an action to be executed.
     
     - parameter state: State passed to the action to be executed.
     - parameter dueTime: Relative time after which to execute the action.
     - parameter action: Action to be executed.
     - returns: The disposable object used to cancel the scheduled action (best effort).
     */
    func scheduleRelative<StateType>(_ state: StateType, dueTime: RxTimeInterval, action: @escaping (StateType) -> Disposable) -> Disposable
    
    /**
     Schedules a periodic piece of work.
     
     - parameter state: State passed to the action to be executed.
     - parameter startAfter: Period after which initial work should be run.
     - parameter period: Period for running the work periodically.
     - parameter action: Action to be executed.
     - returns: The disposable object used to cancel the scheduled action (best effort).
     */
    func schedulePeriodic<StateType>(_ state: StateType, startAfter: RxTimeInterval, period: RxTimeInterval, action: @escaping (StateType) -> StateType) -> Disposable
}
public class DisposeBase {
    init() {
        #if TRACE_RESOURCES
        _ = Resources.incrementTotal()
        #endif
    }
    
    deinit {
        #if TRACE_RESOURCES
        _ = Resources.decrementTotal()
        #endif
    }
}

public protocol Cancelable : Disposable {
    /// Was resource disposed.
    var isDisposed: Bool { get }
}

public final class SingleAssignmentDisposable : DisposeBase, Cancelable {
    
    fileprivate enum DisposeState: Int32 {
        case disposed = 1
        case disposableSet = 2
    }
    
    // state
    private let _state = AtomicInt(0)
    private var _disposable = nil as Disposable?
    
    /// - returns: A value that indicates whether the object is disposed.
    public var isDisposed: Bool {
        return isFlagSet(self._state, DisposeState.disposed.rawValue)
    }
    
    /// Initializes a new instance of the `SingleAssignmentDisposable`.
    public override init() {
        super.init()
    }
    
    /// Gets or sets the underlying disposable. After disposal, the result of getting this property is undefined.
    ///
    /// **Throws exception if the `SingleAssignmentDisposable` has already been assigned to.**
    public func setDisposable(_ disposable: Disposable) {
        self._disposable = disposable
        
        let previousState = fetchOr(self._state, DisposeState.disposableSet.rawValue)
        
        if (previousState & DisposeState.disposableSet.rawValue) != 0 {
            rxFatalError("oldState.disposable != nil")
        }
        
        if (previousState & DisposeState.disposed.rawValue) != 0 {
            disposable.dispose()
            self._disposable = nil
        }
    }
    
    /// Disposes the underlying disposable.
    public func dispose() {
        let previousState = fetchOr(self._state, DisposeState.disposed.rawValue)
        
        if (previousState & DisposeState.disposed.rawValue) != 0 {
            return
        }
        
        if (previousState & DisposeState.disposableSet.rawValue) != 0 {
            guard let disposable = self._disposable else {
                rxFatalError("Disposable not set")
            }
            disposable.dispose()
            self._disposable = nil
        }
    }
    
}


struct BagKey {
    /**
     Unique identifier for object added to `Bag`.
     
     It's underlying type is UInt64. If we assume there in an idealized CPU that works at 4GHz,
     it would take ~150 years of continuous running time for it to overflow.
     */
    fileprivate let rawValue: UInt64
}
typealias RecursiveLock = NSRecursiveLock
typealias SpinLock = RecursiveLock
let arrayDictionaryMaxSize = 30
struct Bag<T> : CustomDebugStringConvertible {
    /// Type of identifier for inserted elements.
    typealias KeyType = BagKey
    
    typealias Entry = (key: BagKey, value: T)
    
    fileprivate var _nextKey: BagKey = BagKey(rawValue: 0)
    
    // data
    
    // first fill inline variables
    var _key0: BagKey?
    var _value0: T?
    
    // then fill "array dictionary"
    var _pairs = ContiguousArray<Entry>()
    
    // last is sparse dictionary
    var _dictionary: [BagKey: T]?
    
    var _onlyFastPath = true
    
    /// Creates new empty `Bag`.
    init() {
    }
    
    /**
     Inserts `value` into bag.
     
     - parameter element: Element to insert.
     - returns: Key that can be used to remove element from bag.
     */
    mutating func insert(_ element: T) -> BagKey {
        let key = _nextKey
        
        _nextKey = BagKey(rawValue: _nextKey.rawValue &+ 1)
        
        if _key0 == nil {
            _key0 = key
            _value0 = element
            return key
        }
        
        _onlyFastPath = false
        
        if _dictionary != nil {
            _dictionary![key] = element
            return key
        }
        
        if _pairs.count < arrayDictionaryMaxSize {
            _pairs.append((key: key, value: element))
            return key
        }
        
        _dictionary = [key: element]
        
        return key
    }
    
    /// - returns: Number of elements in bag.
    var count: Int {
        let dictionaryCount: Int = _dictionary?.count ?? 0
        return (_value0 != nil ? 1 : 0) + _pairs.count + dictionaryCount
    }
    
    /// Removes all elements from bag and clears capacity.
    mutating func removeAll() {
        _key0 = nil
        _value0 = nil
        
        _pairs.removeAll(keepingCapacity: false)
        _dictionary?.removeAll(keepingCapacity: false)
    }
    
    /**
     Removes element with a specific `key` from bag.
     
     - parameter key: Key that identifies element to remove from bag.
     - returns: Element that bag contained, or nil in case element was already removed.
     */
    mutating func removeKey(_ key: BagKey) -> T? {
        if _key0 == key {
            _key0 = nil
            let value = _value0!
            _value0 = nil
            return value
        }
        
        if let existingObject = _dictionary?.removeValue(forKey: key) {
            return existingObject
        }
        
        for i in 0 ..< _pairs.count where _pairs[i].key == key {
            let value = _pairs[i].value
            _pairs.remove(at: i)
            return value
        }
        
        return nil
    }
}
func disposeAll(in bag: Bag<Disposable>) {
    bag._value0?.dispose()
    
    if bag._onlyFastPath {
        return
    }
    
    let pairs = bag._pairs
    for i in 0 ..< pairs.count {
        pairs[i].value.dispose()
    }
    
    if let dictionary = bag._dictionary {
        for element in dictionary.values {
            element.dispose()
        }
    }
}
extension Bag {
    /// A textual representation of `self`, suitable for debugging.
    var debugDescription : String {
        return "\(self.count) elements in Bag"
    }
}

extension Bag {
    /// Enumerates elements inside the bag.
    ///
    /// - parameter action: Enumeration closure.
    func forEach(_ action: (T) -> Void) {
        if _onlyFastPath {
            if let value0 = _value0 {
                action(value0)
            }
            return
        }
        
        let value0 = _value0
        let dictionary = _dictionary
        
        if let value0 = value0 {
            action(value0)
        }
        
        for i in 0 ..< _pairs.count {
            action(_pairs[i].value)
        }
        
        if dictionary?.count ?? 0 > 0 {
            for element in dictionary!.values {
                action(element)
            }
        }
    }
}

extension BagKey: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

func ==(lhs: BagKey, rhs: BagKey) -> Bool {
    return lhs.rawValue == rhs.rawValue
}

public final class CompositeDisposable : DisposeBase, Cancelable {
    /// Key used to remove disposable from composite disposable
    public struct DisposeKey {
        fileprivate let key: BagKey
        fileprivate init(key: BagKey) {
            self.key = key
        }
    }
    
    private var _lock = SpinLock()
    
    // state
    private var _disposables: Bag<Disposable>? = Bag()
    
    public var isDisposed: Bool {
        self._lock.lock(); defer { self._lock.unlock() }
        return self._disposables == nil
    }
    
    public override init() {
    }
    
    /// Initializes a new instance of composite disposable with the specified number of disposables.
    public init(_ disposable1: Disposable, _ disposable2: Disposable) {
        // This overload is here to make sure we are using optimized version up to 4 arguments.
        _ = self._disposables!.insert(disposable1)
        _ = self._disposables!.insert(disposable2)
    }
    
    /// Initializes a new instance of composite disposable with the specified number of disposables.
    public init(_ disposable1: Disposable, _ disposable2: Disposable, _ disposable3: Disposable) {
        // This overload is here to make sure we are using optimized version up to 4 arguments.
        _ = self._disposables!.insert(disposable1)
        _ = self._disposables!.insert(disposable2)
        _ = self._disposables!.insert(disposable3)
    }
    
    /// Initializes a new instance of composite disposable with the specified number of disposables.
    public init(_ disposable1: Disposable, _ disposable2: Disposable, _ disposable3: Disposable, _ disposable4: Disposable, _ disposables: Disposable...) {
        // This overload is here to make sure we are using optimized version up to 4 arguments.
        _ = self._disposables!.insert(disposable1)
        _ = self._disposables!.insert(disposable2)
        _ = self._disposables!.insert(disposable3)
        _ = self._disposables!.insert(disposable4)
        
        for disposable in disposables {
            _ = self._disposables!.insert(disposable)
        }
    }
    
    /// Initializes a new instance of composite disposable with the specified number of disposables.
    public init(disposables: [Disposable]) {
        for disposable in disposables {
            _ = self._disposables!.insert(disposable)
        }
    }
    
    /**
     Adds a disposable to the CompositeDisposable or disposes the disposable if the CompositeDisposable is disposed.
     
     - parameter disposable: Disposable to add.
     - returns: Key that can be used to remove disposable from composite disposable. In case dispose bag was already
     disposed `nil` will be returned.
     */
    public func insert(_ disposable: Disposable) -> DisposeKey? {
        let key = self._insert(disposable)
        
        if key == nil {
            disposable.dispose()
        }
        
        return key
    }
    
    private func _insert(_ disposable: Disposable) -> DisposeKey? {
        self._lock.lock(); defer { self._lock.unlock() }
        
        let bagKey = self._disposables?.insert(disposable)
        return bagKey.map(DisposeKey.init)
    }
    
    /// - returns: Gets the number of disposables contained in the `CompositeDisposable`.
    public var count: Int {
        self._lock.lock(); defer { self._lock.unlock() }
        return self._disposables?.count ?? 0
    }
    
    /// Removes and disposes the disposable identified by `disposeKey` from the CompositeDisposable.
    ///
    /// - parameter disposeKey: Key used to identify disposable to be removed.
    public func remove(for disposeKey: DisposeKey) {
        self._remove(for: disposeKey)?.dispose()
    }
    
    private func _remove(for disposeKey: DisposeKey) -> Disposable? {
        self._lock.lock(); defer { self._lock.unlock() }
        return self._disposables?.removeKey(disposeKey.key)
    }
    
    /// Disposes all disposables in the group and removes them from the group.
    public func dispose() {
        if let disposables = self._dispose() {
            disposeAll(in: disposables)
        }
    }
    
    private func _dispose() -> Bag<Disposable>? {
        self._lock.lock(); defer { self._lock.unlock() }
        
        let disposeBag = self._disposables
        self._disposables = nil
        
        return disposeBag
    }
}

struct DispatchQueueConfiguration {
    let queue: DispatchQueue
    let leeway: DispatchTimeInterval
}
public struct Disposables {
    private init() {}
}
fileprivate final class AnonymousDisposable : DisposeBase, Cancelable {
    public typealias DisposeAction = () -> Void
    
    private let _isDisposed = AtomicInt(0)
    private var _disposeAction: DisposeAction?
    
    /// - returns: Was resource disposed.
    public var isDisposed: Bool {
        return isFlagSet(self._isDisposed, 1)
    }
    
    /// Constructs a new disposable with the given action used for disposal.
    ///
    /// - parameter disposeAction: Disposal action which will be run upon calling `dispose`.
    fileprivate init(_ disposeAction: @escaping DisposeAction) {
        self._disposeAction = disposeAction
        super.init()
    }
    
    // Non-deprecated version of the constructor, used by `Disposables.create(with:)`
    fileprivate init(disposeAction: @escaping DisposeAction) {
        self._disposeAction = disposeAction
        super.init()
    }
    
    /// Calls the disposal action if and only if the current instance hasn't been disposed yet.
    ///
    /// After invoking disposal action, disposal action will be dereferenced.
    fileprivate func dispose() {
        if fetchOr(self._isDisposed, 1) == 0 {
            if let action = self._disposeAction {
                self._disposeAction = nil
                action()
            }
        }
    }
}
extension Disposables {
    
    /// Constructs a new disposable with the given action used for disposal.
    ///
    /// - parameter dispose: Disposal action which will be run upon calling `dispose`.
    public static func create(with dispose: @escaping () -> Void) -> Cancelable {
        return AnonymousDisposable(disposeAction: dispose)
    }
    
}
extension DispatchQueueConfiguration {
    func schedule<StateType>(_ state: StateType, action: @escaping (StateType) -> Disposable) -> Disposable {
        let cancel = SingleAssignmentDisposable()
        
        self.queue.async {
            if cancel.isDisposed {
                return
            }
            
            
            cancel.setDisposable(action(state))
        }
        
        return cancel
    }
    
    func scheduleRelative<StateType>(_ state: StateType, dueTime: RxTimeInterval, action: @escaping (StateType) -> Disposable) -> Disposable {
        let deadline = DispatchTime.now() + dueTime
        
        let compositeDisposable = CompositeDisposable()
        
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: deadline, leeway: self.leeway)
        
        // TODO:
        // This looks horrible, and yes, it is.
        // It looks like Apple has made a conceputal change here, and I'm unsure why.
        // Need more info on this.
        // It looks like just setting timer to fire and not holding a reference to it
        // until deadline causes timer cancellation.
        var timerReference: DispatchSourceTimer? = timer
        let cancelTimer = Disposables.create {
            timerReference?.cancel()
            timerReference = nil
        }
        
        timer.setEventHandler(handler: {
            if compositeDisposable.isDisposed {
                return
            }
            _ = compositeDisposable.insert(action(state))
            cancelTimer.dispose()
        })
        timer.resume()
        
        _ = compositeDisposable.insert(cancelTimer)
        
        return compositeDisposable
    }
    
    func schedulePeriodic<StateType>(_ state: StateType, startAfter: RxTimeInterval, period: RxTimeInterval, action: @escaping (StateType) -> StateType) -> Disposable {
        let initial = DispatchTime.now() + startAfter
        
        var timerState = state
        
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: initial, repeating: period, leeway: self.leeway)
        
        // TODO:
        // This looks horrible, and yes, it is.
        // It looks like Apple has made a conceputal change here, and I'm unsure why.
        // Need more info on this.
        // It looks like just setting timer to fire and not holding a reference to it
        // until deadline causes timer cancellation.
        var timerReference: DispatchSourceTimer? = timer
        let cancelTimer = Disposables.create {
            timerReference?.cancel()
            timerReference = nil
        }
        
        timer.setEventHandler(handler: {
            if cancelTimer.isDisposed {
                return
            }
            timerState = action(timerState)
        })
        timer.resume()
        
        return cancelTimer
    }
}
public class SerialDispatchQueueScheduler : SchedulerType {
    public typealias TimeInterval = Foundation.TimeInterval
    public typealias Time = Date
    
    /// - returns: Current time.
    public var now : Date {
        return Date()
    }
    
    let configuration: DispatchQueueConfiguration
    
    /**
     Constructs new `SerialDispatchQueueScheduler` that wraps `serialQueue`.
     
     - parameter serialQueue: Target dispatch queue.
     - parameter leeway: The amount of time, in nanoseconds, that the system will defer the timer.
     */
    init(serialQueue: DispatchQueue, leeway: DispatchTimeInterval = DispatchTimeInterval.nanoseconds(0)) {
        self.configuration = DispatchQueueConfiguration(queue: serialQueue, leeway: leeway)
    }
    
    /**
     Constructs new `SerialDispatchQueueScheduler` with internal serial queue named `internalSerialQueueName`.
     
     Additional dispatch queue properties can be set after dispatch queue is created using `serialQueueConfiguration`.
     
     - parameter internalSerialQueueName: Name of internal serial dispatch queue.
     - parameter serialQueueConfiguration: Additional configuration of internal serial dispatch queue.
     - parameter leeway: The amount of time, in nanoseconds, that the system will defer the timer.
     */
    public convenience init(internalSerialQueueName: String, serialQueueConfiguration: ((DispatchQueue) -> Void)? = nil, leeway: DispatchTimeInterval = DispatchTimeInterval.nanoseconds(0)) {
        let queue = DispatchQueue(label: internalSerialQueueName, attributes: [])
        serialQueueConfiguration?(queue)
        self.init(serialQueue: queue, leeway: leeway)
    }
    
    /**
     Constructs new `SerialDispatchQueueScheduler` named `internalSerialQueueName` that wraps `queue`.
     
     - parameter queue: Possibly concurrent dispatch queue used to perform work.
     - parameter internalSerialQueueName: Name of internal serial dispatch queue proxy.
     - parameter leeway: The amount of time, in nanoseconds, that the system will defer the timer.
     */
    public convenience init(queue: DispatchQueue, internalSerialQueueName: String, leeway: DispatchTimeInterval = DispatchTimeInterval.nanoseconds(0)) {
        // Swift 3.0 IUO
        let serialQueue = DispatchQueue(label: internalSerialQueueName,
                                        attributes: [],
                                        target: queue)
        self.init(serialQueue: serialQueue, leeway: leeway)
    }
    
    /**
     Constructs new `SerialDispatchQueueScheduler` that wraps on of the global concurrent dispatch queues.
     
     - parameter qos: Identifier for global dispatch queue with specified quality of service class.
     - parameter internalSerialQueueName: Custom name for internal serial dispatch queue proxy.
     - parameter leeway: The amount of time, in nanoseconds, that the system will defer the timer.
     */
    @available(iOS 8, OSX 10.10, *)
    public convenience init(qos: DispatchQoS, internalSerialQueueName: String = "rx.global_dispatch_queue.serial", leeway: DispatchTimeInterval = DispatchTimeInterval.nanoseconds(0)) {
        self.init(queue: DispatchQueue.global(qos: qos.qosClass), internalSerialQueueName: internalSerialQueueName, leeway: leeway)
    }
    
    /**
     Schedules an action to be executed immediately.
     
     - parameter state: State passed to the action to be executed.
     - parameter action: Action to be executed.
     - returns: The disposable object used to cancel the scheduled action (best effort).
     */
    public final func schedule<StateType>(_ state: StateType, action: @escaping (StateType) -> Disposable) -> Disposable {
        return self.scheduleInternal(state, action: action)
    }
    
    func scheduleInternal<StateType>(_ state: StateType, action: @escaping (StateType) -> Disposable) -> Disposable {
        return self.configuration.schedule(state, action: action)
    }
    
    /**
     Schedules an action to be executed.
     
     - parameter state: State passed to the action to be executed.
     - parameter dueTime: Relative time after which to execute the action.
     - parameter action: Action to be executed.
     - returns: The disposable object used to cancel the scheduled action (best effort).
     */
    public final func scheduleRelative<StateType>(_ state: StateType, dueTime: RxTimeInterval, action: @escaping (StateType) -> Disposable) -> Disposable {
        return self.configuration.scheduleRelative(state, dueTime: dueTime, action: action)
    }
    
    /**
     Schedules a periodic piece of work.
     
     - parameter state: State passed to the action to be executed.
     - parameter startAfter: Period after which initial work should be run.
     - parameter period: Period for running the work periodically.
     - parameter action: Action to be executed.
     - returns: The disposable object used to cancel the scheduled action (best effort).
     */
    public func schedulePeriodic<StateType>(_ state: StateType, startAfter: RxTimeInterval, period: RxTimeInterval, action: @escaping (StateType) -> StateType) -> Disposable {
        return self.configuration.schedulePeriodic(state, startAfter: startAfter, period: period, action: action)
    }
}
fileprivate struct NopDisposable : Disposable {
    
    fileprivate static let noOp: Disposable = NopDisposable()
    
    fileprivate init() {
        
    }
    
    /// Does nothing.
    public func dispose() {
    }
}

extension Disposables {
    /**
     Creates a disposable that does nothing on disposal.
     */
    static public func create() -> Disposable {
        return NopDisposable.noOp
    }
}

final private class ObserveOnSerialDispatchQueueSink<Observer: ObserverType>: ObserverBase<Observer.Element> {
    let scheduler: SerialDispatchQueueScheduler
    let observer: Observer
    
    let cancel: Cancelable
    
    var cachedScheduleLambda: (((sink: ObserveOnSerialDispatchQueueSink<Observer>, event: Event<Element>)) -> Disposable)!
    
    init(scheduler: SerialDispatchQueueScheduler, observer: Observer, cancel: Cancelable) {
        self.scheduler = scheduler
        self.observer = observer
        self.cancel = cancel
        super.init()
        
        self.cachedScheduleLambda = { pair in
            guard !cancel.isDisposed else { return Disposables.create() }
            
            pair.sink.observer.on(pair.event)
            
            if pair.event.isStopEvent {
                pair.sink.dispose()
            }
            
            return Disposables.create()
        }
    }
}

class DummyObserver : ObserverType {
    func on(_ event: Event<Int>) {
        
    }
    
    typealias Element = Int
    
    
}

class DummyCancelable : Cancelable {
    var isDisposed: Bool = false
    
    func dispose() {
        isDisposed = true
    }
    
    
    
}

class ViewController: UIViewController {
    
    private var sink: ObserveOnSerialDispatchQueueSink<DummyObserver>!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let scheduler = SerialDispatchQueueScheduler(serialQueue: .main)
        self.sink = ObserveOnSerialDispatchQueueSink<DummyObserver>(scheduler: scheduler, observer: DummyObserver(), cancel: DummyCancelable())
    }


}

