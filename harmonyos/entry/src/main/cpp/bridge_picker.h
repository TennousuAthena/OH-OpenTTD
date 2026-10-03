// bridge_picker.h — pure C++ DocumentViewPicker import/export bridge with a
// cancellable TSFN-style lifecycle, for the OpenTTD HarmonyOS port.
//
// DESIGN CONTRACT
// ---------------
// This header and its implementation are DELIBERATELY free of any XComponent /
// NAPI / OHOS SDK dependency so the full contract can be compiled and exercised
// on the host (see scripts/harmonyos/test-bridges.sh). It models the
// cancellation/result lifecycle that the NAPI ThreadSafeFunction glue
// (bridge_napi.cpp) translates to real napi_release_threadsafe_function calls.
//
// LIFECYCLE (mirrors the W2.T11 storage-contract picker contract):
//   PENDING  -> CALLING  -> DONE      (result delivered)
//   PENDING  -> CALLING  -> ABORTED   (cancelled before any result)
//   PENDING  -> CALLING   (teardown)  -> ABORTED (every outstanding aborted)
//
//   * start() moves an idle request to CALLING. A request is a single
//     import (select) or export (save) operation.
//   * complete(result, uri) moves a CALLING request to DONE and records a
//     typed result. CANCELLED is a VALID, NONFATAL result (the user dismissed
//     the document picker) — it still transitions to DONE.
//   * cancel() BEFORE any result transitions CALLING -> ABORTED (modelled as
//     napi_release_threadsafe_function(..., napi_tsfn_abort): NO callback runs).
//   * teardown() aborts every outstanding request (ability onDestroy aborts all
//     outstanding bridges). After teardown, start()/complete()/cancel() are
//     no-ops and the result queue is closed.
//
// THREAD OWNERSHIP
// ----------------
// start()/complete()/cancel()/teardown() must be called from the UI thread;
// drainResults() is the UI-thread consumer modelling the TSFN call. No method
// blocks.

#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <utility>

namespace openttd {

// Typed picker result union. These never throw across a NAPI boundary and a
// picker failure is always NONFATAL at the bridge level.
enum class PickerResult {
    OK,           // valid document(s) selected / saved
    CANCELLED,    // user dismissed the document picker (nonfatal)
    INVALID_URI,  // expired / one-time URI no longer valid (nonfatal)
    LOW_SPACE,    // insufficient free space (export)
    IO_ERROR,     // generic I/O failure
    PATH_ESCAPE,  // destination escapes the sandbox (export)
};

// Internal lifecycle state of a request.
enum class PickerState {
    IDLE,     // no operation active
    CALLING,  // picker is up, result pending
    DONE,     // result delivered
    ABORTED,  // cancelled before result (no callback); teardown
};

struct PickerRequest {
    uint64_t id = 0;
    bool is_import = false;       // true = import (select), false = export (save)
    PickerState state = PickerState::IDLE;
    PickerResult result = PickerResult::OK;
    std::string uri;              // selected/saved URI (empty for failures)
    std::string error;            // human message for non-OK results
};

// A delivered result, drained on the UI thread (models a TSFN call).
struct PickerCallback {
    uint64_t id = 0;
    PickerResult result = PickerResult::OK;
    std::string uri;
    std::string error;
};

class BridgePicker {
public:
    BridgePicker() = default;
    ~BridgePicker();

    BridgePicker(const BridgePicker&) = delete;
    BridgePicker& operator=(const BridgePicker&) = delete;

    // Starts an import (select) or export (save) request. Returns a nonzero
    // request id, or 0 if a request is already CALLING or the bridge is torn
    // down. Starting a second request while one is CALLING is refused.
    uint64_t start(bool is_import);

    // Completes a CALLING request with a typed result. CANCELLED is valid and
    // nonfatal. Ignores unknown / already-final ids.
    void complete(uint64_t id, PickerResult result, const std::string& uri,
                  const std::string& error = "");

    // Cancels a CALLING request BEFORE any result: transitions it to ABORTED
    // and delivers NO callback (models napi_tsfn_abort). Returns true if the
    // request was aborted.
    bool cancel(uint64_t id);

    // Teardown: aborts every outstanding request and closes the result queue.
    // After this, start()/complete()/cancel() are no-ops and drainResults()
    // runs nothing. Idempotent.
    void teardown();

    // UI-thread consumer: moves any DONE callbacks into `out` and clears the
    // pending queue. Returns the number delivered.
    size_t drainResults(std::deque<PickerCallback>& out);

    // Accessors.
    size_t outstanding() const { return outstanding_; }  // requests not yet DONE/ABORTED
    bool tornDown() const { return torn_down_; }
    PickerState state(uint64_t id) const;

private:
    PickerRequest* find(uint64_t id);
    void abortOne(PickerRequest& req);

    PickerRequest requests_[4];       // small fixed pool (multi-select import)
    uint64_t next_id_ = 1;
    size_t outstanding_ = 0;
    bool torn_down_ = false;
    std::deque<PickerCallback> pending_; // queued DONE callbacks for the UI thread
};

} // namespace openttd
