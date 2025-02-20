//
//  RtReaderType.swift
//  rt-pcsc-wrapper
//
//  Created by Никита Девятых on 24.02.2025.
//

/// Reader type
public enum RtReaderType: Sendable {
    /// Reader type is unkown
    case unknown
    /// Reader type is Bluetooth
    case bt
    /// Reader type is NFC
    case nfc
    /// Reader type is BCR
    case vcr
    /// Reader type is USB
    case usb
}
