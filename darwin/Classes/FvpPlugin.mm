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
#import <AVKit/AVKit.h>  // For PiP
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
    std::mutex mtx; // ensure whole frame render pass commands are recorded before blitting
}
- (instancetype)initWithWidth:(int)width height:(int)height
{
    self = [super init];
    if (self) {
        device = MTLCreateSystemDefaultDevice();
        cmdQueue = [device newCommandQueue];
        auto td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        texture = [device newTextureWithDescriptor:td];
        //assert(!texture.iosurface); // CVPixelBufferCreateWithIOSurface(fltex.iosurface)
        auto attr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attr, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
        auto iosurface_props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attr, kCVPixelBufferIOSurfacePropertiesKey, iosurface_props); // optional?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attr, &pixbuf);
        CFRelease(attr);
        texCache = nullptr;
#if (USE_TEXCACHE + 0)
        CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &texCache);
        CVMetalTextureRef cvtex;
        CVMetalTextureCacheCreateTextureFromImage(nil, texCache, pixbuf, nil, MTLPixelFormatBGRA8Unorm, width, height, 0, &cvtex);
        fltex = CVMetalTextureGetTexture(cvtex);
        CFRelease(cvtex);
#else
        auto iosurface = CVPixelBufferGetIOSurface(pixbuf);
        td.usage = MTLTextureUsageShaderRead; // Unknown?
// macos: failed assertion `Texture Descriptor Validation IOSurface textures must use MTLStorageModeManaged or MTLStorageModeShared'
// ios: failed assertion `Texture Descriptor Validation IOSurface textures must use MTLStorageModeShared
        fltex = [device newTextureWithDescriptor:td iosurface:iosurface plane:0];
#endif
    }
    return self;
}
- (void)dealloc {
    if (pixbuf) {
        CVPixelBufferRelease(pixbuf);
    }
    if (texCache) {
        CFRelease(texCache);
    }
}
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    //return CVPixelBufferRetain(pixbuf);
    std::lock_guard<std::mutex> lock(mtx);
    auto cmdbuf = [cmdQueue commandBuffer];
    auto blit = [cmdbuf blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(texture.width, texture.height, texture.depth)
        toTexture:fltex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)]; // macos 10.15
    [blit endEncoding];
    [cmdbuf commit];
    return CVPixelBufferRetain(pixbuf);
}
@end

// NEW: AVSampleBufferDisplayLayer for PiP (hidden, frame-fed from FFmpeg)
@interface PipDisplayLayer : NSObject
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, assign) int64_t textureId;
@end
@implementation PipDisplayLayer
- (instancetype)initWithTextureId:(int64_t)textureId {
    self = [super init];
    if (self) {
        _textureId = textureId;
        _displayLayer = [AVSampleBufferDisplayLayer layer];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _displayLayer.hidden = YES;  // Hidden for PiP only
        _displayLayer.frame = CGRectZero;  // Offscreen
    }
    return self;
}
- (void)dealloc {
    if (_displayLayer.superlayer) {
        [_displayLayer removeFromSuperlayer];
    }
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
            std::lock_guard<std::mutex> lock(mtex_->mtx);
            renderVideo();
            [texReg textureFrameAvailable:texId_];
            
            // NEW: Bridge to AVSampleBufferDisplayLayer for PiP
            bridgeFrameToPipLayer();
        });
        pipLayer = nil;  // Initialize
    }
    ~TexturePlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
        if (pipLayer) {
            [pipLayer.displayLayer removeFromSuperlayer];
            pipLayer = nil;
        }
    }
    int64_t textureId() const { return texId_; }
    
    // NEW: Bridge FFmpeg frame to AVSampleBufferDisplayLayer
    void bridgeFrameToPipLayer() {
        if (!pipLayer || !pipLayer.displayLayer) return;
        
        CVPixelBufferRef pixbuf = mtex_->pixbuf;  // From FFmpeg decode
        if (!pixbuf) return;
        
        // Create CMSampleBuffer from pixbuf (timing from FFmpeg PTS)
        CMSampleTimingInfo timing = { .presentationTimeStamp = kCMTimeInvalid, .duration = kCMTimeInvalid, .decodeTimeStamp = kCMTimeInvalid };  // Get from FFmpeg (e.g., frame->pts)
        // Assume getFrameTiming() from mdk (adapt as needed)
        CMVideoFormatDescriptionRef formatDesc;
        OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixbuf, &formatDesc);
        if (status != noErr) return;
        
        CMSampleBufferRef sampleBuffer;
        status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixbuf, formatDesc, &timing, &sampleBuffer);
        CFRelease(formatDesc);
        if (status != noErr || !sampleBuffer) return;
        
        [pipLayer.displayLayer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
    
private:
    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
    PipDisplayLayer *pipLayer = nil;  // NEW: For PiP
};

@interface FvpPlugin () {
    std::unordered_map<int64_t, std::shared_ptr<TexturePlayer>> players;
}
@property (readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
@end

@implementation FvpPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
#if TARGET_OS_OSX
    auto messenger = registrar.messenger;
#else
    auto messenger = [registrar messenger];
    // Allow audio playback when the Ring/Silent switch is set to silent
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
#endif
    FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"fvp" binaryMessenger:messenger];
    FvpPlugin* instance = [[FvpPlugin alloc] initWithRegistrar:registrar];
#if TARGET_OS_OSX
#else
    [registrar addApplicationDelegate:instance];
#endif
    [registrar publish:instance];
    [registrar addMethodCallDelegate:instance channel:channel];
    SetGlobalOption("MDK_KEY", "C03BFF5306AB39058A767105F82697F42A00FE970FB0E641D306DEFF3F220547E5E5377A3C504DC30D547890E71059BC023A4DD91
