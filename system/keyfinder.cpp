// baseline-keyfinder: the musical key of some audio, with libkeyfinder.
// Reads mono 32-bit float samples at 44.1 kHz on stdin (ffmpeg -f f32le -ac 1
// -ar 44100 -) and prints the key, e.g. "A minor", or "silence".
// afterlight builds it on first use (g++ -O2 keyfinder.cpp -lkeyfinder).
#include <keyfinder/keyfinder.h>
#include <cstdio>
#include <vector>

int main() {
  static const char* names[] = {"A", "Bb", "B", "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab"};
  std::vector<float> samples;
  float buffer[8192];
  size_t got;
  while ((got = fread(buffer, sizeof(float), 8192, stdin)) > 0) {
    samples.insert(samples.end(), buffer, buffer + got);
    if (samples.size() > 44100u * 60 * 12) break;     // twelve minutes is plenty
  }
  if (samples.empty()) { puts("silence"); return 0; }
  KeyFinder::AudioData audio;
  audio.setFrameRate(44100);
  audio.setChannels(1);
  audio.addToSampleCount(samples.size());
  for (size_t i = 0; i < samples.size(); i++) audio.setSample(i, samples[i]);
  KeyFinder::KeyFinder finder;
  KeyFinder::key_t key = finder.keyOfAudio(audio);
  if (key == KeyFinder::SILENCE) { puts("silence"); return 0; }
  printf("%s %s\n", names[key / 2], key % 2 ? "minor" : "major");
  return 0;
}
