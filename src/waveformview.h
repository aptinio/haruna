/*
 * SPDX-FileCopyrightText: 2026 Aaron Tinio <aptinio@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include <QFutureWatcher>
#include <QMutex>
#include <QQuickPaintedItem>
#include <QUrl>

#include <atomic>
#include <memory>

#include "waveform/peaksgenerator.h"

/**
 * @brief Waveform of the audio of a media file, drawn from its peaks.
 *
 * The peaks are computed in a thread pool, so the item can be shown before the
 * waveform is ready. Channels are drawn stacked, or merged into one row when
 * separateChannels is off; a peak spans from the middle of its row upwards and down
 * again, like the audio thumbnails in Kdenlive.
 */
class WaveformView : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(double duration READ duration WRITE setDuration NOTIFY durationChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QColor backgroundColor READ backgroundColor WRITE setBackgroundColor NOTIFY colorsChanged)
    Q_PROPERTY(QColor waveColorEvenChannel READ waveColorEvenChannel WRITE setWaveColorEvenChannel NOTIFY colorsChanged)
    Q_PROPERTY(QColor waveColorOddChannel READ waveColorOddChannel WRITE setWaveColorOddChannel NOTIFY colorsChanged)
    Q_PROPERTY(QColor centerLineColor READ centerLineColor WRITE setCenterLineColor NOTIFY colorsChanged)
    Q_PROPERTY(bool separateChannels READ separateChannels WRITE setSeparateChannels NOTIFY separateChannelsChanged)

public:
    explicit WaveformView(QQuickItem *parent = nullptr);
    ~WaveformView() override;

    void paint(QPainter *painter) override;

    QUrl source() const;
    void setSource(const QUrl &source);

    double duration() const;
    void setDuration(double duration);

    bool loading() const;

    QColor backgroundColor() const;
    void setBackgroundColor(const QColor &color);

    QColor waveColorEvenChannel() const;
    void setWaveColorEvenChannel(const QColor &color);

    QColor waveColorOddChannel() const;
    void setWaveColorOddChannel(const QColor &color);

    QColor centerLineColor() const;
    void setCenterLineColor(const QColor &color);

    bool separateChannels() const;
    void setSeparateChannels(bool separate);

Q_SIGNALS:
    void sourceChanged();
    void durationChanged();
    void loadingChanged();
    void colorsChanged();
    void separateChannelsChanged();

private:
    void setLoading(bool loading);
    void loadPeaks();
    int peakAt(qsizetype start, qsizetype end, int channel) const;

    /// Peaks together with the request that produced them, so a superseded decode is dropped.
    struct PeaksResult {
        int requestId{0};
        AudioPeaks peaks;
    };

    QUrl m_source;
    int m_requestId{0};
    QFutureWatcher<PeaksResult> m_peaksWatcher;
    std::shared_ptr<std::atomic_bool> m_canceled;
    bool m_loading{false};

    QColor m_backgroundColor{Qt::transparent};
    QColor m_waveColorEvenChannel{0x2a, 0xc1, 0xa0};
    QColor m_waveColorOddChannel{0x2e, 0xd1, 0x72};
    QColor m_centerLineColor{Qt::transparent};
    bool m_separateChannels{true};
    // Seconds the width spans, the player's duration, so the drawing and the playhead share
    // a timeline even when the audio is shorter than the file.
    double m_duration{0.0};

    // Set on the GUI thread, read by the render thread while painting.
    mutable QMutex m_renderMutex;
    AudioPeaks m_peaks;
};
