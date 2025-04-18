#import "RCTVLCPlayer.h"
#import "React/RCTBridgeModule.h"
#import "React/RCTConvert.h"
#import "React/RCTEventDispatcher.h"
#import "React/UIView+React.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIDevice.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIWindowScene.h>
#import <VLCKit/VLCKit.h>

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
  BOOL _isUpdatingLayout;

  int _startTime;

  NSString *_resizeMode;
  UIView *_originalParentView;
  CGRect _originalFrame;
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

    // 添加方向变化监听
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(orientationDidChange:)
               name:UIDeviceOrientationDidChangeNotification
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
  // 先停止当前播放
  if (_player) {
    [self _release];
  }

  // 检查source参数
  if (!source || ![source isKindOfClass:[NSDictionary class]]) {
    return;
  }

  // 获取并验证URI
  NSString *uriString = [source objectForKey:@"uri"];
  if (!uriString || ![uriString isKindOfClass:[NSString class]]) {
    return;
  }

  NSURL *uri = [NSURL URLWithString:uriString];
  if (!uri) {
    return;
  }

  // 获取初始化类型，默认为0
  NSNumber *initTypeNum = [source objectForKey:@"initType"];
  int initType =
      [initTypeNum isKindOfClass:[NSNumber class]] ? [initTypeNum intValue] : 0;

  // 获取初始化选项
  NSDictionary *initOptions = [source objectForKey:@"initOptions"];
  if (initOptions && ![initOptions isKindOfClass:[NSDictionary class]]) {
    initOptions = nil;
  }

  // 创建新的播放器实例
  @try {
    if (initType == 1) {
      _player = [[VLCMediaPlayer alloc] init];
    } else {
      NSArray *options = nil;
      if (initOptions) {
        NSMutableArray *optionsArray = [NSMutableArray array];
        for (NSString *key in initOptions) {
          id value = initOptions[key];
          if ([value isKindOfClass:[NSString class]]) {
            [optionsArray
                addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
          }
        }
        options = optionsArray;
      }
      _player = [[VLCMediaPlayer alloc] initWithOptions:options];
    }

    if (!_player) {
      return;
    }

    _player.delegate = self;
    _player.drawable = self;

    // 设置媒体源
    VLCMedia *media = [[VLCMedia alloc] initWithURL:uri];
    if (!media) {
      [self _release];
      return;
    }

    _player.media = media;

    // 设置循环播放
    if (_repeat) {
      [media addOption:@"input-repeat=1000"];
    } else {
      [media addOption:@"input-repeat=0"];
    }

    // 设置音频会话
    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];

    // 触发播放（如果需要）
    if (!_paused) {
      [_player play];
    }
  } @catch (NSException *exception) {
    [self _release];
    return;
  }
}

- (void)setAutoplay:(BOOL)autoplay {
  if (autoplay) {
    [self play];
    [self setResizeMode:_resizeMode];
  }
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
    // NSLog(@"Invalid subtitle URI: %@", subtitleUri); // Removed
  }
}

// ==== player delegate methods ====

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
  [self updateVideoProgress];
}

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification {
  // 防止在对象被释放后调用此方法
  if (!self || !_player) {
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_player) {
      return;
    }

    @try {
      VLCMediaPlayerState state = strongSelf->_player.state;
      switch (state) {
      case VLCMediaPlayerStateOpening:
        if (strongSelf.onVideoOpen) {
          strongSelf.onVideoOpen(@{@"target" : @(1)});
        }
        if (strongSelf.onVideoLoadStart) {
          strongSelf.onVideoLoadStart(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStatePaused:
        strongSelf->_paused = YES;
        if (strongSelf.onVideoPaused) {
          strongSelf.onVideoPaused(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStateStopped:
        if (strongSelf.onVideoStopped) {
          strongSelf.onVideoStopped(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStateBuffering:
        if (!strongSelf->_videoInfo) {
          // 获取音频轨道
          NSArray *audioTracks = [strongSelf->_player audioTracks];
          if (audioTracks && audioTracks.count > 0) {
            strongSelf->_videoInfo = [strongSelf getVideoInfo];

            // 设置起始时间
            if (strongSelf->_startTime > 0) {
              [strongSelf setStartTime:strongSelf->_startTime];
            }

            if (strongSelf.onVideoLoad && strongSelf->_videoInfo) {
              strongSelf.onVideoLoad(strongSelf->_videoInfo);
            }
          }
        }

        if (strongSelf.onVideoBuffering) {
          strongSelf.onVideoBuffering(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStatePlaying:
        strongSelf->_paused = NO;
        if (strongSelf.onVideoPlaying && strongSelf->_player.media) {
          strongSelf.onVideoPlaying(@{
            @"target" : @(1),
            @"seekable" : @(strongSelf->_player.isSeekable),
            @"duration" : @(strongSelf->_player.media.length.intValue)
          });
        }
        break;

      case VLCMediaPlayerStateError:
        if (strongSelf.onVideoError) {
          strongSelf.onVideoError(@{@"target" : @(1)});
        }
        [strongSelf _release];
        break;

      default:
        break;
      }
    } @catch (NSException *exception) {
      NSLog(@"VLC播放器状态变化处理异常: %@", exception);
      if (strongSelf->_player) {
        [strongSelf _release];
      }
    }
  });
}

//   ===== media delegate methods =====

- (void)mediaDidFinishParsing:(VLCMedia *)aMedia {
}

- (void)mediaMetaDataDidChange:(VLCMedia *)aMedia {
}

//   ===================================

- (void)updateVideoProgress {
  if (_player && !_paused) {
    int currentTime = [[_player time] intValue];
    int remainingTime = [[_player remainingTime] intValue];
    int duration = [_player.media.length intValue];

    // 检查 startTime 是否设置成功
    BOOL startTimeSetSuccessfully = NO;
    if (_startTime > 0 && currentTime >= _startTime) {
      startTimeSetSuccessfully = YES;
    }

    self.onVideoProgress(@{
      @"target" : self.reactTag,
      @"currentTime" : [NSNumber numberWithInt:currentTime],
      @"remainingTime" : [NSNumber numberWithInt:remainingTime],
      @"duration" : [NSNumber numberWithInt:duration],
      @"position" : [NSNumber numberWithFloat:_player.position],
      @"startTimeSetSuccessfully" : @(startTimeSetSuccessfully) // 添加新的字段
    });
  }
}

- (NSDictionary *)getVideoInfo {
  NSMutableDictionary *info = [NSMutableDictionary new];
  info[@"duration"] = _player.media.length.value;

  if (_player.videoSize.width > 0) {
    info[@"videoSize"] = @{
      @"width" : @(_player.videoSize.width),
      @"height" : @(_player.videoSize.height)
    };
  }

  // 获取音频轨道
  NSArray *audioTracks = [_player audioTracks];
  if (audioTracks && audioTracks.count > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (NSUInteger i = 0; i < audioTracks.count; i++) {
      VLCMediaPlayerTrack *track = audioTracks[i];
      NSNumber *trackId = @([audioTracks indexOfObject:track]);
      if (trackId) {
        [tracks
            addObject:@{@"id" : trackId, @"isDefault" : @(track.isSelected)}];
      }
    }
    if (tracks.count > 0) {
      info[@"audioTracks"] = tracks;
    }
  }

  // 获取字幕轨道
  NSArray *subtitleTracks = [_player textTracks];
  if (subtitleTracks && subtitleTracks.count > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (NSUInteger i = 0; i < subtitleTracks.count; i++) {
      VLCMediaPlayerTrack *track = subtitleTracks[i];
      NSNumber *trackId = @([subtitleTracks indexOfObject:track]);
      if (trackId) {
        [tracks
            addObject:@{@"id" : trackId, @"isDefault" : @(track.isSelected)}];
      }
    }
    if (tracks.count > 0) {
      info[@"textTracks"] = tracks;
    }
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
      long long timeInMicroSeconds = (long long)timeInMS * 1000;
      VLCTime *time = [VLCTime
          timeWithNumber:[NSNumber numberWithLongLong:timeInMicroSeconds]];
      [_player setTime:time];

      // 验证设置后的时间
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            long long currentTimeMicros = [[_player.time value] longLongValue];
          });
    }
  }
}

- (void)setStartTime:(int)startTime {
  _startTime = startTime;
  if (_player && _player.media) {
    if (startTime > 0 && [_player isSeekable]) {
      long long timeInMicroSeconds = (long long)startTime * 1000;
      VLCTime *time = [VLCTime
          timeWithNumber:[NSNumber numberWithLongLong:timeInMicroSeconds]];
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
  NSUInteger trackIndex = track; // 假设 track 是传入的索引值
  if (_player) {
    NSArray *audioTracks = [_player audioTracks];
    NSUInteger count = audioTracks.count;

    if (trackIndex >= 0 && trackIndex < count) {
      VLCMediaPlayerTrack *track = audioTracks[trackIndex];
    }
  }
}

- (void)setTextTrack:(int)track {
  NSUInteger trackIndex = track; // 假设 track 是传入的索引值
  if (_player) {
    NSArray *textTracks = [_player textTracks];
    NSUInteger count = textTracks.count;

    if (trackIndex >= 0 && trackIndex < count) {
      VLCMediaPlayerTrack *track = textTracks[trackIndex];
    } else if (track < 0) {
      [_player deselectAllTextTracks];
    } else {
      NSLog(@"Invalid text track index: %d", track);
    }
  }
}

- (void)setVideoAspectRatio:(NSString *)ratio {
  if (ratio && ratio.length > 0) {
    [_player setVideoAspectRatio:ratio];
  }
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
  _resizeMode = resizeMode; // 保存当前的模式

  if (!_player) {
    return;
  }

  // 防止递归调用
  if (_isUpdatingLayout) {
    return;
  }

  _isUpdatingLayout = YES;

  // 使用 UIView 动画为布局变化添加平滑效果（参考 VLC for iOS）
  [UIView animateWithDuration:0.3
      delay:0.0
      options:UIViewAnimationOptionCurveEaseInOut |
              UIViewAnimationOptionBeginFromCurrentState
      animations:^{
        if ([resizeMode isEqualToString:@"cover"]) {
          CGRect viewBounds = self.bounds;
          float videoWidth = self->_player.videoSize.width;
          float videoHeight = self->_player.videoSize.height;

          if (viewBounds.size.width > 0 && viewBounds.size.height > 0 &&
              videoWidth > 0 && videoHeight > 0) {
            float viewWidth = viewBounds.size.width;
            float viewHeight = viewBounds.size.height;
            float viewAspect = viewWidth / viewHeight;
            float videoAspect = videoWidth / videoHeight;
            float scale = 1.0;

            if (viewAspect > videoAspect) {
              scale = viewWidth / videoWidth;
            } else {
              scale = viewHeight / videoHeight;
            }

            int cropWidth = viewWidth * scale;
            int cropHeight = viewHeight * scale;

            // 使用新的API设置裁剪比例
            [self->_player setCropRatioWithNumerator:cropWidth
                                         denominator:cropHeight];
            [self->_player setVideoAspectRatio:NULL];
          } else {
            [self->_player setCropRatioWithNumerator:1 denominator:0];
            [self->_player setVideoAspectRatio:NULL];
          }
        } else {
          [self->_player setCropRatioWithNumerator:1 denominator:0];
          [self->_player setVideoAspectRatio:NULL];
        }
      }
      completion:^(BOOL finished) {
        // 避免在动画块中调用layoutIfNeeded，它可能会触发layoutSubviews
        self->_isUpdatingLayout = NO;
      }];
}

// 重写layoutSubviews方法来处理旋转后的布局
- (void)layoutSubviews {
  [super layoutSubviews];
  // 当视图的 bounds 改变时（例如旋转完成或父视图调整），
  // 确保视频的 resizeMode 被重新应用以匹配新的尺寸。

  // 只有当不在布局更新过程中，且播放器和resizeMode都有效时，才应用resizeMode
  if (!_isUpdatingLayout && _player && _resizeMode && self.window != nil) {
    // 避免快速连续调用
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_isUpdatingLayout) {
        self->_isUpdatingLayout = YES;
        [self setResizeMode:self->_resizeMode];
        // 注意：setResizeMode方法内的completion块会重置_isUpdatingLayout标志
      }
    });
  }
}

- (void)_release {
  @try {
    if (_player) {
      // NSLog(@"RCTVLCPlayer: removeFromSuperview"); // Removed
      // 移除所有通知观察者
      [[NSNotificationCenter defaultCenter] removeObserver:self];

      [_player stop]; // 停止播放
      _player.delegate = nil;
      _player.drawable = nil;
      _player = nil; // 释放播放器
    }
    _videoInfo = nil;
    _paused = YES;
  } @catch (NSException *exception) {
    NSLog(@"VLC播放器释放异常: %@", exception);
  }
}

#pragma mark - Lifecycle
- (void)removeFromSuperview {
  // NSLog(@"RCTVLCPlayer: removeFromSuperview"); // Removed
  // 移除所有通知观察者
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self _release];
  [super removeFromSuperview];
}

// 处理方向变化的函数
- (void)orientationDidChange:(NSNotification *)notification {
  UIDeviceOrientation deviceOrientation =
      [[UIDevice currentDevice] orientation];

  if (UIDeviceOrientationIsLandscape(deviceOrientation) ||
      UIDeviceOrientationIsPortrait(deviceOrientation)) {
    // 如果正在更新布局，则不处理方向变化
    if (_isUpdatingLayout) {
      return;
    }

    _isUpdatingLayout = YES;

    // 先确保父视图布局更新完成
    [self.superview setNeedsLayout];
    [self.superview layoutIfNeeded];

    // 记录旋转前的frame作为动画起点
    CGRect originalFrame = self.frame;

    // 计算旋转角度
    CGFloat rotationAngle = 0.0;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
      rotationAngle = M_PI_2; // 90度
    } else if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
      rotationAngle = -M_PI_2; // -90度
    } else if (deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
      rotationAngle = M_PI; // 180度
    }

    // 获取屏幕尺寸
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat maxSize = MAX(screenBounds.size.width, screenBounds.size.height);
    CGFloat minSize = MIN(screenBounds.size.width, screenBounds.size.height);

    // 计算目标frame
    CGRect targetFrame;
    if (UIDeviceOrientationIsLandscape(deviceOrientation)) {
      targetFrame = CGRectMake(0, 0, maxSize, minSize);
    } else {
      targetFrame = CGRectMake(0, 0, minSize, maxSize);
    }

    // 使用 UIView 动画同时实现旋转过程动画和宽高变化动画
    [UIView animateWithDuration:0.3
        delay:0.0
        options:UIViewAnimationOptionCurveEaseInOut |
                UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          // 旋转过程动画
          self.transform = CGAffineTransformMakeRotation(rotationAngle);
          // 宽高变化动画
          self.frame = targetFrame;
        }
        completion:^(BOOL finished) {
          // 执行一次单独的resizeMode设置，避免在动画块中调用可能触发layoutSubviews的方法
          dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_player && self->_resizeMode) {
              [self setResizeMode:self->_resizeMode];
            }
            self->_isUpdatingLayout = NO;
          });
        }];
  }
}

@end
