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
    c->codec_type = AVMEDIA_TYPE_VIDEO;
    c->width    = width;
	c->height   = height;
    c->time_base.den = 30;
	c->time_base.num = 1;
    c->pix_fmt       = PIX_FMT_YUV420P;
	if (self.parentFile.formatContext->oformat->flags & AVFMT_GLOBALHEADER)
		c->flags |= CODEC_FLAG_GLOBAL_HEADER;
}

- (void) setupAudioContextWithSampleRate:(int)sampleRate {
    AVCodecContext *codecContext = self.stream->codec;
    /* find the audio encoder */
    avcodec_get_context_defaults3(codecContext, NULL);
	codecContext->codec_id = CODEC_ID_AAC;
	codecContext->codec_type = AVMEDIA_TYPE_AUDIO;
    
	//st->id = 1;
	codecContext->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL; // for native aac support
	/* put sample parameters */
	//codecContext->sample_fmt  = AV_SAMPLE_FMT_FLT;
	codecContext->sample_fmt  = AV_SAMPLE_FMT_S16;
	//codecContext->time_base.den = 44100;
	//codecContext->time_base.num = 1;
	//c->bit_rate    = bit_rate;
	codecContext->sample_rate = sampleRate;
	codecContext->channels    = 1;
	NSLog(@"addAudioStream sample_rate %d index %d", codecContext->sample_rate, self.stream->index);
	//LOGI("add_audio_stream parameters: sample_fmt: %d bit_rate: %d sample_rate: %d", codec_audio_sample_fmt, bit_rate, audio_sample_rate);
	// some formats want stream headers to be separate
	if (self.parentFile.formatContext->oformat->flags & AVFMT_GLOBALHEADER)
		codecContext->flags |= CODEC_FLAG_GLOBAL_HEADER;
}

@end