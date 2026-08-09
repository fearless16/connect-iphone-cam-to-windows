#pragma once

#include <cstdint>

enum class RelayRecoveryAction {
    Write,
    Drop,
    ReopenAndWrite,
};

// Small, dependency-free state machine for the OBS UDP muxer. A transient
// write failure does not churn the muxer; a persistent failure arms recovery,
// and recovery may resume only on a self-contained HEVC random-access frame.
class RelayRecoveryGate final {
public:
    static constexpr uint32_t kConsecutiveFailureThreshold = 3;

    RelayRecoveryAction BeforeWrite(bool isKeyframe) const {
        if (!recovering_) return RelayRecoveryAction::Write;
        return isKeyframe ? RelayRecoveryAction::ReopenAndWrite
                          : RelayRecoveryAction::Drop;
    }

    bool OnWriteFailure() {
        if (++consecutive_failures_ < kConsecutiveFailureThreshold) return false;
        consecutive_failures_ = 0;
        recovering_ = true;
        return true;
    }

    void OnWriteSuccess() {
        consecutive_failures_ = 0;
        recovering_ = false;
    }

    void OnReopenFailure() {
        recovering_ = true;
    }

    void OnReopenSuccess() {
        consecutive_failures_ = 0;
    }

    bool IsRecovering() const { return recovering_; }

private:
    uint32_t consecutive_failures_ = 0;
    bool recovering_ = false;
};
