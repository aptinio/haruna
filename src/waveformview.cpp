/*
 * SPDX-FileCopyrightText: 2026 Aaron Tinio <aptinio@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "waveformview.h"

#include <QPainter>
#include <QPainterPath>
#include <QtConcurrent/QtConcurrentRun>

namespace
{
constexpr qreal MaxAmplitude = 32767.0;
}

WaveformView::WaveformView(QQuickItem *parent)
    : QQuickPaintedItem(parent)
{
    setAntialiasing(false);

    connect(&m_peaksWatcher, &QFutureWatcher<PeaksResult>::finished, this, [this] {
        // The empty future that releases the previous result has none.
        if (m_peaksWatcher.future().resultCount() == 0) {
            return;
        }
        const PeaksResult result = m_peaksWatcher.result();
        if (result.requestId != m_requestId) {
            // A newer source replaced the one this decode was started for.
            return;
        }
        {
            QMutexLocker locker(&m_renderMutex);
            m_peaks = result.peaks;
        }
        setLoading(false);
        update();
    });
}

WaveformView::~WaveformView()
{
    // Do not keep decoding a file for an item that no longer exists.
    if (m_canceled) {
        m_canceled->store(true);
    }
}

void WaveformView::paint(QPainter *painter)
{
    // The render thread paints while the GUI thread sets the peaks and the colors.
    QMutexLocker locker(&m_renderMutex);

    painter->fillRect(QRectF(0, 0, width(), height()), m_backgroundColor);

    const int points = m_peaks.points();
    if (points < 1 || width() < 1 || height() < 1) {
        return;
    }
    const qreal pointsPerSecond = m_peaks.pointsPerSecond;
    const qreal duration = m_duration > 0 ? m_duration : points / pointsPerSecond;

    const int rows = m_separateChannels ? m_peaks.channels : 1;
    const qreal rowHeight = height() / rows;
    const qreal halfHeight = qMax(qreal(0), (rowHeight - 2) / 2);
    const int columns = static_cast<int>(width());

    QVector<qreal> amplitudes(columns);
    QPainterPath path;

    for (int row = 0; row < rows; ++row) {
        const qreal middle = row * rowHeight + rowHeight / 2;

        for (int column = 0; column < columns; ++column) {
            const qsizetype start = static_cast<qsizetype>(column * duration / columns * pointsPerSecond);
            qsizetype end = static_cast<qsizetype>((column + 1) * duration / columns * pointsPerSecond);
            if (end <= start) {
                // More columns than peaks, the nearest peak covers several columns.
                end = start + 1;
            }
            // Past the end of the audio the column stays empty.
            amplitudes[column] = start < points ? halfHeight * peakAt(start, qMin(end, static_cast<qsizetype>(points)), row) / MaxAmplitude : 0;
        }

        path.clear();
        path.moveTo(0, middle);
        for (int column = 0; column < columns; ++column) {
            path.lineTo(column + 0.5, middle - amplitudes[column]);
        }
        for (int column = columns - 1; column >= 0; --column) {
            path.lineTo(column + 0.5, middle + amplitudes[column]);
        }
        path.closeSubpath();

        painter->fillPath(path, row % 2 == 0 ? m_waveColorEvenChannel : m_waveColorOddChannel);

        if (m_centerLineColor.alpha() > 0) {
            painter->setPen(QPen(m_centerLineColor, 1));
            painter->drawLine(QPointF(0, middle), QPointF(width(), middle));
        }
    }
}

int WaveformView::peakAt(const qsizetype start, const qsizetype end, const int channel) const
{
    int peak = 0;
    const int channels = m_peaks.channels;

    for (qsizetype point = start; point < end; ++point) {
        if (m_separateChannels) {
            peak = qMax(peak, qAbs(static_cast<int>(m_peaks.peaks[point * channels + channel])));
            continue;
        }
        for (int sourceChannel = 0; sourceChannel < channels; ++sourceChannel) {
            peak = qMax(peak, qAbs(static_cast<int>(m_peaks.peaks[point * channels + sourceChannel])));
        }
    }

    return peak;
}

QUrl WaveformView::source() const
{
    return m_source;
}

void WaveformView::setSource(const QUrl &source)
{
    if (m_source == source) {
        return;
    }
    m_source = source;

    if (m_canceled) {
        m_canceled->store(true);
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_peaks = AudioPeaks();
    }
    update();
    loadPeaks();

    Q_EMIT sourceChanged();
}

void WaveformView::loadPeaks()
{
    const int requestId = ++m_requestId;

    if (!m_source.isLocalFile()) {
        // The finished future still holds the previous peaks.
        m_peaksWatcher.setFuture(QFuture<PeaksResult>());
        setLoading(false);
        return;
    }

    const QString path = m_source.toLocalFile();
    m_canceled = std::make_shared<std::atomic_bool>(false);
    const std::shared_ptr<std::atomic_bool> canceled = m_canceled;

    setLoading(true);
    m_peaksWatcher.setFuture(QtConcurrent::run([path, canceled, requestId] {
        return PeaksResult{requestId, AudioPeaksGenerator::generate(path, canceled.get())};
    }));
}

double WaveformView::duration() const
{
    return m_duration;
}

void WaveformView::setDuration(const double duration)
{
    if (qFuzzyCompare(m_duration, duration)) {
        return;
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_duration = duration;
    }
    update();

    Q_EMIT durationChanged();
}

bool WaveformView::loading() const
{
    return m_loading;
}

void WaveformView::setLoading(const bool loading)
{
    if (m_loading == loading) {
        return;
    }
    m_loading = loading;

    Q_EMIT loadingChanged();
}

QColor WaveformView::backgroundColor() const
{
    return m_backgroundColor;
}

void WaveformView::setBackgroundColor(const QColor &color)
{
    if (m_backgroundColor == color) {
        return;
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_backgroundColor = color;
    }
    update();

    Q_EMIT colorsChanged();
}

QColor WaveformView::waveColorEvenChannel() const
{
    return m_waveColorEvenChannel;
}

void WaveformView::setWaveColorEvenChannel(const QColor &color)
{
    if (m_waveColorEvenChannel == color) {
        return;
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_waveColorEvenChannel = color;
    }
    update();

    Q_EMIT colorsChanged();
}

QColor WaveformView::waveColorOddChannel() const
{
    return m_waveColorOddChannel;
}

void WaveformView::setWaveColorOddChannel(const QColor &color)
{
    if (m_waveColorOddChannel == color) {
        return;
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_waveColorOddChannel = color;
    }
    update();

    Q_EMIT colorsChanged();
}

QColor WaveformView::centerLineColor() const
{
    return m_centerLineColor;
}

void WaveformView::setCenterLineColor(const QColor &color)
{
    if (m_centerLineColor == color) {
        return;
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_centerLineColor = color;
    }
    update();

    Q_EMIT colorsChanged();
}

bool WaveformView::separateChannels() const
{
    return m_separateChannels;
}

void WaveformView::setSeparateChannels(const bool separate)
{
    if (m_separateChannels == separate) {
        return;
    }
    {
        QMutexLocker locker(&m_renderMutex);
        m_separateChannels = separate;
    }
    update();

    Q_EMIT separateChannelsChanged();
}
