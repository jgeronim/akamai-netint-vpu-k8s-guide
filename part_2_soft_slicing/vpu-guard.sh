#!/bin/bash
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export PATH=/usr/local/bin:$PATH

echo "--- Initializing Hardware ABR Ladder ---"

# Initialize device, upload CPU-based testsrc to VPU, then scale/encode entirely in VPU memory.
exec ffmpeg -hide_banner -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30,format=nv12" \
  -init_hw_device "ni_quadra=vpu:/dev/nvme0n1" -filter_hw_device vpu \
  -filter_complex \
  "[0:v]hwupload,ni_quadra_scale=w=1280:h=720[v720]; \
   [0:v]hwupload,ni_quadra_scale=w=854:h=480[v480]; \
   [0:v]hwupload,ni_quadra_scale=w=640:h=360[v360]" \
  -map "[v720]" -c:v h264_ni_quadra_enc -b:v 3000k -f null - \
  -map "[v480]" -c:v h264_ni_quadra_enc -b:v 1500k -f null - \
  -map "[v360]" -c:v h264_ni_quadra_enc -b:v 800k -f null -
