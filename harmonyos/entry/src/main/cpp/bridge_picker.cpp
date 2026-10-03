// bridge_picker.cpp — implementation of the cancellable picker bridge. See
// bridge_picker.h for the lifecycle contract.

#include "bridge_picker.h"

#include <algorithm>

namespace openttd {

BridgePicker::~BridgePicker() = default;

PickerRequest* BridgePicker::find(uint64_t id)
{
    for (auto& req : requests_) {
        if (req.id == id) return &req;
    }
    return nullptr;
}

uint64_t BridgePicker::start(bool is_import)
{
    if (torn_down_) return 0;
    // Only one active picker at a time (the DocumentViewPicker UI is modal).
    for (const auto& req : requests_) {
        if (req.state == PickerState::CALLING) return 0;
    }

    PickerRequest* slot = nullptr;
    for (auto& req : requests_) {
        if (req.state == PickerState::IDLE) {
            slot = &req;
            break;
        }
    }
    if (slot == nullptr) return 0; // pool exhausted

    slot->id = next_id_++;
    slot->is_import = is_import;
    slot->state = PickerState::CALLING;
    slot->result = PickerResult::OK;
    slot->uri.clear();
    slot->error.clear();
    outstanding_++;
    return slot->id;
}

void BridgePicker::complete(uint64_t id, PickerResult result, const std::string& uri,
                            const std::string& error)
{
    if (torn_down_) return;
    PickerRequest* req = find(id);
    if (req == nullptr || req->state != PickerState::CALLING) return;

    req->result = result;
    req->uri = uri;
    req->error = error;
    req->state = PickerState::DONE;
    if (outstanding_ > 0) outstanding_--;

    // Deliver the callback on the UI thread (models a TSFN call). A cancelled
    // picker still delivers a CANCELLED result — nonfatal.
    pending_.push_back(PickerCallback{id, result, uri, error});
}

bool BridgePicker::cancel(uint64_t id)
{
    if (torn_down_) return false;
    PickerRequest* req = find(id);
    if (req == nullptr || req->state != PickerState::CALLING) return false;

    // Cancelled before any result: NO callback is delivered (models
    // napi_release_threadsafe_function with napi_tsfn_abort).
    req->state = PickerState::ABORTED;
    req->result = PickerResult::CANCELLED;
    req->error = "cancelled before result";
    if (outstanding_ > 0) outstanding_--;
    return true;
}

void BridgePicker::abortOne(PickerRequest& req)
{
    if (req.state == PickerState::IDLE || req.state == PickerState::ABORTED) return;
    req.state = PickerState::ABORTED;
    req.result = PickerResult::CANCELLED;
    req.error = "teardown: request aborted";
    if (outstanding_ > 0) outstanding_--;
}

void BridgePicker::teardown()
{
    if (torn_down_) return;
    torn_down_ = true;
    for (auto& req : requests_) {
        abortOne(req);
    }
    pending_.clear(); // no post-teardown callbacks run
}

size_t BridgePicker::drainResults(std::deque<PickerCallback>& out)
{
    if (torn_down_) return 0;
    size_t n = pending_.size();
    while (!pending_.empty()) {
        out.push_back(std::move(pending_.front()));
        pending_.pop_front();
    }
    return n;
}

PickerState BridgePicker::state(uint64_t id) const
{
    for (const auto& req : requests_) {
        if (req.id == id) return req.state;
    }
    return PickerState::IDLE;
}

} // namespace openttd
