import QtQuick

// Segmented control bergaya Dynamic Island: indikator bergeser ke pilihan aktif.
Rectangle {
    id: seg

    required property var theme
    property var items: []            // [{key, label}]
    property string current: ""
    signal picked(string key)

    readonly property int currentIndex: items.findIndex(i => i.key === current)
    readonly property Item currentItem: currentIndex >= 0 && segRepeater.count > currentIndex
                                        ? segRepeater.itemAt(currentIndex) : null

    implicitWidth: segRow.implicitWidth + 4
    implicitHeight: 26
    radius: 13
    color: theme.surface0

    Rectangle {
        visible: !!seg.currentItem
        x: seg.currentItem ? segRow.x + seg.currentItem.x : 2
        y: 2
        width: seg.currentItem ? seg.currentItem.width : 0
        height: seg.height - 4
        radius: 11
        color: seg.theme.surface2
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    Row {
        id: segRow
        anchors.centerIn: parent

        Repeater {
            id: segRepeater
            model: seg.items

            Item {
                id: segItem
                required property var modelData
                readonly property bool active: seg.current === modelData.key
                width: segLabel.implicitWidth + 18
                height: 22

                UiText {
                    id: segLabel
                    anchors.centerIn: parent
                    text: segItem.modelData.label
                    color: segItem.active ? seg.theme.text : seg.theme.subtext0
                    font.pixelSize: 11
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(segItem.modelData.key)
                }
            }
        }
    }
}
