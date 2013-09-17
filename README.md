# FFmpegWrapper

FFmpegWrapper is a lightweight Objective-C wrapper for some FFmpeg libav functions.

## Installation

Note: This project includes [FFmpeg-iOS](https://github.com/chrisballinger/FFmpeg-iOS) as submodule which you will need to build separately.

1. Add this as a git submodule to your project.

		$ git submodule add Submodules/FFmpegWrapper https://github.com/OpenWatch/FFmpegWrapper.git

2. Drag `FFmpegWrapper.xcodeproj` into your project's files.
3. Add `FFmpegWrapper` to your target's Target Dependencies in Build Phases.
4. Add `libFFmpegWrapper.a` to your target's Link Binary with Libraries in Build Phases.

## Usage

`FFmpegWrapper.h` contains the latest documentation so it would be advisable to check there first as this document may be out of date due to rapid development.

Converts file at `inputPath` to a new file at `outputPath` using the parameters specified in the `options` dictionary. The two optional callbacks are for monitoring the progress and completion of a queued task and are always called on the main thread. All calls to this function are currently queued in a synchronous internal dispatch queue.

    - (void) convertInputPath:(NSString*)inputPath outputPath:(NSString*)outputPath options:(NSDictionary*)options progressBlock:(FFmpegWrapperProgressBlock)progressBlock completionBlock:(FFmpegWrapperCompletionBlock)completionBlock;
    
## License

Like [FFmpeg](http://www.ffmpeg.org) itself, this library is LGPL 2.1+.

	FFmpegWrapper
	
	Created by Christopher Ballinger on 9/14/13.
	Copyright (c) 2013 OpenWatch, Inc. All rights reserved.

	FFmpegWrapper is free software; you can redistribute it and/or
	modify it under the terms of the GNU Lesser General Public
	License as published by the Free Software Foundation; either
	version 2.1 of the License, or (at your option) any later version.
	
	FFmpegWrapper is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	Lesser General Public License for more details.
	
	You should have received a copy of the GNU Lesser General Public
	License along with FFmpegWrapper; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA