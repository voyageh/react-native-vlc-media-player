// setCropRatioWithNumerator

- (void)setCropRatioWithNumerator:(unsigned int)numerator denominator:(unsigned int)denominator
  {
  libvlc_video_set_crop_ratio(\_playerInstance, numerator, denominator);
  }.
