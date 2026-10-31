/*
 * SPDX-FileCopyrightText: 2020 George Florea Bănuș <georgefb899@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Qt5Compat.GraphicalEffects

import org.kde.ki18n

import org.kde.haruna
import org.kde.haruna.playlist
import org.kde.haruna.utilities
import org.kde.haruna.settings

import org.kde.kirigami as Kirigami

MpvItem {
    id: root

    property var window: Window.window
    property int preMinimizePlaybackState: MpvItem.PlaybackState.Playing
    property alias mouseY: mouseArea.mouseY
    property bool isRemoteUrl: typeof currentUrl.toString() === "string" && currentUrl.toString().startsWith("http")

    signal mousePositionChanged(double x, double y)
    signal openPlaylist()
    signal closePlaylist()
    signal filesDropped(list<url> urls, int mode)

    onPlaybackStateChanged: {
        switch(playbackState) {
        case MpvItem.PlaybackState.Stopped:
            loadingIndicator.play = false
            break
        case MpvItem.PlaybackState.Playing:
            loadingIndicator.play = false
            break
        case MpvItem.PlaybackState.Loading:
            if (root.isRemoteUrl) {
                loadingIndicator.play = true
            }
            break
        }
    }

    onPlayNext: { HarunaApp.actions.playNextAction.trigger() }
    onPlayPrevious: { HarunaApp.actions.playPreviousAction.trigger() }

    // A waveform strip over the bottom of the video. The audio-only waveform uses the whole
    // surface instead, so at most one of the two is ever available for a file.
    readonly property bool waveformAvailable: waveformView.active || videoWaveform.available

    // MpvItem throttles the reported position, so a seek reaches the playhead only after the
    // next report. Track the position here and move it on seek.
    property double waveformPosition: 0
    readonly property double waveformPlayheadX: xForPosition(waveformPosition)

    // Half a grid unit around the playhead resumes instead of seeking. Pointer scale, not
    // waveform scale: the pointer stays the same size however wide the waveform is.
    readonly property double waveformResumeTolerance: Kirigami.Units.gridUnit / 2

    // A quarter of a grid unit, the small spacing scale, is a twitch rather than a drag.
    readonly property double waveformDragThreshold: Kirigami.Units.gridUnit / 4

    // Height of the video waveform strip: a fraction of the player, kept usable when small.
    readonly property int waveformStripHeight: Math.max(48, Math.min(120, Math.round(height * 0.15)))
    readonly property bool waveformStripAvailable: videoWaveform.available
    readonly property bool containsMouse: mouseArea.containsMouse

    // Set by the window: while one of the player's menus is open the strip stays rather than
    // hiding underneath it.
    property bool menuOpen: false

    // Set by the window: the footer can overlay the player, in fullscreen or as a floating
    // footer. The strip then sits above it, follows its slide, and reveals and hides with it.
    property bool bottomOverlayActive: false
    property bool bottomOverlayShown: false
    property real bottomOverlayHeight: 0

    // Without an overlaying footer, the pointer reveals the strip and scrubbing holds it.
    property bool waveformStripRevealedByPointer: false
    readonly property bool waveformStripRevealed: bottomOverlayActive ? bottomOverlayShown : waveformStripRevealedByPointer

    property bool waveformPressed: false
    property bool waveformDragging: false
    property double waveformPressX: 0
    property double waveformPressY: 0
    property double waveformPressTime: 0
    // A pending click is resolved on release: the player can change size, or playback pause,
    // before it is applied.
    property double waveformPendingPosition: 0
    property bool waveformPendingResumes: false
    property bool waveformDoubleClickPossible: false

    onWaveformStripRevealedChanged: requestVideoWaveformPeaks()

    // A click is applied after the double click interval, so that a double click reaches its
    // configured action without first seeking and pausing.
    Timer {
        id: waveformClickTimer

        // The platform's double click interval, or KDE's default when the platform reports
        // none. A shorter wait would handle a double click as two clicks again.
        interval: Qt.styleHints.mouseDoubleClickInterval > 0 ? Qt.styleHints.mouseDoubleClickInterval : 400
        repeat: false
        onTriggered: root.applyWaveformClick()
    }

    // Mirrors the footer: the pointer reveals the strip as it approaches the bottom edge, and
    // leaving that band only schedules the hide, after the footer's delay, so that passing
    // through it does not flicker.
    Timer {
        id: waveformStripHideTimer

        interval: 2000
        repeat: false
        onTriggered: {
            if (root.waveformStripHovered() || root.waveformPressed || root.menuOpen) {
                return
            }
            root.waveformStripRevealedByPointer = false
        }
    }

    Connections {
        target: root

        function onPositionChanged() {
            // A drag moves the playhead itself; a report from an earlier seek of the drag
            // would pull it back.
            if (!root.waveformDragging) {
                root.waveformPosition = root.position
            }
        }

        function onCurrentUrlChanged() {
            root.waveformPosition = 0
            root.waveformStripRevealedByPointer = false
            videoWaveform.peaksRequested = false
            // A gesture or a pending click belongs to the waveform of the previous file.
            waveformClickTimer.stop()
            root.cancelWaveformPress()
        }

        function onBottomOverlayActiveChanged() {
            // Leaving fullscreen or the floating footer hands the strip back to the pointer.
            // A reveal left over from the overlay must not show the strip with the pointer
            // elsewhere, so it ends at once instead of after the delay.
            if (!root.bottomOverlayActive
                    && !(root.waveformStripHovered() || root.waveformPressed || root.menuOpen)) {
                waveformStripHideTimer.stop()
                root.waveformStripRevealedByPointer = false
                return
            }
            root.updateWaveformStrip()
        }

        function onMenuOpenChanged() {
            // The strip waited for the menu; once it is gone, the strip stays while the pointer
            // is in the reveal band and otherwise hides after the usual delay.
            if (!root.menuOpen) {
                root.updateWaveformStrip()
            }
        }
    }

    Connections {
        target: HarunaApp

        function onQmlApplicationMouseLeave() {
            root.scheduleWaveformStripHide()
        }
    }

    Connections {
        target: videoWaveform

        function onAvailableChanged() {
            // A new file finishing loading with the pointer still in the band, or with the
            // footer shown, should show the strip without waiting for another pointer event.
            root.updateWaveformStrip()
            root.requestVideoWaveformPeaks()
        }
    }

    function xForPosition(position: double) : double {
        return root.duration > 0 ? position / root.duration * root.width : 0
    }

    function positionForX(x: double) : double {
        return root.duration > 0 && root.width > 0 ? Math.max(0, Math.min(1, x / root.width)) * root.duration : 0
    }

    function nearPlayhead(x: double) : bool {
        return Math.abs(x - root.waveformPlayheadX) <= root.waveformResumeTolerance
    }

    // True while the pointer is on the player in the band above the bottom edge that reveals
    // the strip.
    function waveformStripHovered() : bool {
        return mouseArea.containsMouse && root.mouseY > root.height - root.waveformStripHeight * 2
    }

    // The strip only takes clicks inside its visible part, following the slide, and only while
    // it is shown. It spans the whole width, so the pointer's height is enough.
    function waveformStripContains(y: double) : bool {
        return videoWaveform.available
               && videoWaveformContent.y < videoWaveform.height
               && y >= root.height - root.bottomOverlayHeight - root.waveformStripHeight + videoWaveformContent.y
               && y <= root.height - root.bottomOverlayHeight
    }

    function updateWaveformStrip() : void {
        if (!videoWaveform.available) {
            waveformStripHideTimer.stop()
            root.waveformStripRevealedByPointer = false
            return
        }
        if (root.waveformStripHovered()) {
            waveformStripHideTimer.stop()
            root.waveformStripRevealedByPointer = true
            return
        }
        // The pointer is no longer in the band: hide after the same delay as the footer.
        root.scheduleWaveformStripHide()
    }

    // The delay counts from the moment the pointer left the band.
    function scheduleWaveformStripHide() : void {
        if (!waveformStripHideTimer.running) {
            waveformStripHideTimer.start()
        }
    }

    // Peaks are decoded when the strip is first shown, and kept while the file stays loaded:
    // passing the pointer along the bottom must not decode the audio again.
    function requestVideoWaveformPeaks() : void {
        if (videoWaveform.available && root.waveformStripRevealed) {
            videoWaveform.peaksRequested = true
        }
    }

    function beginWaveformPress(x: double, y: double) : void {
        // A click still waiting to be applied here is the first of a double click, whose
        // configured action replaces it.
        waveformClickTimer.stop()
        waveformPressed = true
        waveformDragging = false
        waveformPressX = x
        waveformPressY = y
        waveformPressTime = Date.now()
        waveformDoubleClickPossible = true
    }

    // Qt makes no double click once the pointer has moved this far from the first press,
    // even if it comes back.
    function trackWaveformDoubleClickDistance(x: double, y: double) : void {
        const doubleClickDistance = Qt.styleHints.mouseDoubleClickDistance
        if (waveformDoubleClickPossible
                && (Math.abs(x - waveformPressX) > doubleClickDistance || Math.abs(y - waveformPressY) > doubleClickDistance)) {
            waveformDoubleClickPossible = false
            applyPendingWaveformClick()
        }
    }

    function continueWaveformDrag(x: double, y: double) : void {
        if (!waveformPressed) {
            return
        }
        if (!waveformDragging
                && Math.max(Math.abs(x - waveformPressX), Math.abs(y - waveformPressY)) > waveformDragThreshold) {
            waveformDragging = true
        }
        if (waveformDragging) {
            seekInWaveform(x)
        }
    }

    function finishWaveformPress(x: double, modifiers: int) : void {
        const dragged = waveformDragging
        cancelWaveformPress()
        if (dragged) {
            return
        }
        waveformPendingPosition = positionForX(x)
        waveformPendingResumes = root.pause && nearPlayhead(x)
        // Released off the player, after moving too far, or with no double click action to wait
        // for, the click cannot start a double click, and the next press could otherwise take
        // effect before it.
        if (!mouseArea.containsMouse || !waveformDoubleClickPossible || !root.hasDoubleClickAction(modifiers)) {
            applyWaveformClick()
            return
        }
        waveformClickTimer.restart()
    }

    function cancelWaveformPress() : void {
        waveformPressed = false
        waveformDragging = false
    }

    function hasDoubleClickAction(modifiers: int) : bool {
        return Models.mouseActionsModel.getAction(Qt.LeftButton, modifiers, true) !== ""
    }

    // Anything that cannot make a double click with a pending click comes after it, so the
    // click is applied first and the two take effect in order.
    function applyPendingWaveformClick() : void {
        if (waveformClickTimer.running) {
            waveformClickTimer.stop()
            applyWaveformClick()
        }
    }

    function applyWaveformClick() : void {
        if (!root.waveformAvailable) {
            return
        }
        // A click on the playhead while paused resumes. Any other click seeks there and
        // pauses, so pointing at a spot does not start playback.
        if (root.waveformPendingResumes) {
            root.pause = false
            return
        }
        seekToWaveformPosition(root.waveformPendingPosition)
        root.pause = true
    }

    function seekInWaveform(x: double) : void {
        if (!root.waveformAvailable || root.duration <= 0 || root.width <= 0) {
            return
        }
        seekToWaveformPosition(root.positionForX(x))
    }

    function seekToWaveformPosition(target: double) : void {
        root.waveformPosition = target
        root.command(["seek", target, "absolute"])
    }

    WaveformView {
        id: waveformView

        readonly property bool active: GeneralSettings.showAudioWaveform
                                       && root.finishedLoading
                                       && !root.hasVideoTrack
                                       && root.hasAudioTrack
                                       && root.isLocalFile
                                       && root.duration > 0

        anchors.fill: parent
        visible: active
        source: active ? root.currentUrl : ""
        duration: root.duration
        backgroundColor: Kirigami.Theme.backgroundColor
        waveColorEvenChannel: Kirigami.Theme.highlightColor
        waveColorOddChannel: Qt.lighter(Kirigami.Theme.highlightColor, 1.5)
        centerLineColor: Qt.alpha(Kirigami.Theme.textColor, 0.3)

        Rectangle {
            id: playhead

            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            x: Math.max(0, Math.min(parent.width - width, Math.round(root.waveformPlayheadX)))
            color: Kirigami.Theme.textColor
        }

        Label {
            anchors.centerIn: parent
            visible: waveformView.loading
            text: KI18n.i18nc("@info:status", "Generating waveform…")
            opacity: 0.6
            color: Kirigami.Theme.textColor
        }
    }

    Timer {
        id: hideCursorTimer

        running: root.window.isFullScreen() && mouseArea.containsMouse

        repeat: true
        interval: 2000
        onTriggered: mouseArea.hideCursor = true
    }

    MouseArea {
        id: mouseArea

        property bool hideCursor: false

        function triggerDoubleClickAction(mouse) : void {
            const model = Models.mouseActionsModel
            let actionName
            let modifier = mouse.modifiers
            if (mouse.button === Qt.LeftButton) {
                actionName = model.getAction(Qt.LeftButton, modifier, true)
            } else if (mouse.button === Qt.MiddleButton) {
                actionName = model.getAction(Qt.MiddleButton, modifier, true)
            } else if (mouse.button === Qt.RightButton) {
                actionName = model.getAction(Qt.RightButton, modifier, true)
            } else if (mouse.button === Qt.ForwardButton) {
                actionName = model.getAction(Qt.ForwardButton, modifier, true)
            } else if (mouse.button === Qt.BackButton) {
                actionName = model.getAction(Qt.BackButton, modifier, true)
            }

            if (actionName) {
                HarunaApp.actions[actionName].trigger()
            }
        }

        function triggerWheelAction(wheel) : void {
            const model = Models.mouseActionsModel
            let actionName
            let modifier = wheel.modifiers
            if (wheel.angleDelta.y > 0) {
                actionName = model.getAction(MouseActionsModel.ScrollUp, modifier)
            } else if (wheel.angleDelta.y) {
                actionName = model.getAction(MouseActionsModel.ScrollDown, modifier)
            }

            if (actionName) {
                HarunaApp.actions[actionName].trigger()
            }
        }

        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton | Qt.ForwardButton | Qt.BackButton
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: {
            if (hideCursor && root.window.isFullScreen()) {
                return Qt.BlankCursor
            }
            // While a button is held the cursor follows the gesture, not what is under it.
            const overWaveform = pressed
                    ? root.waveformPressed
                    : waveformView.active || root.waveformStripContains(mouseY)
            if (overWaveform) {
                // A drag keeps the playhead under the pointer, but it seeks rather than resumes.
                const resumes = root.pause && !root.waveformDragging && root.nearPlayhead(mouseX)
                return resumes ? Qt.PointingHandCursor : Qt.SizeHorCursor
            }
            return Qt.ArrowCursor
        }

        onPositionChanged: {
            root.trackWaveformDoubleClickDistance(mouseX, mouseY)

            // Dragging over the waveform seeks without touching the play state.
            if (pressed) {
                root.continueWaveformDrag(mouseX, mouseY)
            }

            root.mousePositionChanged(mouseX, mouseY)
            root.updateWaveformStrip()

            hideCursor = false
            hideCursorTimer.restart()

            // Scrubbing runs the pointer along the edges, which must not toggle the playlist.
            if (!PlaylistSettings.canToggleWithMouse || root.waveformPressed) {
                return
            }
            if (PlaylistSettings.position === "right") {
                if (mouseX > width - 50) {
                    root.openPlaylist()
                } else {
                    root.closePlaylist()
                }
            } else {
                if (mouseX < 50) {
                    root.openPlaylist()
                } else {
                    root.closePlaylist()
                }
            }
        }

        onWheel: function(wheel) {
            root.applyPendingWaveformClick()
            triggerWheelAction(wheel)
        }

        onPressed: function(mouse) {
            focus = true

            const onWaveform = mouse.button === Qt.LeftButton
                    && (waveformView.active || root.waveformStripContains(mouse.y))

            if (waveformClickTimer.running) {
                // Qt makes a double click of a left press close enough in time and place to
                // the pending click: its action, if any, replaces both clicks.
                const doubleClickDistance = Qt.styleHints.mouseDoubleClickDistance
                const completesDoubleClick = mouse.button === Qt.LeftButton
                        && root.hasDoubleClickAction(mouse.modifiers)
                        && Date.now() - root.waveformPressTime < Qt.styleHints.mouseDoubleClickInterval
                        && Math.abs(mouse.x - root.waveformPressX) <= doubleClickDistance
                        && Math.abs(mouse.y - root.waveformPressY) <= doubleClickDistance
                if (!completesDoubleClick) {
                    root.applyPendingWaveformClick()
                } else if (!onWaveform) {
                    return
                }
            }

            if (onWaveform) {
                root.beginWaveformPress(mouse.x, mouse.y)
                return
            }

            const model = Models.mouseActionsModel
            let actionName
            let modifier = mouse.modifiers
            if (mouse.button === Qt.LeftButton) {
                actionName = model.getAction(Qt.LeftButton, modifier)
            } else if (mouse.button === Qt.MiddleButton) {
                actionName = model.getAction(Qt.MiddleButton, modifier)
            } else if (mouse.button === Qt.RightButton) {
                actionName = model.getAction(Qt.RightButton, modifier)
            } else if (mouse.button === Qt.ForwardButton) {
                actionName = model.getAction(Qt.ForwardButton, modifier)
            } else if (mouse.button === Qt.BackButton) {
                actionName = model.getAction(Qt.BackButton, modifier)
            }

            if (actionName) {
                HarunaApp.actions[actionName].trigger()
            }
        }

        onCanceled: {
            root.cancelWaveformPress()
            root.updateWaveformStrip()
        }

        onReleased: function(mouse) {
            if (!root.waveformPressed || mouse.button !== Qt.LeftButton) {
                return
            }
            root.finishWaveformPress(mouse.x, mouse.modifiers)
            root.updateWaveformStrip()
        }

        onEntered: root.updateWaveformStrip()

        onExited: {
            // Off the player, for example over the footer, the next press cannot make a double
            // click with a pending click.
            root.applyPendingWaveformClick()
            root.updateWaveformStrip()
        }

        onDoubleClicked: function(mouse) {
            focus = true
            // Without an action the second press finishes as a click of its own.
            if (mouse.button === Qt.LeftButton && root.hasDoubleClickAction(mouse.modifiers)) {
                // The first click may have landed on the waveform even when this press did
                // not, across the strip's edge, and must not seek after the action.
                waveformClickTimer.stop()
                // The second press belongs to the action: it neither seeks nor holds the
                // footer and strip as a scrub does.
                root.cancelWaveformPress()
            }
            triggerDoubleClickAction(mouse)
        }
    }

    // The waveform of a video, laid over the bottom of the player. The video keeps its size:
    // the strip slides in from the bottom edge and covers the lowest part of the picture, and
    // rides above the footer while the footer overlays the player, in fullscreen or as a
    // floating footer.
    Item {
        id: videoWaveform

        readonly property bool available: GeneralSettings.showAudioWaveform
                                         && root.finishedLoading
                                         && root.hasVideoTrack
                                         && root.hasAudioTrack
                                         && root.isLocalFile
                                         && root.duration > 0

        property bool peaksRequested: false

        anchors.left: parent.left
        anchors.right: parent.right
        y: root.height - root.bottomOverlayHeight - height
        height: root.waveformStripHeight
        clip: true
        visible: available

        Item {
            id: videoWaveformContent

            // 1 while hidden, 0 while shown. Animating the fraction instead of the position
            // keeps the strip out of sight when the window is resized while it is hidden.
            property double hiddenFraction: root.waveformStripRevealed ? 0 : 1

            Behavior on hiddenFraction {
                NumberAnimation {
                    duration: Kirigami.Units.shortDuration
                    easing.type: Easing.Linear
                }
            }

            y: hiddenFraction * height
            width: videoWaveform.width
            height: videoWaveform.height

            WaveformView {
                id: videoWaveformView

                anchors.fill: parent
                visible: source.toString() !== ""
                source: videoWaveform.available && videoWaveform.peaksRequested ? root.currentUrl : ""
                duration: root.duration
                separateChannels: false
                backgroundColor: Qt.alpha(Kirigami.Theme.backgroundColor, 0.7)
                waveColorEvenChannel: Kirigami.Theme.highlightColor
                waveColorOddChannel: Qt.lighter(Kirigami.Theme.highlightColor, 1.5)
                centerLineColor: Qt.alpha(Kirigami.Theme.textColor, 0.3)
            }

            Rectangle {
                id: videoPlayhead

                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                x: Math.max(0, Math.min(parent.width - width, Math.round(root.waveformPlayheadX)))
                color: Kirigami.Theme.textColor
            }

            Label {
                anchors.centerIn: parent
                visible: videoWaveformView.loading
                text: KI18n.i18nc("@info:status", "Generating waveform…")
                opacity: 0.6
                color: Kirigami.Theme.textColor
                font: Kirigami.Theme.smallFont
            }
        }
    }

    DropArea {
        id: dropArea

        property bool dragMedia: false
        property bool dragSubtitle: false
        property int subtitleIndex: -1
        property bool mouseOnTopPart: containsDrag && dragMedia && drag.y <= height * 0.25
        property bool mouseOnBottomPart: containsDrag && dragMedia && drag.y > height * 0.25

        anchors.fill: parent
        keys: ["text/uri-list"]

        onEntered: function (drag) {
            for (var i = 0; i < drag.urls.length; ++i) {
                let mimeType = MiscUtils.mimeType(drag.urls[i])
                let isDir = PathUtils.isDir(drag.urls[i])
                if (mimeType.startsWith("video/") || mimeType.startsWith("audio/") || isDir) {
                    dragMedia = true
                    return
                }
                if (root.window.acceptedSubtitleTypes.includes(mimeType)) {
                    dragSubtitle = true
                    subtitleIndex = i
                }
            }
        }

        onExited: {
            dragMedia = false
            dragSubtitle = false
            subtitleIndex = -1
        }

        onDropped: function (drop) {
            if (dragSubtitle && !dragMedia) {
                // If dragging multiple items and none of them is a media, and if there is a subtitle, load it
                root.addSubtitles(drop.urls[subtitleIndex])
                return
            }
            if (mouseOnTopPart) {
                // Append to playlist
                root.filesDropped(drop.urls, PlaylistModel.Append)
                return
            }
            if (mouseOnBottomPart) {
                // Clear the playlist
                let isDir = PathUtils.isDir(drop.urls[0])
                if (drop.urls.length > 1 || isDir) {
                    // More than one file/folder dragged. Or at least one folder dragged.
                    root.filesDropped(drop.urls, PlaylistModel.Clear)
                } else {
                    // One file dragged
                    root.window.openFile(drop.urls[0], RecentFilesModel.OpenedFrom.ExternalApp)
                }
            }
        }

        Rectangle {
            id: topDropRect

            visible: dropArea.containsDrag
            color: "transparent"
            width: parent.width
            height: parent.height * 0.25
            radius: Kirigami.Units.cornerRadius

            anchors {
                top: dropArea.top
                left: dropArea.left
                right: dropArea.right
                margins: Kirigami.Units.smallSpacing
            }

            border {
                color: dropArea.mouseOnTopPart
                       ? Kirigami.Theme.activeTextColor
                       : "transparent"
                width: dropArea.mouseOnTopPart ? 3 : 0
            }

            Label {
                anchors.fill: parent
                anchors.centerIn: parent

                text: KI18n.i18nc("@info:drag&drop append items", "Add to Playlist")
                elide: Text.ElideRight
                color: Kirigami.Theme.textColor
                opacity: dropArea.mouseOnTopPart ? 1 : 0.7

                font.pointSize: dropArea.calculateAdaptiveFontSize(12, 30, 400, 1200)
                font.bold: true
                horizontalAlignment: Qt.AlignCenter
                verticalAlignment: Qt.AlignVCenter
                layer.enabled: true
                layer.effect: DropShadow {
                    cached: true
                    verticalOffset: 1
                    horizontalOffset: 1
                    color: Kirigami.Theme.backgroundColor
                    radius: 12
                    spread: 0.4
                    samples: 20
                }
            }
        }

        Rectangle {
            id: bottomDropRect

            visible: dropArea.containsDrag
            width: parent.width
            color: "transparent"
            radius: Kirigami.Units.cornerRadius

            anchors {
                top: topDropRect.bottom
                left: dropArea.left
                right: dropArea.right
                bottom: dropArea.bottom
                margins: Kirigami.Units.smallSpacing
            }

            border {
                color: dropArea.mouseOnBottomPart
                       ? Kirigami.Theme.activeTextColor
                       : "transparent"
                width: dropArea.mouseOnBottomPart ? 3 : 0
            }

            Label {
                anchors.fill: parent
                anchors.centerIn: parent

                text: KI18n.i18nc("@info:drag&drop play now", "Play Now")
                elide: Text.ElideRight
                color: Kirigami.Theme.textColor
                opacity: dropArea.mouseOnBottomPart ? 1 : 0.7

                font.pointSize: dropArea.calculateAdaptiveFontSize(18, 36, 400, 1200)
                font.bold: true
                horizontalAlignment: Qt.AlignCenter
                verticalAlignment: Qt.AlignVCenter
                layer.enabled: true
                layer.smooth: true
                layer.effect: DropShadow {
                    cached: true
                    verticalOffset: 1
                    horizontalOffset: 1
                    color: Kirigami.Theme.backgroundColor
                    radius: 12
                    spread: 0.4
                    samples: 20
                }
            }
        }

        function calculateAdaptiveFontSize(minPoint, maxPoint, maxWinHeight, maxWinWidth) {
            let width = root.window.width
            let height = root.window.height
            let cappedWidth = Math.min(Math.max(root.window.minimumWidth, width), maxWinWidth)
            let cappedHeight = Math.min(Math.max(root.window.minimumHeight, height), maxWinHeight)
            const widthScale = maxWinWidth - root.window.minimumWidth
            const heightScale = maxWinHeight - root.window.minimumHeight
            const pointScale = maxPoint - minPoint

            // calculate a font point size separately by considering both current width and height
            let wPoint = (((cappedWidth - root.window.minimumWidth) * pointScale) / widthScale) + minPoint
            let hPoint = (((cappedHeight - root.window.minimumHeight) * pointScale) / heightScale) + minPoint
            return Math.min(wPoint, hPoint)
        }
    }

    Rectangle {
        id: loadingIndicator

        property bool play: false
        property int size: 200

        visible: root.playbackState === MpvItem.PlaybackState.Stopped
                 || (root.playbackState === MpvItem.PlaybackState.Loading && root.isRemoteUrl)
        anchors.centerIn: parent
        radius: Kirigami.Units.cornerRadius
        width: root.width > size ? size : root.width - 10
        height: root.height > size ? size : root.height - 10
        color: play ? Qt.alpha(Kirigami.Theme.backgroundColor, 0.6) : "transparent"

        ColumnLayout {
            anchors.centerIn: parent

            Item {
                property int spriteSize: {
                    const _paddedMaxHeight = root.height - Kirigami.Units.largeSpacing * 2 - loadingText.implicitHeight
                    const _clampedHeight = Math.min(Kirigami.Units.iconSizes.enormous, _paddedMaxHeight)
                    return Math.max(Kirigami.Units.iconSizes.small, _clampedHeight)
                }
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: spriteSize
                Layout.preferredHeight: spriteSize

                Loader {
                    id: loadingIndicatorSprite

                    anchors.fill: parent
                    active: true
                    asynchronous: true
                    sourceComponent: AnimatedSprite {
                        finishBehavior: AnimatedSprite.FinishAtInitialFrame
                        frameCount: 8
                        // Do NOT use frameRate. It causes flickering. Use frameDuration instead
                        frameDuration: Math.round(1000.0 / 30.0)
                        frameHeight: 192
                        frameWidth: 192
                        interpolate: false
                        source: "qrc:/data/animations/192-haruna-animation-sliding.png"
                        reverse: false
                        running: loadingIndicator.play
                        onRunningChanged: currentFrame = 0
                    }
                }
            }

            Text {
                id: loadingText

                text: KI18n.i18nc("@label:title", "Loading…")
                visible: loadingIndicator.play

                font {
                    bold: true
                    pointSize: 16
                }

                Layout.alignment: Qt.AlignHCenter
            }

            layer.enabled: true
            layer.samplerName: "maskSource"
            layer.effect: ShaderEffect {
                property color colorSource: loadingIndicator.play ? Qt.alpha(Kirigami.Theme.textColor, 0.65) : "#222"
                fragmentShader: "qrc:/shader/colorfill.frag.qsb"
                Kirigami.Theme.inherit: false
                Kirigami.Theme.colorSet: Kirigami.Theme.Window
            }
        }
    }
}
