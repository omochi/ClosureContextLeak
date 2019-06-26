import UIKit

public protocol Cancelable {
    var isDisposed: Bool { get }
}

final private class ObserveOnSerialDispatchQueueSink {
    let cancel: Cancelable
    
    var cachedScheduleLambda: ((ObserveOnSerialDispatchQueueSink) -> Void)!
    
    init(cancel: Cancelable) {
        self.cancel = cancel
        
        self.cachedScheduleLambda = { (sink) in
            guard !cancel.isDisposed else { return }
            
            return
        }
    }
}

class DummyCancelable : Cancelable {
    var isDisposed: Bool { return false }
}

class ViewController: UIViewController {
    private var sink: ObserveOnSerialDispatchQueueSink!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.sink = ObserveOnSerialDispatchQueueSink(cancel: DummyCancelable())
    }
}

