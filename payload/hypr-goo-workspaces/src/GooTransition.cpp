#include "GooTransition.hpp"
#include "Config.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <cmath>

namespace goo {

namespace {
constexpr double PI = 3.14159265358979323846;

double applyCurve(const std::string& name, bool out, double t) {
    if (name == "linear")
        return easeLinear(t);
    if (name == "back")
        return out ? easeInBack(t) : easeOutBack(t);
    // default "expo"
    return out ? easeInExpo(t) : easeOutExpo(t);
}
} // namespace

double easeLinear(double t) {
    return t;
}

double easeInExpo(double t) {
    if (t <= 0.0)
        return 0.0;
    if (t >= 1.0)
        return 1.0;
    return std::pow(2.0, 10.0 * t - 10.0);
}

double easeOutExpo(double t) {
    if (t <= 0.0)
        return 0.0;
    if (t >= 1.0)
        return 1.0;
    return 1.0 - std::pow(2.0, -10.0 * t);
}

double easeInBack(double t) {
    constexpr double c1 = 1.70158;
    constexpr double c3 = c1 + 1.0;
    return c3 * t * t * t - c1 * t * t;
}

double easeOutBack(double t) {
    constexpr double c1 = 1.70158;
    constexpr double c3 = c1 + 1.0;
    const double u      = t - 1.0;
    return 1.0 + c3 * u * u * u + c1 * u * u;
}

void TransitionManager::begin(MONITORID mon, WORKSPACEID oldId, WORKSPACEID newId, int side, PHLWORKSPACE oldWs, PHLWORKSPACE newWs,
                                PHLMONITOR monPtr) {
    Transition tr;
    tr.monitor = mon;
    tr.oldId   = oldId;
    tr.newId   = newId;
    tr.side    = side >= 0 ? 1 : -1;
    tr.t0      = std::chrono::steady_clock::now();
    tr.oldWs   = oldWs;
    tr.newWs   = newWs;
    tr.mon     = monPtr;
    m_transitions[mon] = std::move(tr);
}

void TransitionManager::finish(MONITORID mon) {
    auto it = m_transitions.find(mon);
    if (it == m_transitions.end())
        return;
    // Release the outgoing workspace from forced rendering so the renderer
    // goes back to culling it. Guarded: the workspace may be gone.
    if (auto ws = it->second.oldWs.lock()) {
        if (!ws->inert())
            ws->m_forceRendering = false;
    }
    // Full repaint: the goo pass rewrites pixels outside normal damage (smear
    // bleed + wobble). Without this, the last smeared frame's residue stays
    // on screen forever (ghosting/waves that never clear).
    if (auto m = it->second.mon.lock())
        g_pHyprRenderer->damageMonitor(m);
    m_transitions.erase(it);
}

bool TransitionManager::active(MONITORID mon) const {
    const auto it = m_transitions.find(mon);
    return it != m_transitions.end() && !it->second.finished;
}

std::optional<double> TransitionManager::progress(MONITORID mon, double durationMs) {
    const auto it = m_transitions.find(mon);
    if (it == m_transitions.end() || it->second.finished)
        return std::nullopt;
    if (!(durationMs > 0.0))
        durationMs = 550.0;
    const auto now = std::chrono::steady_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(now - it->second.t0).count();
    double t        = ms / durationMs;
    if (t >= 1.0) {
        it->second.finished = true;
        return 1.0;
    }
    return t < 0.0 ? 0.0 : t;
}

const Transition* TransitionManager::get(MONITORID mon) const {
    const auto it = m_transitions.find(mon);
    return it == m_transitions.end() ? nullptr : &it->second;
}

Role TransitionManager::roleFor(MONITORID mon, WORKSPACEID windowWs, PHLWORKSPACE windowWsPtr) const {
    const auto it = m_transitions.find(mon);
    if (it == m_transitions.end() || it->second.finished)
        return Role::NONE;
    // Pointer identity first: exact, no ID-semantics involved. m_workspace
    // only changes when a window MOVES workspaces, never on switches, so a
    // live pointer equal to old/new is definitive.
    if (windowWsPtr) {
        if (auto nw = it->second.newWs.lock()) {
            if (windowWsPtr == nw)
                return Role::INCOMING;
        }
        if (auto ow = it->second.oldWs.lock()) {
            if (windowWsPtr == ow)
                return Role::OUTGOING;
        }
    }
    if (windowWs == it->second.newId)
        return Role::INCOMING;
    if (windowWs == it->second.oldId)
        return Role::OUTGOING;
    return Role::NONE;
}

Transform TransitionManager::transformFor(Role role, double t, double monitorLen, int side) const {
    Transform tr;
    if (role == Role::NONE)
        return tr;
    if (t < 0.0)
        t = 0.0;
    if (t > 1.0)
        t = 1.0;

    const double slideDist = (double)getFloat(Key::SLIDE_RATIO, 0.35f) * monitorLen;
    const double s         = side >= 0 ? 1.0 : -1.0;
    const bool vertical    = getInt(Key::VERTICAL, 0) != 0;

    if (role == Role::OUTGOING) {
        // Gooey-radio out: the window collapses toward a point on the entry
        // side (like the old selection shrinking into the new one), sliding
        // that way with a mid-transition liquid reach along the motion axis.
        const std::string curve = getString(Key::OUT_CURVE, "expo");
        const double e          = applyCurve(curve, true, t);
        const double collapse   = (double)getFloat(Key::COLLAPSE, 0.32f);
        const double base       = 1.0 - (1.0 - collapse) * e;
        const double belly      = std::sin(PI * t); // 0 -> 1 -> 0
        const double stretch    = (double)getFloat(Key::STRETCH, 0.28f);
        const double squash     = (double)getFloat(Key::SQUASH, 0.18f);
        const double along      = base * (1.0 + stretch * 0.5 * belly);
        const double across     = base * (1.0 - squash * 0.5 * belly);
        const double travel     = s * slideDist * e;
        auto setAxis            = [&](Vector2D& v, double x) {
            if (vertical)
                v.y = x;
            else
                v.x = x;
        };
        setAxis(tr.offset, travel * 0.55);
        setAxis(tr.anchorShift, travel * 0.45);
        if (vertical) {
            tr.scaleY = along;
            tr.scaleX = across;
        } else {
            tr.scaleX = along;
            tr.scaleY = across;
        }
    } else {
        // Blob-switch in: travel from the entry side to rest while growing
        // from the condensed blob scale with overshoot + damped wobble. The
        // grow anchor starts pulled toward the entry side (mirror of the
        // outgoing collapse) and settles to center.
        const std::string curve = getString(Key::IN_CURVE, "back");
        const double e          = applyCurve(curve, false, t);
        const double travel     = s * slideDist * (1.0 - e);
        auto setAxis            = [&](Vector2D& v, double x) {
            if (vertical)
                v.y = x;
            else
                v.x = x;
        };
        setAxis(tr.offset, travel);
        setAxis(tr.anchorShift, travel * 0.45);
        const double blob = (double)getFloat(Key::BLOB_SCALE, 0.42f);
        double grow       = blob + (1.0 - blob) * e;
        const double wobAmp  = (double)getFloat(Key::WOBBLE_AMP, 0.06f);
        const double wobFreq = (double)getFloat(Key::WOBBLE_FREQ, 1.5f);
        if (wobAmp > 0.0 && t < 1.0) {
            const double wob = wobAmp * std::sin(2.0 * PI * wobFreq * t) * (1.0 - t);
            tr.scaleX        = grow * (1.0 + wob);
            tr.scaleY        = grow * (1.0 - wob);
        } else {
            tr.scaleX = tr.scaleY = grow;
        }
    }
    return tr;
}

double staggeredT(double t, double centerCoord, double monMin, double monLen, int side) {
    double reserve = (double)getFloat(Key::STAGGER, 0.25f);
    if (!(reserve > 0.0))
        return t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
    if (reserve > 0.6)
        reserve = 0.6;
    if (!(monLen > 0.0))
        return t;
    // Normalized distance from the entry edge (0 = at the edge).
    double d = side >= 0 ? (monMin + monLen - centerCoord) / monLen : (centerCoord - monMin) / monLen;
    if (d < 0.0)
        d = 0.0;
    if (d > 1.0)
        d = 1.0;
    const double local = (t - reserve * d) / (1.0 - reserve);
    if (local <= 0.0)
        return 0.0;
    if (local >= 1.0)
        return 1.0;
    return local;
}

} // namespace goo
