//
//  FFBitstreamFilter.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFBitstreamFilter.h"

@implementation FFBitstreamFilter
@synthesize bitstreamFilterContext;

- (void) dealloc {
    av_bitstream_filter_close(bitstreamFilterContext);
}

- (id) initWithFilterName:(NSString *)filterName {
    if (self = [super init]) {
        self.bitstreamFilterContext = av_bitstream_filter_init([filterName UTF8String]);
    }
    return self;
}

@end
