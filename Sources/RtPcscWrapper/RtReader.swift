//
//  RtReader.swift
//  rt-pcsc-wrapper
//
//  Created by Никита Девятых on 24.02.2025.
//

import Foundation


/// Struct that represents reader
public struct RtReader: Identifiable, Sendable {
    public var id = UUID()

    public let name: String
    public let type: RtReaderType
}
