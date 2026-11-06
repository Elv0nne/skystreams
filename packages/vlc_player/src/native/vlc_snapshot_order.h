#ifndef VLC_PLAYER_NATIVE_VLC_SNAPSHOT_ORDER_H_
#define VLC_PLAYER_NATIVE_VLC_SNAPSHOT_ORDER_H_

#include "vlc_player_types.h"

namespace vlc_player {

// Keeps a plugin's snapshots in the order they were made (FORK.md 37).
//
// Windows and Linux make them on two threads, the update pump's and the
// platform thread's after a command, and outside any lock: libVLC's getters
// can take a while. One the pump began before a SetSource could be sent
// after SetSource's own, and Dart read the failed player's "playing", with
// no hold, as the parked media's: a reopen without the picture (P1 Part 3's
// Windows outage rows).
//
// Not thread-safe: Windows admits under the lock it sends under; Linux admits
// where it delivers, on its main thread, since a snapshot the pump queues
// there runs after one a command sends at once (g_main_context_invoke).
class VlcSnapshotOrder {
 public:
  // Whether `snapshot` goes out. Not one made before the last sent, and not
  // one that says what the last sent said unless `force`. Records it.
  bool Admit(const VlcSnapshot& snapshot, bool force) {
    if (has_last_ && snapshot.sequence < last_.sequence) {
      return false;
    }
    if (!force && has_last_ && snapshot == last_) {
      return false;
    }
    last_ = snapshot;
    has_last_ = true;
    return true;
  }

 private:
  bool has_last_ = false;
  VlcSnapshot last_;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_SNAPSHOT_ORDER_H_
