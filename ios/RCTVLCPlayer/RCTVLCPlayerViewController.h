#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>

@interface RCTVLCPlayerViewController : UIViewController

@property (nonatomic, strong, readonly) UIView *videoView;
@property (nonatomic, weak) VLCMediaPlayer *player;
@property (nonatomic, strong) NSString *resizeMode;

- (void)setResizeMode:(NSString *)resizeMode;
- (void)fillScreenWithScreenSize:(CGSize)screenSize;
- (CGSize)aspectFillWithAspectRatio:(CGSize)aspectRatio minimumSize:(CGSize)minimumSize;
- (UIScreen *)currentScreen;

@end 