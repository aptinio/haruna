/*
 * SPDX-FileCopyrightText: 2024 George Florea Bănuș <georgefb899@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.kde.ki18n

import org.kde.kirigami as Kirigami
import org.kde.haruna
import org.kde.haruna.playlist
import org.kde.haruna.settings

Item {
    id: root

    required property MpvVideo m_mpv
    required property PlaylistsManager playlistsManager
    required property MenuBarLoader m_menuBarLoader
    required property Header m_header
    required property SettingsWindow m_settingsLoader

    property alias progressBar: progressBar
    property string footerState: isFloating ? "hidden" : "visible"
    property bool isFloating: GeneralSettings.footerStyle === "floating"
    property bool isSmallSize: width < 600
    property int buttonSize: isSmallSize ? Kirigami.Units.iconSizes.small : Kirigami.Units.iconSizes.smallMedium
    readonly property bool menuOpen: hamburgerMenu.isOpen || root.progressBar.chaptersPopupIsOpen
    // Height of the footer over the bottom of the window, including its slide in and out.
    readonly property real overlayHeight: footer.visible ? root.height - footer.y : 0
    // The video waveform strip sits above the footer's root area, so the taller of the two also
    // decides when the footer appears, and both leave at the same pointer distance.
    readonly property real revealHeight: root.m_mpv.waveformStripAvailable
                                         ? Math.max(root.height, root.m_mpv.waveformStripHeight)
                                         : footer.height

    implicitWidth: Window.window.contentItem.width
    implicitHeight: root.isFloating
                    ? footer.height + Kirigami.Units.largeSpacing * (root.isSmallSize ? 1 : 2)
                    : footer.height

    ToolBar {
        id: footer

        x: (root.width - width) / 2
        width: root.isFloating
               ? Math.min(Window.window.contentItem.width - Kirigami.Units.largeSpacing * (root.isSmallSize ? 2 : 4), 900)
               : root.width

        state: root.footerState
        padding: Kirigami.Units.smallSpacing
        position: ToolBar.Footer
        hoverEnabled: true
        background: Rectangle {
            color: Qt.alpha(Kirigami.Theme.backgroundColor, root.isFloating ? 0.8 : 1.0)
            radius: root.isFloating ? Kirigami.Units.cornerRadius : 0
        }

        Connections {
            target: HarunaApp
            function onQmlApplicationMouseLeave() {
                if (root.isFloating) {
                    hideFooterTimer.start()
                }
            }
        }

        Connections {
            target: root.m_mpv
            function onMousePositionChanged(x, y) {
                Qt.callLater(footer.setState)
            }

            function onWaveformPressedChanged() {
                // A scrub that ends without another pointer move still has to reevaluate the
                // footer, or a floating footer can be left open.
                Qt.callLater(footer.setState)
            }

            function onMenuOpenChanged() {
                // The footer waits for an open menu; reevaluate once it closes.
                Qt.callLater(footer.setState)
            }
        }

        Connections {
            target: root.Window.window
            function onVisibilityChanged() {
                // Entering fullscreen with the pointer away from the bottom hides the footer
                // at once instead of flashing for the whole delay.
                const mainWindow = root.Window.window as Main
                const inBand = root.m_mpv.containsMouse
                               && root.m_mpv.mouseY > root.m_mpv.height - root.revealHeight * 2
                // Whatever holds the footer against the hide delay holds it here too.
                const held = footer.hovered || root.m_mpv.menuOpen || root.m_mpv.waveformPressed
                if (mainWindow.isFullScreen() && !inBand && !held) {
                    hideFooterTimer.stop()
                    root.footerState = "hidden"
                }
            }
        }

        Timer {
            interval: 50
            running: !root.isFloating
            repeat: true
            onTriggered: {
                Qt.callLater(footer.staticState)
            }
        }

        Timer {
            id: hideFooterTimer

            running: false
            repeat: false
            interval: 2000
            onTriggered: {
                if (footer.hovered || root.m_mpv.menuOpen || root.m_mpv.waveformPressed) {
                    return
                }
                // Started in fullscreen, it can run out after leaving it, where the docked
                // footer stays.
                const mainWindow = root.Window.window as Main
                if (!root.isFloating && !mainWindow.isFullScreen()) {
                    return
                }

                root.footerState = "hidden"
            }
        }

        Component {
            id: togglePlaylistButton

            ToolButton {
                action: HarunaApp.actions.togglePlaylistAction
                icon.width: root.buttonSize
                icon.height: root.buttonSize
                display: root.isSmallSize ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
            }
        }

        ColumnLayout {
            spacing: 0
            anchors.fill: parent

            RowLayout {
                id: footerRow

                spacing: root.isSmallSize ? 1 : Kirigami.Units.smallSpacing

                HamburgerMenu {
                    id: hamburgerMenu

                    m_mpv: root.m_mpv
                    m_settingsLoader: root.m_settingsLoader
                    m_menuBarLoader: root.m_menuBarLoader

                    position: HamburgerMenu.Position.Footer
                    visible: root.m_menuBarLoader.state === "hidden" && !root.m_header.visible
                    icon.width: root.buttonSize
                    icon.height: root.buttonSize
                }

                Loader {
                    sourceComponent: togglePlaylistButton
                    active: !PlaylistSettings.canToggleWithMouse && PlaylistSettings.position === "left"
                    visible: active
                    asynchronous: false
                }

                ToolButton {
                    id: playPauseButton

                    display: AbstractButton.IconOnly
                    icon.name: root.m_mpv.pause ? "media-playback-start" : "media-playback-pause"
                    icon.width: root.buttonSize
                    icon.height: root.buttonSize
                    focusPolicy: Qt.NoFocus
                    enabled: root.m_mpv.duration !== 0

                    onClicked: HarunaApp.actions.playPauseAction.trigger()

                    ToolTip {
                        id: playPauseButtonToolTip

                        text: root.m_mpv.pause ? KI18n.i18nc("@info:tooltip", "Start playback") : KI18n.i18nc("@info:tooltip", "Pause playback")
                        delay: HarunaApp.isAltKeyPressed ? 0 : Kirigami.Units.toolTipDelay
                        visible: playPauseButton.hovered
                                 && (GeneralSettings.showExplanatoryToolTips || HarunaApp.isAltKeyPressed)
                    }
                }

                ToolButton {
                    id: playPreviousFile

                    icon.name: footer.LayoutMirroring.enabled ? "media-skip-forward" : "media-skip-backward"
                    icon.width: root.buttonSize
                    icon.height: root.buttonSize
                    display: AbstractButton.IconOnly
                    focusPolicy: Qt.NoFocus
                    enabled: root.playlistsManager.activePlaylist.itemCount > 1

                    onClicked: HarunaApp.actions.playPreviousAction.trigger()

                    ToolTip {
                        text: KI18n.i18nc("@info:tooltip", "Play previous file")
                        delay: HarunaApp.isAltKeyPressed ? 0 : Kirigami.Units.toolTipDelay
                        visible: playPreviousFile.hovered
                                 && (GeneralSettings.showExplanatoryToolTips || HarunaApp.isAltKeyPressed)
                    }
                }

                ToolButton {
                    id: playNextFile

                    icon.name: footer.LayoutMirroring.enabled ? "media-skip-backward" : "media-skip-forward"
                    icon.width: root.buttonSize
                    icon.height: root.buttonSize
                    display: AbstractButton.IconOnly
                    focusPolicy: Qt.NoFocus
                    enabled: root.playlistsManager.activePlaylist.itemCount > 1

                    onClicked: HarunaApp.actions.playNextAction.trigger()

                    ToolTip {
                        text: KI18n.i18nc("@info:tooltip", "Play next file")
                        delay: HarunaApp.isAltKeyPressed ? 0 : Kirigami.Units.toolTipDelay
                        visible: playNextFile.hovered
                                 && (GeneralSettings.showExplanatoryToolTips || HarunaApp.isAltKeyPressed)
                    }
                }

                ToolButton {
                    id: chaptersMenuButton

                    icon.name: "overflow-menu"
                    focusPolicy: Qt.NoFocus
                    visible: !progressBar.showChapterMarkers && root.m_mpv.chaptersModel.rowCount > 0

                    onClicked: {
                        progressBar.openChapterPopup(this)
                    }

                    ToolTip {
                        text: KI18n.i18nc("@info:tooltip", "Open chapters menu")
                        delay: HarunaApp.isAltKeyPressed ? 0 : Kirigami.Units.toolTipDelay
                        visible: chaptersMenuButton.hovered
                                 && (GeneralSettings.showExplanatoryToolTips || HarunaApp.isAltKeyPressed)
                    }
                }

                HProgressBar {
                    id: progressBar

                    m_mpv: root.m_mpv

                    Layout.fillWidth: true
                    Layout.preferredHeight: 20
                }

                ToolButton {
                    id: mute

                    action: HarunaApp.actions.muteAction
                    icon.name: root.m_mpv.mute || root.m_mpv.volume === 0 ? "player-volume-muted" : "player-volume"
                    icon.width: root.buttonSize
                    icon.height: root.buttonSize
                    display: AbstractButton.IconOnly
                    focusPolicy: Qt.NoFocus

                    ToolTip {
                        text: HarunaApp.actions.muteAction.text
                        delay: HarunaApp.isAltKeyPressed ? 0 : Kirigami.Units.toolTipDelay
                        visible: mute.hovered
                                 && (GeneralSettings.showExplanatoryToolTips || HarunaApp.isAltKeyPressed)
                    }
                }


                VolumeSlider {
                    id: volumeSlider

                    m_mpv: root.m_mpv
                    label.font.pointSize: root.isSmallSize ? 8 : 10

                    Layout.preferredWidth: root.isSmallSize ? 60 : 100
                    Layout.preferredHeight: 20
                }

                Loader {
                    sourceComponent: togglePlaylistButton
                    active: !PlaylistSettings.canToggleWithMouse && PlaylistSettings.position === "right"
                    visible: active
                    asynchronous: false
                }
            }

            RowLayout {
                LabelWithTooltip {
                    id: mediaTitleLabel

                    text: root.m_mpv.mediaTitle
                    font.pointSize: 9
                    toolTipText: root.m_mpv.mediaTitle
                    elide: Text.ElideRight

                    Layout.fillWidth: true
                }

                LabelWithTooltip {
                    id: timeInfo

                    text: "%1 / %2".arg(root.m_mpv.formattedPosition).arg(root.m_mpv.formattedDuration)
                    font.pointSize: 9
                    toolTipText: KI18n.i18nc("@info:tooltip", "Remaining: %1", root.m_mpv.formattedRemaining)
                    alwaysShowToolTip: true
                    horizontalAlignment: Qt.AlignHCenter

                    Layout.minimumWidth: textMetrics.width

                    TextMetrics {
                        id: textMetrics

                        font: timeInfo.font
                        text: "000:00:00 / 000:00:00"
                    }
                }
            }
        }

        function setState() : void {
            if (root.isFloating) {
                floatingState()
            } else {
                staticState()
            }
        }

        function floatingState() {
            if (GeneralSettings.floatingFooterTrigger === "EveryMouseMovement") {
                hideFooterTimer.stop()
                root.footerState = "visible"
                if (root.m_mpv.mouseY < root.m_mpv.height - root.revealHeight * 2) {
                    hideFooterTimer.restart()
                }
            } else {
                if (root.m_mpv.mouseY > root.m_mpv.height - root.revealHeight * 2) {
                    if (root.m_mpv.containsMouse) {
                        hideFooterTimer.stop()
                        root.footerState = "visible"
                    }
                } else {
                    hideFooterTimer.start()
                }
            }
        }

        function staticState() {
            const mainWindow = Window.window as Main
            if (!mainWindow.isFullScreen()
                    || (root.m_mpv.mouseY > root.m_mpv.height - root.revealHeight * 2
                        && root.m_mpv.containsMouse)) {
                hideFooterTimer.stop()
                root.footerState = "visible"
                return
            }
            if (root.footerState === "visible" && !hideFooterTimer.running) {
                hideFooterTimer.start()
            }
        }

        states: [
            State {
                name: "hidden"
                PropertyChanges {
                    footer.y: root.height
                    footer.visible: false
                }
            },
            State {
                name : "visible"
                PropertyChanges {
                    footer.y: 0
                    footer.visible: true
                }
            }
        ]

        transitions: [
            Transition {
                from: "visible"
                to: "hidden"

                SequentialAnimation {
                    ParallelAnimation {
                        NumberAnimation {
                            target: footer
                            property: "y"
                            duration: Kirigami.Units.shortDuration
                            easing.type: Easing.Linear
                        }
                    }
                    PropertyAction {
                        target: footer
                        property: "visible"
                        value: false
                    }
                }
            },
            Transition {
                from: "hidden"
                to: "visible"

                SequentialAnimation {
                    PropertyAction {
                        target: footer
                        property: "visible"
                        value: true
                    }
                    ParallelAnimation {
                        NumberAnimation {
                            target: footer
                            property: "y"
                            duration: Kirigami.Units.shortDuration
                            easing.type: Easing.Linear
                        }
                    }
                }
            }
        ]
    }
}
