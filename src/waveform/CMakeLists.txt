#
# SPDX-FileCopyrightText: 2026 Aaron Tinio <aptinio@gmail.com>
#
# SPDX-License-Identifier: BSD-3-Clause
#

qt_add_library(waveform STATIC)

target_sources(waveform
    PRIVATE
        peaksgenerator.h
        peaksgenerator.cpp
)

ecm_qt_declare_logging_category(waveform
    HEADER "logging/_waveform.h"
    IDENTIFIER "HarunaWaveform"
    CATEGORY_NAME "org.kde.haruna.waveform"
    DEFAULT_SEVERITY Info
)

target_include_directories(waveform
    PRIVATE
        ${FFMPEG_INCLUDE_DIRS}
)

target_link_libraries(waveform PRIVATE
    Qt6::Core

    ${AVUTIL_LIBRARIES}
    ${AVFORMAT_LIBRARIES}
    ${AVCODEC_LIBRARIES}
    ${SWRESAMPLE_LIBRARIES}
)
