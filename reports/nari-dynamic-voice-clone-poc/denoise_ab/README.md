# CastReader server denoise A/B shadow pipeline

This directory contains the non-production A/B harness used to compare the
current CastReader reference-audio pipeline against DeepFilterNet3. It never
changes the public route or worker default. Both branches enter the same clone
worker; only the candidate reference is preprocessed by DeepFilterNet3.

Evaluation flow:

1. Download 12 real indoor/outdoor/transport noises from DEMAND.
2. Mix each noise with an existing clean reference at a controlled active SNR.
3. Run the official DeepFilterNet 0.5.6 static binary with its embedded
   DeepFilterNet3 model, 12 dB attenuation limit, delay compensation, and no
   post-filter.
4. Submit the original noisy reference and enhanced reference separately to the
   same China clone worker.
5. Synthesize the same text with the same seed, delete temporary voices, and
   create labeled plus randomized blind-listening pairs.

DEMAND source: https://zenodo.org/records/1227121

Upstream recording license: CC BY-SA 3.0.
