//
//  FFFile.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "libavformat/avformat.h"

@interface FFFile : NSObject
@property (nonatomic, strong) NSString *path;
@property (nonatomic, strong) NSDictionary *options;
@property (nonatomic) AVFormatContext *formatContext;
@property (nonatomic) NSArray *streams;

- (id) initWithPath:(NSString*)path options:(NSDictionary*)options;
@end