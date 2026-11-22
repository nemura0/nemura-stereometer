// `--feed <file.wav>`: a WAV file played into the meter view.
#include "nmr_corec.h"

#import <nmr/render_view.h>
#include <nmr/file_player.h>
#include <nmr/wav_file.h>

#include <memory>
#include <optional>
#include <utility>

#include "corec_internal.h"

#if !__has_feature(objc_arc)
#error "Sources/CoreC is compiled with ARC (-fobjc-arc) in every build"
#endif

struct nmr_file_feed {
  NMR_OBJC(RenderView) * view;
  std::unique_ptr<nmr::FilePlayer> player;
};

namespace {

nmr_feed_error toC(nmr::wav::Error error) noexcept {
  switch (error) {
    case nmr::wav::Error::kNone: return NMR_FEED_OK;
    case nmr::wav::Error::kUnreadable: return NMR_FEED_UNREADABLE;
    case nmr::wav::Error::kNotWav: return NMR_FEED_NOT_WAV;
    case nmr::wav::Error::kUnsupported: return NMR_FEED_UNSUPPORTED;
    case nmr::wav::Error::kEmpty: return NMR_FEED_EMPTY;
    case nmr::wav::Error::kTooLong: return NMR_FEED_TOO_LONG;
  }
  return NMR_FEED_UNREADABLE;
}

}  // namespace

nmr_file_feed* nmr_file_feed_create(void* view, const char* path, nmr_feed_error* error,
                                    double* sample_rate) {
  nmr_feed_error ignored = NMR_FEED_OK;
  nmr_feed_error& result = error != nullptr ? *error : ignored;
  result = NMR_FEED_UNREADABLE;
  if (view == nullptr || path == nullptr) return nullptr;
  // Anything thrown (out of memory) is a feed that could not be set up.
  return nmr::corec::guarded<nmr_file_feed*>(nullptr, [&]() -> nmr_file_feed* {
    result = NMR_FEED_FAILED;
    nmr::wav::Error wav_error = nmr::wav::Error::kUnreadable;
    std::optional<nmr::wav::Audio> audio = nmr::wav::read(path, wav_error);
    result = toC(wav_error);
    if (!audio) return nullptr;
    const double rate = audio->sample_rate;
    result = NMR_FEED_FAILED;
    auto player = std::make_unique<nmr::FilePlayer>(std::move(*audio));
    auto feed = std::make_unique<nmr_file_feed>(
        nmr_file_feed{(__bridge NMR_OBJC(RenderView)*)view, std::move(player)});
    if (!feed->player->start()) return nullptr;
    [feed->view setSource:feed->player->view() sampleRate:feed->player->sampleRate()];
    result = NMR_FEED_OK;
    if (sample_rate != nullptr) *sample_rate = rate;
    return feed.release();
  });
}

void nmr_file_feed_destroy(nmr_file_feed* feed) {
  if (feed == nullptr) return;
  [feed->view setSource:nmr::FrameRingView{} sampleRate:0];  // returns once nothing reads it
  delete feed;  // the player stops
}
