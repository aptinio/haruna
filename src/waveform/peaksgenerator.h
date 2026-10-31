/*
 * SPDX-FileCopyrightText: 2026 Aaron Tinio <aptinio@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include <QString>
#include <QVector>

#include <atomic>

/**
 * @brief Audio peaks of a media file, the data a waveform is drawn from.
 *
 * A peak is the largest absolute sample value in a fixed time window. Points are
 * stored interleaved by channel: point n of channel c is at peaks[n * channels + c].
 */
struct AudioPeaks {
    QVector<qint16> peaks;
    int channels{0};
    int pointsPerSecond{0};

    int points() const
    {
        return channels > 0 ? static_cast<int>(peaks.size()) / channels : 0;
    }

    bool isEmpty() const
    {
        return peaks.isEmpty() || channels < 1 || pointsPerSecond < 1;
    }
};

class AudioPeaksGenerator
{
public:
    /// Peak points per second of audio, each covering a window of 1/PointsPerSecond seconds.
    static constexpr int PointsPerSecond = 200;
    /// Sample rate the audio is converted to before peaks are computed.
    static constexpr int SampleRate = 48000;

    /**
     * @brief Peaks of the file at @p path.
     *
     * Read from the peaks cache when it holds an entry for the file, decoded with
     * libav otherwise. Returns empty peaks when the file has no decodable audio,
     * when decoding fails, or when @p canceled is set while decoding.
     *
     * The peaks are always those of the default audio stream, so a file with several
     * streams gets the waveform of the stream libav picks, even while another is playing.
     */
    static AudioPeaks generate(const QString &path, const std::atomic_bool *canceled = nullptr);

    /// Cache file the peaks of @p path are stored in.
    static QString cacheFilePath(const QString &path);
};
