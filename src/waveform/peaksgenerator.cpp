/*
 * SPDX-FileCopyrightText: 2026 Aaron Tinio <aptinio@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "peaksgenerator.h"

#include "logging/_waveform.h"

#include <QCryptographicHash>
#include <QDataStream>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QTemporaryFile>

#include <algorithm>
#include <cstdlib>
#include <limits>
#include <memory>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
}

namespace
{
constexpr char CacheMagic[] = "haruna-audio-peaks";
constexpr int CacheVersion = 3;
constexpr int SamplesPerPoint = AudioPeaksGenerator::SampleRate / AudioPeaksGenerator::PointsPerSecond;

static_assert(AudioPeaksGenerator::SampleRate % AudioPeaksGenerator::PointsPerSecond == 0);

/**
 * @brief Collects decoded samples and stores one peak point per time window.
 *
 * The last window is usually shorter, and still gets its point when the result is taken.
 */
class PeakCollector
{
public:
    explicit PeakCollector(const int channels)
        : m_channels(channels)
    {
    }

    void add(const qint16 *samples, const int sampleCount)
    {
        m_pending.insert(m_pending.end(), samples, samples + static_cast<qsizetype>(sampleCount) * m_channels);

        const size_t window = static_cast<size_t>(SamplesPerPoint) * static_cast<size_t>(m_channels);
        size_t consumed = 0;
        while (m_pending.size() - consumed >= window) {
            appendPoint(m_pending.data() + consumed, SamplesPerPoint);
            consumed += window;
        }
        m_pending.erase(m_pending.begin(), m_pending.begin() + static_cast<std::ptrdiff_t>(consumed));
    }

    void addSilence(const qint64 points)
    {
        if (points > 0) {
            m_points.insert(m_points.size(), points * m_channels, 0);
        }
    }

    // Ends the collection: the points move into the result, so a long file is not held
    // twice over.
    AudioPeaks takeResult()
    {
        if (!m_pending.empty()) {
            appendPoint(m_pending.data(), static_cast<int>(m_pending.size()) / m_channels);
            m_pending.clear();
        }
        AudioPeaks peaks;
        peaks.channels = m_channels;
        peaks.pointsPerSecond = AudioPeaksGenerator::PointsPerSecond;
        peaks.peaks = std::move(m_points);
        return peaks;
    }

private:
    void appendPoint(const qint16 *samples, const int sampleCount)
    {
        for (int channel = 0; channel < m_channels; ++channel) {
            int peak = 0;
            for (int sample = 0; sample < sampleCount; ++sample) {
                peak = std::max(peak, std::abs(static_cast<int>(samples[sample * m_channels + channel])));
            }
            m_points.push_back(static_cast<qint16>(std::min(peak, int(std::numeric_limits<qint16>::max()))));
        }
    }

    int m_channels;
    QVector<qint16> m_points;
    std::vector<qint16> m_pending;
};

void saveCache(const QString &cachePath, const AudioPeaks &peaks)
{
    QDir().mkpath(QFileInfo(cachePath).absolutePath());

    // Write to a temporary file first so an interrupted run cannot leave a partial entry.
    // The name is unique per process, so two instances decoding the same file at the same
    // time cannot write into each other's temporary file.
    QTemporaryFile file(cachePath + QStringLiteral(".XXXXXX"));
    if (!file.open()) {
        qCWarning(HarunaWaveform) << "Could not write the peaks cache" << cachePath << file.errorString();
        return;
    }

    QDataStream stream(&file);
    stream << QByteArray(CacheMagic, sizeof(CacheMagic) - 1) << CacheVersion << AudioPeaksGenerator::SampleRate << AudioPeaksGenerator::PointsPerSecond
           << peaks.channels << peaks.peaks;
    file.close();
    if (stream.status() != QDataStream::Ok || file.error() != QFile::NoError) {
        qCWarning(HarunaWaveform) << "Could not write the peaks cache" << cachePath;
        return;
    }

    // QTemporaryFile::rename() refuses an existing destination, so an entry that fails
    // validation would otherwise never be replaced.
    QFile::remove(cachePath);

    // Renaming makes the temporary file the cache entry, so its automatic removal has to be
    // turned off first or the destructor deletes the entry that was just published.
    file.setAutoRemove(false);
    if (!file.rename(cachePath)) {
        qCWarning(HarunaWaveform) << "Could not move the peaks cache into place" << cachePath;
        file.remove();
    }
}

AudioPeaks readCache(const QString &cachePath)
{
    QFile file(cachePath);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }

    QDataStream stream(&file);
    QByteArray magic;
    int version = 0;
    int sampleRate = 0;
    int pointsPerSecond = 0;
    int channels = 0;
    QVector<qint16> points;
    stream >> magic >> version >> sampleRate >> pointsPerSecond >> channels >> points;

    if (stream.status() != QDataStream::Ok || magic != QByteArray(CacheMagic, sizeof(CacheMagic) - 1) || version != CacheVersion
        || sampleRate != AudioPeaksGenerator::SampleRate || pointsPerSecond != AudioPeaksGenerator::PointsPerSecond || channels < 1 || points.isEmpty()
        || points.size() % channels != 0) {
        qCWarning(HarunaWaveform) << "Ignoring an invalid peaks cache entry" << cachePath;
        return {};
    }

    AudioPeaks peaks;
    peaks.channels = channels;
    peaks.pointsPerSecond = pointsPerSecond;
    peaks.peaks = points;
    return peaks;
}

AudioPeaks decodeFile(const QString &path, const std::atomic_bool *canceled)
{
    const QByteArray fileName = QFile::encodeName(path);

    AVFormatContext *formatContext = nullptr;
    if (avformat_open_input(&formatContext, fileName.constData(), nullptr, nullptr) < 0) {
        qCWarning(HarunaWaveform) << "Could not open" << path;
        return {};
    }

    AVCodecContext *codecContext = nullptr;
    SwrContext *resampler = nullptr;
    AVChannelLayout inputLayout{};
    AVChannelLayout outLayout{};
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();

    auto cleanup = [&] {
        av_channel_layout_uninit(&inputLayout);
        av_channel_layout_uninit(&outLayout);
        swr_free(&resampler);
        avcodec_free_context(&codecContext);
        av_frame_free(&frame);
        av_packet_free(&packet);
        avformat_close_input(&formatContext);
    };
    auto fail = [&](const char *message) {
        qCWarning(HarunaWaveform) << message << path;
        cleanup();
    };

    if (!packet || !frame) {
        fail("Could not allocate the audio buffers for");
        return {};
    }

    if (avformat_find_stream_info(formatContext, nullptr) < 0) {
        fail("Could not read the stream info of");
        return {};
    }

    const int streamIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (streamIndex < 0) {
        fail("Could not find an audio stream in");
        return {};
    }

    const AVStream *stream = formatContext->streams[streamIndex];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        fail("Could not find a decoder for the audio stream of");
        return {};
    }

    codecContext = avcodec_alloc_context3(codec);
    if (!codecContext || avcodec_parameters_to_context(codecContext, stream->codecpar) < 0) {
        fail("Could not set up the audio decoder for");
        return {};
    }
    codecContext->pkt_timebase = stream->time_base;

    if (avcodec_open2(codecContext, codec, nullptr) < 0) {
        fail("Could not open the audio decoder for");
        return {};
    }

    if (codecContext->ch_layout.nb_channels < 1 || codecContext->sample_rate < 1 || codecContext->sample_fmt == AV_SAMPLE_FMT_NONE) {
        fail("Unsupported audio format in");
        return {};
    }

    int channels = 0;
    int inputSampleFormat = AV_SAMPLE_FMT_NONE;
    int inputSampleRate = 0;
    std::unique_ptr<PeakCollector> collector;
    QVector<qint16> converted;
    bool wasCanceled = false;
    bool failed = false;

    // Passes a frame through the resampler into the collector; without a frame it drains the
    // samples the resampler still holds.
    auto resample = [&](const AVFrame *decoded) -> bool {
        const int inputSamples = decoded ? decoded->nb_samples : 0;
        const int capacity = static_cast<int>(swr_get_out_samples(resampler, inputSamples));
        if (capacity < 1) {
            return true;
        }
        converted.resize(static_cast<qsizetype>(capacity) * channels);
        uint8_t *output[] = {reinterpret_cast<uint8_t *>(converted.data())};
        const uint8_t **input = decoded ? const_cast<const uint8_t **>(decoded->extended_data) : nullptr;
        const int count = swr_convert(resampler, output, capacity, input, inputSamples);
        if (count < 0) {
            return false;
        }
        if (count > 0) {
            collector->add(converted.constData(), count);
        }
        return true;
    };

    // The decoder picks the output format and can change it mid stream, for example HE-AAC
    // switching sample rate, so the resampler is built from the first frame and rebuilt when
    // a frame no longer matches it. The peaks keep the channel layout of the first frame, and
    // a later change of channels, for example a broadcast switching between stereo and 5.1,
    // is mixed into it.
    auto adoptFrameFormat = [&](const AVFrame *decoded) -> bool {
        const int frameChannels = decoded->ch_layout.nb_channels;
        if (frameChannels < 1 || decoded->sample_rate < 1 || decoded->format == AV_SAMPLE_FMT_NONE) {
            return false;
        }
        if (resampler && decoded->format == inputSampleFormat && decoded->sample_rate == inputSampleRate
            && av_channel_layout_compare(&decoded->ch_layout, &inputLayout) == 0) {
            return true;
        }

        // The samples the old resampler still holds come before this frame.
        if (resampler && !resample(nullptr)) {
            return false;
        }
        swr_free(&resampler);
        if (av_channel_layout_copy(&inputLayout, &decoded->ch_layout) < 0 || (!collector && av_channel_layout_copy(&outLayout, &decoded->ch_layout) < 0)) {
            return false;
        }
        inputSampleFormat = decoded->format;
        inputSampleRate = decoded->sample_rate;
        if (swr_alloc_set_opts2(&resampler,
                                &outLayout,
                                AV_SAMPLE_FMT_S16,
                                AudioPeaksGenerator::SampleRate,
                                &inputLayout,
                                static_cast<AVSampleFormat>(inputSampleFormat),
                                inputSampleRate,
                                0,
                                nullptr)
                < 0
            || swr_init(resampler) < 0) {
            return false;
        }

        if (!collector) {
            channels = frameChannels;
            collector = std::make_unique<PeakCollector>(channels);

            // The playback position counts from the start of the file, and the audio can
            // start later, for example after the first frames of a video. Leading silence
            // keeps the peaks on that timeline.
            if (decoded->best_effort_timestamp != AV_NOPTS_VALUE) {
                const int64_t fileStart = formatContext->start_time != AV_NOPTS_VALUE ? formatContext->start_time : 0;
                const int64_t audioStart = av_rescale_q(decoded->best_effort_timestamp, stream->time_base, AVRational{1, AV_TIME_BASE});
                collector->addSilence(av_rescale(audioStart - fileStart, AudioPeaksGenerator::PointsPerSecond, AV_TIME_BASE));
            }
        }
        return true;
    };

    auto convert = [&](const AVFrame *decoded) {
        if ((decoded && !adoptFrameFormat(decoded)) || (resampler && !resample(decoded))) {
            qCWarning(HarunaWaveform) << "Could not convert the audio of" << path;
            failed = true;
        }
    };

    auto drainDecoder = [&] {
        while (true) {
            const int result = avcodec_receive_frame(codecContext, frame);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
                return;
            }
            if (result < 0) {
                qCWarning(HarunaWaveform) << "Could not decode the audio of" << path;
                failed = true;
                return;
            }
            convert(frame);
            if (failed) {
                return;
            }
        }
    };

    while (true) {
        const int readResult = av_read_frame(formatContext, packet);
        if (readResult < 0) {
            // Anything but a clean end of stream must not be mistaken for one, or a broken
            // read would be published as a complete waveform.
            if (readResult != AVERROR_EOF) {
                qCWarning(HarunaWaveform) << "Could not read" << path;
                failed = true;
            }
            break;
        }
        if (canceled && canceled->load()) {
            wasCanceled = true;
            av_packet_unref(packet);
            break;
        }
        if (packet->stream_index == streamIndex) {
            if (avcodec_send_packet(codecContext, packet) < 0) {
                qCWarning(HarunaWaveform) << "Could not decode the audio of" << path;
                av_packet_unref(packet);
                failed = true;
                break;
            }
            drainDecoder();
        }
        av_packet_unref(packet);
        if (failed) {
            break;
        }
    }

    if (!wasCanceled && !failed) {
        avcodec_send_packet(codecContext, nullptr);
        drainDecoder();
        // Drain the samples the resampler still holds, otherwise the end of the file is lost.
        if (!failed) {
            convert(nullptr);
        }
    }

    if (!wasCanceled && canceled && canceled->load()) {
        wasCanceled = true;
    }

    cleanup();

    if (wasCanceled) {
        qCDebug(HarunaWaveform) << "Canceled the peaks of" << path;
        return {};
    }
    // Every failure has already been logged where it happened.
    if (failed) {
        return {};
    }

    return collector ? collector->takeResult() : AudioPeaks();
}
} // namespace

AudioPeaks AudioPeaksGenerator::generate(const QString &path, const std::atomic_bool *canceled)
{
    const QString cachePath = cacheFilePath(path);

    AudioPeaks peaks = readCache(cachePath);
    if (!peaks.isEmpty()) {
        return peaks;
    }

    peaks = decodeFile(path, canceled);
    if (peaks.isEmpty()) {
        return peaks;
    }

    saveCache(cachePath, peaks);
    return peaks;
}

QString AudioPeaksGenerator::cacheFilePath(const QString &path)
{
    const QFileInfo info(path);
    const QString key = QStringLiteral("%1|%2|%3|%4")
                            .arg(info.absoluteFilePath(),
                                 QString::number(info.size()),
                                 QString::number(info.lastModified().toMSecsSinceEpoch()),
                                 QString::number(PointsPerSecond));
    const QString hash = QString::fromLatin1(QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Sha1).toHex());

    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/waveforms/") + hash;
}
