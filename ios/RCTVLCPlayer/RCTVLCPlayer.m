#import "RCTVLCPlayer.h"
#import "React/RCTBridgeModule.h"
#import "React/RCTConvert.h"
#import "React/RCTEventDispatcher.h"
#import "React/UIView+React.h"
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif
#import <AVFoundation/AVFoundation.h>
static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath =
    @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";

#if !defined(DEBUG) || !(TARGET_IPHONE_SIMULATOR)
#define NSLog(...)
#endif

@implementation RCTVLCPlayer {

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;
  VLCMediaPlayer *_player;

  NSDictionary *_videoInfo;
  NSString *_subtitleUri;

  BOOL _paused;
  BOOL _autoplay;
  BOOL _repeat;

  NSString *_resizeMode;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher {
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationWillResignActive:)
               name:UIApplicationWillResignActiveNotification
             object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationWillEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification
             object:nil];
  }

  return self;
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
  if (!_paused)
    [self play];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
  if (!_paused)
    [self play];
}

- (void)play {
  if (_player) {

    [_player play];
    _paused = NO;
  }
}

- (void)pause {
  if (_player) {
    [_player pause];
    _paused = YES;
  }
}

- (void)setSource:(NSDictionary *)source {
  if (_player) {
    [self _release];
  }

  _videoInfo = nil;

  // [bavv edit start]
  NSString *uriString = [source objectForKey:@"uri"];
  NSURL *uri = [NSURL URLWithString:uriString];
  int initType = [source objectForKey:@"initType"];
  NSDictionary *initOptions = [source objectForKey:@"initOptions"];

  if (initType == 1) {
    _player = [[VLCMediaPlayer alloc] init];
  } else {
    _player = [[VLCMediaPlayer alloc] initWithOptions:initOptions];
  }
  _player.delegate = self;
  _player.drawable = self;

  // [bavv edit end]

  _player.media = [VLCMedia mediaWithURL:uri];

  // 根据repeat属性设置循环播放
  if (_repeat) {
    [_player.media addOption:@"--input-repeat=1000"];
  } else {
    [_player.media addOption:@"--input-repeat=0"];
  }

  [[AVAudioSession sharedInstance]
        setActive:NO
      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:nil];
}

- (void)setAutoplay:(BOOL)autoplay {
  _autoplay = autoplay;
    // 设置视频源后应用当前的resizeMode
    if (_resizeMode) {
      [self setResizeMode:_resizeMode];
    }
  if (autoplay)
    [self play];
}

- (void)setPaused:(BOOL)paused {
  _paused = paused;

  if (!paused) {
    [self play];
  } else {
    [self pause];
  }
}

- (void)setResume:(BOOL)resume {
  if (resume) {
    [self play];
  } else {
    [self pause];
  }
}

- (void)setSubtitleUri:(NSString *)subtitleUri {
  NSURL *url = [NSURL URLWithString:subtitleUri];

  if (url.absoluteString.length != 0 && _player) {
    _subtitleUri = url;
    [_player addPlaybackSlave:_subtitleUri
                         type:VLCMediaPlaybackSlaveTypeSubtitle
                      enforce:YES];
  } else {
    NSLog(@"Invalid subtitle URI: %@", subtitleUri);
  }
}

// ==== player delegate methods ====

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
  [self updateVideoProgress];
}

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification {

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSLog(@"userInfo %@", [aNotification userInfo]);
  NSLog(@"standardUserDefaults %@", defaults);
  if (_player) {
    VLCMediaPlayerState state = _player.state;
    switch (state) {
    case VLCMediaPlayerStateOpening:
      NSLog(@"VLCMediaPlayerStateOpening  %i", _player.numberOfAudioTracks);
      self.onVideoOpen(@{@"target" : self.reactTag});
      self.onVideoLoadStart(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStatePaused:
      _paused = YES;
      NSLog(@"VLCMediaPlayerStatePaused %i", _player.numberOfAudioTracks);
      self.onVideoPaused(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStateStopped:
      NSLog(@"VLCMediaPlayerStateStopped %i", _player.numberOfAudioTracks);
      self.onVideoStopped(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStateBuffering:
      NSLog(@"VLCMediaPlayerStateBuffering %i", _player.numberOfAudioTracks);
      if (!_videoInfo && _player.numberOfAudioTracks > 0) {
        _videoInfo = [self getVideoInfo];
        self.onVideoLoad(_videoInfo);
      }

      self.onVideoBuffering(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStatePlaying:
      _paused = NO;
      NSLog(@"VLCMediaPlayerStatePlaying %i", _player.numberOfAudioTracks);
      self.onVideoPlaying(@{
        @"target" : self.reactTag,
        @"seekable" : [NSNumber numberWithBool:[_player isSeekable]],
        @"duration" : [NSNumber numberWithInt:[_player.media.length intValue]]
      });
      break;
    case VLCMediaPlayerStateError:
      NSLog(@"VLCMediaPlayerStateError %i", _player.numberOfAudioTracks);
      self.onVideoError(@{@"target" : self.reactTag});
      [self _release];
      break;
    default:
      break;
    }
  }
}

//   ===== media delegate methods =====

- (void)mediaDidFinishParsing:(VLCMedia *)aMedia {
  NSLog(@"VLCMediaDidFinishParsing %i", _player.numberOfAudioTracks);
}

- (void)mediaMetaDataDidChange:(VLCMedia *)aMedia {
  NSLog(@"VLCMediaMetaDataDidChange %i", _player.numberOfAudioTracks);
}

//   ===================================

- (void)updateVideoProgress {
  if (_player && !_paused) {
    int currentTime = [[_player time] intValue];
    int remainingTime = [[_player remainingTime] intValue];
    int duration = [_player.media.length intValue];

    self.onVideoProgress(@{
      @"target" : self.reactTag,
      @"currentTime" : [NSNumber numberWithInt:currentTime],
      @"remainingTime" : [NSNumber numberWithInt:remainingTime],
      @"duration" : [NSNumber numberWithInt:duration],
      @"position" : [NSNumber numberWithFloat:_player.position]
    });
  }
}

- (NSDictionary *)getVideoInfo {
  NSMutableDictionary *info = [NSMutableDictionary new];
  info[@"duration"] = _player.media.length.value;
  int i;
  if (_player.videoSize.width > 0) {
    info[@"videoSize"] = @{
      @"width" : @(_player.videoSize.width),
      @"height" : @(_player.videoSize.height)
    };
  }

  if (_player.numberOfAudioTracks > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (i = 0; i < _player.numberOfAudioTracks; i++) {
      if (_player.audioTrackIndexes[i] && _player.audioTrackNames[i]) {
        [tracks addObject:@{
          @"id" : _player.audioTrackIndexes[i],
          @"name" : _player.audioTrackNames[i],
          @"isDefault" : [NSNumber
              numberWithBool:[_player.audioTrackIndexes[i] intValue] ==
                             _player.currentAudioTrackIndex]
        }];
      }
    }
    info[@"audioTracks"] = tracks;
  }

  if (_player.numberOfSubtitlesTracks > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (i = 0; i < _player.numberOfSubtitlesTracks; i++) {
      if (_player.videoSubTitlesIndexes[i] && _player.videoSubTitlesNames[i]) {
        [tracks addObject:@{
          @"id" : _player.videoSubTitlesIndexes[i],
          @"name" : _player.videoSubTitlesNames[i],
          @"isDefault" : [NSNumber
              numberWithBool:[_player.videoSubTitlesIndexes[i] intValue] ==
                             _player.currentVideoSubTitleIndex]
        }];
      }
    }
    info[@"textTracks"] = tracks;
  }

  return info;
}

- (void)jumpBackward:(int)interval {
  if (interval >= 0 && interval <= [_player.media.length intValue])
    [_player jumpBackward:interval];
}

- (void)jumpForward:(int)interval {
  if (interval >= 0 && interval <= [_player.media.length intValue])
    [_player jumpForward:interval];
}

- (void)setSeek:(float)pos {
  if ([_player isSeekable]) {
    if (pos >= 0 && pos <= 1) {
      [_player setPosition:pos];
    }
  }
}

- (void)setSeekTime:(int)timeInMS {
  if (_player && [_player isSeekable]) {
    if (timeInMS >= 0 && timeInMS <= [_player.media.length intValue]) {
      VLCTime *time = [VLCTime timeWithInt:timeInMS];
      NSLog(@"setSeekTime: %i", timeInMS);
      [_player setTime:time];
    }
  }
}

- (void)setSnapshotPath:(NSString *)path {
  if (_player)
    [_player saveVideoSnapshotAt:path withWidth:0 andHeight:0];
}

- (void)setRate:(float)rate {
  [_player setRate:rate];
}

- (void)setAudioTrack:(int)track {
  [_player setCurrentAudioTrackIndex:track];
}

- (void)setTextTrack:(int)track {
  [_player setCurrentVideoSubTitleIndex:track];
}

- (void)setVideoAspectRatio:(NSString *)ratio {
  char *char_content = [ratio cStringUsingEncoding:NSASCIIStringEncoding];
  [_player setVideoAspectRatio:char_content];
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;

  if (_player && _player.media) {
    if (repeat) {
      // 设置VLC循环播放模式
      [_player.media addOption:@"--input-repeat=1000"];
    } else {
      // 设置为不重复模式
      [_player.media addOption:@"--input-repeat=0"];
    }
  }
}

- (void)setMuted:(BOOL)value {
  if (_player) {
    [[_player audio] setMuted:value];
  }
}

- (void)setResizeMode:(NSString *)resizeMode {
  if (!_player) {
    NSLog(@"[VLCPlayer] Player not initialized when setting resizeMode: %@",
          resizeMode);
    return;
  }

  NSLog(@"[VLCPlayer] Setting resizeMode: %@", resizeMode);
  _resizeMode = resizeMode;

  if ([resizeMode isEqualToString:@"cover"]) {
    UIScreen *screen = [UIScreen mainScreen];
    float f_ar = screen.bounds.size.width / screen.bounds.size.height;
    NSLog(@"[VLCPlayer] Screen dimensions - width: %.2f, height: %.2f, aspect "
          @"ratio: %.4f",
          screen.bounds.size.width, screen.bounds.size.height, f_ar);

    if (f_ar == (float)(640. / 1136.)) { // iPhone 5 aka 16:9.01
      NSLog(@"[VLCPlayer] Detected iPhone 5 format, setting crop geometry to "
            @"16:9");
      _player.videoCropGeometry = "16:9";
    } else if (f_ar == (float)(2. / 3.)) { // all other iPhones
      NSLog(@"[VLCPlayer] Detected standard iPhone format, setting crop "
            @"geometry to 2:3");
      _player.videoCropGeometry = "16:10";
    } else if (f_ar == .75) { // all iPads
      NSLog(@"[VLCPlayer] Detected iPad format, setting crop geometry to 4:3");
      _player.videoCropGeometry = "4:3";
    } else if (f_ar == .5625) { // AirPlay
      NSLog(
          @"[VLCPlayer] Detected AirPlay format, setting crop geometry to 4:3");
      _player.videoCropGeometry = "16:9";
    } else {
      NSLog(@"[VLCPlayer] Unknown screen format %.4f, setting custom crop "
            @"geometry: %.0f:%.0f",
            f_ar, screen.bounds.size.width, screen.bounds.size.height);
      NSString *cropGeometry = [NSString stringWithFormat:@"%.0f:%.0f", 
                               screen.bounds.size.width,
                               screen.bounds.size.height];
      _player.videoCropGeometry = cropGeometry.UTF8String;
    }
  } else if ([resizeMode isEqualToString:@"contain"]) {
    NSLog(@"[VLCPlayer] Setting video aspect ratio to NULL (contain mode)");
    [_player setVideoAspectRatio:NULL];
    _player.videoCropGeometry = NULL;
  } else if ([resizeMode isEqualToString:@"stretch"]) {
    NSLog(@"[VLCPlayer] Setting video aspect ratio to 1:1 (stretch mode)");
    [_player setVideoAspectRatio:"1:1"];
    _player.videoCropGeometry = NULL;
  }
}

- (void)_release {
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  if (_player.media)
    [_player stop];

  if (_player)
    _player = nil;

  _eventDispatcher = nil;
}

#pragma mark - Lifecycle
- (void)removeFromSuperview {
  NSLog(@"removeFromSuperview");
  [self _release];
  [super removeFromSuperview];
}

@end
