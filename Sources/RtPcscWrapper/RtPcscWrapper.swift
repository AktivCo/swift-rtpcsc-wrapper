import Combine

import RtPcsc


public enum RtReaderError: Error {
    case unknown
    case readerUnavailable
    case invalidContext
    case nfcIsStopped(RtNfcStopReason)
}

public enum RtNfcStopReason: UInt8 {
    case finished = 0x00
    case unknown = 0x01
    case timeout = 0x02
    case cancelledByUser = 0x03
    case noError = 0x04
    case unsupportedDevice = 0x05
}

public enum RtReaderType {
    case unknown
    case bt
    case nfc
    case vcr
    case usb
}

public struct RtReader: Identifiable {
    public var id = UUID()

    public let name: String
    public let type: RtReaderType
}

public class RtPcscWrapper {
    private enum PcscError: UInt32 {
        case noError = 0x00000000
        case cancelled = 0x80100002
        case noReaders = 0x8010002E

        var int32Value: Int32 {
            return Int32(bitPattern: self.rawValue)
        }
    }

    private class StatesHolder {
        var states: [SCARD_READERSTATE]

        init(states: [SCARD_READERSTATE]) {
            self.states = states
        }

        deinit {
            states.forEach { state in state.szReader.deallocate() }
        }
    }

    private let newReaderNotification = "\\\\?PnP?\\Notification"
    private var context: SCARDCONTEXT?

    private var readersPublisher = CurrentValueSubject<[RtReader], Never>([])
    private var isNfcSearchingActivePublisher = CurrentValueSubject<Bool, Never>(false)

    /// Available readers list publisher
    public var readers: AnyPublisher<[RtReader], Never> {
        readersPublisher.share().eraseToAnyPublisher()
    }

    /// Publisher of the state of the NFC scanning session
    public var isNfcSearchingActive: AnyPublisher<Bool, Never> {
        isNfcSearchingActivePublisher.share().eraseToAnyPublisher()
    }

    public init() {}

    private func getLastNfcStopReason(ofHandle handle: SCARDHANDLE) -> UInt8 {
        var result = UInt8(0)
        var resultLen: DWORD = 0
        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_LAST_NFC_STOP_REASON), nil,
                                              0, &result, 1, &resultLen) else {
            return RUTOKEN_NFC_STOP_REASON_UNKNOWN
        }
        return result
    }

    private func allocatePointerForString(_ str: String) -> UnsafePointer<Int8> {
        let toRawString = str + "\0"
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Int8>.stride*toRawString.utf8.count,
                                                          alignment: MemoryLayout<Int8>.alignment)
        return UnsafePointer(rawPointer.initializeMemory(as: Int8.self, from: toRawString, count: toRawString.utf8.count))
    }

    private func getReaderList() -> [String] {
        guard let ctx = self.context else {
            return []
        }

        var readersLen = DWORD(0)
        var readerNames = [String]()

        let result = SCardListReadersA(ctx, nil, nil, &readersLen)
        guard result == PcscError.noError.int32Value else {
            return []
        }

        var rawReadersName: [Int8] = Array(repeating: Int8(0), count: Int(readersLen))
        guard SCardListReadersA(ctx, nil, &rawReadersName, &readersLen) == PcscError.noError.int32Value else {
            return []
        }

        readerNames = (String(bytes: rawReadersName.map { UInt8($0) }, encoding: .ascii) ?? "")
            .split(separator: Character("\0"))
            .filter { !$0.isEmpty }
            .map { String($0) }

        return readerNames
    }

    private func getReaderStates(for readerNames: [String]) -> StatesHolder {
        guard let ctx = self.context else {
            return StatesHolder(states: [])
        }

        guard !readerNames.isEmpty else {
            return StatesHolder(states: [])
        }

        let states: [SCARD_READERSTATE] = readerNames.map { name in
            var state = SCARD_READERSTATE()
            state.szReader = allocatePointerForString(name)
            state.dwCurrentState = DWORD(SCARD_STATE_UNAWARE)
            return state
        }

        let holder = StatesHolder(states: states)

        guard SCardGetStatusChangeA(ctx, 0, &holder.states, DWORD(holder.states.count)) == PcscError.noError.int32Value else {
            return StatesHolder(states: [])
        }

        return holder
    }

    private func getReaderType(for reader: String) -> RtReaderType {
        guard let ctx = self.context else {
            return .unknown
        }

        var cardHandle = SCARDHANDLE()
        var proto: UInt32 = 0

        guard SCardConnectA(ctx, reader, DWORD(SCARD_SHARE_DIRECT),
                            0, &cardHandle, &proto) == SCARD_S_SUCCESS else {
            return .unknown
        }
        defer {
            SCardDisconnect(cardHandle, 0)
        }

        var attrValue = [RUTOKEN_UNKNOWN_TYPE]
        var attrLength = UInt32(attrValue.count)
        guard SCardGetAttrib(cardHandle,
                             DWORD(SCARD_ATTR_VENDOR_IFD_TYPE),
                             &attrValue,
                             &attrLength) == SCARD_S_SUCCESS else {
            return .unknown
        }

        guard let type = attrValue.first else {
            return .unknown
        }

        switch type {
        case RUTOKEN_BT_TYPE:
            return .bt
        case RUTOKEN_NFC_TYPE:
            return .nfc
        case RUTOKEN_VCR_TYPE:
            return .vcr
        case RUTOKEN_USB_TYPE:
            return .usb
        default:
            return .unknown
        }
    }

    /// Blocking function that waits until the NFC scanning session gets suspended
    /// - Parameter readerName: Name of the reader where the NFC scanning session was created
    ///
    /// This function is necessary because of race condition between `PKCS token observer` and `StartNfc` function from the wrapper.
    /// On the one side `StartNfc` is a blocking function that waits for token appearance. On the other side user can get token out from the NFC
    /// scanner before PKCS finds the token. In this case we have to wait until the NFC scanning session gets suspended or user brings the token back.
    public func waitForExchangeIsOver(withReader readerName: String) throws {
        var state = SCARD_READERSTATE()
        state.szReader = (readerName as NSString).utf8String
        state.dwCurrentState = DWORD(SCARD_STATE_EMPTY)

        guard let ctx = self.context else {
            throw RtReaderError.invalidContext
        }

        defer {
            self.isNfcSearchingActivePublisher.send(false)
        }

        repeat {
            state.dwEventState = 0

            guard SCARD_S_SUCCESS == SCardGetStatusChangeA(ctx, INFINITE, &state, 1) else {
                throw RtReaderError.readerUnavailable
            }

            state.dwCurrentState = state.dwEventState & ~DWORD(SCARD_STATE_CHANGED)
        } while (state.dwEventState & DWORD(SCARD_STATE_MUTE)) != SCARD_STATE_MUTE
    }

    /// Creates publisher that notifies about suspension of the NFC scanning session
    /// - Parameter readerName: Name of the reader where the NFC scanning session was created
    /// - Returns: A publisher  that will notify when the state of the NFC reader changes to muted
    ///
    /// The "Muted" state means that the NFC reader doesn't have present searching session and doesn't have any available tokens too.
    ///
    /// This function is necessary because of race condition between `PKCS token observer` and `StartNfc` function from the wrapper.
    /// On the one side `StartNfc` is a blocking function that waits for token appearance. On the other side user can get token out from the NFC
    /// scanner before PKCS finds the token. In this case we have to wait until the NFC scanning session gets suspended or user brings the token back.
    public func nfcExchangeIsStopped(for readerName: String) -> AnyPublisher<Void, Never> {
        return Deferred {
            Future { promise in
                Task {
                    defer {
                        promise(.success(()))
                    }
                    var state = SCARD_READERSTATE()
                    state.szReader = (readerName as NSString).utf8String
                    state.dwCurrentState = DWORD(SCARD_STATE_EMPTY)

                    guard let ctx = self.context else {
                        throw RtReaderError.invalidContext
                    }

                    repeat {
                        state.dwEventState = 0

                        guard SCARD_S_SUCCESS == SCardGetStatusChangeA(ctx, INFINITE, &state, 1) else {
                            throw RtReaderError.readerUnavailable
                        }

                        state.dwCurrentState = state.dwEventState & ~DWORD(SCARD_STATE_CHANGED)
                    } while (state.dwEventState & DWORD(SCARD_STATE_MUTE)) != SCARD_STATE_MUTE
                }
            }
        }.eraseToAnyPublisher()
    }

    /// Creates the NFC scanning session
    /// - Parameters:
    ///   - readerName: Name of the reader where the NFC scanning session has to be created
    ///   - waitMessage: A message that will appear on the NFC scanning view until token is brought to the scanner
    ///   - workMessage: A message that will appear on the NFC scanning view during connection with token
    public func startNfc(onReader readerName: String, waitMessage: String, workMessage: String) throws {
        guard let ctx = self.context else {
            throw RtReaderError.invalidContext
        }

        var handle = SCARDHANDLE()
        var activeProtocol = DWORD()

        guard SCARD_S_SUCCESS == SCardConnectA(ctx, readerName, DWORD(SCARD_SHARE_DIRECT),
                                               0, &handle, &activeProtocol) else {
            throw RtReaderError.readerUnavailable
        }
        defer {
            SCardDisconnect(handle, 0)
        }

        var state = SCARD_READERSTATE()
        state.szReader = (readerName as NSString).utf8String
        state.dwCurrentState = DWORD(SCARD_STATE_EMPTY)

        let message = "\(waitMessage)\0\(workMessage)\0\0"

        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_START_NFC), (message as NSString).utf8String,
                                              DWORD(message.utf8.count), nil, 0, nil) else {
            throw RtReaderError.readerUnavailable
        }

        isNfcSearchingActivePublisher.send(true)
        // Global SCardGetStatusChange loop can request reader types with SCardConnect call.
        // In this case we can receive events for NFC/VCR reader and should continue waiting for changing of slot state.
        repeat {
            guard SCARD_S_SUCCESS == SCardGetStatusChangeA(ctx, INFINITE, &state, 1) else {
                throw RtReaderError.readerUnavailable
            }
        } while state.dwEventState == SCARD_STATE_EMPTY

        guard (SCARD_STATE_PRESENT | SCARD_STATE_CHANGED | SCARD_STATE_INUSE) == state.dwEventState else {
            let res = getLastNfcStopReason(ofHandle: handle)
            if let reason = RtNfcStopReason(rawValue: res) {
                throw RtReaderError.nfcIsStopped(reason)
            }
            throw RtReaderError.unknown
        }
    }

    /// Suspends the NFC scanning session
    /// - Parameters:
    ///   - readerName: Name of the reader where the NFC scanning has to be suspended
    ///   - message: A message that will appear on the NFC scanning view
    public func stopNfc(onReader readerName: String, withMessage message: String) throws {
        guard let ctx = self.context else {
            throw RtReaderError.invalidContext
        }

        var handle = SCARDHANDLE()
        var activeProtocol = DWORD()

        guard SCARD_S_SUCCESS == SCardConnectA(ctx, readerName, DWORD(SCARD_SHARE_DIRECT),
                                               0, &handle, &activeProtocol) else {
            throw RtReaderError.readerUnavailable
        }
        defer {
            SCardDisconnect(handle, 0)
        }

        var state = SCARD_READERSTATE()
        state.szReader = (readerName as NSString).utf8String
        state.dwCurrentState = DWORD(SCARD_STATE_EMPTY)

        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_STOP_NFC), (message as NSString).utf8String,
                                              DWORD(message.utf8.count), nil, 0, nil) else {
            throw RtReaderError.unknown
        }
    }

    /// Returns a reason why the NFC scanning session got canceled
    /// - Parameter readerName: Name of the reader where the NFC scanning was suspended
    /// - Returns: Error that contains the actual reason
    public func getLastNfcStopReason(onReader readerName: String) throws -> RtReaderError {
        guard let ctx = self.context else {
            throw RtReaderError.invalidContext
        }

        var handle = SCARDHANDLE()
        var activeProtocol = DWORD()

        guard SCARD_S_SUCCESS == SCardConnectA(ctx, readerName, DWORD(SCARD_SHARE_DIRECT),
                                               0, &handle, &activeProtocol) else {
            throw RtReaderError.readerUnavailable
        }
        defer {
            SCardDisconnect(handle, 0)
        }

        if let reason = RtNfcStopReason(rawValue: getLastNfcStopReason(ofHandle: handle)) {
            return RtReaderError.nfcIsStopped(reason)
        }
        return RtReaderError.unknown
    }

    /// Suspend the loop observer for detecting new readers appearance
    public func stop() {
        guard let ctx = context else {
            return
        }

        SCardCancel(ctx)
        SCardReleaseContext(ctx)
        context = nil
    }

    /// Creates the loop observer for detecting new readers appearance
    public func start() {
        guard context == nil else {
            return
        }

        var ctx = SCARDCONTEXT()
        guard SCardEstablishContext(DWORD(SCARD_SCOPE_USER), nil, nil, &ctx) == PcscError.noError.int32Value else {
            fatalError("Unable to create SCardEstablishContext")
        }
        context = ctx

        var readerStates = StatesHolder(states: [])

        var newReaderState = SCARD_READERSTATE()
        newReaderState.szReader = allocatePointerForString(newReaderNotification)
        newReaderState.dwCurrentState = DWORD(readerStates.states.count << 16)
        readerStates.states.append(newReaderState)

        DispatchQueue.global().async { [unowned self] in
            while true {
                guard let ctx = context else {
                    return
                }

                let rv = SCardGetStatusChangeA(ctx,
                                               INFINITE,
                                               &readerStates.states,
                                               DWORD(readerStates.states.count))
                guard rv != PcscError.cancelled.int32Value else { return }
                guard rv == PcscError.noError.int32Value else { continue }

                let isAddedNewReader: (SCARD_READERSTATE) -> Bool = { [newReaderNotification] state in
                      String(cString: state.szReader) == newReaderNotification &&
                      state.dwEventState & UInt32(SCARD_STATE_CHANGED) != 0
                  }

                let isIgnoredReader: (SCARD_READERSTATE) -> Bool = {
                    $0.dwEventState == SCARD_STATE_UNKNOWN | SCARD_STATE_CHANGED | SCARD_STATE_IGNORE
                }

                if readerStates.states.contains(where: { isAddedNewReader($0) || isIgnoredReader($0) }) {
                    let readerNames = getReaderList()
                    readersPublisher.send(readerNames.map { RtReader(name: $0, type: getReaderType(for: $0))})
                    readerStates = getReaderStates(for: readerNames)

                    var newReaderState = SCARD_READERSTATE()
                    newReaderState.szReader = allocatePointerForString(newReaderNotification)
                    newReaderState.dwCurrentState = DWORD(readerStates.states.count << 16)
                    readerStates.states.append(newReaderState)
                }

                readerStates.states = readerStates.states
                    .map { oldState in
                        guard String(cString: oldState.szReader) != newReaderNotification else {
                            return oldState
                        }

                        return SCARD_READERSTATE(szReader: oldState.szReader,
                                                 pvUserData: oldState.pvUserData,
                                                 dwCurrentState: oldState.dwEventState & ~UInt32(SCARD_STATE_CHANGED),
                                                 dwEventState: 0,
                                                 cbAtr: oldState.cbAtr,
                                                 rgbAtr: oldState.rgbAtr)
                    }
            }
        }
    }
}
