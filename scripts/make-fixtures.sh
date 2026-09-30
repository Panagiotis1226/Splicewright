#!/usr/bin/env bash
# Generates short test clips covering the formats Splicewright v1 supports, for trying
# the app by hand. Unit tests don't need these: they synthesize their own media.
#
# Output goes to TestMedia/ (git-ignored). Requires ffmpeg with VideoToolbox
# (the Homebrew build has it): brew install ffmpeg
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg"; exit 1; }
mkdir -p TestMedia
out=TestMedia
common=(-hide_banner -loglevel error -y)
tone=(-f lavfi -i "sine=frequency=440:sample_rate=48000")

hlg_tags=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc)
pq_tags=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
sdr_tags=(-color_primaries bt709 -color_trc bt709 -colorspace bt709)

echo "H.264 SDR 4K30 (.mp4)"
ffmpeg "${common[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=5" "${tone[@]}" -t 5 \
  -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p "${sdr_tags[@]}" -c:a aac -b:a 192k \
  "$out/h264-sdr-4k30.mp4"

echo "HEVC SDR 4K60 (.mov)"
ffmpeg "${common[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=5" "${tone[@]}" -t 5 \
  -c:v hevc_videotoolbox -b:v 50M -tag:v hvc1 -pix_fmt yuv420p "${sdr_tags[@]}" -c:a aac \
  "$out/hevc-sdr-4k60.mov"

echo "HEVC 10-bit HLG 4K 59.94 (.mov)"
ffmpeg "${common[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=60000/1001:duration=5" "${tone[@]}" -t 5 \
  -c:v hevc_videotoolbox -profile:v main10 -b:v 60M -tag:v hvc1 -pix_fmt p010le "${hlg_tags[@]}" \
  -c:a aac "$out/hevc-hlg-4k5994.mov"

echo "HEVC 10-bit PQ (HDR10) 4K 29.97 (.mp4)"
ffmpeg "${common[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=30000/1001:duration=5" "${tone[@]}" -t 5 \
  -c:v hevc_videotoolbox -profile:v main10 -b:v 50M -tag:v hvc1 -pix_fmt p010le "${pq_tags[@]}" \
  -c:a aac "$out/hevc-pq-4k2997.mp4"

echo "ProRes 422 HQ 1080p25 (.mov)"
ffmpeg "${common[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=25:duration=5" "${tone[@]}" -t 5 \
  -c:v prores_videotoolbox -profile:v hq "${sdr_tags[@]}" -c:a pcm_s16le "$out/prores-hq-1080p25.mov"

echo "Variable frame rate H.264 (.mp4)"
ffmpeg "${common[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=5" \
  -vf "select='if(lt(t,2),not(mod(n,2)),1)'" -fps_mode vfr \
  -c:v h264_videotoolbox -b:v 12M "${sdr_tags[@]}" "$out/h264-vfr.mp4" || echo "  (skipped VFR clip)"

echo "Stereo WAV"
ffmpeg "${common[@]}" "${tone[@]}" -t 5 -ac 2 -c:a pcm_s24le "$out/tone-48k.wav"

echo "Done. Import TestMedia/ into Splicewright (drag the folder onto the Project panel)."
