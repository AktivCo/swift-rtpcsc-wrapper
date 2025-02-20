import RtPcsc


// The RtPcscWrapper class provides an interface for interacting with smart card readers and handling NFC sessions
public actor RtPcscWrapper {
    private enum PcscError: UInt32 {
        case noError = 0x00000000
        case cancelled = 0x80100002
        case noReaders = 0x8010002E

        var int32Value: Int32 {
            return Int32(bitPattern: self.rawValue)
        }
    }

    private let newReaderNotification = "\\\\?PnP?\\Notification"
    private var context: SCARDCONTEXT?

    public init() {}

    // MARK: Public functions

    /// Starts the NFC scanning session
    /// - Parameters:
    ///   - readerName: Name of the reader where the NFC scanning session has to be created
    ///   - waitMessage: A message that will appear on the NFC scanning view until token is brought to the scanner
    ///   - workMessage: A message that will appear on the NFC scanning view during connection with token
    /// - Returns: AsyncStream that publishes current NfcSearchStatus
    public func startNfcExchange(onReader readerName: String,
                                 waitMessage: String,
                                 workMessage: String) async -> AsyncStream<RtNfcSearchStatus> {
        return AsyncStream { continuation in
            Task.detached { [unowned self] in
                defer { continuation.finish() }
                do {
                    try await startNfc(onReader: readerName, waitMessage: waitMessage, workMessage: workMessage)
                    continuation.yield(.inProgress)
                    try await nfcExchangeIsStopped(for: readerName)
                    continuation.yield(.exchangeIsCompleted)
                } catch let error as RtReaderError {
                    continuation.yield(.exchangeIsStopped(error))
                } catch {
                    continuation.yield(.exchangeIsStopped(.unknown))
                }
            }
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

    /// Returns a remaining time of when the NFC reader will be ready to search token again
    /// - Parameter readerName: Name of the reader where the NFC reader
    /// - Returns: Remaining time in seconds
    public func getNfcCooldown(for readerName: String) throws -> UInt {
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

        var result = UInt8(0)
        var resultLen: DWORD = 0
        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_NFC_COOLDOWN), nil,
                                              0, &result, 1, &resultLen) else {
            throw RtReaderError.unknown
        }

        return UInt(result)
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
    /// - Returns: An AsyncStream of available readers or nil if the readers observer is already active
    public func start() -> AsyncStream<[RtReader]>? {
        guard context == nil else {
            return nil
        }

        var ctx = SCARDCONTEXT()
        guard SCardEstablishContext(DWORD(SCARD_SCOPE_USER), nil, nil, &ctx) == PcscError.noError.int32Value else {
            fatalError("Unable to create SCardEstablishContext")
        }
        context = ctx

        return AsyncStream { continuation in
            Task.detached { [unowned self] in
                var readerStates = StatesHolder(states: [])

                var newReaderState = SCARD_READERSTATE()
                newReaderState.szReader = RtPcscWrapper.allocatePointerForString(newReaderNotification)
                newReaderState.dwCurrentState = await DWORD(readerStates.count() << 16)
                await readerStates.append(newReaderState)

                while true {
                    guard let ctx = await context else {
                        continuation.finish()
                        return
                    }
                    let rv = await readerStates.ScardGetStatusChangeA(ctx: ctx, dwTimeout: INFINITE)
                    guard rv != PcscError.cancelled.int32Value else {
                        continuation.finish()
                        return
                    }
                    guard rv == PcscError.noError.int32Value else { continue }

                    let isAddedNewReader: (SCARD_READERSTATE) -> Bool = { [newReaderNotification] state in
                        String(cString: state.szReader) == newReaderNotification &&
                        state.dwEventState & UInt32(SCARD_STATE_CHANGED) != 0
                    }

                    let isIgnoredReader: (SCARD_READERSTATE) -> Bool = {
                        $0.dwEventState == SCARD_STATE_UNKNOWN | SCARD_STATE_CHANGED | SCARD_STATE_IGNORE
                    }

                    if await readerStates.contains(predicate: { isAddedNewReader($0) || isIgnoredReader($0) }) {
                        let readerNames = await getReaderList()
                        continuation.yield(await mapReaderNames(readerNames: readerNames))
                        readerStates = await getReaderStates(for: readerNames)

                        var newReaderState = SCARD_READERSTATE()
                        newReaderState.szReader = RtPcscWrapper.allocatePointerForString(newReaderNotification)
                        newReaderState.dwCurrentState = await DWORD(readerStates.count() << 16)
                        await readerStates.append(newReaderState)
                    }
                    await readerStates.map { oldState in
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

    /// Returns a reason why the NFC scanning session got canceled
    /// - Parameter readerName: Name of the reader where the NFC scanning was suspended
    /// - Returns: Error that contains the actual reason
    public func getLastNfcStopReason(onReader readerName: String) throws -> RtNfcStopReason {
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
        return RtNfcStopReason(rawValue: RtPcscWrapper.getLastNfcStopReason(ofHandle: handle)) ?? .unknown
    }

    /// Returns VCR fingerprint related to connected application
    /// - Parameter readerName: Name of the VCR
    /// - Returns: Fingerprint for current VCR connection
    public func getFingerprint(for readerName: String) throws -> Data {
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

        var resultLen: DWORD = 0
        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_VCR_FINGERPRINT), nil,
                                              0, nil, 0, &resultLen) else {
            throw RtReaderError.unknown
        }

        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(resultLen))
        defer {
            pointer.deallocate()
        }

        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_VCR_FINGERPRINT), nil,
                                              0, pointer, DWORD(resultLen), &resultLen) else {
            throw RtReaderError.unknown
        }

        return Data(bytes: pointer, count: Int(resultLen))
    }

    // MARK: Private functions

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

    private func getReaderStates(for readerNames: [String]) async -> StatesHolder {
        guard let ctx = self.context else {
            return StatesHolder(states: [])
        }

        guard !readerNames.isEmpty else {
            return StatesHolder(states: [])
        }

        let states: [SCARD_READERSTATE] = readerNames.map { name in
            var state = SCARD_READERSTATE()
            state.szReader = RtPcscWrapper.allocatePointerForString(name)
            state.dwCurrentState = DWORD(SCARD_STATE_UNAWARE)
            return state
        }

        let holder = StatesHolder(states: states)
        guard await holder.ScardGetStatusChangeA(ctx: ctx, dwTimeout: 0) == PcscError.noError.int32Value else {
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

    /// Notifies about suspension of the NFC scanning session
    /// - Parameter readerName: Name of the reader where the NFC scanning session was created
    /// - Returns: Nothing when NFC session ends successfully and NFC reader state changed to muted
    /// - or throws an error if user cancelled NFC or reader is unavallable
    ///
    /// The "Muted" state means that the NFC reader doesn't have present searching session and doesn't have any available tokens too.
    ///
    /// This function is necessary because of race condition between `PKCS token observer` and `StartNfc` function from the wrapper.
    /// On the one side `StartNfc` is a blocking function that waits for token appearance. On the other side user can get token out from the NFC
    /// scanner before PKCS finds the token. In this case we have to wait until the NFC scanning session gets suspended or user brings the token back.
    private func nfcExchangeIsStopped(for readerName: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                var state = SCARD_READERSTATE()
                state.szReader = (readerName as NSString).utf8String
                state.dwCurrentState = DWORD(SCARD_STATE_EMPTY)

                guard let ctx = await self.context else {
                    continuation.resume(throwing: RtReaderError.invalidContext)
                    return
                }

                repeat {
                    state.dwEventState = 0

                    guard SCARD_S_SUCCESS == SCardGetStatusChangeA(ctx, INFINITE, &state, 1) else {
                        continuation.resume(throwing: RtReaderError.readerUnavailable)
                        return
                    }

                    state.dwCurrentState = state.dwEventState & ~DWORD(SCARD_STATE_CHANGED)
                } while (state.dwEventState & DWORD(SCARD_STATE_MUTE)) != SCARD_STATE_MUTE
                continuation.resume(returning: ())
            }
        }
    }

    /// Creates the NFC scanning session
    /// - Parameters:
    ///   - readerName: Name of the reader where the NFC scanning session has to be created
    ///   - waitMessage: A message that will appear on the NFC scanning view until token is brought to the scanner
    ///   - workMessage: A message that will appear on the NFC scanning view during connection with token
    private func startNfc(onReader readerName: String, waitMessage: String, workMessage: String) throws {
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
            throw RtReaderError.unknown
        }

        // Global SCardGetStatusChange loop can request reader types with SCardConnect call.
        // In this case we can receive events for NFC/VCR reader and should continue waiting for changing of slot state.
        repeat {
            guard SCARD_S_SUCCESS == SCardGetStatusChangeA(ctx, INFINITE, &state, 1) else {
                throw RtReaderError.readerUnavailable
            }
        } while state.dwEventState == SCARD_STATE_EMPTY

        guard (SCARD_STATE_PRESENT | SCARD_STATE_CHANGED | SCARD_STATE_INUSE) == state.dwEventState else {
            let res = RtPcscWrapper.getLastNfcStopReason(ofHandle: handle)
            if let reason = RtNfcStopReason(rawValue: res) {
                throw RtReaderError.nfcIsStopped(reason)
            }
            throw RtReaderError.nfcIsStopped(.unknown)
        }
    }

    private func mapReaderNames(readerNames: [String]) -> [RtReader] {
        readerNames.map { RtReader(name: $0, type: getReaderType(for: $0)) }
    }
}

extension RtPcscWrapper {
    static private func getLastNfcStopReason(ofHandle handle: SCARDHANDLE) -> UInt8 {
        var result = UInt8(0)
        var resultLen: DWORD = 0
        guard SCARD_S_SUCCESS == SCardControl(handle, DWORD(RUTOKEN_CONTROL_CODE_LAST_NFC_STOP_REASON), nil,
                                              0, &result, 1, &resultLen) else {
            return RUTOKEN_NFC_STOP_REASON_UNKNOWN
        }
        return result
    }

    static private func allocatePointerForString(_ str: String) -> UnsafePointer<Int8> {
        let toRawString = str + "\0"
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Int8>.stride*toRawString.utf8.count,
                                                          alignment: MemoryLayout<Int8>.alignment)
        return UnsafePointer(rawPointer.initializeMemory(as: Int8.self, from: toRawString, count: toRawString.utf8.count))
    }
}
