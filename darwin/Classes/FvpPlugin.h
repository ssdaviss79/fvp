#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <AVFoundation/AVFoundation.h>

@interface FvpPlugin : NSObject<FlutterPlugin, AVPictureInPictureControllerDelegate>
@property(readonly, strong, nonatomic) FlutterMethodChannel* channel;
@end
