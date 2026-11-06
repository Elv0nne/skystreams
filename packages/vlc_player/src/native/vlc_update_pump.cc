#include "vlc_update_pump.h"

#include <utility>

namespace vlc_player {

VlcUpdatePump::VlcUpdatePump(std::function<void()> send,
                             std::chrono::milliseconds min_interval,
                             std::chrono::milliseconds heartbeat)
    : send_(std::move(send)),
      min_interval_(min_interval),
      heartbeat_(heartbeat) {}

VlcUpdatePump::~VlcUpdatePump() {
  Stop();
}

void VlcUpdatePump::Start() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_ || thread_.joinable()) {
    return;
  }
  running_ = true;
  thread_ = std::thread([this] { Run(); });
}

void VlcUpdatePump::Wake() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_) {
      return;
    }
    dirty_ = true;
  }
  wake_.notify_one();
}

void VlcUpdatePump::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
  }
  wake_.notify_one();
  if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) {
    thread_.join();
  }
}

void VlcUpdatePump::Run() {
  using Clock = std::chrono::steady_clock;
  std::unique_lock<std::mutex> lock(mutex_);
  Clock::time_point last_sent = Clock::now() - min_interval_;
  while (running_) {
    wake_.wait_for(lock, heartbeat_, [this] { return dirty_ || !running_; });
    if (!running_) {
      break;
    }
    // A change right after an update waits out the rest of the interval,
    // gathering whatever else changes meanwhile into the same update.
    const auto ready = last_sent + min_interval_;
    if (dirty_ && Clock::now() < ready) {
      wake_.wait_until(lock, ready, [this] { return !running_; });
      if (!running_) {
        break;
      }
    }
    dirty_ = false;
    lock.unlock();
    send_();
    lock.lock();
    last_sent = Clock::now();
  }
}

}  // namespace vlc_player
