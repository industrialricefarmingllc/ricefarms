import QtQuick
import Quickshell

// the blur behind one card of the desktop menu's cascade, a hair inside its edge;
// empty while that card is not open
Region {
    id: slot

    property var host: null
    property int level: 0
    readonly property rect r: slot.host ? slot.host.cardRect(slot.level) : Qt.rect(0, 0, 0, 0)

    x: Math.ceil(slot.r.x)
    y: Math.ceil(slot.r.y)
    width: Math.max(0, Math.floor(slot.r.x + slot.r.width) - Math.ceil(slot.r.x))
    height: Math.max(0, Math.floor(slot.r.y + slot.r.height) - Math.ceil(slot.r.y))
    radius: slot.host ? Math.round(slot.host.cardRadius(slot.level)) : 0
}
