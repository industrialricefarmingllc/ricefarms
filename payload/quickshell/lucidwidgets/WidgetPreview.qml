import QtQuick
import qs
import "Stagger.js" as Stagger
import "../squircle"

Item {
    id: pv

    property string wtype: ""
    property string wvariant: ""
    property bool live: true
    property bool hovered: false
    // a card that owns its size, such as a stretched visualiser, draws at that size
    property real bodyW: 0
    property real bodyH: 0
    property var opts: ({})
    // waits for a free frame before building, so a page of previews fills in
    // one card at a time rather than freezing while it builds them all at once
    property bool staggered: false
    property bool _woke: !pv.staggered
    // the gallery holds a new preview back while the sheet is still sliding or
    // the list is moving: building a widget costs more than a frame, and a build
    // in the middle of an animation is a dropped frame
    property bool hold: false

    readonly property var info: Widgets.variantAt(pv.wtype, pv.wvariant)
    // drawn at the interface size, like the card it stands for
    readonly property real sizeScale: Widgets.sizeScale(pv.wtype, pv.wvariant)
    readonly property real natW: Math.round((pv.bodyW > 0 ? pv.bodyW : (pv.info ? pv.info.w : 200)) * pv.sizeScale)
    readonly property real natH: Math.round((pv.bodyH > 0 ? pv.bodyH : (pv.info ? pv.info.h : 200)) * pv.sizeScale)
    readonly property real fit: Math.min(pv.width / pv.natW, pv.height / pv.natH, 1)
    readonly property bool bare: card.item !== null && card.item.bare === true

    clip: true

    Timer {
        id: wake

        interval: 1
        running: !pv._woke
        onTriggered: {
            if (pv.hold) {
                wake.interval = 60;
                wake.restart();
                return;
            }
            const w = Stagger.wait();
            if (w > 0) {
                wake.interval = w;
                wake.restart();
                return;
            }
            pv._woke = true;
            Stagger.ran();
        }
    }

    PreviewHost {
        id: host

        wtype: pv.wtype
        wvariant: pv.wvariant
        hovered: pv.hovered
        opts: pv.opts
    }

    SquircleRect {
        anchors.centerIn: parent
        width: pv.natW
        height: pv.natH
        scale: pv.fit
        radius: card.item !== null && card.item.pill === true ? Math.min(pv.natW, pv.natH) / 2 : Theme.radiusXl
        fillColor: pv.bare ? "transparent" : (card.item && card.item.fill !== undefined ? Theme.alpha(card.item.fill, 1) : Theme.bgOpaque)
        smoothing: Prefs.squircleF
        enabled: false

        Item {
            anchors.fill: parent
            clip: true

            Loader {
                id: card

                anchors.fill: parent
                active: pv.live && pv._woke && pv.wtype !== ""
                source: pv.wtype === "" ? "" : pv.wtype.charAt(0).toUpperCase() + pv.wtype.slice(1) + "Widget.qml"
            }

            Binding {
                target: card.item
                property: "host"
                value: host
                when: card.status === Loader.Ready
            }

        }

    }

}
