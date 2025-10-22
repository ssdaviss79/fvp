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
#import <CoreMedia/CoreMedia.h>
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
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(texture.width, texture.height, texture.depth)
        toTexture:fltex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cmdbuf commit];
    return CVPixelBufferRetain(pixbuf);
}
@end

class TexturePlayer final: public Player {
public:
    TexturePlayer(int64_t handle, int width, int height, NSObject<FlutterTextureRegistry>* texReg, FvpPlugin* plugin)
        : Player(reinterpret_cast<mdkPlayerAPI*>(handle)) {
        mtex_ = [[MetalTexture alloc] initWithWidth:width height:height];
        texId_ = [texReg registerTexture:mtex_];
        plugin_ = plugin;
        MetalRenderAPI ra{};
        ra.device = (__bridge void*)mtex_->device;
        ra.cmdQueue = (__bridge void*)mtex_->cmdQueue;
        ra.texture = (__bridge void*)mtex_->texture;
        setRenderAPI(&ra);
        setVideoSurfaceSize(width, height);

        setRenderCallback([this, texReg](void* opaque) {
            scoped_lock lock(mtex_->mtx);
            renderVideo();
            [texReg textureFrameAvailable:texId_];
            syncFrameToPip();
        });
    }

    ~TexturePlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
    }

    int64_t textureId() const { return texId_; }

    void syncFrameToPip() {
        if (!plugin_ || ![plugin_ getPipControllerForTexture:texId_].isPictureInPictureActive) return;
        static int frameCount = 0;
        CVPixelBufferRef pixelBuffer = [mtex_ copyPixelBuffer];
        if (!pixelBuffer) {
            if (frameCount % 60 == 0) {
                [plugin_ sendLogToFlutter:@"Native: ⚠️ No pixel buffer"];
            }
            frameCount++;
            return;
        }
        CMSampleBufferRef sampleBuffer = createSampleBufferFromPixelBuffer(pixelBuffer);
        if (sampleBuffer) {
            AVSampleBufferDisplayLayer *displayLayer = [plugin_ getDisplayLayerForTexture:texId_];
            if (displayLayer) {
                [displayLayer enqueueSampleBuffer:sampleBuffer];
                if (frameCount % 60 == 0) {
                    [plugin_ sendLogToFlutter:@"Native: ✅ Frame enqueued to PiP"];
                }
            } else {
                if (frameCount % 60 == 0) {
                    [plugin_ sendLogToFlutter:@"Native: ❌ No display layer"];
                }
            }
            CFRelease(sampleBuffer);
        } else {
            if (frameCount % 60 == 0) {
                [plugin_ sendLogToFlutter:@"Native: ❌ Failed to create sample buffer"];
            }
        }
        CVPixelBufferRelease(pixelBuffer);
        frameCount++;
    }

    CMSampleBufferRef createSampleBufferFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
        CMVideoFormatDescriptionRef formatDesc;
        OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
        if (status != noErr) {
            [plugin_ sendLogToFlutter:@"Native: ❌ Failed to create format description"];
            return NULL;
        }
        CMTime timestamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        CMSampleTimingInfo timingInfo = {
            .duration = kCMTimeInvalid,
            .presentationTimeStamp = timestamp,
            .decodeTimeStamp = kCMTimeInvalid
        };
        CMSampleBufferRef sampleBuffer;
        status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, formatDesc, &timingInfo, &sampleBuffer);
        CFRelease(formatDesc);
        if (status != noErr) {
            [plugin_ sendLogToFlutter:@"Native: ❌ Failed to create sample buffer"];
            return NULL;
        }
        return sampleBuffer;
    }

private:
    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
    __weak FvpPlugin* plugin_;
};

@interface FvpPlugin () <AVPictureInPictureControllerDelegate> {
    unordered_map<int64_t, shared_ptr<TexturePlayer>> players;
}
@property(readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
@property(strong, nonatomic) NSMutableDictionary<NSNumber*, AVPictureInPictureController*>* pipControllers;
@property(strong, nonatomic) NSMutableDictionary<NSNumber*, AVSampleBufferDisplayLayer*>* pipLayers;
@property(strong, nonatomic) NSMutableDictionary<NSNumber*, UIView*>* pipDummyViews;
@property(strong, nonatomic) FlutterMethodChannel* channel;
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
#if TARGET_OS_OSX
    _texRegistry = registrar.textures;
#else
    _texRegistry = [registrar textures];
#endif
    _pipControllers = [NSMutableDictionary dictionary];
    _pipLayers = [NSMutableDictionary dictionary];
    _pipDummyViews = [NSMutableDictionary dictionary];
    _channel = [FlutterMethodChannel methodChannelWithName:@"fvp" binaryMessenger:[registrar messenger]];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"CreateRT"]) {
        const auto handle = ((NSNumber*)call.arguments[@"player"]).longLongValue;
        const auto width = ((NSNumber*)call.arguments[@"width"]).intValue;
        const auto height = ((NSNumber*)call.arguments[@"height"]).intValue;
        auto player = make_shared<TexturePlayer>(handle, width, height, _texRegistry, self);
        players[player->textureId()] = player;
        result(@(player->textureId()));
    } else if ([call.method isEqualToString:@"ReleaseRT"]) {
        const auto texId = ((NSNumber*)call.arguments[@"texture"]).longLongValue;
        [_texRegistry unregisterTexture:texId];
        players.erase(texId);
        [self cleanupPipForTextureId:texId];
        result(nil);
    } else if ([call.method isEqualToString:@"MixWithOthers"]) {
        [[maybe_unused]] const auto value = ((NSNumber*)call.arguments[@"value"]).boolValue;
#if TARGET_OS_OSX
#else
        if (value) {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        } else {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        }
#endif
        result(nil);
    } else if ([call.method isEqualToString:@"enablePipForTexture"]) {
        [self sendLogToFlutter:@"🔧 PiP: enablePipForTexture called"];
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            [self sendLogToFlutter:@"❌ PiP: Picture-in-Picture not supported"];
            result([FlutterError errorWithCode:@"NOT_SUPPORTED" message:@"PiP not supported" details:nil]);
            return;
        }
        NSNumber *textureIdNum = call.arguments[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        auto it = players.find(textureId);
        if (it == players.end()) {
            [self sendLogToFlutter:@"❌ PiP: Texture not found"];
            result([FlutterError errorWithCode:@"NO_TEXTURE" message:@"Texture not found" details:nil]);
            return;
        }
        int width = [call.arguments[@"width"] intValue] ?: 640;
        int height = [call.arguments[@"height"] intValue] ?: 360;
        AVSampleBufferDisplayLayer *displayLayer = [AVSampleBufferDisplayLayer layer];
        displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        displayLayer.frame = CGRectMake(0, 0, width, height);
        displayLayer.hidden = YES;
        UIView *dummyView = [[UIView alloc] initWithFrame:displayLayer.frame];
        [dummyView.layer addSublayer:displayLayer];
        dummyView.hidden = YES;
        [[UIApplication sharedApplication].windows.firstObject.rootViewController.view addSubview:dummyView];
        [_pipLayers setObject:displayLayer forKey:@(textureId)];
        [_pipDummyViews setObject:dummyView forKey:@(textureId)];
        [self sendLogToFlutter:@"✅ PiP: Created display layer for texture"];
        result(@YES);
    } else if ([call.method isEqualToString:@"enterPipMode"]) {
        NSNumber *textureIdNum = call.arguments[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        [self sendLogToFlutter:[NSString stringWithFormat:@"🔧 PiP: enterPipMode called - textureId: %lld, size: %@x%@", textureId, call.arguments[@"width"], call.arguments[@"height"]]];
        AVSampleBufferDisplayLayer *displayLayer = [_pipLayers objectForKey:@(textureId)];
        if (!displayLayer) {
            [self sendLogToFlutter:@"❌ PiP: No display layer"];
            result([FlutterError errorWithCode:@"NO_LAYER" message:@"PiP not enabled" details:nil]);
            return;
        }
        AVPictureInPictureControllerContentSource *contentSource;
        if (@available(iOS 15.0, *)) {
            FvpPipPlaybackDelegate *playbackDelegate = [[FvpPipPlaybackDelegate alloc] initWithPlugin:self];
            contentSource = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:displayLayer playbackDelegate:playbackDelegate];
        } else {
            [self sendLogToFlutter:@"❌ PiP: iOS 15+ required for SampleBufferDisplayLayer"];
            result([FlutterError errorWithCode:@"UNSUPPORTED_OS" message:@"iOS 15+ required" details:nil]);
            return;
        }
        AVPictureInPictureController *pipController = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
        if (!pipController) {
            [self sendLogToFlutter:@"❌ PiP: Failed to create AVPictureInPictureController"];
            result(@NO);
            return;
        }
        pipController.delegate = self;
        if (@available(iOS 14.2, *)) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
            [self sendLogToFlutter:@"✅ PiP: Auto-PiP enabled"];
        }
        [_pipControllers setObject:pipController forKey:@(textureId)];
        if (pipController.isPictureInPicturePossible) {
            [pipController startPictureInPicture];
            [self sendLogToFlutter:@"✅ PiP: Started Picture-in-Picture"];
            result(@YES);
        } else {
            [self sendLogToFlutter:@"❌ PiP: Not possible"];
            result(@NO);
        }
    } else if ([call.method isEqualToString:@"exitPipMode"]) {
        [self sendLogToFlutter:@"🔧 PiP: exitPipMode called"];
        NSNumber *textureIdNum = call.arguments[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        AVPictureInPictureController *pipController = [_pipControllers objectForKey:@(textureId)];
        if (pipController) {
            [self sendLogToFlutter:[NSString stringWithFormat:@"🔧 PiP: Found controller, stopping Picture-in-Picture for texture %lld", textureId]];
            [self sendLogToFlutter:[NSString stringWithFormat:@"🔧 PiP: Is PiP active before stop: %@", pipController.isPictureInPictureActive ? @"YES" : @"NO"]];
            [pipController stopPictureInPicture];
            [self sendLogToFlutter:[NSString stringWithFormat:@"✅ PiP: stopPictureInPicture called for texture %lld", textureId]];
        } else {
            [self sendLogToFlutter:@"⚠️ PiP: No controller found for texture"];
        }
        result(@YES);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)controller {
    [self sendLogToFlutter:@"🔄 PiP: Will start"];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    [self sendLogToFlutter:@"✅ PiP: Did start"];
    [self.channel invokeMethod:@"onPipStateChanged" arguments:@YES];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)controller {
    [self sendLogToFlutter:@"🔄 PiP: Will stop"];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    [self sendLogToFlutter:@"✅ PiP: Did stop"];
    [self.channel invokeMethod:@"onPipStateChanged" arguments:@NO];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    [self sendLogToFlutter:[NSString stringWithFormat:@"❌ PiP: Failed to start: %@", error.localizedDescription]];
    if (error.code == -1001) {
        [self sendLogToFlutter:@"Native: Error - PiP already active"];
    } else if (error.code == -1002) {
        [self sendLogToFlutter:@"Native: Error - PiP disabled"];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    [self sendLogToFlutter:@"🔄 PiP: Restore UI for stop"];
    NSError *error;
    if (![[AVAudioSession sharedInstance] setActive:YES withOptions:0 error:&error]) {
        [self sendLogToFlutter:[NSString stringWithFormat:@"Native: Failed to reactivate audio: %@", error.localizedDescription]];
    }
    completionHandler(YES);
}

- (AVSampleBufferDisplayLayer*)getDisplayLayerForTexture:(int64_t)textureId {
    return [_pipLayers objectForKey:@(textureId)];
}

- (AVPictureInPictureController*)getPipControllerForTexture:(int64_t)textureId {
    return [_pipControllers objectForKey:@(textureId)];
}

- (void)sendLogToFlutter:(NSString*)message {
    NSLog(@"%@", message);
    [self.channel invokeMethod:@"nativeLog" arguments:message];
}

- (void)cleanupPipForTextureId:(int64_t)textureId {
    NSNumber *key = @(textureId);
    AVPictureInPictureController *pipController = [_pipControllers objectForKey:key];
    if (pipController && pipController.isPictureInPictureActive) {
        [pipController stopPictureInPicture];
        [self sendLogToFlutter:[NSString stringWithFormat:@"🧹 PiP: Stopped controller for texture %lld", textureId]];
    }
    [_pipControllers removeObjectForKey:key];
    [_pipLayers removeObjectForKey:key];
    UIView *dummyView = [_pipDummyViews objectForKey:key];
    if (dummyView) {
        [dummyView removeFromSuperview];
        [_pipDummyViews removeObjectForKey:key];
    }
    [self sendLogToFlutter:[NSString stringWithFormat:@"🧹 PiP: Cleaned up resources for texture %lld", textureId]];
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    players.clear();
    for (auto& pair : players) {
        [self cleanupPipForTextureId:pair.first];
    }
}

#if TARGET_OS_OSX
#else
- (void)applicationWillTerminate:(UIApplication *)application {
    players.clear();
    for (auto& pair : players) {
        [self cleanupPipForTextureId:pair.first];
    }
}
#endif
@end
