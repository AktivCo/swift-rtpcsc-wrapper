//
//  StatesHolder.swift
//  rt-pcsc-wrapper
//
//  Created by Никита Девятых on 24.02.2025.
//

import RtPcsc


actor StatesHolder {
    private var states: [SCARD_READERSTATE]

    init(states: [SCARD_READERSTATE]) {
        self.states = states
    }

    deinit {
        states.forEach { state in state.szReader.deallocate() }
    }

    func ScardGetStatusChangeA(ctx: SCARDCONTEXT, dwTimeout: DWORD) -> LONG {
        return SCardGetStatusChangeA(ctx, dwTimeout, &states, DWORD(states.count))
    }

    func append(_ readerState: SCARD_READERSTATE) {
        states.append(readerState)
    }

    func map(transform: (SCARD_READERSTATE) -> (SCARD_READERSTATE)) {
        states = states.map( { transform($0) })
    }

    func contains(predicate: (SCARD_READERSTATE) -> Bool) -> Bool {
        states.contains(where: predicate)
    }

    func count() -> Int {
        states.count
    }
}

extension SCARD_READERSTATE: @unchecked Sendable {}
