// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define USE_TEXCACHE 0

#import "FvpPlugin.h"
#include "mdk/RenderAPI.h"
#include "mdk/Player.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <mutex>
#include <unordered_map>
#include <iostream>
#include <libavutil/frame.h> // For AVFrame conversion
#include <libavutil/imgutils.h> // For frame copy

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
    mutex mtx; // ensure whole frame render pass commands are recorded before blitting
}

- (instancetype)initWithWidth:(int)width height:(int)height
{
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
    if (texCache)
        CFRelease(texCache);
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

class TexturePlayer final: public Player
{
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

    int64_t textureId() const { return texId_;}
private:
    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
};

@interface FvpPlugin () {
    unordered_map<int64_t, shared_ptr<TexturePlayer>> players;
    NSMutableDictionary<NSNumber*, AVPictureInPictureController*> *pipControllers;
    NSMutableDictionary<NSNumber*, AVSampleBufferDisplayLayer*> *displayLayers;
    NSMutableDictionary<NSNumber*, UIView*> *dummyViews;
}
@property(readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
@property(readonly, strong, nonatomic) FlutterMethodChannel* channel;
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
    _channel = [FlutterMethodChannel methodChannelWithName:@"fvp" binaryMessenger:[registrar messenger]];
    pipControllers = [NSMutableDictionary new];
    displayLayers = [NSMutableDictionary new];
    dummyViews = [NSMutableDictionary new];
    return self;
}

- (void)sendLog:(NSString*)message {
    [_channel invokeMethod:@"nativeLog" arguments:message];
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
        [pipControllers removeObjectForKey:@(texId)];
        [displayLayers removeObjectForKey:@(texId)];
        [dummyViews[@(texId)] removeFromSuperview];
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
    } else if ([call.method isEqualToString:@"isPipSupported"]) {
        bool isSupported = NO;
#if !TARGET_OS_OSX
        if (@available(iOS 14.0, *)) {
            isSupported = [AVPictureInPictureController isPictureInPictureSupported];
        }
#endif
        [self sendLog:[NSString stringWithFormat:@"Native: PiP supported: %d", isSupported]];
        result(@(isSupported));
    } else if ([call.method isEqualToString:@"enablePiP"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        if (!textureIdNum) {
            [self sendLog:@"Native: ❌ Missing textureId for enablePiP"];
            result([FlutterError errorWithCode:@"INVALID_ARGS" message:@"Missing textureId" details:nil]);
            return;
        }
        int64_t textureId = [textureIdNum longLongValue];
        auto it = players.find(textureId);
        if (it == players.end()) {
            [self sendLog:[NSString stringWithFormat:@"Native: ❌ No player for texture %lld", textureId]];
            result(@NO);
            return;
        }
        shared_ptr<TexturePlayer> texPlayer = it->second;
        [self sendLog:[NSString stringWithFormat:@"Native: Found player for texture %lld", textureId]];
        
        // Setup AVSampleBufferDisplayLayer for PiP
        AVSampleBufferDisplayLayer *displayLayer = [AVSampleBufferDisplayLayer new];
        displayLayer.bounds = CGRectMake(0, 0, texPlayer->videoWidth(), texPlayer->videoHeight());
        displayLayer.position = CGPointMake(CGRectGetMidX(displayLayer.bounds), CGRectGetMidY(displayLayer.bounds));
        displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        
        // Hidden dummy view
        UIView *dummyView = [[UIView alloc] initWithFrame:displayLayer.bounds];
        dummyView.hidden = YES;
        [dummyView.layer addSublayer:displayLayer];
        [[UIApplication sharedApplication].keyWindow.rootViewController.view addSubview:dummyView];
        
        // Store for cleanup
        displayLayers[@(textureId)] = displayLayer;
        dummyViews[@(textureId)] = dummyView;
        
        // Bridge FFmpeg frames to CMSampleBuffer
        __weak typeof(self) weakSelf = self;
        texPlayer->setRenderCallback([weakSelf, displayLayer, textureId](void* opaque) {
            // Get AVFrame from mdk::Player
            MediaInfo info;
            uint8_t* frameData[8] = {NULL};
            int linesize[8] = {0};
            texPlayer->getVideoFrame(&frameData[0], &linesize[0], &info); // Adapt from mdk API
            
            // Convert to CVPixelBuffer (simplified; assumes RGBA/BGRA)
            CVPixelBufferRef pixelBuffer;
            CVPixelBufferCreate(kCFAllocatorDefault, info.video[0].width, info.video[0].height, kCVPixelFormatType_32BGRA, NULL, &pixelBuffer);
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            uint8_t *dst = (uint8_t*)CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
            for (int h = 0; h < info.video[0].height; h++) {
                memcpy(dst + h * dstStride, frameData[0] + h * linesize[0], linesize[0]);
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            
            // Create CMSampleBuffer
            CMSampleTimingInfo timingInfo = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
            CMVideoFormatDescriptionRef formatDesc;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
            CMSampleBufferRef sampleBuffer;
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timingInfo, &sampleBuffer);
            CFRelease(formatDesc);
            
            // Enqueue
            [displayLayer enqueueSampleBuffer:sampleBuffer];
            CFRelease(sampleBuffer);
            CVPixelBufferRelease(pixelBuffer);
            
            [weakSelf sendLog:@"Native: Enqueued frame to AVSampleBufferDisplayLayer"];
        });
        
        // Create PiP controller
        AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:displayLayer placeholderImage:nil];
        AVPictureInPictureController *pipController = [[AVPictureInPictureController alloc] initWithContentSource:source];
        if (!pipController) {
            [self sendLog:@"Native: ❌ Failed to create PiP controller"];
            result(@NO);
            return;
        }
        pipController.delegate = self;
        if (@available(iOS 14.2, *)) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
            [self sendLog:@"Native: Automatic PiP enabled"];
        }
        pipControllers[@(textureId)] = pipController;
        [self sendLog:[NSString stringWithFormat:@"Native: ✅ PiP enabled for texture %lld", textureId]];
        result(@YES);
    } else if ([call.method isEqualToString:@"enterPipMode"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        AVPictureInPictureController *pipController = pipControllers[@(textureId)];
        if (pipController && pipController.isPictureInPicturePossible) {
            [self sendLog:@"Native: ✅ Starting PiP"];
            [pipController startPictureInPicture];
            result(@YES);
        } else {
            [self sendLog:[NSString stringWithFormat:@"Native: ❌ Cannot start PiP for texture %lld", textureId]];
            result(@NO);
        }
    } else if ([call.method isEqualToString:@"exitPipMode"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        AVPictureInPictureController *pipController = pipControllers[@(textureId)];
        if (pipController && pipController.isPictureInPictureActive) {
            [self sendLog:@"Native: Stopping PiP"];
            [pipController stopPictureInPicture];
        }
        [self sendLog:[NSString stringWithFormat:@"Native: ✅ PiP exited for texture %lld", textureId]];
        result(@YES);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    players.clear();
    [pipControllers removeAllObjects];
    [displayLayers removeAllObjects];
    for (UIView *view in [dummyViews allValues]) {
        [view removeFromSuperview];
    }
}

#if TARGET_OS_OSX
#else
- (void)applicationWillTerminate:(UIApplication *)application {
    players.clear();
    [pipControllers removeAllObjects];
    [displayLayers removeAllObjects];
    for (UIView *view in [dummyViews allValues]) {
        [view removeFromSuperview];
    }
}
#endif

// MARK: - AVPictureInPictureControllerDelegate
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [self sendLog:@"Native: PiP will start"];
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    if (error) {
        [self sendLog:[NSString stringWithFormat:@"Native: Failed to activate audio session: %@", error.localizedDescription]];
    }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [self sendLog:@"Native: ✅ PiP did start"];
    [_channel invokeMethod:@"onPipStateChanged" arguments:@YES];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    [self sendLog:[NSString stringWithFormat:@"Native: ❌ PiP failed to start: %@", error.localizedDescription]];
    if (error.code == -1001) {
        [self sendLog:@"Native: Error - PiP already active in another app"];
    } else if (error.code == -1002) {
        [self sendLog:@"Native: Error - PiP disabled in Settings"];
    }
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [self sendLog:@"Native: PiP will stop"];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [self sendLog:@"Native: ✅ PiP did stop"];
    [_channel invokeMethod:@"onPipStateChanged" arguments:@NO];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    [self sendLog:@"Native: Restore UI for PiP stop"];
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    if (error) {
        [self sendLog:[NSString stringWithFormat:@"Native: Failed to reactivate audio session: %@", error.localizedDescription]];
    }
    completionHandler(YES);
}

@end
