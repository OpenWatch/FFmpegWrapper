//
//  FFOutputStream.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFOutputStream.h"
#import "FFOutputFile.h"

@implementation FFOutputStream
@synthesize lastMuxDTS, frameNumber;

- (id) initWithOutputFile:(FFOutputFile*)outputFile outputCodec:(NSString*)outputCodec {
    if (self = [super initWithFile:outputFile]) {
        self.lastMuxDTS = AV_NOPTS_VALUE;
        self.frameNumber = 0;
        
        AVCodec *codec = avcodec_find_encoder_by_name([outputCodec UTF8String]);
        self.stream = avformat_new_stream(outputFile.formatContext, codec);
        [outputFile addOutputStream:self];
    }
    return self;
}
@end