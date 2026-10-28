#include "GooTransition.hpp"
#include "GooConfig.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <cmath>
#include <functional>

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

double springStep(double tSeconds, double stiffness, double damping, double velocity) {
    if (!(tSeconds > 0.0))
        return 0.0;
    if (!(stiffness > 0.0) || !(damping >= 0.0))
        return 1.0;
    const double omega = std::sqrt(stiffness); // mass = 1
    const double zeta  = damping / (2.0 * omega);
    if (zeta < 1.0) {
        const double wd = omega * std::sqrt(1.0 - zeta * zeta);
        const double e  = std::exp(-zeta * omega * tSeconds);
        return 1.0 - e * (std::cos(wd * tSeconds) - ((velocity - zeta * omega) / wd) * std::sin(wd * tSeconds));
    }
    // Critically damped / overdamped fallback: smooth, bounce-free.
    const double e = std::exp(-omega * tSeconds);
    return 1.0 - e * (1.0 + omega * tSeconds);
}

void TransitionManager::begin(MONITORID mon, WORKSPACEID oldId, WORKSPACEID newId, int side, bool vertical, PHLWORKSPACE oldWs,
                                PHLWORKSPACE newWs, PHLMONITOR monPtr) {
    Transition tr;
    tr.monitor  = mon;
    tr.oldId    = oldId;
    tr.newId    = newId;
    tr.side     = side >= 0 ? 1 : -1;
    tr.vertical = vertical;
    tr.t0       = std::chrono::steady_clock::now();
    tr.oldWs    = oldWs;
    tr.newWs    = newWs;
    tr.mon      = monPtr;
    m_transitions[mon] = std::move(tr);
}

Vector2D edgeCenterPoint(Vector2D monPos, Vector2D monSize, int side, bool vertical) {
    if (vertical)
        return {monPos.x + monSize.x * 0.5, side >= 0 ? monPos.y + monSize.y : monPos.y};
    return {side >= 0 ? monPos.x + monSize.x : monPos.x, monPos.y + monSize.y * 0.5};
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
        // Do NOT mark finished here. Keep returning 1.0 so the next render
        // warps every participant at the exact endpoint; sustainTick releases
        // the transition after that frame has had a chance to draw.
        if (!it->second.atEnd) {
            it->second.atEnd = true;
            it->second.endAt = now;
        }
        return 1.0;
    }
    return t < 0.0 ? 0.0 : t;
}

const Transition* TransitionManager::get(MONITORID mon) const {
    const auto it = m_transitions.find(mon);
    return it == m_transitions.end() ? nullptr : &it->second;
}

std::vector<std::pair<MONITORID, PHLMONITOR>> TransitionManager::liveMonitors() const {
    std::vector<std::pair<MONITORID, PHLMONITOR>> out;
    for (auto const& [monId, tr] : m_transitions) {
        if (tr.finished)
            continue;
        auto mon = tr.mon.lock();
        if (!mon)
            continue;
        out.emplace_back(monId, mon);
    }
    return out;
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

Transform TransitionManager::transformFor(Role role, double t, double monitorLen, int side, bool vertical) const {
    Transform tr;
    if (role == Role::NONE)
        return tr;
    if (t < 0.0)
        t = 0.0;
    if (t > 1.0)
        t = 1.0;

    const double slideDist = (double)getFloat(Key::SLIDE_RATIO, 0.18f) * monitorLen;
    const double s         = side >= 0 ? 1.0 : -1.0;

    if (role == Role::OUTGOING) {
        // Gooey-radio out: the window collapses toward a point on the entry
        // side (like the old selection shrinking into the new one), sliding
        // that way with a mid-transition liquid reach along the motion axis.
        // Alpha eases 1.0 -> fade_out_min (default 0.33) on ease-OUT (fast
        // initial dip, glide into the floor) — deliberately NOT the ease-in
        // geometry curve: ease-in expo sits at ~1.0 for 75% of the flight and
        // reads as "vanishes at the end". Material-style fades lead fast.
        const std::string curve = getString(Key::OUT_CURVE, "expo");
        const double e          = applyCurve(curve, true, t);
        double fadeMin          = (double)getFloat(Key::FADE_OUT_MIN, 0.33f);
        if (!(fadeMin >= 0.0) || fadeMin > 1.0)
            fadeMin = 0.33;
        tr.alpha                = 1.0 - (1.0 - fadeMin) * easeOutExpo(t);
        const double collapse   = (double)getFloat(Key::COLLAPSE, 0.40f);
        const double base       = 1.0 - (1.0 - collapse) * e;
        const double belly      = std::sin(PI * t); // 0 -> 1 -> 0
        const double stretch    = (double)getFloat(Key::STRETCH, 0.10f);
        const double squash     = (double)getFloat(Key::SQUASH, 0.06f);
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
        // in_curve="spring" (default) drives the grow on a true underdamped
        // spring over wall-clock time (t * duration_ms): slight, soft bounce,
        // never stiff. "back"/"expo"/"linear" keep the legacy easings.
        const std::string curve = getString(Key::IN_CURVE, "spring");
        double e          = 0.0;
        if (curve == "spring") {
            const double k  = (double)getFloat(Key::SPRING_STIFF, 110.0f);
            const double c  = (double)getFloat(Key::SPRING_DAMP, 13.0f);
            const double v0 = (double)getFloat(Key::SPRING_VEL, 4.0f);
            // Normalized spring: soft tunings never settle within a wall
            // deadline (e.g. 60/15 reaches ~95% at 400ms), and the finish
            // then snaps the last percent = abrupt end. Evaluating in fixed
            // spring-time (decoupled from wall duration: every window plays
            // the identical shape at its own pace) and dividing by the
            // endpoint value lands EXACTLY on 1.0 at localT=1, always —
            // overshoot character preserved, discontinuity deleted.
            constexpr double T_END = 0.5;
            const double     sEnd  = springStep(T_END, k, c, v0);
            if (sEnd > 1e-6 && sEnd < 1e6)
                e = springStep(t * T_END, k, c, v0) / sEnd;
            else
                e = t;
        } else {
            e = applyCurve(curve, false, t);
        }
        tr.alpha = 1.0;
        const double travel     = s * slideDist * (1.0 - e);
        auto setAxis            = [&](Vector2D& v, double x) {
            if (vertical)
                v.y = x;
            else
                v.x = x;
        };
        setAxis(tr.offset, travel);
        setAxis(tr.anchorShift, travel * 0.45);
        const double blob = (double)getFloat(Key::BLOB_SCALE, 0.60f);
        double grow       = blob + (1.0 - blob) * e;
        const double wobAmp  = (double)getFloat(Key::WOBBLE_AMP, 0.02f);
        const double wobFreq = (double)getFloat(Key::WOBBLE_FREQ, 1.5f);
        const double wob = (wobAmp > 0.0 && t < 1.0) ? wobAmp * std::sin(2.0 * PI * wobFreq * t) * (1.0 - t) : 0.0;
        // Directional liquid stretch on the way in too: elongated along the
        // motion axis at mid-flight, squashed across it, settling to 1.0 at
        // both endpoints. This is real geometry, not a screen-space overlay.
        const double belly   = std::sin(PI * t);
        const double stretch = (double)getFloat(Key::STRETCH, 0.10f);
        const double squash  = (double)getFloat(Key::SQUASH, 0.06f);
        const double along   = grow * (1.0 + wob + stretch * 0.5 * belly);
        const double across  = grow * (1.0 + wob - squash * 0.5 * belly);
        if (vertical) {
            tr.scaleY = along;
            tr.scaleX = across;
        } else {
            tr.scaleX = along;
            tr.scaleY = across;
        }
    }
    return tr;
}

double jitteredT(double t, double rank01, const void* windowKey, long long oldId, long long newId) {
    double dur = (double)getFloat(Key::DURATION_MS, 400.0f);
    if (!(dur > 0.0))
        dur = 400.0;
    double spread = (double)getFloat(Key::DUR_SPREAD, 500.0f);
    if (!(spread >= 0.0))
        spread = 0.0;
    if (!(rank01 >= 0.0) || rank01 > 1.0)
        rank01 = 0.0;
    // Rank spread (85%) + hash wobble (15%): full-range durations that never
    // collapse, with organic imperfection. Both parts stable within a
    // transition (same rank + same hash every frame). t runs over the full
    // dur+spread; window i completes at dur+spread*r_i.
    size_t h = std::hash<const void*>{}(windowKey);
    h ^= std::hash<long long>{}(oldId + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
    h ^= std::hash<long long>{}(newId + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
    const double r       = rank01 * 0.85 + (double)(h % 1000) / 1000.0 * 0.15;
    const double myDur   = dur + spread * r;
    const double total   = dur + spread;
    const double local   = t < 0.0 ? 0.0 : (t * total) / (myDur > 0.0 ? myDur : total);
    if (local <= 0.0)
        return 0.0;
    if (local >= 1.0)
        return 1.0;
    return local;
}

} // namespace goo
