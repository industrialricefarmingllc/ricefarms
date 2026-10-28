// hypr-edge-swipe: touch gestures for Hyprland.
//
// Why a plugin: Hyprland's built-in gestures:workspace_swipe_touch refuses
// to begin when the touch lands on a layer surface above the bottom layer
// (the m_foundLSToFocus <= 1 check in Touch.cpp). A shell with permanent
// fullscreen top/overlay surfaces (quickshell panels, decorative overlays,
// wallpaper layers) therefore blocks the built-in edge swipe everywhere.
// This plugin listens on the compositor's input.touch event bus instead
// (emitted before normal touch processing, so it sees every touch).
//
// Gestures:
//   * Edge swipe: a touch that STARTS inside an edge band (zone_px logical px
//     from a screen edge) slides the neighbouring workspace in as the finger
//     moves. Both directions work: inward goes one way, outward from the
//     same edge goes the other. Release past min_distance_px (20 logical px
//     by default) to switch; release earlier and it slides back. Left/right
//     use the workspace grid row, top/bottom its column; both wrap like
//     custom.lua's gridHorizontal/gridVertical.
//   * Reverse edge swipe: start in the interior and move toward an edge; the
//     workspace goes the opposite way from the same-edge inward swipe.
//   * Corner launcher: diagonal inward from the top-left opens Pibble; the
//     reverse (toward the top-left corner) closes it, and an up-left swipe
//     from the bottom-right also closes it. A straight horizontal/vertical
//     swipe in a corner still navigates the workspace.
//   * Pinch out on a window: grow it live while the fingers move, then
//     maximize it (tmux "z"), or fullscreen (tmux "f") if already maximized.
//     The preview only grows an axis if maximizing will actually grow that
//     axis; a dimension that will shrink at commit stays put during the
//     preview.
//   * Pinch in: shrink a normal window live (it stays floating), or step
//     fullscreen -> maximized -> normal.
//   * Touch drag on a window: double-tap the window, then drag with the
//     second touch. A single-finger drag is left entirely to the app, and a
//     vertical scroll pauses drag arming briefly so page scrolling is not
//     hijacked. Tiled windows are floated at their exact tile geometry first,
//     so they do not
//     jump or resize when the drag starts. On release every normal window
//     snaps back into the tiling tree at the drop point; a maximized window
//     is returned to its tile first. Fullscreen windows are left alone so a
//     stray drag cannot yank a game out of fullscreen.
//
// Taps/clicks are preserved: nothing is consumed until drag (only after a
// double tap), a pinch, or an edge gesture starts moving. At that point the
// touch stream is cancelled for the client (wl_touch.cancel) and the plugin
// takes over.

#include "Config.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/config/supplementary/executor/Executor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/devices/ITouch.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorQuery.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

#define ES_NAME    "hypr-touch-gestures"
#define ES_DESC    "Touch gestures: edge-swipe workspaces, pinch to resize, drag windows"
#define ES_AUTHOR  "Lucid"
#define ES_VERSION "1.1.15"

HANDLE PHANDLE = nullptr;

CHyprSignalListener G_LISTEN_DOWN;
CHyprSignalListener G_LISTEN_MOTION;
CHyprSignalListener G_LISTEN_UP;
CHyprSignalListener G_LISTEN_CANCEL;

using Clock = std::chrono::steady_clock;

enum class EEdge : uint8_t {
    NONE = 0,
    LEFT,
    RIGHT,
    TOP,
    BOTTOM,
};

enum class ECorner : uint8_t {
    NONE = 0,
    TOP_LEFT,
    BOTTOM_RIGHT,
};

enum class ECornerAction : uint8_t {
    NONE = 0,
    OPEN,
    CLOSE,
};

// One edge-swipe candidate at a time; the first finger that starts inside an
// edge band claims it. The workspace slide is driven manually in onMotion.
struct SGesture {
    bool          active         = false;
    int32_t       touchID        = -1;
    EEdge         edge           = EEdge::NONE;
    bool          vertical       = false;
    int           edgeSign       = 0; // -1 = left/top, +1 = right/bottom
    int           dir            = 0; // workspace direction, -1 = left/up, +1 = right/down
    bool          outward        = false; // swipe away from the screen interior
    double        dominance      = 1.2; // required axis / perpendicular ratio
    PHLMONITORREF monitor;
    Vector2D      startPx;
    Vector2D      lastPx;
    PHLWORKSPACE  begin;
    PHLWORKSPACE  target;
    int           targetID       = -1;
    bool          previewing     = false;
    bool          clientCancelled = false;
    double        progress       = 0;
    std::string   style;
};

// Every finger we track (for pinch and drag). Motion/up events only carry the
// touch id, so this map is keyed by id like Hyprland's own touch state.
struct STouch {
    SP<ITouch>                  device;
    int32_t                     id   = -1;
    PHLMONITORREF               monitor;
    Vector2D                    startPx;
    Vector2D                    px;
    PHLWINDOWREF                window;
    bool                        onLayer = false;
    Clock::time_point           startTime;
    bool                        consumed    = false;
    bool                        dragBlocked = false;
    bool                        multiTouch  = false;
    bool                        doubleTapArmed = false;
    bool                        verticalSwipe = false;
};

// The last completed one-finger tap, used to arm a drag only when the next
// touch is a second tap on the same window.
struct STapRecord {
    bool              valid = false;
    Clock::time_point time;
    Vector2D          px;
    PHLWINDOWREF      window;
};

// Corner launcher gesture: a diagonal inward swipe from the top-left opens
// Pibble; the reverse (toward the corner) closes it, and an up-left swipe
// from the bottom-right also closes it. The normal edge candidate still runs
// alongside so a straight horizontal/vertical swipe navigates.
struct SCornerState {
    bool          candidate  = false;
    bool          fired      = false;
    bool          closeOnly  = false;
    bool          closeArmed = false; // close starts on release
    ECorner       corner     = ECorner::NONE;
    int32_t       id         = -1;
    PHLMONITORREF monitor;
    Vector2D      startPx;
    Vector2D      lastPx;
};

// A swipe that starts in the interior and heads toward an edge. It is only a
// candidate until the finger has moved far enough; the app keeps the touch
// until then.
struct SReverseState {
    bool          candidate = false;
    int32_t       id        = -1;
    PHLMONITORREF monitor;
    Vector2D      startPx;
};

struct SPinchState {
    bool          active   = false;
    bool          previewing = false;
    bool          finished = false;
    int32_t       idA      = -1;
    int32_t       idB      = -1;
    PHLWINDOWREF  window;
    PHLMONITORREF monitor;
    double        initialDistance = 0;

    // Live resize snapshot (only for windows in normal state).
    bool          originalFloating = false;
    CBox          originalBox;
    Vector2D      originalSize;
    Vector2D      center;
    double        lastScale = 1.0;
};

struct SDragState {
    bool          active    = false;
    bool          tileOnEnd = false;
    int32_t       id        = -1;
    PHLWINDOWREF  window;
    PHLMONITORREF monitor;
    Vector2D      previousFloatSize;
};

SGesture                            G_GESTURE;
std::unordered_map<int32_t, STouch> G_TOUCHES;
SPinchState                         G_PINCH;
SDragState                          G_DRAG;
STapRecord                          G_LAST_TAP;
Clock::time_point                   G_LAST_VERTICAL_SWIPE;
SCornerState                        G_CORNER;
SReverseState                       G_REVERSE;

// ~/.cache/hypr-edge-swipe/debug.log — candidate starts, commits (with
// workspace + travel) and cancels. Size-capped; never throws. Same pattern
// as hypr-goo-workspaces.
void dbgLog(const std::string& msg) {
    try {
        const char* home = std::getenv("HOME");
        if (!home || !*home)
            return;
        const std::string dir = std::string(home) + "/.cache/hypr-edge-swipe";
        std::error_code   ec;
        std::filesystem::create_directories(dir, ec);
        const std::string path = dir + "/debug.log";
        if (std::filesystem::file_size(path, ec) > 128 * 1024)
            std::filesystem::remove(path, ec);
        std::ofstream f(path, std::ios::app);
        if (!f)
            return;
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        f << "[" << ms << "] " << msg << "\n";
    } catch (...) {}
}

// Same monitor resolution the touch manager uses: the device's bound output
// if set, otherwise the focused monitor (Touch.cpp onTouchDown).
PHLMONITOR resolveTouchMonitor(const SP<ITouch>& device) {
    auto mon = State::monitorState()->query().name(device && !device->m_boundOutput.empty() ? device->m_boundOutput : "").run();
    return mon ? mon : Desktop::focusState()->monitor();
}

Vector2D toPx(const PHLMONITOR& mon, const Vector2D& pos) {
    return Vector2D{pos.x * mon->m_size.x, pos.y * mon->m_size.y};
}

Vector2D toGlobal(const PHLMONITOR& mon, const Vector2D& localPx) {
    return mon->m_position + localPx;
}

// True when a layer surface that accepts input sits above the point. Shell
// bars/docks must keep working; click-through overlays (empty input regions)
// do not count because layerSurfaceAt() skips them.
bool layerBlocks(const PHLMONITOR& mon, const Vector2D& globalPos) {
    if (!mon)
        return true;

    for (int layer = 3; layer >= 1; --layer) {
        Vector2D coords;
        PHLLS    found = nullptr;
        if (Desktop::viewState()->hitTest().layerSurfaceAt(globalPos, &mon->m_layerSurfaceLayers[layer], &coords, &found))
            return true;
    }

    return false;
}

PHLWINDOW windowAt(const PHLMONITOR& mon, const Vector2D& globalPos) {
    if (!mon)
        return nullptr;
    return Desktop::viewState()->hitTest().windowAt(globalPos,
                                                    static_cast<uint16_t>(Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS |
                                                                          Desktop::View::ALLOW_FLOATING));
}

// ---------------------------------------------------------------------------
// Workspace grid (kept in sync with custom.lua's GRID_ROWS / EDP_ROWS).
// ---------------------------------------------------------------------------

// Real grid: 5 wide x 3 tall per monitor.
// DP-1 r0: 1,2,3,31,32 | r1: 11,12,13,33,34 | r2: 21,22,23,35,36
// DP-2 r0: 4,5,6,37,38 | r1: 14,15,16,39,40 | r2: 24,25,26,41,42
// DP-3 r0: 7,8,9,43,44 | r1: 17,18,19,45,46 | r2: 27,28,29,47,48
const std::vector<std::vector<int>> DP_GRID = {
    {1, 2, 3, 31, 32},   {11, 12, 13, 33, 34}, {21, 22, 23, 35, 36},
    {4, 5, 6, 37, 38},   {14, 15, 16, 39, 40}, {24, 25, 26, 41, 42},
    {7, 8, 9, 43, 44},   {17, 18, 19, 45, 46}, {27, 28, 29, 47, 48},
};
// Solo internal panel: 5x3 block starting at 10.
const std::vector<std::vector<int>> EDP_GRID = {
    {10, 11, 12, 13, 14},
    {20, 21, 22, 23, 24},
    {30, 31, 32, 33, 34},
};

struct SGridPos {
    int  row = -1;
    int  col = -1;
    int  n   = 0;

    bool ok() const {
        return row >= 0;
    }
};

SGridPos findGridPos(const std::vector<std::vector<int>>& rows, const int id) {
    for (size_t r = 0; r < rows.size(); ++r) {
        for (size_t c = 0; c < rows[r].size(); ++c) {
            if (rows[r][c] == id)
                return {static_cast<int>(r), static_cast<int>(c), static_cast<int>(rows[r].size())};
        }
    }
    return {};
}

const std::vector<std::vector<int>>& gridRowsFor(const PHLMONITOR& mon) {
    const auto& MONS = State::monitorState()->monitors();
    const bool  SOLO = (MONS.size() == 1 && MONS[0] && MONS[0]->m_name == "eDP-1") || (MONS.empty() && mon && mon->m_name == "eDP-1");
    return SOLO ? EDP_GRID : DP_GRID;
}

int fallbackVerticalTarget(const int id, const int dir) {
    // Free row anchors 10/20/30 (outside the 45-cell grid) wrap as a 3-row
    // column, exactly like custom.lua's FALLBACK_DOWN / FALLBACK_UP.
    if (id == 10)
        return dir > 0 ? 20 : 30;
    if (id == 20)
        return dir > 0 ? 30 : 10;
    if (id == 30)
        return dir > 0 ? 10 : 20;
    const int target = id + dir * 10;
    return target > 0 ? target : -1;
}

int resolveSwipeTarget(const PHLMONITOR& mon, const int id, const bool vertical, const int dir, std::string& style) {
    const auto& ROWS = gridRowsFor(mon);
    const auto  POS  = findGridPos(ROWS, id);

    if (vertical) {
        if (!POS.ok()) {
            style = dir > 0 ? "slidevert bottom" : "slidevert top";
            return fallbackVerticalTarget(id, dir);
        }

        // Every monitor owns three consecutive rows; wrap inside that block,
        // not across the whole 45-cell board.
        constexpr int BLOCK = 3;
        const int     BASE  = (POS.row / BLOCK) * BLOCK;
        const int     NR    = BASE + ((POS.row - BASE + dir) % BLOCK + BLOCK) % BLOCK;
        if (NR < 0 || NR >= static_cast<int>(ROWS.size()) || POS.col >= static_cast<int>(ROWS[NR].size()))
            return -1;

        const int target = ROWS[NR][POS.col];
        // Wrap >1 row away continues the press direction filmstrip-style.
        if (std::abs(NR - POS.row) > 1)
            style = POS.row > NR ? "slidevert bottom" : "slidevert top";
        else
            style = NR > POS.row ? "slidevert bottom" : "slidevert top";
        return target;
    }

    if (!POS.ok()) {
        style = dir > 0 ? "slide right" : "slide left";
        const int target = id + dir;
        return target > 0 ? target : -1;
    }

    const int NC = ((POS.col + dir) % POS.n + POS.n) % POS.n;
    const int target = ROWS[POS.row][NC];
    if (std::abs(NC - POS.col) == POS.n - 1)
        style = POS.col > NC ? "slide right" : "slide left";
    else
        style = NC > POS.col ? "slide right" : "slide left";
    return target;
}

// ---------------------------------------------------------------------------
// Edge swipe helpers.
// ---------------------------------------------------------------------------

double edgeZonePx() {
    return static_cast<double>(std::max(es::getInt(es::Key::ZONE_PX, 56), 1));
}

EEdge edgeAt(const PHLMONITOR& mon, const Vector2D& px, int& edgeSign) {
    const double ZONE = edgeZonePx();
    const double DL   = px.x;
    const double DR   = mon->m_size.x - px.x;
    const double DT   = px.y;
    const double DB   = mon->m_size.y - px.y;

    EEdge  edge = EEdge::NONE;
    double best = ZONE + 1.0;

    auto consider = [&](const EEdge candidate, const double distance) {
        if (distance <= ZONE && distance < best) {
            best = distance;
            edge = candidate;
        }
    };

    consider(EEdge::LEFT, DL);
    consider(EEdge::RIGHT, DR);
    consider(EEdge::TOP, DT);
    consider(EEdge::BOTTOM, DB);

    edgeSign = (edge == EEdge::LEFT || edge == EEdge::TOP) ? -1 : (edge == EEdge::RIGHT || edge == EEdge::BOTTOM) ? 1 : 0;
    return edge;
}

const char* edgeName(const EEdge edge) {
    switch (edge) {
        case EEdge::LEFT: return "left";
        case EEdge::RIGHT: return "right";
        case EEdge::TOP: return "top";
        case EEdge::BOTTOM: return "bottom";
        default: return "none";
    }
}

// Signed travel along the edge axis: positive = inward, negative = outward.
double inwardTravel(const SGesture& g) {
    if (!g.active)
        return 0;
    const double DELTA = g.vertical ? (g.lastPx.y - g.startPx.y) : (g.lastPx.x - g.startPx.x);
    return DELTA * -g.edgeSign;
}

// The corner gesture needs a deliberate diagonal, not a left/top edge swipe
// that happens to start near the corner.
constexpr double CORNER_DIAGONAL_RATIO = 0.5;
constexpr const char* PIBBLE_OPEN_COMMAND =
    "/home/nicerice/src/pibble/pibble start >/dev/null 2>&1; "
    "for i in $(seq 1 50); do "
    "qs -p /home/nicerice/src/pibble ipc -n call launcher open >/dev/null 2>&1 && exit 0; "
    "sleep 0.1; "
    "done";
constexpr const char* PIBBLE_CLOSE_COMMAND = "qs -p /home/nicerice/src/pibble ipc -n call launcher close >/dev/null 2>&1";

double cornerZonePx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::CORNER_PX, 48), 8)), 8.0, 300.0);
}

double cornerCloseZonePx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::CORNER_CLOSE_PX, 120), 8)), 8.0, 400.0);
}

double cornerMinPx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::CORNER_MIN_PX, 24), 8)), 8.0, 200.0);
}

ECorner cornerAt(const PHLMONITOR& mon, const Vector2D& px) {
    if (!mon)
        return ECorner::NONE;

    const double ZONE = cornerZonePx();
    const double DR   = mon->m_size.x - px.x;
    const double DB   = mon->m_size.y - px.y;
    if (px.x >= 0.0 && px.y >= 0.0 && px.x <= ZONE && px.y <= ZONE)
        return ECorner::TOP_LEFT;
    if (DR >= 0.0 && DB >= 0.0 && DR <= ZONE && DB <= ZONE)
        return ECorner::BOTTOM_RIGHT;
    return ECorner::NONE;
}

bool inTopLeftCloseZone(const Vector2D& px) {
    const double ZONE = cornerCloseZonePx();
    return px.x >= 0.0 && px.y >= 0.0 && px.x <= ZONE && px.y <= ZONE;
}

// The Pibble launcher stays mapped; when open it moves to the overlay layer.
PHLLS pibbleLauncher(const PHLMONITOR& mon) {
    if (!mon)
        return nullptr;

    for (int layer = 3; layer >= 0; --layer) {
        for (const auto& LS : mon->m_layerSurfaceLayers[layer]) {
            const auto SHARED = LS.lock();
            if (SHARED && SHARED->m_mapped && SHARED->m_layer >= 3 && SHARED->m_namespace == "quickshell-pibble")
                return SHARED;
        }
    }

    return nullptr;
}

bool cornerDiagonal(const double dx, const double dy) {
    const double ADX = std::abs(dx);
    const double ADY = std::abs(dy);
    const double MIN = cornerMinPx();
    if (ADX < MIN || ADY < MIN)
        return false;
    return std::min(ADX, ADY) >= std::max(ADX, ADY) * CORNER_DIAGONAL_RATIO;
}

ECornerAction cornerAction(const ECorner corner, const bool closeOnly, const double dx, const double dy) {
    if (!cornerDiagonal(dx, dy))
        return ECornerAction::NONE;

    if (closeOnly) {
        if (corner == ECorner::TOP_LEFT && dx < 0.0 && dy < 0.0)
            return ECornerAction::CLOSE;
        if (corner == ECorner::BOTTOM_RIGHT && dx < 0.0 && dy < 0.0)
            return ECornerAction::CLOSE;
        return ECornerAction::NONE;
    }

    if (corner == ECorner::TOP_LEFT) {
        if (dx > 0.0 && dy > 0.0)
            return ECornerAction::OPEN;
        if (dx < 0.0 && dy < 0.0)
            return ECornerAction::CLOSE;
    } else if (corner == ECorner::BOTTOM_RIGHT) {
        if (dx < 0.0 && dy < 0.0)
            return ECornerAction::CLOSE; // reverse/inward, up-left
    }

    return ECornerAction::NONE;
}

// True while the movement still looks like one of the corner gestures, so the
// edge preview can be held instead of flashing a workspace.
bool cornerDiagonalPlausible(const ECorner corner, const bool closeOnly, const double dx, const double dy) {
    const double ADX = std::abs(dx);
    const double ADY = std::abs(dy);
    if (ADX < 1.0 && ADY < 1.0)
        return false;
    if (std::min(ADX, ADY) < std::max(ADX, ADY) * CORNER_DIAGONAL_RATIO)
        return false;

    if (corner == ECorner::TOP_LEFT) {
        if (closeOnly)
            return dx < 0.0 && dy < 0.0;
        return (dx > 0.0 && dy > 0.0) || (dx < 0.0 && dy < 0.0);
    }
    if (corner == ECorner::BOTTOM_RIGHT)
        return dx < 0.0 && dy < 0.0;
    return false;
}

const char* cornerName(const ECorner corner) {
    switch (corner) {
        case ECorner::TOP_LEFT: return "top-left";
        case ECorner::BOTTOM_RIGHT: return "bottom-right";
        default: return "none";
    }
}

double reverseZonePx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::REVERSE_ZONE, 120), 0)), 0.0, 4000.0);
}

double reverseMinPx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::REVERSE_MIN, 24), 8)), 8.0, 400.0);
}

double edgeDistance(const PHLMONITOR& mon, const Vector2D& px) {
    if (!mon)
        return 0.0;
    return std::min({px.x, mon->m_size.x - px.x, px.y, mon->m_size.y - px.y});
}

// Pick the edge a reverse swipe is heading toward. The start must be outside
// the normal edge band (so normal edge swipes keep priority) and, unless the
// zone is 0, within reverse_zone_px of that edge. Diagonals are allowed.
EEdge pickReverseEdge(const PHLMONITOR& mon, const Vector2D& start, const Vector2D& now, double& travel, int& sign, bool& vertical) {
    travel   = 0.0;
    sign     = 0;
    vertical = false;
    if (!mon)
        return EEdge::NONE;

    const double ZONE   = edgeZonePx();
    const double RZONE  = reverseZonePx();
    const double MIN    = reverseMinPx();
    const double DX     = now.x - start.x;
    const double DY     = now.y - start.y;

    auto allowed = [&](const double startDist) { return startDist > ZONE && (RZONE <= 0.0 || startDist <= RZONE); };

    EEdge best = EEdge::NONE;
    auto  add  = [&](const EEdge edge, const double axis, const int edgeSign, const bool vert, const double startDist) {
        if (!allowed(startDist) || axis < MIN)
            return;
        const double PERP = vert ? std::abs(DX) : std::abs(DY);
        if (axis < PERP)
            return;
        if (axis > travel) {
            travel   = axis;
            sign     = edgeSign;
            vertical = vert;
            best     = edge;
        }
    };

    add(EEdge::LEFT, -DX, -1, false, start.x);
    add(EEdge::RIGHT, DX, 1, false, mon->m_size.x - start.x);
    add(EEdge::TOP, -DY, -1, true, start.y);
    add(EEdge::BOTTOM, DY, 1, true, mon->m_size.y - start.y);
    return best;
}

// Travel along whichever direction this gesture chose. Both inward and
// outward swipes grow from 0, so the same activation/commit logic applies.
double gestureTravel(const SGesture& g) {
    const double RAW = inwardTravel(g);
    return g.outward ? -RAW : RAW;
}

double perpendicularTravel(const SGesture& g) {
    return g.vertical ? std::abs(g.lastPx.x - g.startPx.x) : std::abs(g.lastPx.y - g.startPx.y);
}

double swipeDistancePx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::SWIPE_DISTANCE, 900), 1)), 80.0, 4000.0);
}

double commitThresholdPx() {
    return std::max(static_cast<double>(std::max(es::getInt(es::Key::MIN_DIST, 20), 1)), 1.0);
}

// A tap must be short; this is independent of the gap between the two taps.
constexpr double TAP_MAX_DURATION_MS   = 300.0;
constexpr double TAP_SLOP_PX           = 12.0;
// A diagonal page scroll still counts if its vertical component is at least
// half the horizontal one.
constexpr double SCROLL_VERTICAL_RATIO = 0.5;

double dragDoubleTapMs() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::DRAG_DOUBLE_TAP_MS, 150), 80)), 80.0, 1000.0);
}

double dragDoubleTapPx() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::DRAG_DOUBLE_TAP_PX, 40), 4)), 4.0, 200.0);
}

double dragCooldownMs() {
    return std::clamp(static_cast<double>(std::max(es::getInt(es::Key::DRAG_COOLDOWN_MS, 300), 0)), 0.0, 2000.0);
}

bool dragCooldownActive() {
    const double MS = dragCooldownMs();
    return MS > 0.0 && (Clock::now() - G_LAST_VERTICAL_SWIPE) < std::chrono::duration<double, std::milli>(MS);
}

void clearTapRecord() {
    G_LAST_TAP = {};
}

bool gestureArmed() {
    if (!G_GESTURE.active || !G_GESTURE.previewing)
        return false;
    const double TRAVEL = gestureTravel(G_GESTURE);
    const double PERP   = perpendicularTravel(G_GESTURE);
    return TRAVEL >= commitThresholdPx() && TRAVEL >= PERP * G_GESTURE.dominance;
}

void damageMonitor(const PHLMONITOR& mon) {
    if (mon)
        g_pHyprRenderer->damageMonitor(mon);
}

void updateSwipePreview() {
    if (!G_GESTURE.previewing)
        return;

    const auto MON   = G_GESTURE.monitor.lock();
    const auto BEGIN = G_GESTURE.begin;
    const auto TARGET = G_GESTURE.target;
    if (!MON || !BEGIN || !TARGET || MON->m_activeWorkspace != BEGIN) {
        G_GESTURE.previewing = false;
        G_GESTURE           = {};
        return;
    }

    const double DIST = swipeDistancePx();
    // Only claim workspace state once the finger has actually moved; a tap
    // inside the edge band never gets here.
    const double TRAVEL = std::max(0.0, gestureTravel(G_GESTURE));
    G_GESTURE.progress  = std::clamp(TRAVEL / DIST, 0.0, 1.0);

    const double SIDE = G_GESTURE.vertical ? MON->m_size.y : MON->m_size.x;
    const double P    = G_GESTURE.progress;
    const Vector2D BEGINOFF = G_GESTURE.vertical ? Vector2D{0.0, -G_GESTURE.dir * P * SIDE} : Vector2D{-G_GESTURE.dir * P * SIDE, 0.0};
    const Vector2D TARGETOFF = G_GESTURE.vertical ? Vector2D{0.0, G_GESTURE.dir * (1.0 - P) * SIDE} : Vector2D{G_GESTURE.dir * (1.0 - P) * SIDE, 0.0};

    BEGIN->m_forceRendering = true;
    TARGET->m_forceRendering = true;
    BEGIN->m_alpha->setValueAndWarp(1.F);
    TARGET->m_alpha->setValueAndWarp(1.F);
    BEGIN->m_renderOffset->setValueAndWarp(BEGINOFF);
    TARGET->m_renderOffset->setValueAndWarp(TARGETOFF);

    BEGIN->updateWindowDecos();
    TARGET->updateWindowDecos();
    damageMonitor(MON);
}

void startSwipePreview() {
    if (!G_GESTURE.active || G_GESTURE.previewing)
        return;

    const auto MON = G_GESTURE.monitor.lock();
    if (!MON || !MON->m_activeWorkspace) {
        G_GESTURE = {};
        return;
    }

    const auto BEGIN = MON->m_activeWorkspace;
    std::string STYLE;
    const int  TARGETID = resolveSwipeTarget(MON, static_cast<int>(BEGIN->m_id), G_GESTURE.vertical, G_GESTURE.dir, STYLE);
    if (TARGETID <= 0 || TARGETID == BEGIN->m_id) {
        dbgLog("swipe no target from " + std::to_string(BEGIN->m_id) + " vertical=" + std::to_string(G_GESTURE.vertical) + " dir=" + std::to_string(G_GESTURE.dir));
        G_GESTURE = {};
        return;
    }

    auto target = State::workspaceState()->query().id(TARGETID).run();
    if (!target)
        target = State::workspaceState()->create(TARGETID, MON->m_id, std::to_string(TARGETID));
    if (!target) {
        dbgLog("swipe target create failed id=" + std::to_string(TARGETID));
        G_GESTURE = {};
        return;
    }

    G_GESTURE.begin      = BEGIN;
    G_GESTURE.target     = target;
    G_GESTURE.targetID   = TARGETID;
    G_GESTURE.style      = STYLE;
    G_GESTURE.previewing = true;

    // Hand the touch stream over to the gesture: the client saw the initial
    // down (so edge taps still work), but must not also scroll/drag while we
    // slide a workspace.
    g_pSeatManager->sendTouchCancel();
    G_GESTURE.clientCancelled = true;

    updateSwipePreview();
    if (!G_GESTURE.previewing) {
        dbgLog("swipe preview failed begin=" + std::to_string(BEGIN->m_id) + " target=" + std::to_string(TARGETID));
        return;
    }

    char buf[256];
    std::snprintf(buf, sizeof(buf), "swipe preview edge=%s begin=%lld target=%d dir=%d outward=%d style=%s", edgeName(G_GESTURE.edge), (long long)G_GESTURE.begin->m_id,
                  TARGETID, G_GESTURE.dir, (int)G_GESTURE.outward, STYLE.c_str());
    dbgLog(buf);
}

void endSwipe(const bool commit) {
    if (!G_GESTURE.active) {
        G_GESTURE = {};
        return;
    }

    const auto MON    = G_GESTURE.monitor.lock();
    const auto BEGIN  = G_GESTURE.begin;
    const auto TARGET = G_GESTURE.target;
    const bool PREVIEW = G_GESTURE.previewing;
    const double TRAVEL = gestureTravel(G_GESTURE);

    if (!PREVIEW || !MON || !BEGIN || !TARGET) {
        G_GESTURE = {};
        return;
    }

    if (commit && MON->m_activeWorkspace == BEGIN) {
        const Vector2D TARGETMID = TARGET->m_renderOffset->value();

        // m_animationStyle is read by CMonitor::changeWorkspace to pick the
        // directional slide; startAnimation() then warps the incoming
        // workspace off-screen. Restore the live mid-swipe offset right after
        // so the compositor animation continues from the finger position.
        const auto OLDSTYLE = TARGET->m_animationStyle;
        TARGET->m_animationStyle = G_GESTURE.style;

        if (Desktop::focusState()->monitor() != MON)
            Desktop::focusState()->rawMonitorFocus(MON);

        MON->changeWorkspace(TARGET);
        TARGET->m_renderOffset->setValue(TARGETMID);
        TARGET->m_animationStyle = OLDSTYLE;

        BEGIN->m_forceRendering  = false;
        TARGET->m_forceRendering = false;
        BEGIN->m_alpha->setValueAndWarp(1.F);
        TARGET->m_alpha->setValueAndWarp(1.F);

        damageMonitor(MON);

        char buf[256];
        std::snprintf(buf, sizeof(buf), "swipe commit edge=%s travel=%.0f progress=%.2f -> %d (mon %s)", edgeName(G_GESTURE.edge), TRAVEL,
                      G_GESTURE.progress, G_GESTURE.targetID, MON->m_name.c_str());
        dbgLog(buf);
    } else {
        // Slide back and let the normal workspace animation config take over.
        const double SIDE = G_GESTURE.vertical ? MON->m_size.y : MON->m_size.x;
        const Vector2D BEGINGOAL{0.0, 0.0};
        const Vector2D TARGETGOAL = G_GESTURE.vertical ? Vector2D{0.0, G_GESTURE.dir * SIDE} : Vector2D{G_GESTURE.dir * SIDE, 0.0};

        *BEGIN->m_renderOffset  = BEGINGOAL;
        *TARGET->m_renderOffset = TARGETGOAL;
        BEGIN->m_forceRendering  = false;
        TARGET->m_forceRendering = false;
        BEGIN->m_alpha->setValueAndWarp(1.F);

        damageMonitor(MON);

        char buf[256];
        std::snprintf(buf, sizeof(buf), "swipe cancel edge=%s travel=%.0f progress=%.2f target=%d", edgeName(G_GESTURE.edge), TRAVEL,
                      G_GESTURE.progress, G_GESTURE.targetID);
        dbgLog(buf);
    }

    G_GESTURE = {};
}

// The corner overrides a workspace preview instead of committing it: cancel
// any slide, take the touch away from the client, and open Pibble.
void fireCorner(const int32_t id, const ECornerAction action) {
    if (G_GESTURE.active && G_GESTURE.touchID == id)
        endSwipe(false);

    G_TOUCHES.erase(id);
    g_pSeatManager->sendTouchCancel();

    const ECorner CORNER = G_CORNER.corner;
    bool          spawned = false;
    if (auto& EXEC = Config::Supplementary::executor(); EXEC)
        spawned = EXEC->spawnRaw(action == ECornerAction::CLOSE ? PIBBLE_CLOSE_COMMAND : PIBBLE_OPEN_COMMAND).has_value();

    G_CORNER.candidate = false;
    G_CORNER.fired     = true;
    G_CORNER.id        = id;

    dbgLog(std::string("corner ") + cornerName(CORNER) + " " + (action == ECornerAction::CLOSE ? "close" : "open") + " -> pibble " +
           (spawned ? "spawned" : "spawn failed"));
}

void clearCorner() {
    G_CORNER = {};
}

// ---------------------------------------------------------------------------
// Pinch: live resize + discrete maximize/fullscreen steps.
// ---------------------------------------------------------------------------

double pinchDistance() {
    const auto A = G_TOUCHES.find(G_PINCH.idA);
    const auto B = G_TOUCHES.find(G_PINCH.idB);
    if (A == G_TOUCHES.end() || B == G_TOUCHES.end())
        return 0;
    return std::hypot(A->second.px.x - B->second.px.x, A->second.px.y - B->second.px.y);
}

void markPinchBlocked() {
    for (const auto id : {G_PINCH.idA, G_PINCH.idB}) {
        if (const auto IT = G_TOUCHES.find(id); IT != G_TOUCHES.end())
            IT->second.dragBlocked = true;
    }
}

void markPinchConsumed() {
    for (const auto id : {G_PINCH.idA, G_PINCH.idB}) {
        if (const auto IT = G_TOUCHES.find(id); IT != G_TOUCHES.end())
            IT->second.consumed = true;
    }
}

void abortPinchPreview() {
    if (!G_PINCH.previewing)
        return;

    const auto WINDOW = G_PINCH.window.lock();
    if (WINDOW && WINDOW->m_isMapped) {
        const auto TARGET = WINDOW->layoutTarget();
        TARGET->setPositionGlobal(G_PINCH.originalBox);
        TARGET->warpPositionSize();

        if (!G_PINCH.originalFloating && WINDOW->m_isFloating) {
            Pointer::mgr()->warpTo(G_PINCH.originalBox.middle());
            (void)Config::Actions::floatWindow(Config::Actions::TOGGLE_ACTION_DISABLE, WINDOW);
        }
    }

    G_PINCH.previewing = false;
    dbgLog("pinch preview abort");
}

bool startPinchPreview() {
    if (G_PINCH.previewing || G_PINCH.finished)
        return false;
    if (!es::getInt(es::Key::PINCH_LIVE, 1))
        return false;

    const auto WINDOW = G_PINCH.window.lock();
    if (!WINDOW || !WINDOW->m_isMapped)
        return false;

    const auto MODES = Fullscreen::controller()->getFullscreenModes(WINDOW);
    if (MODES.internal != Fullscreen::FSMODE_NONE)
        return false; // never yank a fullscreen/maximized window into a float

    G_PINCH.originalFloating = WINDOW->m_isFloating;
    G_PINCH.originalBox      = CBox{WINDOW->position(Desktop::View::IGeometric::GEOMETRIC_GOAL), WINDOW->size(Desktop::View::IGeometric::GEOMETRIC_GOAL)};
    G_PINCH.originalSize     = G_PINCH.originalBox.size();
    G_PINCH.center           = G_PINCH.originalBox.middle();
    G_PINCH.lastScale        = 1.0;

    if (!G_PINCH.originalFloating) {
        if (!Config::Actions::floatWindow(Config::Actions::TOGGLE_ACTION_ENABLE, WINDOW))
            return false;

        // floatWindow may restore an old floating size; snap the preview to
        // the exact tile the user grabbed.
        WINDOW->layoutTarget()->setPositionGlobal(G_PINCH.originalBox);
        WINDOW->layoutTarget()->warpPositionSize();
    }

    g_pSeatManager->sendTouchCancel();
    G_PINCH.previewing = true;
    markPinchConsumed();

    char buf[256];
    std::snprintf(buf, sizeof(buf), "pinch preview begin win=%s floating=%d size=%.0fx%.0f", WINDOW->m_title.c_str(), (int)G_PINCH.originalFloating,
                  G_PINCH.originalSize.x, G_PINCH.originalSize.y);
    dbgLog(buf);
    return true;
}

void updatePinchPreview() {
    if (!G_PINCH.previewing)
        return;

    const auto WINDOW = G_PINCH.window.lock();
    const auto MON    = G_PINCH.monitor.lock();
    if (!WINDOW || !WINDOW->m_isMapped || !MON || !WINDOW->m_isFloating) {
        abortPinchPreview();
        return;
    }

    if (Fullscreen::controller()->getFullscreenModes(WINDOW).internal != Fullscreen::FSMODE_NONE) {
        abortPinchPreview();
        return;
    }

    const double DIST = pinchDistance();
    if (DIST <= 1.0 || G_PINCH.initialDistance <= 1.0)
        return;

    const double SCALE = std::clamp(DIST / G_PINCH.initialDistance, 0.30, 2.50);
    if (std::abs(SCALE - G_PINCH.lastScale) < 0.002)
        return;

    const auto TARGET = WINDOW->layoutTarget();
    Vector2D   MINSIZE = TARGET->minSize().value_or(Vector2D{80.0, 60.0});
    Vector2D   MAXSIZE = TARGET->maxSize().value_or(Vector2D{MON->m_size.x, MON->m_size.y});
    MINSIZE.x          = std::max(MINSIZE.x, 1.0);
    MINSIZE.y          = std::max(MINSIZE.y, 1.0);
    MAXSIZE.x          = std::min(MAXSIZE.x, MON->m_size.x);
    MAXSIZE.y          = std::min(MAXSIZE.y, MON->m_size.y);
    MAXSIZE.x          = std::max(MAXSIZE.x, MINSIZE.x);
    MAXSIZE.y          = std::max(MAXSIZE.y, MINSIZE.y);

    // The geometry a pinch-out will end at (maximize). A tiled window is put
    // back into the tiling tree before maximizing, so use the tiled work
    // area; a floating window maximizes in the floating work area. The
    // maximized client box is the work area minus the window's reserved
    // extents, which is what hyprctl reports as the window size.
    const auto WORKSPACE = WINDOW->m_workspace;
    const CBox WORK      = WORKSPACE && WORKSPACE->m_space ? WORKSPACE->m_space->workArea(G_PINCH.originalFloating) : CBox{MON->m_position, MON->m_size};
    const auto RESERVED  = WINDOW->getFullWindowReservedArea();
    const Vector2D FINAL = (WORK.size() - (RESERVED.topLeft + RESERVED.bottomRight)).clamp(Vector2D{1.0, 1.0}, MON->m_size);

    Vector2D NEWSIZE;
    if (SCALE >= 1.0) {
        // Grow only the axes that the final maximize will grow. A dimension
        // that will shrink at commit stays at its pre-gesture size during the
        // preview, instead of ballooning and then snapping back on release.
        NEWSIZE = G_PINCH.originalSize;
        if (FINAL.x > G_PINCH.originalSize.x + 0.5) {
            const double CAP = std::max(MINSIZE.x, std::min(FINAL.x, MAXSIZE.x));
            NEWSIZE.x        = std::clamp(G_PINCH.originalSize.x * SCALE, MINSIZE.x, CAP);
        }
        if (FINAL.y > G_PINCH.originalSize.y + 0.5) {
            const double CAP = std::max(MINSIZE.y, std::min(FINAL.y, MAXSIZE.y));
            NEWSIZE.y        = std::clamp(G_PINCH.originalSize.y * SCALE, MINSIZE.y, CAP);
        }
    } else
        NEWSIZE = (G_PINCH.originalSize * SCALE).clamp(MINSIZE, MAXSIZE);

    Vector2D NEWPOS = G_PINCH.center - NEWSIZE / 2.0;

    const double MINX = WORK.x;
    const double MINY = WORK.y;
    const double MAXX = WORK.x + WORK.w - NEWSIZE.x;
    const double MAXY = WORK.y + WORK.h - NEWSIZE.y;
    NEWPOS.x          = MAXX < MINX ? MINX : std::clamp(NEWPOS.x, MINX, MAXX);
    NEWPOS.y          = MAXY < MINY ? MINY : std::clamp(NEWPOS.y, MINY, MAXY);

    TARGET->setPositionGlobal(CBox{NEWPOS, NEWSIZE});
    TARGET->warpPositionSize();
    G_PINCH.lastScale = SCALE;
}

void finishPinch() {
    const auto WINDOW = G_PINCH.window.lock();
    if (!WINDOW) {
        abortPinchPreview();
        G_PINCH.finished = true;
        return;
    }

    const auto   MODES  = Fullscreen::controller()->getFullscreenModes(WINDOW);
    const double RATIO  = std::max(static_cast<double>(es::getFloat(es::Key::PINCH_RATIO, 1.25F)), 1.05);
    const double DIST   = pinchDistance();
    const double SCALE  = G_PINCH.initialDistance > 1.0 && DIST > 0.0 ? DIST / G_PINCH.initialDistance : 1.0;
    const bool   EXPAND = SCALE >= RATIO;
    const bool   CONTRACT = SCALE * RATIO <= 1.0;
    bool         consumed = G_PINCH.previewing; // preview already cancelled the client stream

    std::string action;

    if (EXPAND) {
        if (MODES.internal == Fullscreen::FSMODE_NONE) {
            if (G_PINCH.previewing) {
                // Undo the preview before maximizing, so unmaximizing later
                // returns to the pre-gesture tile/float size rather than the
                // inflated preview size. Tiled windows also go back into the
                // tiling tree, so they unmaximize to a tile.
                WINDOW->layoutTarget()->setPositionGlobal(G_PINCH.originalBox);
                WINDOW->layoutTarget()->warpPositionSize();
                if (!G_PINCH.originalFloating) {
                    Pointer::mgr()->warpTo(G_PINCH.originalBox.middle());
                    (void)Config::Actions::floatWindow(Config::Actions::TOGGLE_ACTION_DISABLE, WINDOW);
                }
            }
            action = "maximize";
            (void)Config::Actions::fullscreenWindow(Fullscreen::FSMODE_MAXIMIZED, true, WINDOW);
            if (!G_PINCH.previewing)
                g_pSeatManager->sendTouchCancel();
            consumed = true;
        } else if (MODES.internal == Fullscreen::FSMODE_MAXIMIZED) {
            action = "fullscreen";
            (void)Config::Actions::fullscreenWindow(Fullscreen::FSMODE_FULLSCREEN, true, WINDOW);
            g_pSeatManager->sendTouchCancel();
            consumed = true;
        } else
            action = "none (already fullscreen)";
    } else if (CONTRACT) {
        if (MODES.internal == Fullscreen::FSMODE_FULLSCREEN) {
            action = "unfullscreen -> maximize";
            (void)Config::Actions::fullscreenWindow(Fullscreen::FSMODE_MAXIMIZED, true, WINDOW);
            g_pSeatManager->sendTouchCancel();
            consumed = true;
        } else if (MODES.internal == Fullscreen::FSMODE_MAXIMIZED) {
            action = "unmaximize";
            (void)Config::Actions::fullscreenWindow(Fullscreen::FSMODE_MAXIMIZED, true, WINDOW);
            g_pSeatManager->sendTouchCancel();
            consumed = true;
        } else if (G_PINCH.previewing) {
            // The live resize is the contract action: leave the window at the
            // size the fingers pulled it down to (floating, on purpose).
            action = "contract (floating at pinched size)";
        } else if (WINDOW->m_isFloating) {
            const auto SIZE = WINDOW->size(Desktop::View::IGeometric::GEOMETRIC_GOAL);
            if (SIZE.x > 320 && SIZE.y > 240) {
                action = "shrink";
                (void)Config::Actions::resize(Vector2D{-SIZE.x * 0.12, -SIZE.y * 0.12}, true, WINDOW);
                g_pSeatManager->sendTouchCancel();
                consumed = true;
            } else
                action = "none (floating window already small)";
        } else
            action = "none (tiled normal window)";
    } else {
        abortPinchPreview();
        action = "abort";
    }

    if (G_PINCH.previewing && !EXPAND && !CONTRACT)
        consumed = true; // abort already had a cancelled stream

    G_PINCH.previewing = false;
    G_PINCH.finished   = true;
    if (consumed)
        markPinchConsumed();

    char buf[256];
    std::snprintf(buf, sizeof(buf), "pinch %s scale=%.2f win=%s mode=%d action=%s", EXPAND ? "out" : CONTRACT ? "in" : "none", SCALE, WINDOW->m_title.c_str(),
                  (int)MODES.internal, action.c_str());
    dbgLog(buf);
}

void clearPinch() {
    if (G_PINCH.previewing && !G_PINCH.finished)
        abortPinchPreview();
    G_PINCH = {};
}

void maybeStartPinch() {
    if (!es::getInt(es::Key::PINCH_ENABLED, 1))
        return;
    if (G_PINCH.active || G_DRAG.active || G_PINCH.finished)
        return;
    if (G_TOUCHES.size() != 2)
        return;

    const auto A = G_TOUCHES.begin();
    const auto B = std::next(A);
    if (A->second.device != B->second.device)
        return; // two devices reporting the same physical finger: not a pinch
    if (A->second.onLayer || B->second.onLayer)
        return;
    if (A->second.consumed || B->second.consumed)
        return;

    const auto WA = A->second.window.lock();
    const auto WB = B->second.window.lock();
    if (!WA || WA.get() != WB.get())
        return; // both fingers must land on the same window

    const auto TIMEOUT = std::chrono::milliseconds(std::max(es::getInt(es::Key::PINCH_TIMEOUT, 400), 50));
    const auto GAP     = A->second.startTime > B->second.startTime ? A->second.startTime - B->second.startTime : B->second.startTime - A->second.startTime;
    if (GAP > TIMEOUT)
        return;

    const double DIST = std::hypot(A->second.px.x - B->second.px.x, A->second.px.y - B->second.px.y);
    if (DIST < std::max(es::getInt(es::Key::PINCH_MIN_DIST, 40), 1))
        return;

    G_PINCH = {};
    G_PINCH.active          = true;
    G_PINCH.idA             = A->first;
    G_PINCH.idB             = B->first;
    G_PINCH.window          = WA;
    G_PINCH.monitor         = A->second.monitor;
    G_PINCH.initialDistance = DIST;

    A->second.dragBlocked = true;
    B->second.dragBlocked = true;

    dbgLog("pinch candidate ids=" + std::to_string(A->first) + "," + std::to_string(B->first) + " dist=" + std::to_string((int)DIST) +
           " win=" + WA->m_title);
}

// ---------------------------------------------------------------------------
// Drag: Hyprland's drag controller, driven from touch coordinates.
// ---------------------------------------------------------------------------

void endDragAtLastPosition() {
    if (!G_DRAG.active)
        return;

    const auto WINDOW         = G_DRAG.window.lock();
    const bool TILE_ON_END    = G_DRAG.tileOnEnd;
    const auto PREVIOUS_FLOAT = G_DRAG.previousFloatSize;

    if (const auto IT = G_TOUCHES.find(G_DRAG.id); IT != G_TOUCHES.end()) {
        if (const auto MON = IT->second.monitor.lock()) {
            const Vector2D GLOBAL = toGlobal(MON, IT->second.px);
            Pointer::mgr()->warpTo(GLOBAL);
            g_layoutManager->moveMouse(GLOBAL);
        }
    }

    if (g_layoutManager->dragController()->target())
        g_layoutManager->endDragTarget();

    // A normal window is always put back into the tiling tree, including one
    // that was floating before the drag. The cursor is still at the drop
    // point, so the tiling algorithm inserts it into the tile under the
    // finger. Keep the grabbed size for the next float toggle.
    if (TILE_ON_END && WINDOW && WINDOW->m_isMapped) {
        if (const auto TARGET = WINDOW->layoutTarget(); TARGET && TARGET->floating())
            g_layoutManager->changeFloatingMode(TARGET);

        if (const auto TARGET = WINDOW->layoutTarget(); TARGET && PREVIOUS_FLOAT.x > 5 && PREVIOUS_FLOAT.y > 5)
            TARGET->rememberFloatingSize(PREVIOUS_FLOAT);
    }

    g_pInputManager->refocus();
    G_DRAG = {};
}

void startDrag(STouch& touch, Event::SCallbackInfo& info) {
    const auto WINDOW = touch.window.lock();
    if (!WINDOW || !WINDOW->m_isMapped || touch.onLayer)
        return;

    if (!touch.doubleTapArmed)
        return; // a single-finger drag belongs to the app

    clearTapRecord();

    if (g_layoutManager->dragController()->target())
        return; // don't steal an in-flight mouse drag

    const auto MODES = Fullscreen::controller()->getFullscreenModes(WINDOW);
    if (MODES.internal == Fullscreen::FSMODE_FULLSCREEN)
        return; // never yank a fullscreen app out with a stray drag

    // A maximized window is returned to its normal tile first, so the drag
    // starts from the real tile geometry and ends tiled instead of staying
    // maximized/floating.
    if (MODES.internal == Fullscreen::FSMODE_MAXIMIZED)
        Fullscreen::controller()->setFullscreenMode(WINDOW, Fullscreen::FSMODE_NONE);

    const auto MON = touch.monitor.lock();
    if (!MON)
        return;

    const auto TARGET = WINDOW->layoutTarget();
    if (!TARGET)
        return;

    const bool WAS_TILE = !TARGET->floating();
    // The layout target's box includes tiling gaps; use the window's actual
    // goal box so floating it does not grow it by the gap width.
    const CBox ORIGINAL{WINDOW->position(Desktop::View::IGeometric::GEOMETRIC_GOAL), WINDOW->size(Desktop::View::IGeometric::GEOMETRIC_GOAL)};
    // Preserve the size the window had when grabbed, not a stale float size
    // (which can be an old full-screen box).
    const auto PREVIOUS_FLOAT = ORIGINAL.size();

    // Hyprland's tiled drag path centers the freshly-floated window under the
    // cursor and resizes it to ~84.89% of the tile. Float it ourselves first,
    // at the exact tile geometry, so beginDragTarget() sees a floating window:
    // the drag then starts at the original position and size.
    if (WAS_TILE) {
        TARGET->rememberFloatingSize(ORIGINAL.size());
        g_layoutManager->changeFloatingMode(TARGET);
        if (!TARGET->floating()) {
            dbgLog("drag abort: could not float tiled window");
            return;
        }
        TARGET->setPositionGlobal(ORIGINAL);
        TARGET->warpPositionSize();
    }

    // beginDragTarget() anchors the drag on the cursor; put it under the
    // finger before the controller reads it, otherwise the first moveMouse()
    // applies a huge bogus delta from wherever the mouse happened to be.
    const Vector2D GLOBAL = toGlobal(MON, touch.px);
    Pointer::mgr()->warpTo(GLOBAL);

    g_layoutManager->beginDragTarget(TARGET, MBIND_MOVE);
    if (!g_layoutManager->dragController()->target()) {
        // Roll back the pre-float so a failed drag does not leave the window
        // floating.
        if (WAS_TILE && TARGET->floating()) {
            g_layoutManager->changeFloatingMode(TARGET);
            TARGET->rememberFloatingSize(PREVIOUS_FLOAT);
        }
        return;
    }

    g_layoutManager->moveMouse(GLOBAL);

    G_DRAG = {};
    G_DRAG.active            = true;
    G_DRAG.tileOnEnd         = true;
    G_DRAG.id                = touch.id;
    G_DRAG.window            = WINDOW;
    G_DRAG.monitor           = MON;
    G_DRAG.previousFloatSize = PREVIOUS_FLOAT;

    markPinchBlocked();
    clearPinch();

    touch.consumed = true;
    g_pSeatManager->sendTouchCancel();
    info.cancelled = true;

    dbgLog("drag begin id=" + std::to_string(touch.id) + " win=" + WINDOW->m_title + " tiled=" + std::to_string((int)WAS_TILE) + " pos=" +
           std::to_string((int)touch.px.x) + "," + std::to_string((int)touch.px.y) + " size=" + std::to_string((int)ORIGINAL.size().x) + "x" +
           std::to_string((int)ORIGINAL.size().y));
}

void moveDrag(const STouch& touch) {
    const auto WINDOW = G_DRAG.window.lock();
    const auto MON    = G_DRAG.monitor.lock();
    if (!WINDOW || !MON) {
        G_DRAG = {};
        return;
    }

    const Vector2D GLOBAL = toGlobal(MON, touch.px);
    Pointer::mgr()->warpTo(GLOBAL);
    g_layoutManager->moveMouse(GLOBAL);
}

// ---------------------------------------------------------------------------
// Touch event handlers.
// ---------------------------------------------------------------------------

void onDown(ITouch::SDownEvent e, Event::SCallbackInfo&) {
    if (!es::getInt(es::Key::ENABLED, 1))
        return;

    if (G_GESTURE.active) {
        if (e.touchID == G_GESTURE.touchID)
            return; // duplicate report for the finger we are already tracking
        // A genuinely second finger cancels the one-finger edge swipe; a
        // touch-up lost by the device must not wedge the gesture forever.
        endSwipe(false);
    }

    if ((G_CORNER.candidate || G_CORNER.fired || G_CORNER.closeArmed) && e.touchID == G_CORNER.id)
        return; // duplicate down for the corner finger

    if ((G_CORNER.candidate || G_CORNER.closeArmed) && e.touchID != G_CORNER.id)
        clearCorner(); // a second finger abandons the corner gesture

    if (G_REVERSE.candidate && e.touchID == G_REVERSE.id)
        return; // duplicate down for the reverse candidate
    if (G_REVERSE.candidate && e.touchID != G_REVERSE.id)
        G_REVERSE = {}; // a second finger abandons the reverse gesture

    const auto PMONITOR = resolveTouchMonitor(e.device);
    if (!PMONITOR)
        return;

    const Vector2D PX = toPx(PMONITOR, e.pos);

    // Corner launcher: track a potential diagonal Pibble swipe alongside the
    // normal edge candidate. While the launcher is open, the top-left close
    // gets a wider start area so it is easy to grab from farther in.
    const ECorner CORNER   = cornerAt(PMONITOR, PX);
    const auto    LAUNCHER = pibbleLauncher(PMONITOR);
    if (es::getInt(es::Key::CORNER_ENABLED, 1) && !G_CORNER.fired && G_TOUCHES.empty() && !G_DRAG.active && !G_PINCH.active && !G_PINCH.finished) {
        ECorner EFFECTIVE  = CORNER;
        bool    CLOSE_ONLY = false;
        if (EFFECTIVE == ECorner::NONE && LAUNCHER && inTopLeftCloseZone(PX)) {
            EFFECTIVE  = ECorner::TOP_LEFT;
            CLOSE_ONLY = true;
        }

        if (EFFECTIVE != ECorner::NONE) {
            G_CORNER = {};
            G_CORNER.candidate = true;
            G_CORNER.closeOnly = CLOSE_ONLY;
            G_CORNER.corner    = EFFECTIVE;
            G_CORNER.id        = e.touchID;
            G_CORNER.monitor   = PMONITOR;
            G_CORNER.startPx   = PX;
            G_CORNER.lastPx    = PX;
            dbgLog("corner candidate id=" + std::to_string(e.touchID) + " corner=" + cornerName(EFFECTIVE) + " closeOnly=" + (CLOSE_ONLY ? "1" : "0"));
        }
    }

    // Optional dead band near the top (keeps bar gestures out when wanted).
    // Only suppress edge swipes; a drag/pinch that starts under the bar still
    // works like any other touch.
    const bool IN_TOP_DEADBAND = PX.y < static_cast<double>(std::max(es::getInt(es::Key::ZONE_TOP_PX, 0), 0));

    // Edge swipe: only from the first finger.
    if (!IN_TOP_DEADBAND && G_TOUCHES.empty() && !G_DRAG.active && !G_PINCH.active && !G_PINCH.finished) {
        int          edgeSign = 0;
        const EEdge  EDGE     = edgeAt(PMONITOR, PX, edgeSign);
        const bool   VERTICAL = EDGE == EEdge::TOP || EDGE == EEdge::BOTTOM;
        if (EDGE != EEdge::NONE && (!VERTICAL || es::getInt(es::Key::VERTICAL_ENABLED, 1))) {
            clearTapRecord();
            G_GESTURE = {};
            G_GESTURE.active  = true;
            G_GESTURE.touchID = e.touchID;
            G_GESTURE.edge    = EDGE;
            G_GESTURE.vertical = VERTICAL;
            G_GESTURE.edgeSign  = edgeSign;
            G_GESTURE.dir       = edgeSign;
            G_GESTURE.dominance = static_cast<double>(std::max(es::getFloat(es::Key::DOMINANCE, 1.2F), 1.0F));
            if (es::getInt(es::Key::INVERT, 0))
                G_GESTURE.dir = -G_GESTURE.dir;
            G_GESTURE.startPx = PX;
            G_GESTURE.lastPx  = PX;
            G_GESTURE.monitor = PMONITOR;

            char buf[256];
            std::snprintf(buf, sizeof(buf), "swipe candidate id=%d edge=%s start=(%.0f,%.0f) mon=%s", e.touchID, edgeName(EDGE), PX.x, PX.y,
                          PMONITOR->m_name.c_str());
            dbgLog(buf);
            return;
        }
    }

    if (G_DRAG.active)
        return; // extra fingers during a drag are ignored

    // Reverse swipe candidate: start in the interior and head toward an
    // edge. The app keeps the touch until the movement crosses the reverse
    // threshold in onMotion().
    if (es::getInt(es::Key::REVERSE_ENABLED, 1) && G_TOUCHES.empty() && !G_PINCH.active && !G_PINCH.finished && !G_CORNER.candidate) {
        const double DIST  = edgeDistance(PMONITOR, PX);
        const double ZONE  = edgeZonePx();
        const double RZONE = reverseZonePx();
        if (DIST > ZONE && (RZONE <= 0.0 || DIST <= RZONE)) {
            G_REVERSE = {};
            G_REVERSE.candidate = true;
            G_REVERSE.id        = e.touchID;
            G_REVERSE.monitor   = PMONITOR;
            G_REVERSE.startPx   = PX;
            dbgLog("reverse candidate id=" + std::to_string(e.touchID) + " dist=" + std::to_string((int)DIST));
        }
    }

    // Some devices report a duplicate down for a finger already tracked. If
    // that finger is the armed second tap, keep its state instead of
    // overwriting it with a fresh, unarmed touch.
    if (const auto EXISTING = G_TOUCHES.find(e.touchID); EXISTING != G_TOUCHES.end() && EXISTING->second.doubleTapArmed)
        return;

    STouch touch;
    touch.device    = e.device;
    touch.id        = e.touchID;
    touch.monitor   = PMONITOR;
    touch.startPx   = PX;
    touch.px        = PX;
    touch.startTime = Clock::now();

    const Vector2D GLOBAL = toGlobal(PMONITOR, PX);
    touch.onLayer         = layerBlocks(PMONITOR, GLOBAL);
    if (!touch.onLayer)
        touch.window = windowAt(PMONITOR, GLOBAL);

    // Mark every finger in a multi-touch sequence so a two-finger tap can
    // never be mistaken for a tap that arms a later drag.
    touch.multiTouch = !G_TOUCHES.empty();
    if (touch.multiTouch) {
        for (auto& [id, other] : G_TOUCHES)
            other.multiTouch = true;
    }

    // Drag is opt-in: the previous touch must have been a short tap on this
    // same window, and this down must be close both in time and position.
    if (es::getInt(es::Key::DRAG_ENABLED, 1) && !touch.onLayer && G_LAST_TAP.valid) {
        const auto WINDOW      = touch.window.lock();
        const auto LAST_WINDOW = G_LAST_TAP.window.lock();
        const auto ELAPSED     = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - G_LAST_TAP.time).count();
        const double DIST      = std::hypot(PX.x - G_LAST_TAP.px.x, PX.y - G_LAST_TAP.px.y);
        const bool MATCH       = WINDOW && LAST_WINDOW && WINDOW == LAST_WINDOW && ELAPSED >= 0 && ELAPSED <= dragDoubleTapMs() && DIST <= dragDoubleTapPx();
        if (MATCH && !dragCooldownActive()) {
            touch.doubleTapArmed = true;
            char buf[256];
            std::snprintf(buf, sizeof(buf), "drag double-tap armed id=%d win=%s", e.touchID, WINDOW->m_title.c_str());
            dbgLog(buf);
        } else if (MATCH) {
            dbgLog("drag arm blocked: scroll cooldown id=" + std::to_string(e.touchID));
        }
    }

    // A down either consumes a matching first tap or discards a stale one.
    clearTapRecord();

    G_TOUCHES[e.touchID] = touch;

    maybeStartPinch();
}

void onMotion(ITouch::SMotionEvent e, Event::SCallbackInfo& info) {
    if (G_CORNER.closeArmed && e.touchID == G_CORNER.id) {
        info.cancelled = true;
        return;
    }

    if (G_CORNER.fired && e.touchID == G_CORNER.id) {
        info.cancelled = true;
        return;
    }

    if (G_CORNER.candidate && e.touchID == G_CORNER.id) {
        const auto CMON = G_CORNER.monitor.lock();
        if (!CMON) {
            clearCorner();
        } else {
            const Vector2D PX = toPx(CMON, e.pos);
            const double DX   = PX.x - G_CORNER.startPx.x;
            const double DY   = PX.y - G_CORNER.startPx.y;
            G_CORNER.lastPx   = PX;
            const auto ACTION = cornerAction(G_CORNER.corner, G_CORNER.closeOnly, DX, DY);
            if (ACTION == ECornerAction::OPEN) {
                fireCorner(e.touchID, ACTION);
                info.cancelled = true;
                return;
            }
            if (ACTION == ECornerAction::CLOSE) {
                // Close on release, not at the threshold. Consume the rest of
                // the drag so the client does not see it.
                G_CORNER.closeArmed = true;
                endSwipe(false);
                G_TOUCHES.erase(e.touchID);
                g_pSeatManager->sendTouchCancel();
                info.cancelled = true;
                return;
            }
        }
    }

    if (G_GESTURE.active && e.touchID == G_GESTURE.touchID) {
        const auto PMONITOR = G_GESTURE.monitor.lock();
        if (!PMONITOR) {
            endSwipe(false);
            return;
        }

        G_GESTURE.lastPx = toPx(PMONITOR, e.pos);

        if (!G_GESTURE.previewing) {
            const double ACTIVATION         = std::max(static_cast<double>(es::getInt(es::Key::SWIPE_ACTIVATION, 12)), 1.0);
            const double OUTWARD_ACTIVATION = std::max(ACTIVATION, 6.0);
            const double RAW                = inwardTravel(G_GESTURE);
            // Inward keeps the existing 2 px activation. Outward needs a
            // slightly longer, deliberate movement so a small backswing on
            // an inward swipe cannot lock the wrong direction.
            if (RAW >= ACTIVATION || RAW <= -OUTWARD_ACTIVATION) {
                // The first deliberate movement chooses the direction. An
                // outward swipe from the same edge goes the other way.
                G_GESTURE.outward = RAW < 0.0;
                G_GESTURE.dir     = G_GESTURE.edgeSign * (G_GESTURE.outward ? -1 : 1);
                if (es::getInt(es::Key::INVERT, 0))
                    G_GESTURE.dir = -G_GESTURE.dir;

                // While a top-left diagonal is still plausible, don't start
                // the workspace slide: the launcher gesture should not flash
                // a neighbouring workspace on its way in.
                bool HOLD_FOR_CORNER = false;
                if (G_CORNER.candidate && G_CORNER.id == e.touchID) {
                    const Vector2D PX = toPx(PMONITOR, e.pos);
                    const double DX   = PX.x - G_CORNER.startPx.x;
                    const double DY   = PX.y - G_CORNER.startPx.y;
                    HOLD_FOR_CORNER   = cornerDiagonalPlausible(G_CORNER.corner, G_CORNER.closeOnly, DX, DY);
                }
                if (!HOLD_FOR_CORNER)
                    startSwipePreview();
            }
            if (!G_GESTURE.previewing)
                return; // still a tap/scroll for the client
        }

        updateSwipePreview();
        info.cancelled = true;
        return;
    }

    const auto IT = G_TOUCHES.find(e.touchID);
    if (IT == G_TOUCHES.end())
        return;

    auto&      touch    = IT->second;
    const auto PMONITOR = touch.monitor.lock();
    if (!PMONITOR) {
        G_TOUCHES.erase(IT);
        return;
    }
    touch.px = toPx(PMONITOR, e.pos);

    if (G_PINCH.active && (e.touchID == G_PINCH.idA || e.touchID == G_PINCH.idB)) {
        if (G_PINCH.finished) {
            info.cancelled = true;
            return;
        }

        const auto A = G_TOUCHES.find(G_PINCH.idA);
        const auto B = G_TOUCHES.find(G_PINCH.idB);
        if (A == G_TOUCHES.end() || B == G_TOUCHES.end()) {
            markPinchBlocked();
            clearPinch();
            return;
        }

        const double DIST = pinchDistance();
        if (!G_PINCH.previewing) {
            // Wait for a deliberate pinch before cancelling the client's
            // stream. A little movement keeps normal two-finger scroll.
            const double DEADBAND = std::max(6.0, G_PINCH.initialDistance * 0.04);
            if (std::abs(DIST - G_PINCH.initialDistance) >= DEADBAND)
                startPinchPreview();
        }

        if (G_PINCH.previewing) {
            updatePinchPreview();
            info.cancelled = true;
        }
        return;
    }

    if (G_DRAG.active) {
        if (e.touchID == G_DRAG.id) {
            info.cancelled = true;
            moveDrag(touch);
        }
        return;
    }

    // A completed pinch/drag cancels the client's touch stream; keep
    // swallowing the remaining motion of whichever finger is still down.
    if (touch.consumed) {
        info.cancelled = true;
        return;
    }

    if (G_PINCH.active)
        return; // candidate: let the client keep the touch until it commits

    // Reverse edge swipe: start in the interior, move toward an edge. The
    // target workspace is the opposite of the normal same-edge swipe.
    if (G_REVERSE.candidate && e.touchID == G_REVERSE.id) {
        const auto RMON     = G_REVERSE.monitor.lock();
        const bool ELIGIBLE = RMON && G_TOUCHES.size() == 1 && !touch.doubleTapArmed && !touch.dragBlocked && !touch.consumed;
        if (!ELIGIBLE) {
            G_REVERSE = {};
        } else {
            double      TRAVEL = 0.0;
            int         SIGN   = 0;
            bool        VERT   = false;
            const EEdge EDGE   = pickReverseEdge(RMON, G_REVERSE.startPx, touch.px, TRAVEL, SIGN, VERT);
            if (EDGE != EEdge::NONE) {
                G_GESTURE             = {};
                G_GESTURE.active      = true;
                G_GESTURE.touchID     = e.touchID;
                G_GESTURE.edge        = EDGE;
                G_GESTURE.vertical    = VERT;
                G_GESTURE.edgeSign    = SIGN;
                G_GESTURE.outward     = true;
                G_GESTURE.dominance   = 1.0;
                G_GESTURE.dir         = -SIGN;
                if (es::getInt(es::Key::INVERT, 0))
                    G_GESTURE.dir = -G_GESTURE.dir;
                G_GESTURE.startPx = G_REVERSE.startPx;
                G_GESTURE.lastPx  = touch.px;
                G_GESTURE.monitor = RMON;

                char buf[256];
                std::snprintf(buf, sizeof(buf), "reverse swipe edge=%s travel=%.0f dir=%d", edgeName(EDGE), TRAVEL, G_GESTURE.dir);
                dbgLog(buf);

                G_REVERSE = {};
                startSwipePreview();
                if (G_GESTURE.previewing) {
                    G_TOUCHES.erase(e.touchID);
                    info.cancelled = true;
                    return;
                }
            }
        }
    }

    // A one-finger vertical or mostly-vertical movement is a page scroll,
    // not a drag candidate. Remember it so a quick tap followed by another
    // swipe keeps scrolling instead of arming a window drag.
    if (!touch.doubleTapArmed && !touch.dragBlocked && !touch.onLayer) {
        const double DX = touch.px.x - touch.startPx.x;
        const double DY = touch.px.y - touch.startPx.y;
        if (std::abs(DY) > TAP_SLOP_PX && std::abs(DY) >= std::abs(DX) * SCROLL_VERTICAL_RATIO) {
            if (!touch.verticalSwipe) {
                touch.verticalSwipe = true;
                dbgLog("scroll swipe id=" + std::to_string(e.touchID));
            }
            G_LAST_VERTICAL_SWIPE = Clock::now();
        }
    }

    if (G_TOUCHES.size() == 1 && !touch.consumed && !touch.dragBlocked && !touch.onLayer && touch.doubleTapArmed && es::getInt(es::Key::DRAG_ENABLED, 1)) {
        const double TRAVEL = std::hypot(touch.px.x - touch.startPx.x, touch.px.y - touch.startPx.y);
        if (TRAVEL >= std::max(es::getInt(es::Key::DRAG_THRESHOLD, 24), 1))
            startDrag(touch, info);
    }
}

void onUp(ITouch::SUpEvent e, Event::SCallbackInfo& info) {
    if (G_CORNER.closeArmed && e.touchID == G_CORNER.id) {
        fireCorner(e.touchID, ECornerAction::CLOSE);
        clearCorner();
        info.cancelled = true;
        return;
    }

    if (G_CORNER.fired && e.touchID == G_CORNER.id) {
        clearCorner();
        info.cancelled = true;
        return;
    }

    if (G_CORNER.candidate && e.touchID == G_CORNER.id)
        clearCorner();

    if (G_REVERSE.candidate && e.touchID == G_REVERSE.id)
        G_REVERSE = {};

    if (G_GESTURE.active && e.touchID == G_GESTURE.touchID) {
        const bool PREVIEW = G_GESTURE.previewing;
        const bool COMMIT  = PREVIEW && gestureArmed();

        if (PREVIEW)
            info.cancelled = true;

        endSwipe(COMMIT);
        return;
    }

    bool consumed = false;

    if (G_DRAG.active && e.touchID == G_DRAG.id) {
        endDragAtLastPosition();
        dbgLog("drag end id=" + std::to_string(e.touchID));
        consumed = true;
    }

    if (G_PINCH.active && (e.touchID == G_PINCH.idA || e.touchID == G_PINCH.idB)) {
        if (!G_PINCH.finished)
            finishPinch();
        consumed = true;
        clearPinch();
    }

    const auto IT = G_TOUCHES.find(e.touchID);
    if (IT != G_TOUCHES.end()) {
        auto& TOUCH = IT->second;
        consumed    = consumed || TOUCH.consumed;

        // Remember a clean one-finger tap so a following tap on the same
        // window can arm a drag. The armed second tap is deliberately not
        // recorded, so a triple tap cannot chain into another arm.
        if (TOUCH.verticalSwipe)
            G_LAST_VERTICAL_SWIPE = Clock::now();

        const auto TAPWINDOW = TOUCH.window.lock();
        const bool SINGLE    = G_TOUCHES.size() == 1;
        const bool CLEAN     = !TOUCH.consumed && !TOUCH.dragBlocked && !TOUCH.onLayer && !TOUCH.multiTouch && !TOUCH.doubleTapArmed;
        const auto DURATION  = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - TOUCH.startTime).count();
        const double TRAVEL  = std::hypot(TOUCH.px.x - TOUCH.startPx.x, TOUCH.px.y - TOUCH.startPx.y);
        if (SINGLE && CLEAN && TAPWINDOW && DURATION <= TAP_MAX_DURATION_MS && TRAVEL <= std::min(12.0, dragDoubleTapPx())) {
            G_LAST_TAP.valid  = true;
            // Measure the double-tap window from the first tap-down, not the
            // release, so a held first tap cannot arm a much later drag.
            G_LAST_TAP.time   = TOUCH.startTime;
            G_LAST_TAP.px     = TOUCH.startPx;
            G_LAST_TAP.window = TAPWINDOW;
            dbgLog("drag tap recorded id=" + std::to_string(e.touchID) + " win=" + TAPWINDOW->m_title);
        }

        G_TOUCHES.erase(IT);
    }

    if (G_TOUCHES.empty()) {
        if (G_PINCH.active)
            clearPinch();
        if (G_DRAG.active)
            endDragAtLastPosition();
    }

    if (consumed)
        info.cancelled = true;
}

void onCancel(ITouch::SCancelEvent e, Event::SCallbackInfo&) {
    if ((G_CORNER.candidate || G_CORNER.fired || G_CORNER.closeArmed) && e.touchID == G_CORNER.id)
        clearCorner();

    if (G_REVERSE.candidate && e.touchID == G_REVERSE.id)
        G_REVERSE = {};

    if (G_GESTURE.active && e.touchID == G_GESTURE.touchID) {
        dbgLog("swipe cancel-event id=" + std::to_string(e.touchID));
        endSwipe(false);
    }

    if (G_DRAG.active && e.touchID == G_DRAG.id) {
        endDragAtLastPosition();
        dbgLog("drag cancel id=" + std::to_string(e.touchID));
    }

    if (G_PINCH.active && (e.touchID == G_PINCH.idA || e.touchID == G_PINCH.idB)) {
        markPinchBlocked();
        clearPinch();
    }

    if (const auto IT = G_TOUCHES.find(e.touchID); IT != G_TOUCHES.end() && IT->second.verticalSwipe)
        G_LAST_VERTICAL_SWIPE = Clock::now();

    G_TOUCHES.erase(e.touchID);
    clearTapRecord();
}

void cleanupAll() {
    endSwipe(false);
    if (G_DRAG.active) {
        if (g_layoutManager->dragController()->target())
            g_layoutManager->endDragTarget();
        G_DRAG = {};
    }
    if (G_PINCH.previewing)
        abortPinchPreview();
    G_PINCH = {};
    G_TOUCHES.clear();
    clearTapRecord();
    G_LAST_VERTICAL_SWIPE = {};
    clearCorner();
    G_REVERSE             = {};
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;
    es::registerConfig(handle);

    dbgLog(std::string("init ") + ES_NAME + " enabled=" + std::to_string(es::getInt(es::Key::ENABLED, -1)) + " zone=" +
           std::to_string(es::getInt(es::Key::ZONE_PX, -1)) + " vertical=" + std::to_string(es::getInt(es::Key::VERTICAL_ENABLED, -1)));

    G_LISTEN_DOWN   = Event::bus()->m_events.input.touch.down.listen(onDown);
    G_LISTEN_MOTION = Event::bus()->m_events.input.touch.motion.listen(onMotion);
    G_LISTEN_UP     = Event::bus()->m_events.input.touch.up.listen(onUp);
    G_LISTEN_CANCEL = Event::bus()->m_events.input.touch.cancel.listen(onCancel);

    return {ES_NAME, ES_DESC, ES_AUTHOR, ES_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    cleanupAll();

    G_LISTEN_DOWN.reset();
    G_LISTEN_MOTION.reset();
    G_LISTEN_UP.reset();
    G_LISTEN_CANCEL.reset();
}
