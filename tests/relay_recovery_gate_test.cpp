#include <cassert>

#include "relay_recovery.h"

int main() {
    RelayRecoveryGate gate;

    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Write);
    assert(!gate.OnWriteFailure());
    assert(!gate.OnWriteFailure());
    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Write);

    // A successful write breaks the failure streak.
    gate.OnWriteSuccess();
    assert(!gate.OnWriteFailure());
    assert(!gate.OnWriteFailure());
    assert(gate.OnWriteFailure());
    assert(gate.IsRecovering());

    // Recovery must not reopen on every delta frame. Only a clean random
    // access frame is allowed to create a fresh MPEG-TS muxer.
    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Drop);
    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Drop);
    assert(gate.BeforeWrite(true) == RelayRecoveryAction::ReopenAndWrite);

    // A failed reopen keeps the IDR gate armed.
    gate.OnReopenFailure();
    assert(gate.IsRecovering());
    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Drop);
    assert(gate.BeforeWrite(true) == RelayRecoveryAction::ReopenAndWrite);

    gate.OnReopenSuccess();
    // Opening AVIO is not recovery: the fresh IDR must itself be accepted by
    // the muxer before delta frames are admitted again.
    assert(gate.IsRecovering());
    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Drop);
    gate.OnWriteSuccess();
    assert(!gate.IsRecovering());
    assert(gate.BeforeWrite(false) == RelayRecoveryAction::Write);

    // Long-running recovery churn remains bounded and never admits a delta
    // between muxer reopen and the first successful IDR write.
    for (int cycle = 0; cycle < 10'000; ++cycle) {
        assert(!gate.OnWriteFailure());
        assert(!gate.OnWriteFailure());
        assert(gate.OnWriteFailure());
        assert(gate.BeforeWrite(false) == RelayRecoveryAction::Drop);
        assert(gate.BeforeWrite(true) == RelayRecoveryAction::ReopenAndWrite);
        gate.OnReopenSuccess();
        assert(gate.BeforeWrite(false) == RelayRecoveryAction::Drop);
        gate.OnWriteSuccess();
        assert(gate.BeforeWrite(false) == RelayRecoveryAction::Write);
    }
    return 0;
}
