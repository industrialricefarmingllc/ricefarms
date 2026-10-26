import QtQuick

// a press that lets go where it went down is a tap; one that travels moves the card
MouseArea {
    id: tap

    property Item widget: null
    property real pressX: 0
    property real pressY: 0
    // past the slop, whether or not the card could follow
    property bool strayed: false
    property bool moved: false
    readonly property bool movable: tap.widget !== null && !tap.widget.preview && tap.widget.host !== null && !tap.widget.host.locked

    signal tapped()

    acceptedButtons: Qt.LeftButton
    hoverEnabled: true
    cursorShape: tap.moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    onPressed: (mouse) => {
        tap.pressX = mouse.x;
        tap.pressY = mouse.y;
        tap.strayed = false;
        tap.moved = false;
    }
    onPositionChanged: (mouse) => {
        if (!tap.pressed)
            return ;

        if (!tap.strayed) {
            if (Math.abs(mouse.x - tap.pressX) < 4 && Math.abs(mouse.y - tap.pressY) < 4)
                return ;

            tap.strayed = true;
            if (tap.movable) {
                tap.moved = true;
                const from = tap.mapToItem(tap.widget.host, tap.pressX, tap.pressY);
                tap.widget.host.beginDrag(from.x, from.y);
            }
        }
        if (!tap.moved)
            return ;

        const at = tap.mapToItem(tap.widget.host, mouse.x, mouse.y);
        tap.widget.host.moveDrag(at.x, at.y);
    }
    onReleased: {
        if (tap.moved) {
            tap.moved = false;
            tap.widget.host.endDrag();
            return ;
        }
        if (!tap.strayed)
            tap.tapped();

    }
    onCanceled: {
        if (tap.moved && tap.widget && tap.widget.host)
            tap.widget.host.endDrag();

        tap.moved = false;
        tap.strayed = false;
    }
}
