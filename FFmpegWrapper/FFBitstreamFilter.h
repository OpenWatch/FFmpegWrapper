//
//  FFBitstreamFilter.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "libavcodec/avcodec.h"

@interface FFBitstreamFilter : NSObject

@property (nonatomic) AVBitStreamFilterContext *bitstreamFilterContext;

- (id) initWithFilterName:(NSString*)filterName;

@end
