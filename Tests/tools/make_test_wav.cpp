// Writes deterministic 32-bit float stereo WAV files for tests, baselines and snapshots.
//
//   nmr_make_test_wav tone <out.wav> [--seconds S] [--rate HZ] [--freq HZ] [--dbfs DB]
//   nmr_make_test_wav mix  <out.wav> [--seconds S] [--rate HZ]
//
// tone: one sine on both channels (default 1 kHz at -60 dBFS: far below listening level, but
//       never digital silence, so a capture test can tell it from a denied permission).
// mix:  the test mix (nmr/test_mix.h).
#include <nmr/test_mix.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Options {
  std::string kind;
  std::string path;
  double seconds = 10;
  double rate = 48000;
  double freq = 1000;
  double dbfs = -60;
};

void putU16(std::vector<uint8_t>& out, uint16_t v) {
  out.push_back(static_cast<uint8_t>(v & 0xff));
  out.push_back(static_cast<uint8_t>(v >> 8));
}

void putU32(std::vector<uint8_t>& out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

void putTag(std::vector<uint8_t>& out, const char* tag) { out.insert(out.end(), tag, tag + 4); }

// RIFF/WAVE, WAVE_FORMAT_IEEE_FLOAT, 2 channels, little-endian samples.
bool writeWav(const std::string& path, double rate, const std::vector<float>& interleaved) {
  const auto frames = static_cast<uint32_t>(interleaved.size() / 2);
  const uint32_t data_bytes = frames * 2 * sizeof(float);
  std::vector<uint8_t> header;
  putTag(header, "RIFF");
  putU32(header, 4 + (8 + 18) + (8 + 4) + (8 + data_bytes));
  putTag(header, "WAVE");
  putTag(header, "fmt ");
  putU32(header, 18);
  putU16(header, 3);  // WAVE_FORMAT_IEEE_FLOAT
  putU16(header, 2);
  putU32(header, static_cast<uint32_t>(rate));
  putU32(header, static_cast<uint32_t>(rate) * 2 * sizeof(float));
  putU16(header, 2 * sizeof(float));
  putU16(header, 32);
  putU16(header, 0);  // cbSize
  putTag(header, "fact");
  putU32(header, 4);
  putU32(header, frames);
  putTag(header, "data");
  putU32(header, data_bytes);

  std::FILE* file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  bool ok = std::fwrite(header.data(), 1, header.size(), file) == header.size();
  std::vector<uint8_t> bytes(data_bytes);
  for (size_t i = 0; i < interleaved.size(); ++i) {
    uint32_t bits = 0;
    std::memcpy(&bits, &interleaved[i], sizeof(bits));
    for (int b = 0; b < 4; ++b) bytes[i * 4 + b] = static_cast<uint8_t>((bits >> (8 * b)) & 0xff);
  }
  ok = ok && std::fwrite(bytes.data(), 1, bytes.size(), file) == bytes.size();
  return std::fclose(file) == 0 && ok;
}

std::vector<float> makeTone(const Options& o, uint64_t frames) {
  const double amplitude = std::pow(10.0, o.dbfs / 20.0);
  std::vector<float> out(frames * 2);
  for (uint64_t i = 0; i < frames; ++i) {
    const auto s = static_cast<float>(amplitude * std::sin(2 * kPi * o.freq * i / o.rate));
    out[2 * i] = s;
    out[2 * i + 1] = s;
  }
  return out;
}

std::vector<float> makeMix(const Options& o, uint64_t frames) {
  std::vector<float> out(frames * 2);
  nmr::TestMix(o.rate).fill(out.data(), static_cast<uint32_t>(frames));
  return out;
}

bool parse(int argc, char** argv, Options& o) {
  if (argc < 3) return false;
  o.kind = argv[1];
  o.path = argv[2];
  for (int i = 3; i + 1 < argc; i += 2) {
    const std::string key = argv[i];
    const double value = std::atof(argv[i + 1]);
    if (key == "--seconds") o.seconds = value;
    else if (key == "--rate") o.rate = value;
    else if (key == "--freq") o.freq = value;
    else if (key == "--dbfs") o.dbfs = value;
    else return false;
  }
  return (o.kind == "tone" || o.kind == "mix") && o.seconds > 0 && o.rate >= 8000 &&
         o.rate <= 384000;
}

}  // namespace

int main(int argc, char** argv) {
  Options options;
  if (!parse(argc, argv, options)) {
    std::fprintf(stderr,
                 "usage: nmr_make_test_wav <tone|mix> <out.wav> [--seconds S] [--rate HZ] "
                 "[--freq HZ] [--dbfs DB]\n");
    return 2;
  }
  const auto frames = static_cast<uint64_t>(options.seconds * options.rate);
  const std::vector<float> samples =
      options.kind == "tone" ? makeTone(options, frames) : makeMix(options, frames);
  if (!writeWav(options.path, options.rate, samples)) {
    std::fprintf(stderr, "error: cannot write %s\n", options.path.c_str());
    return 1;
  }
  std::printf("wrote %s (%s, %.1f s, %.0f Hz)\n", options.path.c_str(), options.kind.c_str(),
              options.seconds, options.rate);
  return 0;
}
