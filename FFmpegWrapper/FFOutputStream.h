//
//  FFOutputStream.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFStream.h"

@class FFOutputFile, FFFile;

@interface FFOutputStream : FFStream

@property (nonatomic) int64_t lastMuxDTS;
@property (nonatomic) int frameNumber;
@property (nonatomic, readonly) AVCodec *codec;

- (id) initWithOutputFile:(FFOutputFile*)outputFile outputCodec:(NSString*)outputCodec;

- (void) setupVideoContextWithWidth:(int)width height:(int)height;
- (void) setupAudioContextWithSampleRate:(int)sampleRate;

@end