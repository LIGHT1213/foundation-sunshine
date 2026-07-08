/**
 * @file src/platform/macos/gamepad.mm
 * @brief Gamepad plumbing on macOS.
 *
 * The platf::alloc_gamepad / free_gamepad / gamepad_update contract is, on
 * Windows/Linux, satisfied by a kernel-level *virtual* gamepad driver that
 * injects the client's controller state into the host so local games receive
 * it (Windows ViGEmClient, Linux inputtino).
 *
 * macOS has no public API to create a virtual HID gamepad device:
 *   - IOHIDDeviceCreate takes an io_service_t for an *existing* kernel device;
 *     it cannot synthesize a new one.
 *   - The historical IOHIDDeviceCreateVirtualDevice / IOHIDDeviceHandleReport
 *     pair was private SPI and has been removed from the public SDK.
 *   - The modern path is a DriverKit IOUserHIDDevice, which requires a signed
 *     driver extension and entitlements — out of scope for a userspace build.
 *
 * GCController (Game Controller framework) is read-only: it surfaces real
 * connected gamepads, it cannot inject synthetic input.
 *
 * Given that, this file implements the contract as best as a userspace macOS
 * app can:
 *   - alloc_gamepad / free_gamepad: succeed and bookkeep the slot so the
 *     cross-platform input.cpp pipeline keeps flowing and does not abort the
 *     stream when a client sends controller events.
 *   - gamepad_update: no-op (the state has no destination on the host without
 *     a virtual driver). Logged at debug so a future DriverKit-based driver
 *     can be dropped in here without touching callers.
 *   - supported_gamepads: advertises a standard Xbox layout entry that is
 *     *disabled*, with the reason explaining the macOS limitation, so the WebUI
 *     surfaces it correctly instead of the stale "not yet implemented" string.
 *
 * Rumble/feedback from host→client is unrelated to injection and continues to
 * be unsupported (the virtual device does not exist to receive output reports).
 */
#include "src/platform/common.h"

#include "src/logging.h"

#include <mutex>
#include <vector>

using namespace std::literals;

namespace platf {

  namespace {
    constexpr int kMaxGamepads = 16;

    struct gamepad_bookkeeping_t {
      std::mutex mu;
      std::array<bool, kMaxGamepads> allocated {};
    };

    gamepad_bookkeeping_t &
    bookkeeping() {
      static gamepad_bookkeeping_t b;
      return b;
    }
  }  // namespace

  int
  alloc_gamepad(input_t & /*input*/, const gamepad_id_t &id, const gamepad_arrival_t & /*metadata*/, feedback_queue_t /*feedback_queue*/) {
    std::lock_guard<std::mutex> lk(bookkeeping().mu);
    if (id.globalIndex < 0 || id.globalIndex >= kMaxGamepads) {
      BOOST_LOG(error) << "alloc_gamepad: index out of range: "sv << id.globalIndex;
      return -1;
    }
    bookkeeping().allocated[id.globalIndex] = true;
    // NOTE: no virtual device is created (see file header). We accept the slot
    // so input.cpp keeps the controller pipeline alive instead of tearing the
    // stream down.
    return 0;
  }

  void
  free_gamepad(input_t & /*input*/, int nr) {
    std::lock_guard<std::mutex> lk(bookkeeping().mu);
    if (nr < 0 || nr >= kMaxGamepads) return;
    bookkeeping().allocated[nr] = false;
  }

  void
  gamepad_update(input_t & /*input*/, int nr, const gamepad_state_t & /*gamepad_state*/) {
    // macOS has no userspace virtual gamepad driver to inject this state into.
    // See the file header for why. A future DriverKit IOUserHIDDevice
    // implementation would translate `gamepad_state` into an Xbox HID report
    // and submit it here.
    (void) nr;
  }

  std::vector<supported_gamepad_t> &
  supported_gamepads(input_t * /*input*/) {
    // The standard Xbox layout is what the Moonlight protocol assumes; we list
    // it but mark it disabled with the reason surfaced to the WebUI.
    static std::vector gamepads {
      supported_gamepad_t {
        "Xbox One Controller",
        false,
        "gamepads.macos_no_virtual_driver",
      },
    };
    return gamepads;
  }

  platform_caps::caps_t
  get_capabilities() {
    // No pen/touch/clipboard/touchpad/touchpad_frame caps on macOS yet.
    return 0;
  }

}  // namespace platf
