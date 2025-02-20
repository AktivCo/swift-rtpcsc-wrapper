//
//  RtReaderError.swift
//  rt-pcsc-wrapper
//
//  Created by Никита Девятых on 24.02.2025.
//

/// Errors that might happen when working with reader
public enum RtReaderError: Error {
    /// Unknown error
    case unknown
    /// Communication with reader failed
    case readerUnavailable
    /// There is no valid SCARDCONTEXT. Maybe method start() was never called or
    /// method stop() was called after start() call
    case invalidContext
    /// NFC session was stopped with specific reason
    /// - Parameter RtNfcStopReason: Reason why NFC session stopped
    case nfcIsStopped(RtNfcStopReason)
}
