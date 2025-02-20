//
//  RtNfcSearchStatus.swift
//  rt-pcsc-wrapper
//
//  Created by Никита Девятых on 24.02.2025.
//

/// Current NFC session status
public enum RtNfcSearchStatus: Sendable {
    /// The NFC session is active
    case inProgress
    /// The NFC session finished with error
    ///  - Parameter RtReaderError: The reason why NFC session has been stopped
    case exchangeIsStopped(RtReaderError)
    /// The NFC session finished succesfully
    case exchangeIsCompleted
}
