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
        
        //_codec = avcodec_find_encoder_by_name([outputCodec UTF8String]);
        //_codec = avcodec_find_encoder();
        self.stream = avformat_new_stream(outputFile.formatContext, NULL);
        [outputFile addOutputStream:self];
    }
    return self;
}

- (void) setupVideoContextWithWidth:(int)width height:(int)height {
    AVCodecContext *c = self.stream->codec;
    avcodec_get_context_defaults3(c, NULL);
    c->codec_id = CODEC_ID_H264;
    c->width    = width;
	c->height   = height;
    c->time_base.den = 30;
	c->time_base.num = 1;
    c->pix_fmt       = PIX_FMT_YUV420P;
	if (self.parentFile.formatContext->oformat->flags & AVFMT_GLOBALHEADER)
		c->flags |= CODEC_FLAG_GLOBAL_HEADER;
}

@end