// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define USE_TEXCACHE 0

#import "FvpPlugin.h"
#include "mdk/RenderAPI.h"
#include "mdk/Player.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <mutex>
#include <unordered_map>
#include <iostream>

using namespace mdk;
using namespace std;

@interface MetalTexture : NSObject<FlutterTexture>
@end

@implementation MetalTexture {
    @public
    id<MTLDevice> device;
    id<MTLCommandQueue> cmdQueue;
    id<MTLTexture> texture;
    CVPixelBufferRef pixbuf;
    id<MTLTexture> fltex;
    CVMetalTextureCacheRef texCache;
    mutex mtx;
}

- (instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    device = MTLCreateSystemDefaultDevice();
    cmdQueue = [device newCommandQueue];
    auto td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    texture = [device newTextureWithDescriptor:td];
    auto attr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attr, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
    auto iosurface_props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attr, kCVPixelBufferIOSurfacePropertiesKey, iosurface_props);
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attr, &pixbuf);
    CFRelease(attr);
    texCache = {};
#if (USE_TEXCACHE + 0)
    CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &texCache);
    CVMetalTextureRef cvtex;
    CVMetalTextureCacheCreateTextureFromImage(nil, texCache, pixbuf, nil, MTLPixelFormatBGRA8Unorm, width, height, 0, &cvtex);
    fltex = CVMetalTextureGetTexture(cvtex);
    CFRelease(cvtex);
#else
    auto iosurface = CVPixelBufferGetIOSurface(pixbuf);
    td.usage = MTLTextureUsageShaderRead;
    fltex = [device newTextureWithDescriptor:td iosurface:iosurface plane:0];
#endif
    return self;
}

- (void)dealloc {
    CVPixelBufferRelease(pixbuf);
    if (texCache) CFRelease(texCache);
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    scoped_lock lock(mtx);
    auto cmdbuf = [cmdQueue commandBuffer];
    auto blit = [cmdbuf blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) 
              sourceSize:MTLSizeMake(texture.width, texture.height, texture.depth)
           toTexture:fltex destinationSlice:0 destinationLevel:0 
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cmdbuf commit];
    return CVPixelBufferRetain(pixbuf);
}
@end

class TexturePlayer final: public Player {
public:
    TexturePlayer(int64_t handle, int width, int height, NSObject<FlutterTextureRegistry>* texReg)
        : Player(reinterpret_cast<mdkPlayerAPI*>(handle))
    {
        mtex_ = [[MetalTexture alloc] initWithWidth:width height:height];
        texId_ = [texReg registerTexture:mtex_];
        MetalRenderAPI ra{};
        ra.device = (__bridge void*)mtex_->device;
        ra.cmdQueue = (__bridge void*)mtex_->cmdQueue;
        ra.texture = (__bridge void*)mtex_->texture;
        setRenderAPI(&ra);
        setVideoSurfaceSize(width, height);
        setRenderCallback([this, texReg](void* opaque){
            scoped_lock lock(mtex_->mtx);
            renderVideo();
            [texReg textureFrameAvailable:texId_];
        });
    }

    ~TexturePlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
    }

    int64_t textureId() const { return texId_; }
private:
    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
};

@interface FvpPlugin () {
    unordered_map<int64_t, shared_ptr<TexturePlayer>> players;
}
- (BOOL)enablePipForTexture:(int64_t)texId;
- (BOOL)enterPipModeForTexture:(int64_t)texId width:(int)width height:(int)height;
@end

@implementation FvpPipController
- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (self.channel) {
        [self.channel invokeMethod:@"onPipStateChanged" arguments:@YES];
    }
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (self.channel) {
        [self.channel invokeMethod:@"onPipStateChanged" arguments:@NO];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController 
    failedToStartPictureInPictureWithError:(NSError *)error {
    if (self.channel) {
        [self.channel invokeMethod:@"onPipError" arguments:error.localizedDescription];
    }
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // Pre-start logic
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // Pre-stop logic
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController 
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    completionHandler(YES);
}
@end

@implementation FvpPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
#if TARGET_OS_OSX
    auto messenger = registrar.messenger;
#else
    auto messenger = [registrar messenger];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
#endif
    FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"fvp" binaryMessenger:messenger];
    FvpPlugin* instance = [[FvpPlugin alloc] initWithRegistrar:registrar];
    instance.channel = channel;
#if TARGET_OS_OSX
#else
    [registrar addApplicationDelegate:instance];
#endif
    [registrar publish:instance];
    [registrar addMethodCallDelegate:instance channel:channel];
    SetGlobalOption("MDK_KEY", "C03BFF5306AB39058A767105F82697F42A00FE970FB0E641D306DEFF3F220547E5E5377A3C504DC30D547890E71059BC023A4DD91A95474D1F33CA4C26C81B0FC73B00ACF954C6FA75898EFA07D9680B6A00FDF179C0A15381101D01124498AF55B069BD4B0156D5CF5A56DEDE782E5F3930AD47C8F40BFBA379231142E31B0F");
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    self = [super init];
    if (self) {
        _texRegistry = [registrar textures];
        _pipControllers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"CreateRT"]) {
        const auto handle = ((NSNumber*)call.arguments[@"player"]).longLongValue;
        const auto width = ((NSNumber*)call.arguments[@"width"]).intValue;
        const auto height = ((NSNumber*)call.arguments[@"height"]).intValue;
        auto player = make_shared<TexturePlayer>(handle, width, height, _texRegistry);
        players[player->textureId()] = player;
        result(@(player->textureId()));
    } else if ([call.method isEqualToString:@"ReleaseRT"]) {
        const auto texId = ((NSNumber*)call.arguments[@"texture"]).longLongValue;
        [_texRegistry unregisterTexture:texId];
        players.erase(texId);
        [_pipControllers removeObjectForKey:@(texId)];
        result(nil);
    } else if ([call.method isEqualToString:@"MixWithOthers"]) {
        [[maybe_unused]] const auto value = ((NSNumber*)call.arguments[@"value"]).boolValue;
#if !TARGET_OS_OSX
        if (value) {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        } else {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        }
#endif
        result(nil);
    } else if (@available(iOS 14.0, *)) {
        if ([call.method isEqualToString:@"isPipSupported"]) {
            BOOL supported = [AVPictureInPictureController isPictureInPictureSupported];
            [self.channel invokeMethod:@"nativeLog" arguments:[NSString stringWithFormat:@"Native: PiP supported: %d", supported]];
            result(@(supported));
        } else if ([call.method isEqualToString:@"getTextureId"]) {
            if (players.empty()) {
                result(@(-1LL));
                return;
            }
            auto it = players.begin();
            result(@(it->first));
        } else if ([call.method isEqualToString:@"enablePiP"]) {
            NSNumber *texIdNum = call.arguments[@"textureId"];
            if (!texIdNum) {
                result([FlutterError errorWithCode:@"INVALID_ARGS" message:@"Missing textureId" details:nil]);
                return;
            }
            int64_t texId = [texIdNum longLongValue];
            BOOL success = [self enablePipForTexture:texId];
            result(@(success));
        } else if ([call.method isEqualToString:@"enterPipMode"]) {
            NSDictionary *args = call.arguments;
            NSNumber *texIdNum = args[@"textureId"];
            NSNumber *widthNum = args[@"width"];
            NSNumber *heightNum = args[@"height"];
            if (!texIdNum || !widthNum || !heightNum) {
                result([FlutterError errorWithCode:@"INVALID_ARGS" message:@"Missing args" details:nil]);
                return;
            }
            int64_t texId = [texIdNum longLongValue];
            int width = [widthNum intValue];
            int height = [heightNum intValue];
            BOOL success = [self enterPipModeForTexture:texId width:width height:height];
            result(@(success));
        } else if ([call.method isEqualToString:@"exitPipMode"]) {
            for (NSNumber *key in _pipControllers) {
                FvpPipController *ctrl = _pipControllers[key];
                if (ctrl.pipController.isPictureInPictureActive) {
                    [ctrl.pipController stopPictureInPicture];
                    break;
                }
            }
            result(@YES);
        } else {
            result(FlutterMethodNotImplemented);
        }
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (BOOL)enablePipForTexture:(int64_t)texId {
    auto it = players.find(texId);
    if (it == players.end()) {
        [self.channel invokeMethod:@"nativeLog" arguments:@"Native: No TexturePlayer for textureId"];
        return NO;
    }
    shared_ptr<TexturePlayer> player = it->second;
    
    // Create hidden AVSampleBufferDisplayLayer
    AVSampleBufferDisplayLayer *pipLayer = [[AVSampleBufferDisplayLayer alloc] init];
    pipLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    
    // Create dummy view to keep layer alive
    UIView *dummyView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    dummyView.hidden = YES;
    [dummyView.layer addSublayer:pipLayer];
    if (UIApplication.sharedApplication.windows.first.rootViewController.view) {
        [UIApplication.sharedApplication.windows.first.rootViewController.view addSubview:dummyView];
    }
    
    // Create PiP controller
    AVPictureInPictureController *pipCtrl = [[AVPictureInPictureController alloc] initWithSampleBufferDisplayLayer:pipLayer source:nil];
    if (!pipCtrl) {
        [self.channel invokeMethod:@"nativeLog" arguments:@"Native: Failed to create AVPictureInPictureController"];
        return NO;
    }
    
    // Setup FvpPipController
    FvpPipController *controller = [[FvpPipController alloc] init];
    controller.pipController = pipCtrl;
    controller.pipLayer = pipLayer;
    controller.textureId = texId;
    controller.channel = self.channel;
    pipCtrl.delegate = controller;
    
    if (@available(iOS 14.2, *)) {
        pipCtrl.canStartPictureInPictureAutomaticallyFromInline = YES;
        [self.channel invokeMethod:@"nativeLog" arguments:@"Native: Auto PiP enabled"];
    }
    
    _pipControllers[@(texId)] = controller;
    
    // Bridge FFmpeg frames (hook into render callback)
    player->setRenderCallback([this, pipLayer, texId](void* opaque){
        // Get frame data from mdk::Player
        MediaInfo info = players[texId]->mediaInfo();
        if (info.video.empty()) return;
        
        // Create CVPixelBuffer for FFmpeg frame (simplified; assumes RGB)
        CVPixelBufferRef pixelBuffer;
        CVPixelBufferCreate(nil, info.video[0].width, info.video[0].height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer);
        
        // Copy frame data (pseudo; needs actual FFmpeg AVFrame access)
        // AVFrame *frame = players[texId]->getCurrentFrame(); // Requires mdk API exposure
        // Copy frame->data to pixelBuffer (libavcodec conversion)
        
        // Create CMSampleBuffer
        CMSampleTimingInfo timing = {
            .presentationTimeStamp = CMTimeMake(1, 30), // Adjust based on frame rate
            .duration = kCMTimeInvalid,
            .decodeTimeStamp = kCMTimeInvalid
        };
        CMSampleBufferRef sampleBuffer;
        CMSampleBufferCreateForImageBuffer(nil, pixelBuffer, YES, nil, nil, nil, &timing, &sampleBuffer);
        
        // Enqueue to sample buffer layer
        [pipLayer enqueueSampleBuffer:sampleBuffer];
        
        CFRelease(pixelBuffer);
        CFRelease(sampleBuffer);
    });
    
    [self.channel invokeMethod:@"nativeLog" arguments:@"Native: PiP enabled for texture"];
    return YES;
}

- (BOOL)enterPipModeForTexture:(int64_t)texId width:(int)width height:(int)height {
    FvpPipController *pipCtrl = _pipControllers[@(texId)];
    if (!pipCtrl || !pipCtrl.pipController) {
        [self.channel invokeMethod:@"nativeLog" arguments:@"Native: No PiP controller"];
        return NO;
    }
    
    if (pipCtrl.pipController.isPictureInPicturePossible) {
        [pipCtrl.pipController startPictureInPicture];
        [self.channel invokeMethod:@"nativeLog" arguments:@"Native: Started PiP"];
        return YES;
    }
    [self.channel invokeMethod:@"nativeLog" arguments:@"Native: PiP not possible"];
    return NO;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    players.clear();
    [_pipControllers removeAllObjects];
}

@end
