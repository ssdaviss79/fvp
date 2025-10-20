#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif

@interface FvpPlugin : NSObject<FlutterPlugin>

// NEW: Declaration for custom initializer (required for PiP bridge)
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar;

@end
