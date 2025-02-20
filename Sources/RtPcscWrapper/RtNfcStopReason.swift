//
//  RtNfcStopReason.swift
//  rt-pcsc-wrapper
//
//  Created by Никита Девятых on 24.02.2025.
//

/// Reason why the NFC session was finished
public enum RtNfcStopReason: UInt8, Sendable {
    /// The NFC session finished because method stop was called
    /// and SCardControl was called with parameter RUTOKEN_CONTROL_CODE_STOP_NFC
    case finished = 0x00
    /// The NFC session finished by an unknown reason
    case unknown = 0x01
    /// The NFC session finished due to system timeout
    case timeout = 0x02
    /// The NFC session ended due to user cancellation. For example user pressed cancel button when working with NFC window
    case cancelledByUser = 0x03
    /// The NFC session is still active
    case noError = 0x04
    /// Current device doesn't support working with NFC
    case unsupportedDevice = 0x05
}
