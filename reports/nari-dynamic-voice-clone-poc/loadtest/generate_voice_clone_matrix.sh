#!/usr/bin/env bash
# Generate a consent-safe, non-biometric voice-clone fixture matrix from macOS
# system voices. These files are test inputs only and are not shipped.
set -euo pipefail

output_dir=${1:-"$(cd "$(dirname "$0")/.." && pwd)/artifacts/clone-input-matrix"}
mkdir -p "$output_dir"
temporary_dir=$(mktemp -d)
cleanup() { rm -r -- "$temporary_dir"; }
trap cleanup EXIT

zh_text='今天我们继续测试声音克隆。请保持自然、清晰和稳定的语气，让每一个字都容易听懂。'
en_text='Today we are testing voice cloning with a clear, natural, and steady speaking style for every sentence.'
de_text='Heute testen wir das Klonen einer Stimme mit einer klaren, natürlichen und ruhigen Sprechweise für jeden Satz.'
es_text='Hoy probamos la clonación de voz con una forma de hablar clara, natural y estable en cada frase.'
fr_text='Aujourd’hui, nous testons le clonage vocal avec une voix claire, naturelle et régulière dans chaque phrase.'
it_text='Oggi proviamo la clonazione vocale con un modo di parlare chiaro, naturale e stabile in ogni frase.'
ja_text='今日は音声クローニングをテストします。すべての文を自然で明瞭かつ安定した話し方で読みます。'
ko_text='오늘은 음성 복제를 테스트합니다. 모든 문장을 자연스럽고 명확하며 안정된 말투로 읽습니다.'
pt_text='Hoje testamos a clonagem de voz com uma maneira de falar clara, natural e estável em cada frase.'
ru_text='Сегодня мы тестируем клонирование голоса с ясной, естественной и ровной манерой речи в каждом предложении.'

synthesize() {
  local name=$1 voice=$2 rate=$3 text=$4
  say -v "$voice" -r "$rate" -o "$temporary_dir/$name.aiff" "$text"
  ffmpeg -hide_banner -loglevel error -y -i "$temporary_dir/$name.aiff" \
    -ac 1 -ar 24000 -c:a pcm_s16le "$output_dir/$name.wav"
}

synthesize zh_tingting_clean Tingting 175 "$zh_text"
synthesize zh_eddy_clean 'Eddy (Chinese (China mainland))' 170 "$zh_text"
synthesize zh_grandma_clean 'Grandma (Chinese (China mainland))' 165 "$zh_text"
synthesize en_samantha_clean Samantha 175 "$en_text"
synthesize en_daniel_clean Daniel 170 "$en_text"
synthesize en_karen_clean Karen 180 "$en_text"
synthesize en_fred_aux Fred 170 "$en_text"
synthesize de_anna_clean Anna 170 "$de_text"
synthesize es_monica_clean Mónica 175 "$es_text"
synthesize fr_thomas_clean Thomas 170 "$fr_text"
synthesize it_alice_clean Alice 175 "$it_text"
synthesize ja_kyoko_clean Kyoko 170 "$ja_text"
synthesize ko_yuna_clean Yuna 170 "$ko_text"
synthesize pt_luciana_clean Luciana 175 "$pt_text"
synthesize ru_milena_clean Milena 170 "$ru_text"

# Acceptable device/room variation: modest level difference, stable light
# background noise, and a small room reflection.
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_daniel_clean.wav" \
  -af 'volume=-8dB' -ac 1 -ar 24000 -c:a pcm_s16le \
  "$output_dir/en_daniel_quiet_ok.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/zh_tingting_clean.wav" \
  -f lavfi -i 'anoisesrc=color=pink:amplitude=0.006:sample_rate=24000' \
  -filter_complex '[0:a][1:a]amix=inputs=2:duration=first:weights=1 0.22:normalize=0' \
  -ac 1 -ar 24000 -c:a pcm_s16le "$output_dir/zh_tingting_light_noise.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_samantha_clean.wav" \
  -af 'aecho=0.8:0.45:45:0.10' -ac 1 -ar 24000 -c:a pcm_s16le \
  "$output_dir/en_samantha_light_reverb.wav"

# Common recorder/container variations. The worker owns channel folding and
# sample-rate normalization, so these should behave exactly like clean input.
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_samantha_clean.wav" \
  -ac 2 -ar 48000 -c:a pcm_s16le "$output_dir/en_samantha_48k_stereo.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/zh_tingting_clean.wav" \
  -ac 2 -ar 44100 -c:a pcm_s16le "$output_dir/zh_tingting_44100_stereo.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/de_anna_clean.wav" \
  -ac 1 -ar 16000 -c:a pcm_s16le "$output_dir/de_anna_16k_mono.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_karen_clean.wav" \
  -ac 1 -ar 24000 -c:a flac "$output_dir/en_karen_clean.flac"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/fr_thomas_clean.wav" \
  -af 'aeval=val(0)+0.02' -ac 1 -ar 24000 -c:a pcm_s16le \
  "$output_dir/fr_thomas_dc_offset.wav"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -t 1.5 -i 'anullsrc=channel_layout=mono:sample_rate=24000' \
  -i "$output_dir/it_alice_clean.wav" \
  -f lavfi -t 2.0 -i 'anullsrc=channel_layout=mono:sample_rate=24000' \
  -filter_complex '[0:a][1:a][2:a]concat=n=3:v=0:a=1' \
  -ac 1 -ar 24000 -c:a pcm_s16le \
  "$output_dir/it_alice_outer_silence.wav"

# Deliberately invalid inputs. The service should reject these with actionable
# quality codes rather than a generic 503.
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_samantha_clean.wav" \
  -t 1.8 -ac 1 -ar 24000 -c:a pcm_s16le "$output_dir/reject_too_short.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_daniel_clean.wav" \
  -af 'volume=-45dB' -ac 1 -ar 24000 -c:a pcm_s16le \
  "$output_dir/reject_too_quiet.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/en_karen_clean.wav" \
  -af 'volume=24dB' -ac 1 -ar 24000 -c:a pcm_s16le \
  "$output_dir/reject_clipped.wav"
ffmpeg -hide_banner -loglevel error -y -i "$output_dir/zh_eddy_clean.wav" \
  -f lavfi -i 'anoisesrc=color=white:amplitude=0.18:sample_rate=24000' \
  -filter_complex '[0:a][1:a]amix=inputs=2:duration=first:weights=0.65 1:normalize=0' \
  -ac 1 -ar 24000 -c:a pcm_s16le "$output_dir/reject_heavy_noise.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i 'anullsrc=channel_layout=mono:sample_rate=24000' -t 6 \
  -c:a pcm_s16le "$output_dir/reject_silence.wav"
ffmpeg -hide_banner -loglevel error -y \
  -i "$output_dir/en_samantha_clean.wav" -i "$output_dir/en_fred_aux.wav" \
  -filter_complex '[0:a]atrim=0:3,asetpts=PTS-STARTPTS[first];[1:a]atrim=3:6,asetpts=PTS-STARTPTS[second];[first][second]concat=n=2:v=0:a=1' \
  -ac 1 -ar 24000 -c:a pcm_s16le "$output_dir/reject_two_speakers.wav"

rm -f -- "$output_dir/en_fred_aux.wav"
printf 'Generated %s audio fixtures in %s\n' \
  "$(find "$output_dir" -type f \( -name '*.wav' -o -name '*.flac' \) | wc -l | tr -d ' ')" \
  "$output_dir"
