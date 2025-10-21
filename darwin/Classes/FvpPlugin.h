#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <AVFoundation/AVFoundation.h>

@interface FvpPlugin : NSObject<FlutterPlugin, AVPictureInPictureControllerDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, AVPlayerLayer*> *pipLayers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, AVPictureInPictureController*> *pipControllers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, NSNumber*> *pipActiveFlags;
@end
